package main

import (
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestParseInstallOptions(t *testing.T) {
	opts, help, err := parseInstallOptions([]string{"--skills-only", "--replace-skills"})
	if err != nil || help {
		t.Fatalf("parse: help=%v err=%v", help, err)
	}
	if opts.app || opts.cli || !opts.skills || opts.hooks || !opts.replaceSkills {
		t.Fatalf("unexpected options: %+v", opts)
	}
	if _, _, err := parseInstallOptions([]string{"--wat"}); err == nil {
		t.Fatal("unknown flag accepted")
	}
	opts, _, err = parseInstallOptions([]string{"--replace-skills", "--skills-only"})
	if err != nil || !opts.replaceSkills || !opts.skills {
		t.Fatalf("--replace-skills lost to flag order: %+v err=%v", opts, err)
	}
}

func TestRetireClaudeHooksKeepsUnrelatedSettings(t *testing.T) {
	input := []byte(`{"theme":"dark","hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"printf unrelated"}]},` +
		`{"hooks":[{"type":"command","command":"'/opt/vitrinka' hook-context todo 2>/dev/null || true; # ` + todoHookTag + `","timeout":15}]},` +
		`{"hooks":[{"type":"command","command":"'/opt/vitrinka' hook-context schedule 2>/dev/null || true; # ` + timeHookTag + `","timeout":15}]}]}}`)
	first, err := retireClaudeHooks(input)
	if err != nil {
		t.Fatal(err)
	}
	if want := `{"theme":"dark","hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"printf unrelated"}]}]}}`; string(first) != want {
		t.Fatalf("retired:\n%s\nwant:\n%s", first, want)
	}
	second, err := retireClaudeHooks(first)
	if err != nil || !bytes.Equal(first, second) {
		t.Fatalf("a rerun changed the file: %s err=%v", second, err)
	}
}

func TestRetireClaudeHooksPreservesMixedHookGroup(t *testing.T) {
	input := []byte(`{"hooks":{"SessionStart":[{"matcher":"startup","hooks":[{"type":"command","command":"pultik todo list --open --compact --here"},{"type":"command","command":"printf unrelated"}]}]}}`)
	retired, err := retireClaudeHooks(input)
	if err != nil {
		t.Fatal(err)
	}
	// The user's group keeps its own bytes, compact spacing included.
	if want := `{"hooks":{"SessionStart":[{"matcher":"startup","hooks":[{"type":"command","command":"printf unrelated"}]}]}}`; string(retired) != want {
		t.Fatalf("mixed group not preserved:\n%s", retired)
	}
}

func TestRetireClaudeHooksRejectsInvalidJSON(t *testing.T) {
	if _, err := retireClaudeHooks([]byte(`{"hooks":`)); err == nil {
		t.Fatal("invalid settings accepted")
	}
}

// The skills moved into the vitrinka plugin: the installer retires the copies
// it once wrote (marker or repo-link) and never touches a same-named skill the
// user owns.
func TestRetireLegacySkillsKeepsUserSkills(t *testing.T) {
	config := t.TempDir()
	t.Setenv("CLAUDE_CONFIG_DIR", config)
	skills := filepath.Join(config, "skills")
	managed := filepath.Join(skills, "todo")
	if err := os.MkdirAll(managed, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(managed, ".pultik-managed"), nil, 0o644); err != nil {
		t.Fatal(err)
	}
	personal := filepath.Join(skills, "remind")
	if err := os.MkdirAll(personal, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(personal, "SKILL.md"), []byte("personal skill"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(filepath.Join(t.TempDir(), "gone", "tools", "pultik", "installassets", "skills", "todo-list"),
		filepath.Join(skills, "todo-list")); err != nil {
		t.Fatal(err)
	}
	// A dangling link into somewhere ELSE (a user's own checkout, an
	// unmounted volume) is not ours, however broken it is right now.
	if err := os.Symlink(filepath.Join(t.TempDir(), "gone", "my-skills", "todo-done"),
		filepath.Join(skills, "todo-done")); err != nil {
		t.Fatal(err)
	}
	if err := retireLegacySkills(false); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Lstat(filepath.Join(skills, "todo-done")); err != nil {
		t.Fatalf("a user's dangling link was claimed as installer-owned: %v", err)
	}
	if _, err := os.Stat(managed); !os.IsNotExist(err) {
		t.Fatal("managed copy survived retirement")
	}
	if _, err := os.Lstat(filepath.Join(skills, "todo-list")); !os.IsNotExist(err) {
		t.Fatal("dangling repo link survived retirement")
	}
	if _, err := os.Stat(filepath.Join(personal, "SKILL.md")); err != nil {
		t.Fatalf("user-owned skill was removed: %v", err)
	}
}

func TestRecoverInterruptedSwap(t *testing.T) {
	dir := t.TempDir()
	destination := filepath.Join(dir, "Pultik.app")
	backup := filepath.Join(dir, ".Pultik.app.previous")

	if err := recoverInterruptedSwap(destination, backup); err != nil {
		t.Fatalf("nothing to recover: %v", err)
	}
	if err := os.MkdirAll(backup, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := recoverInterruptedSwap(destination, backup); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(destination); err != nil {
		t.Fatalf("stranded backup was not restored: %v", err)
	}
	if _, err := os.Stat(backup); !os.IsNotExist(err) {
		t.Fatal("backup still present after restore")
	}

	if err := os.MkdirAll(backup, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := recoverInterruptedSwap(destination, backup); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(backup); err != nil {
		t.Fatal("backup was touched although the destination exists")
	}
}

func TestInstallReleasedAppRecoversBeforeDownload(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv("PULTIK_APP_URL", "http://127.0.0.1:1/pultik.zip")
	apps := filepath.Join(home, "Applications")
	if err := os.MkdirAll(filepath.Join(apps, ".Pultik.app.previous"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := installReleasedApp(); err == nil {
		t.Fatal("unreachable download unexpectedly succeeded")
	}
	if _, err := os.Stat(filepath.Join(apps, "Pultik.app")); err != nil {
		t.Fatalf("stranded app was not recovered before the failed download: %v", err)
	}
}

// Every generation goes: the vitrinka-tagged pair, the `pultik:` tagged pair
// before it (2026-09), and an unrelated hook stays.
func TestRetireClaudeHooksRetiresEveryTaggedGeneration(t *testing.T) {
	input := []byte(`{"hooks":{"SessionStart":[` +
		`{"hooks":[{"type":"command","command":"'/Users/x/.local/bin/pultik' hook-context todo 2>/dev/null || true; # pultik:todo-session-context","timeout":15}]},` +
		`{"hooks":[{"type":"command","command":"'/Users/x/.local/bin/pultik' hook-context schedule 2>/dev/null || true; # pultik:schedule-session-context","timeout":15}]},` +
		`{"hooks":[{"type":"command","command":"deployik context --hook"}]},` +
		`{"hooks":[{"type":"command","command":"'/opt/vitrinka' hook-context todo 2>/dev/null || true; # vitrinka:todo-session-context","timeout":15}]},` +
		`{"hooks":[{"type":"command","command":"'/opt/vitrinka' hook-context schedule 2>/dev/null || true; # vitrinka:schedule-session-context","timeout":15}]}` +
		`]}}`)
	if listed := pultikHookCommands(input); len(listed) != 4 {
		t.Fatalf("the dry run should list four hooks to retire, got %v", listed)
	}
	retired, err := retireClaudeHooks(input)
	if err != nil {
		t.Fatal(err)
	}
	if left := pultikHookCommands(retired); len(left) != 0 {
		t.Fatalf("pultik hooks survived: %v\n%s", left, retired)
	}
	if want := `{"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"deployik context --hook"}]}]}}`; string(retired) != want {
		t.Fatalf("retired:\n%s\nwant:\n%s", retired, want)
	}
}

// The legacy hooks quote the binary path, so the retirement matcher must not
// depend on `pultik` and the verb being adjacent. This is the exact shape found
// installed in the field on 2026-08-27, where both hook pairs coexisted and the
// todo context printed twice per session.
func TestRetireClaudeHooksRetiresQuotedLegacyHooks(t *testing.T) {
	input := []byte(`{"hooks":{"SessionStart":[` +
		`{"hooks":[{"type":"command","command":"out=$(\"$HOME/.local/bin/pultik\" todo list --open --compact --here 2>/dev/null); [ -n \"$out\" ] && printf %s \"$out\" | jq -Rs '{}'; true","timeout":15}]},` +
		`{"hooks":[{"type":"command","command":"out=$(\"$HOME/.local/bin/pultik\" schedule ripe --claim --compact 2>/dev/null); true","timeout":15}]},` +
		`{"hooks":[{"type":"command","command":"deployik context --hook"}]}` +
		`]}}`)
	retired, err := retireClaudeHooks(input)
	if err != nil {
		t.Fatal(err)
	}
	text := string(retired)
	if strings.Contains(text, "todo list --open") || strings.Contains(text, "schedule ripe --claim") {
		t.Fatalf("quoted legacy hooks survived: %s", retired)
	}
	if !strings.Contains(text, "deployik context --hook") {
		t.Fatalf("an unrelated hook was removed: %s", retired)
	}
}

// A user-owned script that happens to mention a todo list is not ours.
func TestRetireClaudeHooksLeavesUnrelatedTodoHooks(t *testing.T) {
	input := []byte(`{"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"mytool todo list --open --compact --here"}]}]}}`)
	retired, err := retireClaudeHooks(input)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(retired, input) {
		t.Fatalf("an unrelated tool's hook was claimed as ours: %s", retired)
	}
}
