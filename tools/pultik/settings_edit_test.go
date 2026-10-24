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

func TestMergeClaudeSettingsKeepsEveryByteOutsideSessionStart(t *testing.T) {
	raw := []byte(handWrittenSettings)
	merged, err := mergeClaudeSettings(raw, "/opt/vitrinka")
	if err != nil {
		t.Fatal(err)
	}
	head := handWrittenSettings[:strings.Index(handWrittenSettings, `"SessionStart": [`)]
	tail := handWrittenSettings[strings.Index(handWrittenSettings, "\n  },\n  \"env\""):]
	text := string(merged)
	if !strings.HasPrefix(text, head) || !strings.HasSuffix(text, tail) {
		t.Fatalf("bytes outside hooks.SessionStart changed:\n%s", merged)
	}
	for _, escape := range []string{`\u0026`, `\u003c`, `\u003e`} {
		if strings.Contains(text, escape) {
			t.Fatalf("output escapes %s:\n%s", escape, merged)
		}
	}
	if !strings.Contains(text, `{ "type": "command", "command": "deployik context --hook" }`) {
		t.Fatalf("the user's own SessionStart group was reformatted:\n%s", merged)
	}
	if !strings.Contains(text, `'/opt/vitrinka' hook-context todo 2>/dev/null || true; # `+todoHookTag) {
		t.Fatalf("our hook line is missing or escaped:\n%s", merged)
	}
	var settings map[string]any
	if err := json.Unmarshal(merged, &settings); err != nil {
		t.Fatalf("output is not JSON: %v\n%s", err, merged)
	}
}

func TestMergeClaudeSettingsRerunIsByteIdentical(t *testing.T) {
	first, err := mergeClaudeSettings([]byte(handWrittenSettings), "/opt/vitrinka")
	if err != nil {
		t.Fatal(err)
	}
	second, err := mergeClaudeSettings(first, "/opt/vitrinka")
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(first, second) {
		t.Fatalf("a rerun changed the file:\nfirst:\n%s\nsecond:\n%s", first, second)
	}
}

func TestMergeClaudeSettingsInsertsMissingHooksInTheFileStyle(t *testing.T) {
	for name, input := range map[string]string{
		"spaces": "{\n    \"model\": \"opus\",\n    \"env\": {\"A\": \"x && y\"}\n}\n",
		"tabs":   "{\n\t\"model\": \"opus\"\n}\n",
		"empty":  "{}\n",
	} {
		t.Run(name, func(t *testing.T) {
			merged, err := mergeClaudeSettings([]byte(input), "/opt/vitrinka")
			if err != nil {
				t.Fatal(err)
			}
			var settings map[string]any
			if err := json.Unmarshal(merged, &settings); err != nil {
				t.Fatalf("output is not JSON: %v\n%s", err, merged)
			}
			if len(pultikHookCommands(merged)) != 2 {
				t.Fatalf("expected our two hooks:\n%s", merged)
			}
			body := strings.TrimSuffix(strings.TrimSuffix(strings.TrimSuffix(input, "\n"), "}"), "\n")
			if !strings.HasPrefix(string(merged), body) {
				t.Fatalf("existing members changed:\n%s", merged)
			}
			if name == "spaces" && !strings.Contains(string(merged), "\n    \"hooks\": {\n        \"SessionStart\": [") {
				t.Fatalf("four-space indent not followed:\n%s", merged)
			}
			if name == "tabs" && !strings.Contains(string(merged), "\n\t\"hooks\": {\n\t\t\"SessionStart\": [") {
				t.Fatalf("tab indent not followed:\n%s", merged)
			}
		})
	}
}

func TestMergeClaudeSettingsInsertsSessionStartBesideOtherHooks(t *testing.T) {
	input := "{\n  \"hooks\": {\n    \"Stop\": [{\"hooks\": [{\"type\": \"command\", \"command\": \"a && b\"}]}]\n  }\n}\n"
	merged, err := mergeClaudeSettings([]byte(input), "/opt/vitrinka")
	if err != nil {
		t.Fatal(err)
	}
	text := string(merged)
	if !strings.HasPrefix(text, "{\n  \"hooks\": {\n    \"Stop\": [{\"hooks\": [{\"type\": \"command\", \"command\": \"a && b\"}]}],\n    \"SessionStart\": [") {
		t.Fatalf("SessionStart was not added after the existing hook event:\n%s", merged)
	}
	if len(pultikHookCommands(merged)) != 2 {
		t.Fatalf("expected our two hooks:\n%s", merged)
	}
}

func TestMergeClaudeSettingsKeepsASingleLineFileOnOneLine(t *testing.T) {
	input := `{"theme":"dark","hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"x && y"}]}]}}`
	merged, err := mergeClaudeSettings([]byte(input), "/opt/vitrinka")
	if err != nil {
		t.Fatal(err)
	}
	if bytes.ContainsRune(merged, '\n') {
		t.Fatalf("a one-line file became multi-line:\n%s", merged)
	}
	if !strings.HasPrefix(string(merged), `{"theme":"dark","hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"x && y"}]},`) {
		t.Fatalf("existing text changed:\n%s", merged)
	}
}

func TestMergeClaudeSettingsTreatsNullLikeAMissingKey(t *testing.T) {
	for _, input := range []string{"{\n  \"hooks\": null\n}\n", "{\n  \"hooks\": {\"SessionStart\": null}\n}\n"} {
		merged, err := mergeClaudeSettings([]byte(input), "/opt/vitrinka")
		if err != nil {
			t.Fatalf("%s: %v", input, err)
		}
		if len(pultikHookCommands(merged)) != 2 {
			t.Fatalf("expected our two hooks:\n%s", merged)
		}
	}
}

// A file the old installer wrote (keys sorted, `>` escaped as \u003e) that
// already holds the current hooks is left exactly as it is.
func TestMergeClaudeSettingsLeavesAnOldStyleCurrentFileAlone(t *testing.T) {
	settings := map[string]any{
		"theme": "dark",
		"hooks": map[string]any{"SessionStart": []hookGroup{
			{Hooks: []commandHook{{Type: "command", Command: hookCommand("/opt/vitrinka", "todo"), Timeout: 15}}},
			{Hooks: []commandHook{{Type: "command", Command: hookCommand("/opt/vitrinka", "schedule"), Timeout: 15}}},
		}},
	}
	old, err := json.MarshalIndent(settings, "", "  ")
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(old), `\u003e`) {
		t.Fatalf("fixture lost the old escapes: %s", old)
	}
	merged, err := mergeClaudeSettings(old, "/opt/vitrinka")
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(merged, old) {
		t.Fatalf("an old-style current file was rewritten:\n%s", merged)
	}
}

func TestMergeClaudeSettingsKeepsCRLFLineEndings(t *testing.T) {
	input := "{\r\n  \"model\": \"opus\"\r\n}\r\n"
	merged, err := mergeClaudeSettings([]byte(input), "/opt/vitrinka")
	if err != nil {
		t.Fatal(err)
	}
	if strings.Count(string(merged), "\n") != strings.Count(string(merged), "\r\n") {
		t.Fatalf("a CRLF file got bare LF lines: %q", merged)
	}
	if len(pultikHookCommands(merged)) != 2 {
		t.Fatalf("expected our two hooks: %q", merged)
	}
}

func TestMergeClaudeSettingsRejectsNonObjects(t *testing.T) {
	for _, input := range []string{`null`, `[]`, `{"hooks":[]}`, `{"hooks":{"SessionStart":{}}}`} {
		if _, err := mergeClaudeSettings([]byte(input), "/opt/vitrinka"); err == nil {
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

func TestInstallClaudeHooksLeavesACurrentFileAlone(t *testing.T) {
	dir := isolateClaudeConfig(t)
	path := filepath.Join(dir, "settings.json")
	binary, _ := vitrinkaBinary()
	current, err := mergeClaudeSettings([]byte(handWrittenSettings), binary)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, current, 0o600); err != nil {
		t.Fatal(err)
	}
	if err := installClaudeHooks(false); err != nil {
		t.Fatal(err)
	}
	after, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(after, current) {
		t.Fatalf("a current settings.json was rewritten:\n%s", after)
	}
	if matches, _ := filepath.Glob(path + ".pultik-backup*"); len(matches) != 0 {
		t.Fatalf("a no-op run wrote backups: %v", matches)
	}
}

func TestInstallClaudeHooksNeverOverwritesABackup(t *testing.T) {
	dir := isolateClaudeConfig(t)
	path := filepath.Join(dir, "settings.json")
	if err := os.WriteFile(path, []byte(handWrittenSettings), 0o600); err != nil {
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
	fresh, err := os.ReadFile(matches[0])
	if err != nil || string(fresh) != handWrittenSettings {
		t.Fatalf("the new backup is not the pre-install file: err=%v", err)
	}
}

func TestInstallClaudeHooksWritesThroughASymlinkedSettingsFile(t *testing.T) {
	dir := isolateClaudeConfig(t)
	dotfiles := filepath.Join(t.TempDir(), "settings.json")
	if err := os.WriteFile(dotfiles, []byte(handWrittenSettings), 0o644); err != nil {
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
	merged, err := os.ReadFile(dotfiles)
	if err != nil {
		t.Fatal(err)
	}
	if len(pultikHookCommands(merged)) != 2 {
		t.Fatalf("the link target did not get our hooks:\n%s", merged)
	}
	if info, err := os.Stat(dotfiles); err != nil || info.Mode().Perm() != 0o644 {
		t.Fatalf("the edit changed the file mode: %v err=%v", info.Mode(), err)
	}
}

func TestInstallClaudeHooksRefusesADanglingSettingsLink(t *testing.T) {
	dir := isolateClaudeConfig(t)
	missing := filepath.Join(t.TempDir(), "not-yet", "settings.json")
	path := filepath.Join(dir, "settings.json")
	if err := os.Symlink(missing, path); err != nil {
		t.Fatal(err)
	}
	if err := installClaudeHooks(true); err != nil {
		t.Fatalf("a dry run must only warn: %v", err)
	}
	if err := installClaudeHooks(false); err == nil {
		t.Fatal("a dangling settings.json link was accepted")
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
