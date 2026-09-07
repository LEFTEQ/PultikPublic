package main

import (
	"os"
	"path/filepath"
	"testing"
)

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
