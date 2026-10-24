package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
)

func TestPublicMirrorIncludesHammerspoonPackage(t *testing.T) {
	data, err := os.ReadFile(filepath.Join("..", "..", "mirror", "manifest.json"))
	if os.IsNotExist(err) {
		t.Skip("private mirror manifest is absent in the public checkout")
	}
	if err != nil {
		t.Fatal(err)
	}
	var manifest struct {
		Include []string `json:"include"`
	}
	if err := json.Unmarshal(data, &manifest); err != nil {
		t.Fatal(err)
	}
	included := make(map[string]bool, len(manifest.Include))
	for _, path := range manifest.Include {
		included[path] = true
	}
	for _, name := range hammerspoonFiles {
		for _, dir := range []string{"hammerspoon", "tools/pultik/installassets/hammerspoon"} {
			path := dir + "/" + name
			if !included[path] {
				t.Errorf("public mirror omits required Hammerspoon module %s", path)
			}
		}
	}
}

// The test binary lives in a go-build temp dir, so the executable-walk leg of
// repo detection finds nothing; with HOME isolated and PULTIK_REPO unset the
// ladder must bottom out on the embedded copies.
func isolateHammerspoonHome(t *testing.T) string {
	t.Helper()
	home := t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv("PULTIK_REPO", "")
	return home
}

func TestParseInstallOptionsHammerspoon(t *testing.T) {
	opts, _, err := parseInstallOptions(nil)
	if err != nil || !opts.hammerspoon {
		t.Fatalf("full install must include hammerspoon: %+v err=%v", opts, err)
	}
	opts, _, err = parseInstallOptions([]string{"--hammerspoon-only"})
	if err != nil || opts.app || opts.cli || opts.skills || opts.hooks || !opts.hammerspoon {
		t.Fatalf("unexpected options: %+v err=%v", opts, err)
	}
	opts, _, err = parseInstallOptions([]string{"--no-hammerspoon"})
	if err != nil || opts.hammerspoon || !opts.app {
		t.Fatalf("--no-hammerspoon: %+v err=%v", opts, err)
	}
	opts, _, err = parseInstallOptions([]string{"--skills-only"})
	if err != nil || opts.hammerspoon {
		t.Fatalf("--skills-only must not install hammerspoon: %+v err=%v", opts, err)
	}
	opts, _, _ = parseInstallOptions(nil)
	if opts.replaceHammerspoon {
		t.Fatalf("a full install must not replace a foreign Hammerspoon config: %+v", opts)
	}
	for _, flag := range []string{"--hammerspoon", "--hammerspoon-only"} {
		opts, _, _ = parseInstallOptions([]string{flag})
		if opts.replaceHammerspoon {
			t.Fatalf("%s alone must not replace a foreign config: %+v", flag, opts)
		}
	}
	// --hammerspoon-force is a modifier: it survives a focused mode in either
	// order, and a full install keeps every step.
	for _, args := range [][]string{{"--hammerspoon-force", "--hammerspoon-only"}, {"--hammerspoon-only", "--hammerspoon-force"}} {
		opts, _, _ = parseInstallOptions(args)
		if !opts.replaceHammerspoon || !opts.hammerspoon || opts.app {
			t.Fatalf("%v: %+v", args, opts)
		}
	}
	opts, _, _ = parseInstallOptions([]string{"--hammerspoon-force"})
	if !opts.replaceHammerspoon || !opts.app || !opts.hooks || !opts.hammerspoon {
		t.Fatalf("--hammerspoon-force must not narrow the install: %+v", opts)
	}
}

func TestHammerspoonOnlyKeepsAForeignConfigWithoutForce(t *testing.T) {
	home := isolateHammerspoonHome(t)
	link := filepath.Join(home, ".hammerspoon", "init.lua")
	if err := os.MkdirAll(filepath.Dir(link), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(link, []byte("-- hand-written"), 0o644); err != nil {
		t.Fatal(err)
	}
	only, _, _ := parseInstallOptions([]string{"--hammerspoon-only"})
	if err := installHammerspoonStep(only); err != nil {
		t.Fatal(err)
	}
	if data, err := os.ReadFile(link); err != nil || string(data) != "-- hand-written" {
		t.Fatalf("--hammerspoon-only replaced a foreign config without --hammerspoon-force: %q err=%v", data, err)
	}
}

func writeDotfilesHammerspoon(t *testing.T) string {
	t.Helper()
	dir := filepath.Join(t.TempDir(), "dotfiles", "hammerspoon")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	target := filepath.Join(dir, "init.lua")
	if err := os.WriteFile(target, []byte("-- someone else's config"), 0o644); err != nil {
		t.Fatal(err)
	}
	return target
}

func TestFullInstallKeepsAForeignHammerspoonConfig(t *testing.T) {
	home := isolateHammerspoonHome(t)
	link := filepath.Join(home, ".hammerspoon", "init.lua")
	if err := os.MkdirAll(filepath.Dir(link), 0o755); err != nil {
		t.Fatal(err)
	}
	dotfiles := writeDotfilesHammerspoon(t)
	if err := os.Symlink(dotfiles, link); err != nil {
		t.Fatal(err)
	}
	full, _, _ := parseInstallOptions(nil)
	if err := installHammerspoonStep(full); err != nil {
		t.Fatal(err)
	}
	if target, err := os.Readlink(link); err != nil || target != dotfiles {
		t.Fatalf("a foreign symlink was replaced: %q err=%v", target, err)
	}

	if err := os.Remove(link); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(link, []byte("-- hand-written"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := installHammerspoonStep(full); err != nil {
		t.Fatal(err)
	}
	if data, err := os.ReadFile(link); err != nil || string(data) != "-- hand-written" {
		t.Fatalf("a hand-written init.lua was replaced: %q err=%v", data, err)
	}
	if matches, _ := filepath.Glob(link + ".pultik-backup*"); len(matches) != 0 {
		t.Fatalf("a kept config must not leave backups: %v", matches)
	}
}

func TestExplicitHammerspoonBacksUpAForeignSymlink(t *testing.T) {
	home := isolateHammerspoonHome(t)
	link := filepath.Join(home, ".hammerspoon", "init.lua")
	if err := os.MkdirAll(filepath.Dir(link), 0o755); err != nil {
		t.Fatal(err)
	}
	dotfiles := writeDotfilesHammerspoon(t)
	if err := os.Symlink(dotfiles, link); err != nil {
		t.Fatal(err)
	}
	explicit, _, _ := parseInstallOptions([]string{"--hammerspoon-only", "--hammerspoon-force"})
	if err := installHammerspoonStep(explicit); err != nil {
		t.Fatal(err)
	}
	if target, err := os.Readlink(link + ".pultik-backup"); err != nil || target != dotfiles {
		t.Fatalf("the foreign link was not kept as a backup: %q err=%v", target, err)
	}
	managed := filepath.Join(home, "Library", "Application Support", "Pultik", "hammerspoon", "init.lua")
	if target, err := os.Readlink(link); err != nil || target != managed {
		t.Fatalf("init.lua was not linked to pultik: %q err=%v", target, err)
	}
}

// A dotfiles folder that copied all three modules is still somebody else's
// config: only a checkout (tools/pultik beside it) or the managed copy is ours.
func TestACopiedModuleSetIsNotPultiks(t *testing.T) {
	home := isolateHammerspoonHome(t)
	link := filepath.Join(home, ".hammerspoon", "init.lua")
	if err := os.MkdirAll(filepath.Dir(link), 0o755); err != nil {
		t.Fatal(err)
	}
	dotfiles := writeDotfilesHammerspoon(t)
	for _, name := range []string{"organize.lua", "cmux.lua"} {
		if err := os.WriteFile(filepath.Join(filepath.Dir(dotfiles), name), []byte("-- copy"), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	if err := os.Symlink(dotfiles, link); err != nil {
		t.Fatal(err)
	}
	full, _, _ := parseInstallOptions(nil)
	if err := installHammerspoonStep(full); err != nil {
		t.Fatal(err)
	}
	if target, err := os.Readlink(link); err != nil || target != dotfiles {
		t.Fatalf("a full install took over a copied config: %q err=%v", target, err)
	}
	explicit, _, _ := parseInstallOptions([]string{"--hammerspoon-force"})
	if err := installHammerspoonStep(explicit); err != nil {
		t.Fatal(err)
	}
	if target, err := os.Readlink(link + ".pultik-backup"); err != nil || target != dotfiles {
		t.Fatalf("--hammerspoon-force did not keep the copied config as a backup: %q err=%v", target, err)
	}
	managed := filepath.Join(home, "Library", "Application Support", "Pultik", "hammerspoon", "init.lua")
	if target, err := os.Readlink(link); err != nil || target != managed {
		t.Fatalf("--hammerspoon-force did not link pultik: %q err=%v", target, err)
	}
}

// A checkout that moved leaves a dangling link; that link is still pultik's,
// so a full install repairs it instead of keeping it.
func TestFullInstallRepairsAMovedPultikLink(t *testing.T) {
	home := isolateHammerspoonHome(t)
	link := filepath.Join(home, ".hammerspoon", "init.lua")
	if err := os.MkdirAll(filepath.Dir(link), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink("/gone/Projects/pultik/hammerspoon/init.lua", link); err != nil {
		t.Fatal(err)
	}
	full, _, _ := parseInstallOptions(nil)
	if err := installHammerspoonStep(full); err != nil {
		t.Fatal(err)
	}
	managed := filepath.Join(home, "Library", "Application Support", "Pultik", "hammerspoon", "init.lua")
	if target, err := os.Readlink(link); err != nil || target != managed {
		t.Fatalf("the moved pultik link was not repaired: %q err=%v", target, err)
	}
	if matches, _ := filepath.Glob(link + ".pultik-backup*"); len(matches) != 0 {
		t.Fatalf("pultik's own link needs no backup: %v", matches)
	}
}

func TestInstallHammerspoonEmbeddedFallback(t *testing.T) {
	home := isolateHammerspoonHome(t)
	if err := installHammerspoon(); err != nil {
		t.Fatal(err)
	}
	link := filepath.Join(home, ".hammerspoon", "init.lua")
	target, err := os.Readlink(link)
	if err != nil {
		t.Fatalf("init.lua is not a symlink: %v", err)
	}
	managed := filepath.Join(home, "Library", "Application Support", "Pultik", "hammerspoon")
	if filepath.Dir(target) != managed {
		t.Fatalf("expected link into %s, got %s", managed, target)
	}
	for _, name := range hammerspoonFiles {
		actual, err := os.ReadFile(filepath.Join(managed, name))
		if err != nil {
			t.Fatalf("%s not materialized: %v", name, err)
		}
		expected, err := installAssets.ReadFile("installassets/hammerspoon/" + name)
		if err != nil {
			t.Fatal(err)
		}
		if string(actual) != string(expected) {
			t.Fatalf("%s differs from the embedded asset", name)
		}
	}
}

func TestInstallHammerspoonBacksUpUnmanagedInit(t *testing.T) {
	home := isolateHammerspoonHome(t)
	link := filepath.Join(home, ".hammerspoon", "init.lua")
	if err := os.MkdirAll(filepath.Dir(link), 0o755); err != nil {
		t.Fatal(err)
	}
	original := []byte("-- hand-written config")
	if err := os.WriteFile(link, original, 0o644); err != nil {
		t.Fatal(err)
	}
	if err := installHammerspoon(); err != nil {
		t.Fatal(err)
	}
	backup, err := os.ReadFile(link + ".pultik-backup")
	if err != nil {
		t.Fatalf("no backup of the hand-written config: %v", err)
	}
	if string(backup) != string(original) {
		t.Fatalf("backup content mangled: %q", backup)
	}
	if _, err := os.Readlink(link); err != nil {
		t.Fatalf("init.lua was not replaced by the managed symlink: %v", err)
	}
}

func TestInstallHammerspoonPrefersRepo(t *testing.T) {
	isolateHammerspoonHome(t)
	repo := t.TempDir()
	dir := filepath.Join(repo, "hammerspoon")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	for _, name := range hammerspoonFiles {
		if err := os.WriteFile(filepath.Join(dir, name), []byte("-- repo"), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	t.Setenv("PULTIK_REPO", repo)
	if err := installHammerspoon(); err != nil {
		t.Fatal(err)
	}
	home := os.Getenv("HOME")
	target, err := os.Readlink(filepath.Join(home, ".hammerspoon", "init.lua"))
	if err != nil {
		t.Fatal(err)
	}
	if target != filepath.Join(dir, "init.lua") {
		t.Fatalf("expected repo link, got %s", target)
	}
	// A second run must be a no-op, not an error.
	if err := installHammerspoon(); err != nil {
		t.Fatalf("reinstall over own symlink failed: %v", err)
	}
}

// An existing symlink into a live checkout survives an embedded-mode reinstall:
// the ladder treats it as the detected repo instead of downgrading to copies.
func TestInstallHammerspoonKeepsExistingRepoLink(t *testing.T) {
	home := isolateHammerspoonHome(t)
	repo := t.TempDir()
	dir := filepath.Join(repo, "hammerspoon")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	// A checkout carries tools/pultik beside its hammerspoon package.
	if err := os.MkdirAll(filepath.Join(repo, "tools", "pultik"), 0o755); err != nil {
		t.Fatal(err)
	}
	for _, name := range hammerspoonFiles {
		if err := os.WriteFile(filepath.Join(dir, name), []byte("-- repo"), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	link := filepath.Join(home, ".hammerspoon", "init.lua")
	if err := os.MkdirAll(filepath.Dir(link), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(filepath.Join(dir, "init.lua"), link); err != nil {
		t.Fatal(err)
	}
	if err := installHammerspoon(); err != nil {
		t.Fatal(err)
	}
	target, err := os.Readlink(link)
	if err != nil {
		t.Fatal(err)
	}
	if target != filepath.Join(dir, "init.lua") {
		t.Fatalf("live repo link was downgraded to %s", target)
	}
}

func TestCheckHammerspoon(t *testing.T) {
	home := isolateHammerspoonHome(t)
	if check := checkHammerspoon(); check.Status != "warning" {
		t.Fatalf("missing install must be a warning, got %+v", check)
	}
	if err := installHammerspoon(); err != nil {
		t.Fatal(err)
	}
	if check := checkHammerspoon(); check.Status != "ok" {
		t.Fatalf("healthy install reported %+v", check)
	}
	// Delete the sibling: a target directory missing organize.lua is broken
	// (init.lua dofile()s it), and doctor must say so.
	managed := filepath.Join(home, "Library", "Application Support", "Pultik", "hammerspoon")
	if err := os.Remove(filepath.Join(managed, "organize.lua")); err != nil {
		t.Fatal(err)
	}
	if check := checkHammerspoon(); check.Status != "error" {
		t.Fatalf("broken sibling must be an error, got %+v", check)
	}
}

// The embedded assets are copies of the repo's hammerspoon/ package (go:generate
// in hammerspoon.go refreshes them); drift means the installer ships stale Lua.
func TestEmbeddedHammerspoonMatchesRepo(t *testing.T) {
	for _, name := range hammerspoonFiles {
		repoFile := filepath.Join("..", "..", "hammerspoon", name)
		expected, err := os.ReadFile(repoFile)
		if os.IsNotExist(err) {
			t.Skipf("repo checkout not present (%s)", repoFile)
		}
		if err != nil {
			t.Fatal(err)
		}
		embedded, err := installAssets.ReadFile("installassets/hammerspoon/" + name)
		if err != nil {
			t.Fatalf("%s is not embedded: %v", name, err)
		}
		if string(embedded) != string(expected) {
			t.Errorf("installassets/hammerspoon/%s is stale — run `go generate` to refresh it from ../../hammerspoon", name)
		}
	}
}

// --hammerspoon is the documented spelling (README, decision log); it must
// behave exactly like --hammerspoon-only rather than erroring as unknown.
func TestHammerspoonFlagAlias(t *testing.T) {
	opts, _, err := parseInstallOptions([]string{"--hammerspoon"})
	if err != nil || opts.app || opts.cli || opts.skills || opts.hooks || !opts.hammerspoon {
		t.Fatalf("--hammerspoon must alias --hammerspoon-only: %+v err=%v", opts, err)
	}
}

// A relative symlink target resolves against the LINK's directory, not the
// process cwd — doctor from any other directory must still report healthy.
func TestCheckHammerspoonRelativeSymlink(t *testing.T) {
	home := isolateHammerspoonHome(t)
	if err := installHammerspoon(); err != nil {
		t.Fatal(err)
	}
	link := filepath.Join(home, ".hammerspoon", "init.lua")
	if err := os.Remove(link); err != nil {
		t.Fatal(err)
	}
	// Same managed target, expressed relative to ~/.hammerspoon.
	rel := filepath.Join("..", "Library", "Application Support", "Pultik", "hammerspoon", "init.lua")
	if err := os.Symlink(rel, link); err != nil {
		t.Fatal(err)
	}
	if check := checkHammerspoon(); check.Status != "ok" {
		t.Fatalf("relative symlink must resolve against the link dir, got %+v", check)
	}
}

// Only a moved checkout's exact link shape is pultik's. Dangling links that
// merely pass through a directory named pultik belong to the user: a full
// install keeps them, and --hammerspoon-force keeps them as a backup.
func TestDanglingForeignLinksThroughAPultikDirectoryAreKept(t *testing.T) {
	for _, target := range []string{
		"/Volumes/dotfiles/pultik/custom/init.lua",
		"/srv/pultik/dotfiles/hammerspoon/init.lua",
	} {
		t.Run(target, func(t *testing.T) {
			home := isolateHammerspoonHome(t)
			link := filepath.Join(home, ".hammerspoon", "init.lua")
			if err := os.MkdirAll(filepath.Dir(link), 0o755); err != nil {
				t.Fatal(err)
			}
			if err := os.Symlink(target, link); err != nil {
				t.Fatal(err)
			}
			full, _, _ := parseInstallOptions(nil)
			if err := installHammerspoonStep(full); err != nil {
				t.Fatal(err)
			}
			if got, err := os.Readlink(link); err != nil || got != target {
				t.Fatalf("a full install replaced the user's link: %q err=%v", got, err)
			}
			forced, _, _ := parseInstallOptions([]string{"--hammerspoon-only", "--hammerspoon-force"})
			if err := installHammerspoonStep(forced); err != nil {
				t.Fatal(err)
			}
			if got, err := os.Readlink(link + ".pultik-backup"); err != nil || got != target {
				t.Fatalf("the forced install did not keep the user's link: %q err=%v", got, err)
			}
		})
	}
}

// A forced replace of a hand-written file keeps it as a hard link under a
// new name and never touches an older backup.
func TestForcedReplaceKeepsAHandWrittenFileBesideOlderBackups(t *testing.T) {
	home := isolateHammerspoonHome(t)
	link := filepath.Join(home, ".hammerspoon", "init.lua")
	if err := os.MkdirAll(filepath.Dir(link), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(link+".pultik-backup", []byte("-- older"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(link, []byte("-- hand-written"), 0o644); err != nil {
		t.Fatal(err)
	}
	forced, _, _ := parseInstallOptions([]string{"--hammerspoon-only", "--hammerspoon-force"})
	if err := installHammerspoonStep(forced); err != nil {
		t.Fatal(err)
	}
	if data, err := os.ReadFile(link + ".pultik-backup"); err != nil || string(data) != "-- older" {
		t.Fatalf("the older backup was overwritten: %q err=%v", data, err)
	}
	matches, _ := filepath.Glob(link + ".pultik-backup-*")
	if len(matches) != 1 {
		t.Fatalf("expected one new timestamped backup, got %v", matches)
	}
	if data, err := os.ReadFile(matches[0]); err != nil || string(data) != "-- hand-written" {
		t.Fatalf("the new backup is not the hand-written file: %q err=%v", data, err)
	}
}
