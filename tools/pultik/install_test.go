package main

import (
	"encoding/json"
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

func TestMergeClaudeSettingsIsIdempotent(t *testing.T) {
	input := []byte(`{"theme":"dark","hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"printf unrelated"}]}]}}`)
	first, err := mergeClaudeSettings(input, "/tmp/pultik")
	if err != nil {
		t.Fatal(err)
	}
	second, err := mergeClaudeSettings(first, "/tmp/pultik")
	if err != nil {
		t.Fatal(err)
	}
	if strings.Count(string(second), todoHookTag) != 1 || strings.Count(string(second), timeHookTag) != 1 {
		t.Fatalf("hooks duplicated: %s", second)
	}
	var settings map[string]any
	if err := json.Unmarshal(second, &settings); err != nil {
		t.Fatal(err)
	}
	if settings["theme"] != "dark" || !strings.Contains(string(second), "printf unrelated") {
		t.Fatalf("unrelated settings were lost: %s", second)
	}
}

func TestMergeClaudeSettingsPreservesMixedHookGroup(t *testing.T) {
	input := []byte(`{"hooks":{"SessionStart":[{"matcher":"startup","hooks":[{"type":"command","command":"pultik todo list --open --compact --here"},{"type":"command","command":"printf unrelated"}]}]}}`)
	merged, err := mergeClaudeSettings(input, "/tmp/it's $(safe)/pultik")
	if err != nil {
		t.Fatal(err)
	}
	text := string(merged)
	if !strings.Contains(text, "printf unrelated") || !strings.Contains(text, `"matcher": "startup"`) {
		t.Fatalf("mixed group was not preserved: %s", merged)
	}
	if strings.Contains(text, "todo list --open") {
		t.Fatalf("legacy Pultik hook survived: %s", merged)
	}
	if !strings.Contains(text, `'/tmp/it'\\''s $(safe)/pultik' hook-context todo`) {
		t.Fatalf("binary was not safely shell-quoted: %s", merged)
	}
}

func TestMergeClaudeSettingsRejectsInvalidJSON(t *testing.T) {
	if _, err := mergeClaudeSettings([]byte(`{"hooks":`), "/tmp/pultik"); err == nil {
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

// One `pultik install` after the 2026-09 move must swap the `pultik:` tagged
// hooks for the vitrinka ones — and stay idempotent from there.
func TestMergeClaudeSettingsMigratesPultikTaggedHooks(t *testing.T) {
	input := []byte(`{"hooks":{"SessionStart":[` +
		`{"hooks":[{"type":"command","command":"'/Users/x/.local/bin/pultik' hook-context todo 2>/dev/null || true; # pultik:todo-session-context","timeout":15}]},` +
		`{"hooks":[{"type":"command","command":"'/Users/x/.local/bin/pultik' hook-context schedule 2>/dev/null || true; # pultik:schedule-session-context","timeout":15}]},` +
		`{"hooks":[{"type":"command","command":"deployik context --hook"}]}` +
		`]}}`)
	merged, err := mergeClaudeSettings(input, "/opt/vitrinka")
	if err != nil {
		t.Fatal(err)
	}
	text := string(merged)
	if strings.Contains(text, legacyTodoHookTag) || strings.Contains(text, legacyTimeHookTag) || strings.Contains(text, "pultik' hook-context") {
		t.Fatalf("pultik-tagged hooks survived the migration: %s", merged)
	}
	if !strings.Contains(text, "deployik context --hook") {
		t.Fatalf("an unrelated hook was removed: %s", merged)
	}
	// Compared after decoding: json.Marshal escapes `>` as >, so the
	// exact line is only visible through the parsed document.
	counts := map[string]int{}
	for _, command := range pultikHookCommands(merged) {
		counts[command]++
	}
	for _, want := range []string{
		`'/opt/vitrinka' hook-context todo 2>/dev/null || true; # ` + todoHookTag,
		`'/opt/vitrinka' hook-context schedule 2>/dev/null || true; # ` + timeHookTag,
	} {
		if counts[want] != 1 {
			t.Fatalf("expected exactly one %q, got: %s", want, merged)
		}
	}
	if len(counts) != 2 {
		t.Fatalf("unexpected pultik hooks after the merge: %v", counts)
	}
	retired := pultikHookCommands(input)
	if len(retired) != 2 {
		t.Fatalf("dry run should list the two pultik hooks to retire, got %v", retired)
	}
}

// The legacy hooks quote the binary path, so the retirement matcher must not
// depend on `pultik` and the verb being adjacent. This is the exact shape found
// installed in the field on 2026-08-27, where both hook pairs coexisted and the
// todo context printed twice per session.
func TestMergeClaudeSettingsRetiresQuotedLegacyHooks(t *testing.T) {
	input := []byte(`{"hooks":{"SessionStart":[` +
		`{"hooks":[{"type":"command","command":"out=$(\"$HOME/.local/bin/pultik\" todo list --open --compact --here 2>/dev/null); [ -n \"$out\" ] && printf %s \"$out\" | jq -Rs '{}'; true","timeout":15}]},` +
		`{"hooks":[{"type":"command","command":"out=$(\"$HOME/.local/bin/pultik\" schedule ripe --claim --compact 2>/dev/null); true","timeout":15}]},` +
		`{"hooks":[{"type":"command","command":"deployik context --hook"}]}` +
		`]}}`)
	merged, err := mergeClaudeSettings(input, "/tmp/pultik")
	if err != nil {
		t.Fatal(err)
	}
	text := string(merged)
	if strings.Contains(text, "todo list --open") || strings.Contains(text, "schedule ripe --claim") {
		t.Fatalf("quoted legacy hooks survived the merge: %s", merged)
	}
	if !strings.Contains(text, "deployik context --hook") {
		t.Fatalf("an unrelated hook was removed: %s", merged)
	}
	if strings.Count(text, "hook-context todo") != 1 {
		t.Fatalf("expected exactly one todo hook, got: %s", merged)
	}
	if strings.Count(text, "hook-context schedule") != 1 {
		t.Fatalf("expected exactly one schedule hook, got: %s", merged)
	}
}

// A user-owned script that happens to mention a todo list is not ours.
func TestMergeClaudeSettingsLeavesUnrelatedTodoHooks(t *testing.T) {
	input := []byte(`{"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"mytool todo list --open --compact --here"}]}]}}`)
	merged, err := mergeClaudeSettings(input, "/tmp/pultik")
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(merged), "mytool todo list") {
		t.Fatalf("an unrelated tool's hook was claimed as ours: %s", merged)
	}
}
