package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
)

// A settings.json the way people write it: keys in their own order, shell
// operators in commands, and a SessionStart group that is not ours.
const handWrittenSettings = `{
  "model": "opus",
  "statusLine": {
    "type": "command",
    "command": "bun run status.ts && echo \"a<b>c\" 2>&1"
  },
  "hooks": {
    "PreToolUse": [
      { "matcher": "Bash", "hooks": [ { "type": "command", "command": "guard.sh 2>/dev/null || true" } ] }
    ],
    "SessionStart": [
      {
        "hooks": [
          { "type": "command", "command": "deployik context --hook" }
        ]
      }
    ]
  },
  "env": { "BRACES": "}{][", "QUOTE": "say \"hi\" \\ bye" }
}
`

// writtenHook is a hook line exactly as installs before 2026-11 wrote it, so
// the fixtures hold what Macs in the field carry.
func writtenHook(kind string) string {
	tag := todoHookTag
	if kind == "schedule" {
		tag = timeHookTag
	}
	return "'/opt/vitrinka' hook-context " + kind + " 2>/dev/null || true; # " + tag
}

// handWrittenWithOurHooks is handWrittenSettings after an older install
// appended its two groups to hooks.SessionStart.
func handWrittenWithOurHooks(t *testing.T) string {
	t.Helper()
	var groups []string
	for _, kind := range []string{"todo", "schedule"} {
		group, err := json.Marshal(map[string]any{"hooks": []map[string]any{{"type": "command", "command": writtenHook(kind), "timeout": 15}}})
		if err != nil {
			t.Fatal(err)
		}
		groups = append(groups, string(group))
	}
	closing := "\n      }\n    ]\n  },\n  \"env\""
	if !strings.Contains(handWrittenSettings, closing) {
		t.Fatal("fixture changed shape")
	}
	return strings.Replace(handWrittenSettings, closing,
		"\n      },\n      "+groups[0]+",\n      "+groups[1]+"\n    ]\n  },\n  \"env\"", 1)
}

func TestRetireClaudeHooksRestoresTheHandWrittenFile(t *testing.T) {
	input := handWrittenWithOurHooks(t)
	if len(pultikHookCommands([]byte(input))) != 2 {
		t.Fatalf("fixture lacks our two hooks:\n%s", input)
	}
	retired, err := retireClaudeHooks([]byte(input))
	if err != nil {
		t.Fatal(err)
	}
	if string(retired) != handWrittenSettings {
		t.Fatalf("retiring our hooks changed other bytes:\n%s", retired)
	}
	again, err := retireClaudeHooks(retired)
	if err != nil || !bytes.Equal(again, retired) {
		t.Fatalf("a rerun changed the file:\n%s err=%v", again, err)
	}
}

func TestRetireClaudeHooksLeavesAFileWithoutThemByteIdentical(t *testing.T) {
	for name, input := range map[string]string{
		"hand-written":  handWrittenSettings,
		"spaces":        "{\n    \"model\": \"opus\",\n    \"env\": {\"A\": \"x && y\"}\n}\n",
		"tabs":          "{\n\t\"model\": \"opus\"\n}\n",
		"empty":         "{}\n",
		"null hooks":    "{\n  \"hooks\": null\n}\n",
		"null start":    "{\n  \"hooks\": {\"SessionStart\": null}\n}\n",
		"other events":  "{\n  \"hooks\": {\n    \"Stop\": [{\"hooks\": [{\"type\": \"command\", \"command\": \"a && b\"}]}]\n  }\n}\n",
		"crlf":          "{\r\n  \"model\": \"opus\"\r\n}\r\n",
		"empty session": `{"hooks":{"SessionStart":[]}}`,
	} {
		retired, err := retireClaudeHooks([]byte(input))
		if err != nil {
			t.Fatalf("%s: %v", name, err)
		}
		if string(retired) != input {
			t.Fatalf("%s: a file without our hooks changed:\n%q", name, retired)
		}
	}
}

func TestRetireClaudeHooksKeepsASingleLineFileOnOneLine(t *testing.T) {
	input := `{"theme":"dark","hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"x && y"}]},{"hooks":[{"type":"command","command":"` +
		writtenHook("todo") + `","timeout":15}]}]}}`
	retired, err := retireClaudeHooks([]byte(input))
	if err != nil {
		t.Fatal(err)
	}
	if want := `{"theme":"dark","hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"x && y"}]}]}}`; string(retired) != want {
		t.Fatalf("retired:\n%s\nwant:\n%s", retired, want)
	}
}

// A file the old installer marshalled whole (keys sorted, `>` escaped as
// >) still has our hooks found and removed.
func TestRetireClaudeHooksFromAnOldStyleFile(t *testing.T) {
	var groups []map[string]any
	for _, kind := range []string{"todo", "schedule"} {
		groups = append(groups, map[string]any{"hooks": []map[string]any{{"type": "command", "command": writtenHook(kind), "timeout": 15}}})
	}
	old, err := json.MarshalIndent(map[string]any{"theme": "dark", "hooks": map[string]any{"SessionStart": groups}}, "", "  ")
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(old), `\`+"u003e") {
		t.Fatalf("fixture lost the old escapes: %s", old)
	}
	retired, err := retireClaudeHooks(old)
	if err != nil {
		t.Fatal(err)
	}
	var settings map[string]any
	if err := json.Unmarshal(retired, &settings); err != nil || settings["theme"] != "dark" {
		t.Fatalf("output is not the same settings: %v\n%s", err, retired)
	}
	if left := pultikHookCommands(retired); len(left) != 0 {
		t.Fatalf("our hooks survived: %v", left)
	}
}

func TestRetireClaudeHooksKeepsCRLFLineEndings(t *testing.T) {
	input := "{\r\n  \"hooks\": {\r\n    \"SessionStart\": [\r\n      {\"hooks\": [{\"type\": \"command\", \"command\": \"deployik\"}]},\r\n      {\"hooks\": [{\"type\": \"command\", \"command\": \"" +
		writtenHook("todo") + "\"}]}\r\n    ]\r\n  }\r\n}\r\n"
	retired, err := retireClaudeHooks([]byte(input))
	if err != nil {
		t.Fatal(err)
	}
	if strings.Count(string(retired), "\n") != strings.Count(string(retired), "\r\n") {
		t.Fatalf("a CRLF file got bare LF lines: %q", retired)
	}
	if left := pultikHookCommands(retired); len(left) != 0 || !strings.Contains(string(retired), "deployik") {
		t.Fatalf("retired wrongly: %q", retired)
	}
}

func TestRetireClaudeHooksRejectsNonObjects(t *testing.T) {
	for _, input := range []string{`null`, `[]`, `{"hooks":[]}`, `{"hooks":{"SessionStart":{}}}`} {
		if _, err := retireClaudeHooks([]byte(input)); err == nil {
			t.Errorf("accepted %s", input)
		}
	}
}

func isolateClaudeConfig(t *testing.T) string {
	t.Helper()
	dir := t.TempDir()
	t.Setenv("CLAUDE_CONFIG_DIR", dir)
	t.Setenv("HOME", t.TempDir())
	t.Setenv("PATH", t.TempDir())
	return dir
}

func TestInstallClaudeHooksLeavesAFileWithoutThemAlone(t *testing.T) {
	dir := isolateClaudeConfig(t)
	path := filepath.Join(dir, "settings.json")
	if err := os.WriteFile(path, []byte(handWrittenSettings), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := installClaudeHooks(false); err != nil {
		t.Fatal(err)
	}
	after, err := os.ReadFile(path)
	if err != nil || string(after) != handWrittenSettings {
		t.Fatalf("a settings.json without our hooks was rewritten:\n%s err=%v", after, err)
	}
	if matches, _ := filepath.Glob(path + ".pultik-backup*"); len(matches) != 0 {
		t.Fatalf("a no-op run wrote backups: %v", matches)
	}
}

// No settings.json means no hook to retire, and the step writes none.
func TestInstallClaudeHooksNeverCreatesASettingsFile(t *testing.T) {
	dir := isolateClaudeConfig(t)
	for _, dry := range []bool{true, false} {
		if err := installClaudeHooks(dry); err != nil {
			t.Fatal(err)
		}
	}
	if _, err := os.Stat(filepath.Join(dir, "settings.json")); !os.IsNotExist(err) {
		t.Fatalf("the hooks step created settings.json: %v", err)
	}
}

func TestInstallClaudeHooksDryRunListsAndWritesNothing(t *testing.T) {
	dir := isolateClaudeConfig(t)
	path := filepath.Join(dir, "settings.json")
	input := handWrittenWithOurHooks(t)
	if err := os.WriteFile(path, []byte(input), 0o600); err != nil {
		t.Fatal(err)
	}
	out := &bytes.Buffer{}
	uiOut = out
	t.Cleanup(func() { uiOut = os.Stdout })
	if err := installClaudeHooks(true); err != nil {
		t.Fatal(err)
	}
	if after, _ := os.ReadFile(path); string(after) != input {
		t.Fatal("a dry run wrote settings.json")
	}
	if got := strings.Count(out.String(), "would remove SessionStart hook: "); got != 2 {
		t.Fatalf("the dry run listed %d hooks, want 2:\n%s", got, out.String())
	}
}

func TestInstallClaudeHooksNeverOverwritesABackup(t *testing.T) {
	dir := isolateClaudeConfig(t)
	path := filepath.Join(dir, "settings.json")
	input := handWrittenWithOurHooks(t)
	if err := os.WriteFile(path, []byte(input), 0o600); err != nil {
		t.Fatal(err)
	}
	older := []byte(`{"the":"first original"}`)
	if err := os.WriteFile(path+".pultik-backup", older, 0o600); err != nil {
		t.Fatal(err)
	}
	if err := installClaudeHooks(false); err != nil {
		t.Fatal(err)
	}
	kept, err := os.ReadFile(path + ".pultik-backup")
	if err != nil || !bytes.Equal(kept, older) {
		t.Fatalf("the older backup was overwritten: %q err=%v", kept, err)
	}
	matches, _ := filepath.Glob(path + ".pultik-backup-*")
	if len(matches) != 1 {
		t.Fatalf("expected one new timestamped backup, got %v", matches)
	}
	if fresh, err := os.ReadFile(matches[0]); err != nil || string(fresh) != input {
		t.Fatalf("the new backup is not the pre-install file: err=%v", err)
	}
	if after, err := os.ReadFile(path); err != nil || string(after) != handWrittenSettings {
		t.Fatalf("our hooks were not retired:\n%s err=%v", after, err)
	}
}

func TestInstallClaudeHooksWritesThroughASymlinkedSettingsFile(t *testing.T) {
	dir := isolateClaudeConfig(t)
	dotfiles := filepath.Join(t.TempDir(), "settings.json")
	if err := os.WriteFile(dotfiles, []byte(handWrittenWithOurHooks(t)), 0o644); err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(dir, "settings.json")
	if err := os.Symlink(dotfiles, path); err != nil {
		t.Fatal(err)
	}
	if err := installClaudeHooks(false); err != nil {
		t.Fatal(err)
	}
	if target, err := os.Readlink(path); err != nil || target != dotfiles {
		t.Fatalf("the settings.json symlink was replaced: target=%q err=%v", target, err)
	}
	if after, err := os.ReadFile(dotfiles); err != nil || string(after) != handWrittenSettings {
		t.Fatalf("the link target kept our hooks:\n%s err=%v", after, err)
	}
	if info, err := os.Stat(dotfiles); err != nil || info.Mode().Perm() != 0o644 {
		t.Fatalf("the edit changed the file mode: %v err=%v", info.Mode(), err)
	}
}

// A dangling settings.json link holds no hook: the step says so and leaves it.
func TestInstallClaudeHooksLeavesADanglingSettingsLink(t *testing.T) {
	dir := isolateClaudeConfig(t)
	missing := filepath.Join(t.TempDir(), "not-yet", "settings.json")
	path := filepath.Join(dir, "settings.json")
	if err := os.Symlink(missing, path); err != nil {
		t.Fatal(err)
	}
	for _, dry := range []bool{true, false} {
		if err := installClaudeHooks(dry); err != nil {
			t.Fatalf("dry=%v: %v", dry, err)
		}
	}
	if target, err := os.Readlink(path); err != nil || target != missing {
		t.Fatalf("the dangling link was replaced: %q err=%v", target, err)
	}
	if _, err := os.Stat(missing); !os.IsNotExist(err) {
		t.Fatalf("the missing target was created: %v", err)
	}
}

// Installs racing each other each get their own backup name, and every
// backup holds the bytes that install copied.
func TestPlaceBackupNeverSharesANameUnderRace(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "settings.json")
	const racers = 16
	names := make(chan string, racers)
	errs := make(chan error, racers)
	var start sync.WaitGroup
	start.Add(1)
	var done sync.WaitGroup
	for i := 0; i < racers; i++ {
		done.Add(1)
		go func(i int) {
			defer done.Done()
			start.Wait()
			body := []byte(fmt.Sprintf("racer %d", i))
			name, err := placeBackup(path, func(candidate string) error {
				file, err := os.OpenFile(candidate, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o600)
				if err != nil {
					return err
				}
				if _, err := file.Write(body); err != nil {
					file.Close()
					return err
				}
				return file.Close()
			})
			if err != nil {
				errs <- err
				return
			}
			names <- name + "\x00" + string(body)
		}(i)
	}
	start.Done()
	done.Wait()
	close(names)
	close(errs)
	for err := range errs {
		t.Fatal(err)
	}
	seen := map[string]bool{}
	for entry := range names {
		name, body, _ := strings.Cut(entry, "\x00")
		if seen[name] {
			t.Fatalf("two installs took the backup name %s", name)
		}
		seen[name] = true
		if data, err := os.ReadFile(name); err != nil || string(data) != body {
			t.Fatalf("%s holds %q, want %q (err=%v)", name, data, body, err)
		}
	}
	if len(seen) != racers {
		t.Fatalf("got %d backups, want %d", len(seen), racers)
	}
}
