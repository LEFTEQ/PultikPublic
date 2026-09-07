// pultik — the release counter. `pultik ship` builds an app from its
// release.yaml, drafts release notes (AI when available), and puts the
// artifact + metadata on downloads.example.invalid, where the marketplace picks it up.
//
// Deterministic core: build/upload never needs AI; notes drafting shells out
// to `claude -p` only when asked (default when claude is on PATH) and the
// draft is always shown for approval before anything leaves the machine.
package main

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"syscall"
	"time"

	"gopkg.in/yaml.v3"
)

const (
	defaultBase = "https://downloads.example.invalid"
	bold        = "\033[1m"
	dim         = "\033[2m"
	red         = "\033[31m"
	green       = "\033[32m"
	yellow      = "\033[33m"
	cyan        = "\033[36m"
	reset       = "\033[0m"
)

type manifest struct {
	App         string   `yaml:"app"`
	Name        string   `yaml:"name"`
	Icon        string   `yaml:"icon"`
	IconFile    string   `yaml:"icon_file"` // square full-bleed PNG ≥256px — the app's real marketplace icon
	Description string   `yaml:"description"`
	Platform    string   `yaml:"platform"`
	Channel     string   `yaml:"channel"`
	Build       string   `yaml:"build"`
	Artifact    string   `yaml:"artifact"`
	VersionCmd  string   `yaml:"version_cmd"`
	Version     string   `yaml:"version"`
	NotesPaths  []string `yaml:"notes_paths"` // scope AI release notes to these paths (monorepos)
}

type release struct {
	App         string `json:"app"`
	Name        string `json:"name"`
	Icon        string `json:"icon"`
	IconFile    string `json:"icon_file,omitempty"`
	Description string `json:"description"`
	Platform    string `json:"platform"`
	Channel     string `json:"channel"`
	Version     string `json:"version"`
	Artifact    string `json:"artifact"`
	Size        int64  `json:"size"`
	Sha256      string `json:"sha256"`
	Notes       string `json:"notes"`
	Ts          int64  `json:"ts"`
	Commit      string `json:"commit,omitempty"` // git SHA this artifact was built from — the next release's notes window
	URL         string `json:"url,omitempty"`
}

var segmentRe = regexp.MustCompile(`^[a-z0-9][a-z0-9._-]{0,63}$`)

// Progress goes here. Under --json it moves to stderr so stdout carries
// nothing but the result object — an agent can parse stdout blind.
var uiOut io.Writer = os.Stdout

// aiTimeout bounds the notes/manifest drafter. Unbounded, a stuck `claude -p`
// hangs a ship forever inside a CI job or a background agent run.
const aiTimeout = 3 * time.Minute

// interactive reports whether there's a human at stdin. Everything that would
// block — a confirm prompt, an editor — is gated on it: without a terminal
// pultik fails with the flag you should have passed instead of hanging on vi.
func interactive() bool {
	fi, err := os.Stdin.Stat()
	if err != nil || fi.Mode()&os.ModeCharDevice == 0 {
		return false // a pipe, a file, or nothing at all
	}
	// /dev/null is a character device too, so the mode test ALONE calls
	// `pultik ship < /dev/null` interactive — and that is the exact shape of
	// a CI job, a git hook and an agent's shell. Rule it out by device id.
	null, err := os.Stat(os.DevNull)
	if err != nil {
		return true
	}
	in, okIn := fi.Sys().(*syscall.Stat_t)
	dev, okDev := null.Sys().(*syscall.Stat_t)
	return !(okIn && okDev && in.Rdev == dev.Rdev)
}

// aiCommand is the drafting command. PULTIK_AI overrides it, which is how you
// give the drafter credentials it wouldn't otherwise have — e.g.
// PULTIK_AI="switcheroo exec -a work -- claude -p" when the keychain login has
// expired and a bare `claude` can no longer authenticate.
func aiCommand() string {
	if cmd := strings.TrimSpace(os.Getenv("PULTIK_AI")); cmd != "" {
		return cmd
	}
	return "claude -p"
}

// aiAvailable reports whether the drafter can run at all (first word on PATH).
func aiAvailable() bool {
	fields := strings.Fields(aiCommand())
	if len(fields) == 0 {
		return false
	}
	_, err := exec.LookPath(fields[0])
	return err == nil
}

func main() {
	if len(os.Args) < 2 {
		usage()
		os.Exit(2)
	}
	var err error
	switch os.Args[1] {
	case "ship":
		err = ship(os.Args[2:])
	case "init":
		err = initManifest(os.Args[2:])
	case "releases":
		err = listReleases(os.Args[2:])
	case "todo", "schedule", "hook-context":
		// Moved into the vitrinka CLI (2026-09-05): one binary owns the model.
		err = fmt.Errorf("pultik %s is gone — todos live in vitrinka now: vitrinka %s (vitrinka import pultik moves an old vault)", os.Args[1], os.Args[1])
	case "note":
		err = noteCmd(os.Args[2:])
	case "install":
		err = installCmd(os.Args[2:])
	case "doctor":
		err = doctorCmd(os.Args[2:])
	case "version", "--version", "-V":
		fmt.Println("pultik 0.1.0")
	case "help", "--help", "-h":
		usage()
	default:
		usage()
		os.Exit(2)
	}
	if err != nil {
		fmt.Fprintf(os.Stderr, "%s✕ %v%s\n", red, err, reset)
		os.Exit(1)
	}
}

func usage() {
	fmt.Print(`pultik — the release counter

USAGE
  pultik ship [flags]        build + publish the app described by ./release.yaml
  pultik init [--force]      draft a release.yaml for this repo (AI-assisted)
  pultik releases [app]      list what's on the counter (downloads.example.invalid)
  pultik note <cmd>          scratch notes for the panel rail (add/list/rm)
                             (todos + reminders: vitrinka todo | schedule)
  pultik install [flags]     install app + CLI + Claude integration
  pultik doctor [--json]     diagnose the local Pultik installation

  pultik <cmd> --help        flags for that command

SHIP FLAGS
  -f <file>          manifest path (default ./release.yaml)
  --version <v>      override the manifest/derived version
  --channel <c>      override channel (default from manifest, else "stable")
  --notes <mode>     ai | editor | - (stdin) | literal text
                     default: RELEASE_NOTES.md if present, else ai, else editor
  --skip-build       publish the existing artifact without rebuilding
  --dry-run          do everything except upload
  --yes              answer every prompt yes (accept the draft, ship it)
  --allow-overwrite  replace a version already on the counter
  --json             result object on stdout, progress on stderr

CONFIG
  PULTIK_TOKEN     upload bearer token (or ~/.config/pultik/token)
  PULTIK_BASE      server base URL (default ` + defaultBase + `)
  PULTIK_AI        notes/manifest drafting command (default "claude -p"),
                   e.g. "switcheroo exec -a work -- claude -p"

Unattended runs never open an editor and never wait on a prompt: pass --yes
plus a notes source and pultik reports anything missing before it builds.
`)
}

func step(msg string) { fmt.Fprintf(uiOut, "%s▸%s %s\n", cyan, reset, msg) }
func ok(format string, a ...any) {
	fmt.Fprintf(uiOut, "%s✓%s %s\n", green, reset, fmt.Sprintf(format, a...))
}

func shipUsage() {
	fmt.Print(`pultik ship — build + publish the app described by ./release.yaml

FLAGS
  -f <file>          manifest path (default ./release.yaml)
  --version <v>      override the manifest/derived version
  --channel <c>      override channel (default from manifest, else "stable")
  --notes <mode>     ai | editor | - (stdin) | literal text
                     default: RELEASE_NOTES.md if present, else ai when the
                     drafter is available, else editor (needs a terminal)
  --skip-build       publish the existing artifact without rebuilding
  --dry-run          do everything except upload
  --yes              answer every prompt yes: accept the AI draft and ship
  --allow-overwrite  replace a version that is already on the counter
  --json             result object on stdout, progress on stderr

UNATTENDED (CI, hooks, agents)
  There is no terminal to ask, so pultik never opens an editor and never
  waits: pass --yes with a notes source (--notes "…", RELEASE_NOTES.md, or a
  working drafter) and it runs start to finish. Missing pieces are reported
  before the build, not after it.

  PULTIK_AI   drafting command (default "claude -p"). Set this to give the
              drafter credentials, e.g. "switcheroo exec -a work -- claude -p".
`)
}

// ── ship ────────────────────────────────────────────────────────────────────

func ship(args []string) error {
	file := "./release.yaml"
	var overrideVersion, channel, notesMode string
	var skipBuild, dryRun, yes, allowOverwrite, asJSON bool
	notesGiven := false
	for i := 0; i < len(args); i++ {
		switch args[i] {
		case "-f":
			i++
			file = arg(args, i, "-f")
		case "--version":
			i++
			overrideVersion = arg(args, i, "--version")
		case "--channel":
			i++
			channel = arg(args, i, "--channel")
		case "--notes":
			i++
			notesMode = arg(args, i, "--notes")
			notesGiven = true
		case "--skip-build":
			skipBuild = true
		case "--dry-run":
			dryRun = true
		case "--yes":
			yes = true
		case "--allow-overwrite":
			allowOverwrite = true
		case "--json":
			asJSON = true
		case "--help", "-h":
			shipUsage()
			return nil
		default:
			return fmt.Errorf("unknown flag %q (see pultik ship --help)", args[i])
		}
	}
	if asJSON {
		// stdout belongs to the result object from here on.
		uiOut = os.Stderr
	}

	raw, err := os.ReadFile(file)
	if err != nil {
		return fmt.Errorf("no manifest: %w (run from the app repo, or pass -f)", err)
	}
	var m manifest
	if err := yaml.Unmarshal(raw, &m); err != nil {
		return fmt.Errorf("parse %s: %w", file, err)
	}
	if m.App == "" || m.Artifact == "" {
		return fmt.Errorf("%s must set at least `app` and `artifact`", file)
	}
	if !segmentRe.MatchString(m.App) {
		return fmt.Errorf("app id %q must match %s", m.App, segmentRe)
	}
	if m.Name == "" {
		m.Name = m.App
	}
	if channel == "" {
		channel = m.Channel
	}
	if channel == "" {
		channel = "stable"
	}
	dir := filepath.Dir(file)

	// Version: flag > version_cmd > manifest literal.
	version := overrideVersion
	if version == "" && m.VersionCmd != "" {
		out, err := shell(dir, m.VersionCmd)
		if err != nil {
			return fmt.Errorf("version_cmd: %w", err)
		}
		version = strings.TrimSpace(out)
	}
	if version == "" {
		version = m.Version
	}
	if version == "" {
		return fmt.Errorf("no version: set `version`, `version_cmd`, or pass --version")
	}
	version = strings.ToLower(version)
	if !segmentRe.MatchString(version) {
		return fmt.Errorf("version %q must match %s", version, segmentRe)
	}

	fmt.Fprintf(uiOut, "%s%s %s%s %s%s · %s · %s%s\n", bold, m.Icon, m.Name, reset, cyan, version, m.Platform, channel, reset)

	// Refuse to quietly replace a published release. Re-running a ship after a
	// mid-flight failure is normal; overwriting what users already downloaded
	// is not — say so before the build, when it still costs nothing.
	if !allowOverwrite && !dryRun && alreadyShipped(m.App, version) {
		return fmt.Errorf("%s %s is already on the counter — bump the version, or pass --allow-overwrite to replace it", m.Name, version)
	}

	// Notes BEFORE the build: a missing notes source used to surface only
	// after the build had run, which on a notarized macOS app meant throwing
	// away three minutes of Apple's time to learn that vi wasn't available.
	notes, err := resolveNotes(notesMode, notesGiven, dir, m, version, yes)
	if err != nil {
		return err
	}

	if m.Build != "" && !skipBuild {
		step("build: " + m.Build)
		cmd := exec.Command("sh", "-c", m.Build)
		cmd.Dir = dir
		cmd.Stdout = os.Stdout
		cmd.Stderr = os.Stderr
		if err := cmd.Run(); err != nil {
			return fmt.Errorf("build failed: %w", err)
		}
		ok("built")
	} else if m.Build != "" {
		fmt.Fprintf(uiOut, "%s▸ skipping build%s\n", dim, reset)
	}

	// Artifact: newest glob match.
	matches, err := filepath.Glob(filepath.Join(dir, m.Artifact))
	if err != nil || len(matches) == 0 {
		return fmt.Errorf("no artifact matches %s", m.Artifact)
	}
	sort.Slice(matches, func(i, j int) bool {
		fi, _ := os.Stat(matches[i])
		fj, _ := os.Stat(matches[j])
		if fi == nil || fj == nil {
			return false
		}
		return fi.ModTime().After(fj.ModTime())
	})
	artifact := matches[0]
	info, err := os.Stat(artifact)
	if err != nil {
		return err
	}
	sum, err := fileSha256(artifact)
	if err != nil {
		return err
	}
	ok("artifact %s (%s, sha256 %s…)", filepath.Base(artifact), humanSize(info.Size()), sum[:12])

	// Real icon: shipped beside the artifact as icon.png; the marketplace
	// prefers it over the emoji everywhere.
	iconPath := ""
	if m.IconFile != "" {
		iconPath = filepath.Join(dir, m.IconFile)
		if _, err := os.Stat(iconPath); err != nil {
			return fmt.Errorf("icon_file: %w", err)
		}
		if !strings.EqualFold(filepath.Ext(iconPath), ".png") {
			return fmt.Errorf("icon_file must be a PNG (square, full-bleed, ≥256px)")
		}
		ok("icon %s", m.IconFile)
	} else {
		fmt.Fprintf(uiOut, "%s▸ no icon_file — the marketplace shows the emoji fallback%s\n", dim, reset)
	}

	rel := release{
		App: m.App, Name: m.Name, Icon: m.Icon, Description: m.Description,
		Platform: m.Platform, Channel: channel, Version: version,
		Artifact: filepath.Base(artifact), Size: info.Size(), Sha256: sum,
		Notes: notes, Ts: time.Now().Unix(), Commit: headCommit(dir),
	}
	if iconPath != "" {
		rel.IconFile = "icon.png"
	}

	fmt.Fprintf(uiOut, "\n%s%s %s %s%s → %s/%s\n", bold, m.Icon, m.Name, version, reset, baseURL(), m.App)
	if notes != "" {
		fmt.Fprintf(uiOut, "%s%s%s\n", dim, indent(notes), reset)
	}
	if dryRun {
		fmt.Fprintf(uiOut, "%s▸ dry run — nothing uploaded%s\n", dim, reset)
		if asJSON {
			printResult(rel, artifact, true)
		}
		return nil
	}
	if !yes {
		if !interactive() {
			return fmt.Errorf("nothing to confirm with — no terminal on stdin; pass --yes to ship unattended")
		}
		if !confirm("ship it?") {
			return fmt.Errorf("aborted")
		}
	}

	token, err := readToken()
	if err != nil {
		return err
	}
	step("uploading artifact")
	if err := putFile(token, fmt.Sprintf("%s/api/releases/%s/%s/artifact/%s", baseURL(), m.App, version, rel.Artifact), artifact); err != nil {
		return err
	}
	if iconPath != "" {
		step("uploading icon")
		if err := putFile(token, fmt.Sprintf("%s/api/releases/%s/%s/artifact/icon.png", baseURL(), m.App, version), iconPath); err != nil {
			return err
		}
	}
	step("publishing release")
	body, _ := json.Marshal(rel)
	if err := putJSON(token, fmt.Sprintf("%s/api/releases/%s/%s", baseURL(), m.App, version), body); err != nil {
		return err
	}
	ok("shipped — it's on the counter")
	fmt.Fprintf(uiOut, "\n  %smarketplace%s  %s/\n  %sdirect%s       %s/releases/%s/%s/%s\n  %sstable%s       %s/get/%s\n",
		dim, reset, baseURL(),
		dim, reset, baseURL(), m.App, version, rel.Artifact,
		dim, reset, baseURL(), m.App)
	if asJSON {
		printResult(rel, artifact, false)
	}
	return nil
}

// printResult is the machine-readable half of a ship: everything a caller
// would otherwise have to scrape out of decorated prose.
func printResult(rel release, artifactPath string, dryRun bool) {
	out := struct {
		release
		ArtifactPath string `json:"artifact_path"`
		DryRun       bool   `json:"dry_run"`
		Download     string `json:"download"`
		Stable       string `json:"stable"`
		Page         string `json:"page"`
	}{
		release:      rel,
		ArtifactPath: artifactPath,
		DryRun:       dryRun,
		Download:     fmt.Sprintf("%s/releases/%s/%s/%s", baseURL(), rel.App, rel.Version, rel.Artifact),
		Stable:       fmt.Sprintf("%s/get/%s", baseURL(), rel.App),
		Page:         fmt.Sprintf("%s/%s", baseURL(), rel.App),
	}
	b, err := json.MarshalIndent(out, "", "  ")
	if err != nil {
		// Nothing recoverable here, but the ship itself already succeeded —
		// say so on stderr rather than pretending the release didn't happen.
		fmt.Fprintf(os.Stderr, "%s✕ result json: %v%s\n", red, err, reset)
		return
	}
	fmt.Println(string(b))
}

// alreadyShipped reports whether this exact version is on the counter. It
// reads the index, not /api/releases/<app>/<version> — that path isn't an API
// route at all: it falls through to the SPA and answers 200 with HTML for a
// version that was never shipped, so a status-code check would block every
// ship. Unknown (offline, malformed) answers false: never block a release on
// a failed lookup, the upload itself is the backstop.
func alreadyShipped(app, version string) bool {
	client := &http.Client{Timeout: 5 * time.Second}
	resp, err := client.Get(baseURL() + "/api/releases")
	if err != nil {
		return false
	}
	defer resp.Body.Close()
	if resp.StatusCode != 200 {
		return false
	}
	var data struct {
		Apps []struct {
			ID       string    `json:"id"`
			Releases []release `json:"releases"`
		} `json:"apps"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&data); err != nil {
		return false
	}
	for _, a := range data.Apps {
		if a.ID != app {
			continue
		}
		for _, r := range a.Releases {
			if strings.EqualFold(r.Version, version) {
				return true
			}
		}
	}
	return false
}

// ── init ────────────────────────────────────────────────────────────────────

// initManifest drafts a release.yaml for the current repo: deterministic fact
// gathering, AI drafting (claude -p), then parse + validate + confirm before
// anything is written. The contract lives at downloads.example.invalid/docs/shipping.
func initManifest(args []string) error {
	force := false
	for _, a := range args {
		switch a {
		case "--force":
			force = true
		case "--help", "-h":
			fmt.Print(`pultik init — draft a release.yaml for this repo (AI-assisted)

FLAGS
  --force   redraft over an existing release.yaml

  Needs a drafter and a terminal to approve the draft. PULTIK_AI overrides
  the drafting command (default "claude -p"); without one, copy the template
  from ` + baseURL() + `/docs/shipping and write the manifest by hand.
`)
			return nil
		default:
			return fmt.Errorf("unknown flag %q (pultik init --help)", a)
		}
	}
	if _, err := os.Stat("release.yaml"); err == nil && !force {
		return fmt.Errorf("release.yaml already exists — pass --force to redraft")
	}
	if !aiAvailable() {
		return fmt.Errorf("init drafts with AI and needs %q available (set PULTIK_AI to override) — or copy the template from %s/docs/shipping", aiCommand(), baseURL())
	}
	if !interactive() {
		return fmt.Errorf("init shows the draft for approval and needs a terminal — run it interactively, or write release.yaml from %s/docs/shipping", baseURL())
	}

	step("inspecting the repo")
	facts := repoFacts(".")
	fmt.Printf("%s%s%s\n", dim, indent(facts), reset)

	step("drafting release.yaml (claude)")
	prompt := fmt.Sprintf(`Draft a pultik release.yaml manifest for this repo. Output ONLY the YAML, no fences, no commentary.

The contract (all paths relative to the repo root):
  app:          marketplace id, [a-z0-9._-], derived from the repo/product name
  name:         display name
  icon:         one emoji fallback
  icon_file:    path to a square full-bleed PNG >=256px if the repo has a real app icon (omit if none)
  description:  one terse line, user-facing
  platform:     macos | ios | android | chrome | windows | linux | web
  channel:      stable
  build:        shell command that produces the artifact (use an existing dist script if the repo has one; if none exists, write the most plausible one-liner and mark it with a "# TODO verify" comment)
  artifact:     glob matching the built artifact
  version_cmd:  shell one-liner printing the version from the repo's own source of truth (package.json / tauri.conf.json / Project.swift / git tag). Use a literal version: 0.1.0 only when there is no source of truth.
  notes_paths:  only for monorepos — the subtree(s) this app lives in

Repo facts:
%s`, facts)
	out, diag, err := shellTimeout(".", aiCommand()+" "+shellQuote(prompt), aiTimeout)
	if err != nil {
		return fmt.Errorf("%s: %w\n  %s", aiCommand(), err, indent(diag))
	}
	draft := stripFences(strings.TrimSpace(out))
	var m manifest
	if err := yaml.Unmarshal([]byte(draft), &m); err != nil {
		return fmt.Errorf("AI draft is not valid YAML: %w\n%s", err, draft)
	}
	if m.App == "" || m.Artifact == "" || m.Build == "" {
		return fmt.Errorf("AI draft is missing app/build/artifact:\n%s", draft)
	}
	if !segmentRe.MatchString(m.App) {
		return fmt.Errorf("drafted app id %q must match %s:\n%s", m.App, segmentRe, draft)
	}
	if m.IconFile != "" {
		if _, err := os.Stat(m.IconFile); err != nil {
			fmt.Printf("%s▸ drafted icon_file %s does not exist — dropping it%s\n", yellow, m.IconFile, reset)
			draft = dropLine(draft, "icon_file:")
		}
	}

	fmt.Printf("\n%s\n\n", draft)
	if !confirm("write release.yaml? (review the build command before your first ship)") {
		return fmt.Errorf("aborted")
	}
	if err := os.WriteFile("release.yaml", []byte(draft+"\n"), 0o644); err != nil {
		return err
	}
	ok("release.yaml written — try: pultik ship --dry-run")
	return nil
}

// repoFacts gathers the deterministic evidence the AI drafts from.
func repoFacts(dir string) string {
	var b strings.Builder
	add := func(label, cmd string) {
		out, err := shell(dir, cmd)
		out = strings.TrimSpace(out)
		if err != nil || out == "" {
			return
		}
		if len(out) > 800 {
			out = out[:800] + "…"
		}
		fmt.Fprintf(&b, "%s:\n%s\n\n", label, out)
	}
	add("top-level files", "ls -1")
	add("git remote", "git remote get-url origin")
	add("package.json (name/version/scripts)", `[ -f package.json ] && node -p "const p=require('./package.json');JSON.stringify({name:p.name,version:p.version,scripts:Object.keys(p.scripts||{})})"`)
	add("tauri configs", "find . -maxdepth 4 -name tauri.conf.json -not -path '*/node_modules/*' -not -path '*/.*'")
	add("xcode projects", "ls -d *.xcodeproj *.xcworkspace Project.swift 2>/dev/null")
	add("go module", "[ -f go.mod ] && head -1 go.mod")
	add("dist/build scripts", "find . -maxdepth 3 \\( -name 'dist*.sh' -o -name 'build*.sh' -o -path '*/tools/dist*' \\) -not -path '*/node_modules/*' -not -path '*/.*'")
	add("icon candidates", "find . -maxdepth 5 \\( -iname '*icon*.png' -o -iname '*icon*.icns' \\) -not -path '*/node_modules/*' -not -path '*/.*' -not -path '*/DerivedData/*' | head -10")
	add("marketing version hints", "grep -l CFBundleShortVersionString Project.swift */Info.plist 2>/dev/null | head -3")
	return b.String()
}

// stripFences removes a ```yaml … ``` wrapper if the model added one anyway.
func stripFences(s string) string {
	if !strings.HasPrefix(s, "```") {
		return s
	}
	if i := strings.Index(s, "\n"); i >= 0 {
		s = s[i+1:]
	}
	if i := strings.LastIndex(s, "```"); i >= 0 {
		s = s[:i]
	}
	return strings.TrimSpace(s)
}

// dropLine removes the line starting with prefix from a YAML draft.
func dropLine(s, prefix string) string {
	lines := strings.Split(s, "\n")
	kept := lines[:0]
	for _, l := range lines {
		if !strings.HasPrefix(strings.TrimSpace(l), prefix) {
			kept = append(kept, l)
		}
	}
	return strings.Join(kept, "\n")
}

// ── notes ───────────────────────────────────────────────────────────────────

func resolveNotes(mode string, given bool, dir string, m manifest, version string, yes bool) (string, error) {
	// A hand-written RELEASE_NOTES.md beside the manifest beats the AI draft —
	// write it, ship, delete it. Checked whether or not a drafter exists: it
	// used to be consulted only on the "ai" path, so on a machine without
	// claude the mode fell to "editor" and the file you wrote was ignored.
	if !given || mode == "ai" {
		if b, err := os.ReadFile(filepath.Join(dir, "RELEASE_NOTES.md")); err == nil && len(strings.TrimSpace(string(b))) > 0 {
			ok("notes from RELEASE_NOTES.md")
			return strings.TrimSpace(string(b)), nil
		}
	}

	if !given {
		switch {
		case aiAvailable():
			mode = "ai"
		case interactive():
			mode = "editor"
		default:
			// Fail here, before the build — this is the case that used to
			// open vi in a pipeline and take the whole ship down with it.
			return "", fmt.Errorf("no notes source: %q isn't on PATH and there's no terminal to open an editor.\n"+
				"  Pass --notes \"…\", write RELEASE_NOTES.md next to the manifest, or set PULTIK_AI to a working drafter", aiCommand())
		}
	}

	switch mode {
	case "ai":
		return aiNotes(dir, m, version, yes)
	case "editor":
		return editorNotes("")
	case "-":
		b, err := io.ReadAll(os.Stdin)
		return strings.TrimSpace(string(b)), err
	default:
		return mode, nil // literal text
	}
}

// notesLog returns the commit log feeding the AI draft: commits since the
// app's last shipped release when the server knows one (falling back to the
// last 30), scoped to notes_paths in monorepos.
// It returns fresh=false when the app has shipped before and nothing has
// landed since — previously that case silently fell back to the last 30
// commits, so the draft re-announced work that shipped releases ago.
//
// The window is the previous release's commit when there is one: `<sha>..HEAD`
// is the exact set of commits this release adds. The date window it replaces
// is only an approximation — a commit authored before the last ship but merged
// after it (rebase, squash, cherry-pick, a long-lived branch) sits outside
// `--since` and would silently go unmentioned.
func notesLog(dir string, m manifest) (log string, fresh bool) {
	prev := lastShipped(m.App)
	logCmd := "git log --oneline --no-decorate -n 30"
	switch {
	case prev.Commit != "" && haveCommit(dir, prev.Commit):
		logCmd = "git log --oneline --no-decorate -n 100 " + shellQuote(prev.Commit) + "..HEAD"
	case prev.Ts > 0:
		// Shipped before this field existed, or from a different clone.
		logCmd = fmt.Sprintf("git log --oneline --no-decorate -n 100 --since=%s", time.Unix(prev.Ts, 0).Format(time.RFC3339))
	}
	if len(m.NotesPaths) > 0 {
		quoted := make([]string, len(m.NotesPaths))
		for i, p := range m.NotesPaths {
			quoted[i] = shellQuote(p)
		}
		logCmd += " -- " + strings.Join(quoted, " ")
	}
	out, _ := shell(dir, logCmd)
	if strings.TrimSpace(out) == "" {
		if prev.Ts > 0 {
			return "", false
		}
		// Never shipped: the window is the whole history, not an empty set.
		out, _ = shell(dir, "git log --oneline --no-decorate -n 30")
	}
	return out, strings.TrimSpace(out) != ""
}

// lastShipped is the app's most recent release as the server knows it; a zero
// value means never shipped, offline, or an answer we couldn't read.
func lastShipped(app string) release {
	client := &http.Client{Timeout: 5 * time.Second}
	resp, err := client.Get(baseURL() + "/api/releases/" + app + "/latest")
	if err != nil {
		return release{}
	}
	defer resp.Body.Close()
	if resp.StatusCode != 200 {
		return release{}
	}
	var rel release
	if err := json.NewDecoder(resp.Body).Decode(&rel); err != nil {
		return release{}
	}
	return rel
}

// haveCommit reports whether this clone actually contains that commit — a
// shallow checkout or a fresh clone of a rewritten history won't, and
// `<sha>..HEAD` against a missing object is a hard git error, not an empty log.
func haveCommit(dir, sha string) bool {
	_, err := shell(dir, "git cat-file -e "+shellQuote(sha)+"^{commit} 2>/dev/null")
	return err == nil
}

// headCommit is the SHA the artifact is built from, stamped into the release
// so the next one knows exactly where its notes start. Empty outside a repo.
func headCommit(dir string) string {
	out, err := shell(dir, "git rev-parse HEAD 2>/dev/null")
	if err != nil {
		return ""
	}
	return strings.TrimSpace(out)
}

func aiNotes(dir string, m manifest, version string, yes bool) (string, error) {
	log, fresh := notesLog(dir, m)
	if !fresh {
		// Nothing new since the last release — a rebuild of the same code.
		// Drafting here is what produced notes describing already-shipped
		// work, because the empty window silently widened to the last 30
		// commits. Ship with no notes instead of inventing a changelog.
		step("no commits since the last release — shipping without notes")
		return "", nil
	}

	step("drafting release notes (" + aiCommand() + ")")
	// "Output ONLY …" matters as much here as it does for init: without it a
	// capable drafter answers conversationally — preamble, headings, fenced
	// blocks, questions back — and all of it lands verbatim on the shelf.
	prompt := fmt.Sprintf(
		"Write release notes for %s %s (%s app). Output ONLY the notes: 2-5 terse bullet points starting with \"- \", plain text, no preamble, no heading, no code fences, no commentary or questions back — only user-visible changes. Commits since the last release:\n%s",
		m.Name, version, m.Platform, log)

	out, diag, err := shellTimeout(dir, aiCommand()+" "+shellQuote(prompt), aiTimeout)
	if err != nil {
		// The drafter's own message is the diagnosis and it arrives on
		// stdout, which used to be captured and dropped — leaving only
		// "exit status 1" for a plain "OAuth session expired" that any
		// reader could have acted on. Show it.
		detail := diag
		if detail == "" {
			detail = "(no output)"
		}
		if !interactive() {
			return "", fmt.Errorf("notes drafter %q failed: %v\n  %s\n"+
				"  Pass --notes \"…\", write RELEASE_NOTES.md, or set PULTIK_AI to a working drafter", aiCommand(), err, indent(detail))
		}
		fmt.Fprintf(uiOut, "%s▸ %s failed (%v) — opening editor%s\n  %s\n", yellow, aiCommand(), err, reset, indent(detail))
		return editorNotes("")
	}

	notes := stripFences(strings.TrimSpace(out))
	if notes == "" {
		return "", fmt.Errorf("notes drafter %q returned nothing — pass --notes \"…\" or write RELEASE_NOTES.md", aiCommand())
	}
	fmt.Fprintf(uiOut, "%s%s%s\n", dim, indent(notes), reset)
	if yes {
		// --yes means "don't ask me anything", which has to include this.
		return notes, nil
	}
	if !interactive() {
		return "", fmt.Errorf("drafted notes need approval and there's no terminal — pass --yes to accept the draft unattended")
	}
	if confirm("use these notes? (n opens editor)") {
		return notes, nil
	}
	return editorNotes(notes)
}

func editorNotes(seed string) (string, error) {
	if !interactive() {
		return "", fmt.Errorf("an editor needs a terminal and stdin isn't one — pass --notes \"…\" or write RELEASE_NOTES.md")
	}
	editor := os.Getenv("EDITOR")
	if editor == "" {
		editor = "vi"
	}
	tmp, err := os.CreateTemp("", "pultik-notes-*.md")
	if err != nil {
		return "", err
	}
	defer os.Remove(tmp.Name())
	tmp.WriteString(seed)
	tmp.Close()
	cmd := exec.Command("sh", "-c", editor+" "+shellQuote(tmp.Name()))
	cmd.Stdin, cmd.Stdout, cmd.Stderr = os.Stdin, os.Stdout, os.Stderr
	if err := cmd.Run(); err != nil {
		return "", fmt.Errorf("editor: %w", err)
	}
	b, err := os.ReadFile(tmp.Name())
	return strings.TrimSpace(string(b)), err
}

// ── releases ────────────────────────────────────────────────────────────────

func listReleases(args []string) error {
	resp, err := http.Get(baseURL() + "/api/releases")
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode != 200 {
		return fmt.Errorf("%s from %s", resp.Status, baseURL())
	}
	var data struct {
		Apps []struct {
			ID       string `json:"id"`
			Name     string `json:"name"`
			Icon     string `json:"icon"`
			Platform string `json:"platform"`
			External *struct {
				URL string `json:"url"`
			} `json:"external"`
			Latest   *release  `json:"latest"`
			Releases []release `json:"releases"`
		} `json:"apps"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&data); err != nil {
		return err
	}
	filter := ""
	if len(args) > 0 {
		filter = args[0]
	}
	for _, app := range data.Apps {
		if filter != "" && app.ID != filter {
			continue
		}
		fmt.Printf("%s%s %s%s %s(%s)%s", bold, app.Icon, app.Name, reset, dim, app.Platform, reset)
		switch {
		case app.External != nil:
			fmt.Printf(" %s↗ %s%s\n", dim, app.External.URL, reset)
		case app.Latest == nil:
			fmt.Printf(" %s— nothing shipped yet%s\n", dim, reset)
		default:
			fmt.Println()
			rels := app.Releases
			if filter == "" && len(rels) > 3 {
				rels = rels[:3]
			}
			for _, r := range rels {
				fmt.Printf("  %s%-12s%s %s · %s%s%s\n", cyan, r.Version, reset,
					humanSize(r.Size), dim, time.Unix(r.Ts, 0).Format("2006-01-02 15:04"), reset)
			}
		}
	}
	return nil
}

// ── plumbing ────────────────────────────────────────────────────────────────

func arg(args []string, i int, flag string) string {
	if i >= len(args) {
		fmt.Fprintf(os.Stderr, "%s✕ %s needs a value%s\n", red, flag, reset)
		os.Exit(2)
	}
	return args[i]
}

func baseURL() string {
	if b := os.Getenv("PULTIK_BASE"); b != "" {
		return strings.TrimSuffix(b, "/")
	}
	return defaultBase
}

func readToken() (string, error) {
	if t := os.Getenv("PULTIK_TOKEN"); t != "" {
		return strings.TrimSpace(t), nil
	}
	home, _ := os.UserHomeDir()
	b, err := os.ReadFile(filepath.Join(home, ".config", "pultik", "token"))
	if err != nil {
		return "", fmt.Errorf("no token: set PULTIK_TOKEN or write ~/.config/pultik/token")
	}
	return strings.TrimSpace(string(b)), nil
}

func shell(dir, cmd string) (string, error) {
	c := exec.Command("sh", "-c", cmd)
	c.Dir = dir
	var out bytes.Buffer
	c.Stdout = &out
	c.Stderr = os.Stderr
	err := c.Run()
	return out.String(), err
}

// shellTimeout runs cmd with a deadline. It returns stdout as the payload and
// stdout+stderr as diag, kept apart on purpose: a wrapper around the drafter
// (PULTIK_AI="switcheroo exec -- claude -p") narrates on stderr, and merging
// the streams would splice that narration into the release notes. diag exists
// because the failure reason is often on the stream the payload isn't.
// Unbounded, a stuck drafter used to hang a ship indefinitely.
func shellTimeout(dir, cmd string, limit time.Duration) (payload, diag string, err error) {
	ctx, cancel := context.WithTimeout(context.Background(), limit)
	defer cancel()

	c := exec.CommandContext(ctx, "sh", "-c", cmd)
	c.Dir = dir
	var out, errBuf bytes.Buffer
	c.Stdout = &out
	c.Stderr = &errBuf
	err = c.Run()
	if ctx.Err() == context.DeadlineExceeded {
		err = fmt.Errorf("timed out after %s", limit)
	}
	return out.String(), strings.TrimSpace(out.String() + "\n" + errBuf.String()), err
}

func shellQuote(s string) string {
	return "'" + strings.ReplaceAll(s, "'", `'\''`) + "'"
}

func confirm(q string) bool {
	fmt.Printf("%s?%s %s [y/N] ", yellow, reset, q)
	var answer string
	fmt.Scanln(&answer)
	return strings.EqualFold(strings.TrimSpace(answer), "y")
}

func fileSha256(path string) (string, error) {
	f, err := os.Open(path)
	if err != nil {
		return "", err
	}
	defer f.Close()
	h := sha256.New()
	if _, err := io.Copy(h, f); err != nil {
		return "", err
	}
	return hex.EncodeToString(h.Sum(nil)), nil
}

func humanSize(n int64) string {
	switch {
	case n >= 1<<30:
		return fmt.Sprintf("%.1f GB", float64(n)/(1<<30))
	case n >= 1<<20:
		return fmt.Sprintf("%.1f MB", float64(n)/(1<<20))
	case n >= 1<<10:
		return fmt.Sprintf("%.1f KB", float64(n)/(1<<10))
	}
	return fmt.Sprintf("%d B", n)
}

func indent(s string) string {
	return "  " + strings.ReplaceAll(s, "\n", "\n  ")
}

func putFile(token, url, path string) error {
	f, err := os.Open(path)
	if err != nil {
		return err
	}
	defer f.Close()
	info, _ := f.Stat()
	req, err := http.NewRequest(http.MethodPut, url, f)
	if err != nil {
		return err
	}
	req.ContentLength = info.Size()
	req.Header.Set("Authorization", "Bearer "+token)
	return doUpload(req)
}

func putJSON(token, url string, body []byte) error {
	req, err := http.NewRequest(http.MethodPut, url, bytes.NewReader(body))
	if err != nil {
		return err
	}
	req.Header.Set("Authorization", "Bearer "+token)
	req.Header.Set("Content-Type", "application/json")
	return doUpload(req)
}

func doUpload(req *http.Request) error {
	client := &http.Client{Timeout: 10 * time.Minute}
	resp, err := client.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		b, _ := io.ReadAll(io.LimitReader(resp.Body, 500))
		return fmt.Errorf("%s: %s", resp.Status, strings.TrimSpace(string(b)))
	}
	return nil
}
