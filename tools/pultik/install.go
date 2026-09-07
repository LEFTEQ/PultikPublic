package main

import (
	"embed"
	"encoding/json"
	"fmt"
	"io"
	"io/fs"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"time"
)

//go:embed installassets/hammerspoon/*.lua
var installAssets embed.FS

// legacySkillNames are the five skills `pultik install` used to copy into
// ~/.claude/skills. They ship through vitrinka's kit plugin now (/todo,
// /todo-list, /todo-done, /todo-milestone, /remind), so the installer's only
// remaining job for them is retiring the copies it once wrote — recognised by
// the `.pultik-managed` marker, never by name alone.
var legacySkillNames = []string{"todo", "todo-list", "todo-done", "todo-milestone", "remind"}

const (
	maxAppDownload = 1 << 30
	todoHookTag    = "vitrinka:todo-session-context"
	timeHookTag    = "vitrinka:schedule-session-context"
	// The pre-2026-09 tags. Matched on retirement so one `pultik install`
	// migrates a machine; never written again.
	legacyTodoHookTag = "pultik:todo-session-context"
	legacyTimeHookTag = "pultik:schedule-session-context"
)

type installOptions struct {
	app, cli, skills, hooks, hammerspoon bool
	replaceSkills                        bool
	// dryRun prints every step's plan and writes nothing.
	dryRun bool
}

type commandHook struct {
	Type    string  `json:"type"`
	Command string  `json:"command"`
	Timeout float64 `json:"timeout,omitempty"`
}

type hookGroup struct {
	Matcher string        `json:"matcher,omitempty"`
	Hooks   []commandHook `json:"hooks"`
}

func installCmd(args []string) error {
	opts, help, err := parseInstallOptions(args)
	if help {
		installUsage()
		return nil
	}
	if err != nil {
		return err
	}
	if runtime.GOOS != "darwin" {
		return fmt.Errorf("Pultik requires macOS")
	}
	if opts.cli {
		if opts.dryRun {
			step("would install the CLI (dry run)")
		} else if err := installCurrentCLI(); err != nil {
			return err
		}
	}
	if opts.skills {
		if err := retireLegacySkills(opts.dryRun); err != nil {
			return err
		}
	}
	if opts.hooks {
		if err := installClaudeHooks(opts.dryRun); err != nil {
			return err
		}
	}
	if opts.hammerspoon {
		if opts.dryRun {
			step("would link ~/.hammerspoon/init.lua (dry run)")
		} else if err := installHammerspoon(); err != nil {
			return err
		}
	}
	if opts.app {
		if opts.dryRun {
			step("would download and install the released Pultik.app (dry run)")
		} else if err := installReleasedApp(); err != nil {
			return err
		}
	}
	if opts.dryRun {
		ok("dry run — nothing written")
		return nil
	}
	ok("Pultik installation complete")
	return nil
}

func parseInstallOptions(args []string) (installOptions, bool, error) {
	opts := installOptions{app: true, cli: true, skills: true, hooks: true, hammerspoon: true}
	only := func(name string) {
		// A focused mode narrows WHAT installs; it never cancels modifier
		// flags, whatever order they were typed in.
		opts = installOptions{replaceSkills: opts.replaceSkills, dryRun: opts.dryRun}
		switch name {
		case "app":
			opts.app = true
		case "cli":
			opts.cli = true
		case "skills":
			opts.skills = true
		case "hooks":
			opts.hooks = true
		case "hammerspoon":
			opts.hammerspoon = true
		}
	}
	for _, arg := range args {
		switch arg {
		case "--app-only":
			only("app")
		case "--cli-only":
			only("cli")
		case "--skills-only":
			only("skills")
		case "--hooks-only":
			only("hooks")
		case "--hammerspoon-only", "--hammerspoon":
			// --hammerspoon is the documented spelling (README, decision log,
			// PersonalSetup's pointer); both narrow to just the symlink step.
			only("hammerspoon")
		case "--no-app":
			opts.app = false
		case "--no-hooks":
			opts.hooks = false
		case "--no-hammerspoon":
			opts.hammerspoon = false
		case "--replace-skills", "--copy-skills": // Compatibility: skills ship via the vitrinka plugin now.
			opts.replaceSkills = true
		case "--dry-run":
			opts.dryRun = true
		case "--help", "-h":
			return opts, true, nil
		default:
			return opts, false, fmt.Errorf("unknown flag %q", arg)
		}
	}
	return opts, false, nil
}

func installUsage() {
	fmt.Print(`pultik install — install Pultik on this Mac

FLAGS
  --app-only | --cli-only | --skills-only | --hooks-only | --hammerspoon-only
  --no-app            skip the released macOS app
  --no-hooks          skip Claude SessionStart hooks
  --no-hammerspoon    skip the ~/.hammerspoon/init.lua symlink
  --dry-run           print every step's plan (hook lines included), write nothing

The SessionStart hooks run "vitrinka hook-context todo|schedule" — the todo
and reminder skills (/todo, /todo-list, /todo-done, /todo-milestone, /remind)
ship through vitrinka's kit plugin, and the skills step only retires the copies
an older pultik wrote into ~/.claude/skills. It never installs credentials, the
privileged fan helper, or login-at-launch.
`)
}

func pultikBinDir() (string, error) {
	if value := os.Getenv("PULTIK_BIN_DIR"); value != "" {
		return value, nil
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return "", fmt.Errorf("find home directory: %w", err)
	}
	return filepath.Join(home, ".local", "bin"), nil
}

func claudeConfigDir() (string, error) {
	if value := os.Getenv("CLAUDE_CONFIG_DIR"); value != "" {
		return value, nil
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return "", fmt.Errorf("find home directory: %w", err)
	}
	return filepath.Join(home, ".claude"), nil
}

func installCurrentCLI() error {
	source, err := os.Executable()
	if err != nil {
		return fmt.Errorf("find running CLI: %w", err)
	}
	source, err = filepath.EvalSymlinks(source)
	if err != nil {
		return fmt.Errorf("resolve running CLI: %w", err)
	}
	binDir, err := pultikBinDir()
	if err != nil {
		return err
	}
	destination := filepath.Join(binDir, "pultik")
	if sameFile(source, destination) {
		ok("CLI already installed at %s", destination)
		return nil
	}
	step("installing CLI → " + destination)
	if err := copyFileAtomic(source, destination, 0o755); err != nil {
		return fmt.Errorf("install CLI: %w", err)
	}
	return nil
}

func sameFile(a, b string) bool {
	aInfo, aErr := os.Stat(a)
	bInfo, bErr := os.Stat(b)
	return aErr == nil && bErr == nil && os.SameFile(aInfo, bInfo)
}

// legacyManagedSkills lists the ~/.claude/skills entries an older pultik
// wrote: one of the five names AND carrying the `.pultik-managed` marker (or
// a symlink into this repo's retired installassets tree). A same-named skill
// without the marker is the user's and is never touched.
func legacyManagedSkills() ([]string, error) {
	configDir, err := claudeConfigDir()
	if err != nil {
		return nil, err
	}
	var stale []string
	for _, name := range legacySkillNames {
		target := filepath.Join(configDir, "skills", name)
		info, err := os.Lstat(target)
		if err != nil {
			continue
		}
		if _, err := os.Stat(filepath.Join(target, ".pultik-managed")); err == nil {
			stale = append(stale, target)
			continue
		}
		if info.Mode()&os.ModeSymlink != 0 && isLegacySkillLink(target, name) {
			stale = append(stale, target)
		}
	}
	return stale, nil
}

// isLegacySkillLink recognises the one symlink shape an older pultik (or its
// install.sh) wrote: a link INTO this repo's retired
// tools/pultik/installassets/skills/<name> tree. The raw link target is what
// decides it — a dangling link is retired only when it still points there;
// a broken same-named link into anything else is the user's and stays put.
func isLegacySkillLink(link, name string) bool {
	rawTarget, err := os.Readlink(link)
	if err != nil {
		return false
	}
	installassets := filepath.Join("tools", "pultik", "installassets", "skills", name)
	if strings.HasSuffix(filepath.Clean(rawTarget), installassets) {
		return true
	}
	// A link into the repo's .claude/skills that itself pointed at the
	// installassets tree; resolvable only while that checkout exists.
	resolved, err := filepath.EvalSymlinks(link)
	return err == nil && strings.HasSuffix(resolved, installassets)
}

// retireLegacySkills removes the installer-owned copies so the plugin's
// skills are the only /todo* and /remind on the machine (two skills with one
// name = a coin toss per session).
func retireLegacySkills(dryRun bool) error {
	stale, err := legacyManagedSkills()
	if err != nil {
		return err
	}
	if len(stale) == 0 {
		ok("no pultik-managed skills left in ~/.claude/skills (the vitrinka plugin owns /todo* and /remind)")
		return nil
	}
	for _, target := range stale {
		if dryRun {
			step("would retire " + target)
			continue
		}
		if err := os.RemoveAll(target); err != nil {
			return err
		}
	}
	if !dryRun {
		ok("retired %d pultik-managed skill(s); /todo* and /remind come from the vitrinka plugin now", len(stale))
	}
	return nil
}

// vitrinkaBinary resolves the vitrinka CLI the SessionStart hooks will run,
// the way the app resolves its own helpers: the shim `vitrinka install`
// writes first, then PATH, then the usual manual-build locations. Nothing here
// is a personal path. When nothing resolves the bare name is written — the
// hook line is fail-open (`|| true`), so a missing binary costs nothing but
// the context it would have printed.
func vitrinkaBinary() (path string, found bool) {
	home, _ := os.UserHomeDir()
	candidates := []string{filepath.Join(home, ".local", "bin", "vitrinka")}
	if onPath, err := exec.LookPath("vitrinka"); err == nil {
		candidates = append(candidates, onPath)
	}
	candidates = append(candidates,
		filepath.Join(home, ".bun", "bin", "vitrinka"),
		"/opt/homebrew/bin/vitrinka",
		"/usr/local/bin/vitrinka",
	)
	for _, candidate := range candidates {
		if info, err := os.Stat(candidate); err == nil && !info.IsDir() && info.Mode()&0o111 != 0 {
			return candidate, true
		}
	}
	return "vitrinka", false
}

func installClaudeHooks(dryRun bool) error {
	dir, err := claudeConfigDir()
	if err != nil {
		return err
	}
	if !dryRun {
		if err := os.MkdirAll(dir, 0o755); err != nil {
			return err
		}
	}
	path := filepath.Join(dir, "settings.json")
	raw, err := os.ReadFile(path)
	if os.IsNotExist(err) {
		raw = []byte("{}")
	} else if err != nil {
		return err
	}
	binary, found := vitrinkaBinary()
	if !found {
		fmt.Fprintf(uiOut, "%s! vitrinka CLI not found — writing the bare name; install it (bun add -g @vitrinka/cli) and rerun%s\n", yellow, reset)
	}
	merged, err := mergeClaudeSettings(raw, binary)
	if err != nil {
		return fmt.Errorf("%s: %w", path, err)
	}
	if dryRun {
		for _, command := range pultikHookCommands(raw) {
			step("would remove SessionStart hook: " + command)
		}
		step("would write SessionStart hook: " + hookCommand(binary, "todo"))
		step("would write SessionStart hook: " + hookCommand(binary, "schedule"))
		return nil
	}
	if _, err := os.Stat(path); err == nil {
		if err := copyFileAtomic(path, path+".pultik-backup", 0o600); err != nil {
			return err
		}
	}
	if err := writeFileAtomic(path, merged, 0o600); err != nil {
		return err
	}
	ok("merged Claude SessionStart hooks into %s", path)
	return nil
}

func mergeClaudeSettings(raw []byte, binary string) ([]byte, error) {
	var settings map[string]any
	if err := json.Unmarshal(raw, &settings); err != nil {
		return nil, fmt.Errorf("invalid JSON: %w", err)
	}
	hooks, okType := settings["hooks"].(map[string]any)
	if settings["hooks"] != nil && !okType {
		return nil, fmt.Errorf("hooks must be an object")
	}
	if hooks == nil {
		hooks = map[string]any{}
	}
	groups, okType := hooks["SessionStart"].([]any)
	if hooks["SessionStart"] != nil && !okType {
		return nil, fmt.Errorf("hooks.SessionStart must be an array")
	}
	kept := make([]any, 0, len(groups)+2)
	for _, group := range groups {
		cleaned, keep := withoutPultikHooks(group)
		if keep {
			kept = append(kept, cleaned)
		}
	}
	todo := hookCommand(binary, "todo")
	timed := hookCommand(binary, "schedule")
	kept = append(kept,
		hookGroup{Hooks: []commandHook{{Type: "command", Command: todo, Timeout: 15}}},
		hookGroup{Hooks: []commandHook{{Type: "command", Command: timed, Timeout: 15}}},
	)
	hooks["SessionStart"] = kept
	settings["hooks"] = hooks
	return json.MarshalIndent(settings, "", "  ")
}

func withoutPultikHooks(group any) (any, bool) {
	object, ok := group.(map[string]any)
	if !ok {
		return group, true
	}
	hooks, ok := object["hooks"].([]any)
	if !ok {
		return group, true
	}
	kept := make([]any, 0, len(hooks))
	for _, hook := range hooks {
		if !isPultikHook(hook) {
			kept = append(kept, hook)
		}
	}
	if len(kept) == 0 {
		return nil, false
	}
	copy := make(map[string]any, len(object))
	for key, value := range object {
		copy[key] = value
	}
	copy["hooks"] = kept
	return copy, true
}

// legacyHookArgs are the pre-tag hooks' exact argument strings.
//
// Deliberately WITHOUT the binary name: the real legacy hooks shell-quote the
// path ("$HOME/.local/bin/pultik" todo list ...), so matching on
// `pultik todo list …` skipped every one of them in the field while passing a
// test that used a bare invocation. The retirement silently never happened and
// each install stacked another pair, so a session's todo context printed twice.
//
// These flag combinations are pultik's own and specific enough to be safe;
// they are still exact substrings, never loose words that could claim a
// user-owned wrapper as ours.
var legacyHookArgs = []string{
	"todo list --open --compact --here",
	"schedule ripe --claim --compact",
}

// isPultikHook matches every generation of our SessionStart hook: the current
// vitrinka tags, the pultik tags they replaced (2026-09 migration), and the
// pre-tag legacy invocations.
func isPultikHook(hook any) bool {
	object, ok := hook.(map[string]any)
	if !ok {
		return false
	}
	command, _ := object["command"].(string)
	for _, tag := range []string{todoHookTag, timeHookTag, legacyTodoHookTag, legacyTimeHookTag} {
		if strings.Contains(command, tag) {
			return true
		}
	}
	// Only ours: an unrelated script may well mention "todo list", but not
	// alongside a pultik binary invocation.
	if !strings.Contains(command, "pultik") {
		return false
	}
	for _, args := range legacyHookArgs {
		if strings.Contains(command, args) {
			return true
		}
	}
	return false
}

// pultikHookCommands lists the SessionStart hook commands in raw settings
// that a merge would retire — the dry run's "before" half.
func pultikHookCommands(raw []byte) []string {
	var settings struct {
		Hooks struct {
			SessionStart []struct {
				Hooks []map[string]any `json:"hooks"`
			} `json:"SessionStart"`
		} `json:"hooks"`
	}
	if err := json.Unmarshal(raw, &settings); err != nil {
		return nil
	}
	var out []string
	for _, group := range settings.Hooks.SessionStart {
		for _, hook := range group.Hooks {
			if isPultikHook(hook) {
				command, _ := hook["command"].(string)
				out = append(out, command)
			}
		}
	}
	return out
}

// hookCommand is the exact line written into settings.json: the vitrinka CLI
// prints the SessionStart context itself, fail-open so a signed-out or
// off-mesh machine starts its session in silence rather than with an error.
func hookCommand(binary, kind string) string {
	tag := todoHookTag
	if kind == "schedule" {
		tag = timeHookTag
	}
	return shellQuote(binary) + " hook-context " + kind + " 2>/dev/null || true; # " + tag
}

func installReleasedApp() error {
	// Recover a swap interrupted by a previous run BEFORE anything that can
	// fail — an offline machine or a bad download must still get its working
	// app back, not only runs that reach extractApp.
	candidates, err := appCandidates()
	if err != nil {
		return err
	}
	for _, destination := range candidates {
		backup := filepath.Join(filepath.Dir(destination), ".Pultik.app.previous")
		if err := recoverInterruptedSwap(destination, backup); err != nil {
			return err
		}
	}
	url := os.Getenv("PULTIK_APP_URL")
	if url == "" {
		url = baseURL() + "/get/pultik"
	}
	step("downloading released Pultik.app")
	client := http.Client{Timeout: 2 * time.Minute}
	response, err := client.Get(url)
	if err != nil {
		return err
	}
	defer response.Body.Close()
	if response.StatusCode < 200 || response.StatusCode >= 300 {
		return fmt.Errorf("download: %s", response.Status)
	}
	if response.ContentLength > maxAppDownload {
		return fmt.Errorf("download exceeds %d bytes", maxAppDownload)
	}
	tmp, err := os.CreateTemp("", "pultik-*.zip")
	if err != nil {
		return err
	}
	zipPath := tmp.Name()
	defer os.Remove(zipPath)
	written, copyErr := io.Copy(tmp, io.LimitReader(response.Body, maxAppDownload+1))
	closeErr := tmp.Close()
	if copyErr != nil {
		return copyErr
	}
	if closeErr != nil {
		return closeErr
	}
	if written > maxAppDownload {
		return fmt.Errorf("download exceeds %d bytes", maxAppDownload)
	}

	destination, err := appInstallDestination()
	if err != nil {
		return err
	}
	if err := extractApp(zipPath, destination); err != nil {
		return err
	}
	ok("installed %s", destination)
	return nil
}

func appCandidates() ([]string, error) {
	home, err := os.UserHomeDir()
	if err != nil {
		return nil, fmt.Errorf("find home directory: %w", err)
	}
	return []string{"/Applications/Pultik.app", filepath.Join(home, "Applications", "Pultik.app")}, nil
}

func appInstallDestination() (string, error) {
	candidates, err := appCandidates()
	if err != nil {
		return "", err
	}
	for _, destination := range candidates {
		parent := filepath.Dir(destination)
		if err := os.MkdirAll(parent, 0o755); err != nil {
			continue
		}
		probe, err := os.CreateTemp(parent, ".pultik-write-test-")
		if err != nil {
			continue
		}
		name := probe.Name()
		closeErr := probe.Close()
		removeErr := os.Remove(name)
		if closeErr == nil && removeErr == nil {
			return destination, nil
		}
	}
	return "", fmt.Errorf("neither /Applications nor ~/Applications is writable")
}

func extractApp(zipPath, destination string) error {
	parent := filepath.Dir(destination)
	stageRoot, err := os.MkdirTemp(parent, ".pultik-installing-")
	if err != nil {
		return err
	}
	defer os.RemoveAll(stageRoot)
	if output, err := exec.Command("/usr/bin/ditto", "-x", "-k", zipPath, stageRoot).CombinedOutput(); err != nil {
		return fmt.Errorf("extract app: %w: %s", err, strings.TrimSpace(string(output)))
	}
	staged := filepath.Join(stageRoot, "Pultik.app")
	if err := validateApp(staged); err != nil {
		return err
	}
	backup := filepath.Join(parent, ".Pultik.app.previous")
	if err := recoverInterruptedSwap(destination, backup); err != nil {
		return err
	}
	if err := os.RemoveAll(backup); err != nil {
		return err
	}
	hadDestination := false
	if _, err := os.Stat(destination); err == nil {
		if err := os.Rename(destination, backup); err != nil {
			return fmt.Errorf("stage existing app: %w", err)
		}
		hadDestination = true
	} else if !os.IsNotExist(err) {
		return err
	}
	if err := os.Rename(staged, destination); err != nil {
		if hadDestination {
			if restoreErr := os.Rename(backup, destination); restoreErr != nil {
				return fmt.Errorf("install app: %w (restore also failed: %v)", err, restoreErr)
			}
		}
		return fmt.Errorf("install app: %w", err)
	}
	if hadDestination {
		if err := os.RemoveAll(backup); err != nil {
			return fmt.Errorf("remove previous app: %w", err)
		}
	}
	return nil
}

// recoverInterruptedSwap restores the working app when a previous run died
// between staging it to the backup path and renaming the new app into place —
// the backup must never be the only copy right before it is deleted.
func recoverInterruptedSwap(destination, backup string) error {
	if _, err := os.Stat(destination); !os.IsNotExist(err) {
		return err
	}
	if _, err := os.Stat(backup); err != nil {
		if os.IsNotExist(err) {
			return nil
		}
		return err
	}
	if err := os.Rename(backup, destination); err != nil {
		return fmt.Errorf("recover interrupted install: %w", err)
	}
	return nil
}

func validateApp(app string) error {
	plist := filepath.Join(app, "Contents", "Info.plist")
	bundleID, err := exec.Command("/usr/libexec/PlistBuddy", "-c", "Print :CFBundleIdentifier", plist).Output()
	if err != nil || strings.TrimSpace(string(bundleID)) != "dev.example.pultik" {
		return fmt.Errorf("downloaded app has unexpected bundle identifier")
	}
	executable, err := exec.Command("/usr/libexec/PlistBuddy", "-c", "Print :CFBundleExecutable", plist).Output()
	if err != nil {
		return fmt.Errorf("read app executable: %w", err)
	}
	binary := filepath.Join(app, "Contents", "MacOS", strings.TrimSpace(string(executable)))
	info, err := os.Stat(binary)
	if err != nil || info.Mode()&0o111 == 0 {
		return fmt.Errorf("downloaded app executable is missing")
	}
	// --test-requirement takes ONE requirement expression; the requirement-SET
	// header `designated =>` makes codesign reject the string itself
	// ("unexpected token: designated"), which failed every verification.
	requirement := `=anchor apple generic and identifier "dev.example.pultik" and certificate leaf[subject.OU] = "YJ77YV2PNA"`
	if output, err := exec.Command("/usr/bin/codesign", "--verify", "--deep", "--strict", "--test-requirement", requirement, app).CombinedOutput(); err != nil {
		return fmt.Errorf("verify app signature: %w: %s", err, strings.TrimSpace(string(output)))
	}
	return nil
}

func copyFileAtomic(source, destination string, mode fs.FileMode) error {
	input, err := os.Open(source)
	if err != nil {
		return err
	}
	defer input.Close()
	if err := os.MkdirAll(filepath.Dir(destination), 0o755); err != nil {
		return err
	}
	tmp, err := os.CreateTemp(filepath.Dir(destination), ".pultik-*")
	if err != nil {
		return err
	}
	name := tmp.Name()
	defer os.Remove(name)
	if _, err := io.Copy(tmp, input); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Chmod(mode); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Close(); err != nil {
		return err
	}
	return os.Rename(name, destination)
}

func writeFileAtomic(path string, data []byte, mode fs.FileMode) error {
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}
	tmp, err := os.CreateTemp(filepath.Dir(path), ".pultik-*")
	if err != nil {
		return err
	}
	name := tmp.Name()
	defer os.Remove(name)
	if _, err := tmp.Write(data); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Chmod(mode); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Close(); err != nil {
		return err
	}
	return os.Rename(name, path)
}
