package main

import (
	"bytes"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// TestMain points HOME, the Claude config and the CLI's bin dir at a scratch
// directory for the whole package: an installer step a test forgets to
// isolate can never write the real ones (the profile step reads only HOME).
func TestMain(m *testing.M) {
	home, err := os.MkdirTemp("", "pultik-test-home-")
	if err != nil {
		panic(err)
	}
	os.Setenv("HOME", home)
	os.Setenv("CLAUDE_CONFIG_DIR", filepath.Join(home, ".claude"))
	os.Setenv("PULTIK_BIN_DIR", filepath.Join(home, ".local", "bin"))
	code := m.Run()
	os.RemoveAll(home)
	os.Exit(code)
}

// isolateAppSettings gives a test its own HOME and returns the settings.json
// the app reads there. PULTIK_SETTINGS points elsewhere: the step ignores it.
func isolateAppSettings(t *testing.T) string {
	t.Helper()
	home := t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv("PULTIK_SETTINGS", filepath.Join(t.TempDir(), "prod-only.json"))
	return filepath.Join(home, "Library", "Application Support", "Pultik", "settings.json")
}

// A Pultik settings.json the way an older app build or a hand edit leaves it:
// keys in their own order, a shell operator in a value, odd spacing.
const existingPultikSettings = `{
  "hotkey": "cmd+option+space",
  "pinnedRepos": ["owner/one"],
  "todoProject": "a&b <c>",
  "notifyFiring" : true
}
`

func TestChooseProfileAsksOnlyAMacWithoutSettings(t *testing.T) {
	picked := 0
	pick := func() (string, error) { picked++; return "genesis", nil }

	// An existing settings.json is never asked, whatever stdin is: a file
	// without a profile key reads as example (every Mac that predates profiles).
	for _, tty := range []bool{false, true} {
		if choice, err := chooseProfile("", true, tty, pick); err != nil || choice != "" {
			t.Fatalf("existing settings (tty=%v): choice=%q err=%v", tty, choice, err)
		}
	}
	if picked != 0 {
		t.Fatalf("an existing settings.json was asked %d times", picked)
	}

	// No settings.json: a terminal picks, anything else fails with the flag.
	if choice, err := chooseProfile("", false, true, pick); err != nil || choice != "genesis" || picked != 1 {
		t.Fatalf("terminal pick: choice=%q err=%v picked=%d", choice, err, picked)
	}
	_, err := chooseProfile("", false, false, pick)
	if err == nil || !strings.Contains(err.Error(), "--profile example|genesis|custom") {
		t.Fatalf("a non-terminal run must fail with the flag to pass: %v", err)
	}
	if picked != 1 {
		t.Fatal("a non-terminal run must never prompt")
	}

	// The flag wins everywhere and is validated.
	for _, exists := range []bool{false, true} {
		if choice, err := chooseProfile("custom", exists, false, pick); err != nil || choice != "custom" {
			t.Fatalf("--profile custom (exists=%v): choice=%q err=%v", exists, choice, err)
		}
	}
	if _, err := chooseProfile("Genesis", false, true, pick); err == nil {
		t.Fatal("an unknown profile was accepted")
	}

	failing := func() (string, error) { return "", errors.New("closed") }
	if _, err := chooseProfile("", false, true, failing); err == nil {
		t.Fatal("a failed pick must fail the install")
	}
}

func TestPickProfileTakesANumberOrAName(t *testing.T) {
	cases := []struct {
		input, want string
	}{
		{"2\n", "genesis"},
		{"custom\n", "custom"},
		{"Genesis\n", "genesis"},
		{"9\n\n1\n", "example"}, // re-asks after a wrong answer
		{"3", "custom"},        // a last line without a newline still counts
	}
	for _, c := range cases {
		var out bytes.Buffer
		got, err := pickProfile(strings.NewReader(c.input), &out)
		if err != nil || got != c.want {
			t.Errorf("input %q: got %q err=%v", c.input, got, err)
		}
		for _, name := range installProfiles {
			if !strings.Contains(out.String(), name) {
				t.Errorf("the prompt does not list %s:\n%s", name, out.String())
			}
		}
	}
	for _, input := range []string{"", "x\ny\nz\n", "4\n5\n6\n1\n"} {
		if got, err := pickProfile(strings.NewReader(input), &bytes.Buffer{}); err == nil {
			t.Errorf("input %q chose %q; three wrong answers or EOF must fail", input, got)
		}
	}
}

func TestRecordProfileEditsInPlace(t *testing.T) {
	raw := []byte(existingPultikSettings)
	edited, added, err := recordProfile(raw, "genesis")
	if err != nil || added != nil {
		t.Fatalf("record: added=%v err=%v", added, err)
	}
	want := strings.Replace(existingPultikSettings, `"notifyFiring" : true`,
		`"notifyFiring" : true,
  "profile": "genesis"`, 1) // the file's first member sets the colon style
	if string(edited) != want {
		t.Fatalf("only the profile member may change:\n%s\nwant:\n%s", edited, want)
	}

	// A recorded profile is replaced where it stands.
	again, _, err := recordProfile(edited, "custom")
	if err != nil {
		t.Fatal(err)
	}
	if got := strings.Count(string(again), `"profile"`); got != 1 {
		t.Fatalf("profile written %d times:\n%s", got, again)
	}
	if !strings.HasPrefix(string(again), existingPultikSettings[:strings.Index(existingPultikSettings, `"notifyFiring"`)]) {
		t.Fatalf("bytes before the profile changed:\n%s", again)
	}
	var settings map[string]any
	if err := json.Unmarshal(again, &settings); err != nil || settings["profile"] != "custom" ||
		settings["todoProject"] != "a&b <c>" || settings["hotkey"] != "cmd+option+space" {
		t.Fatalf("decoded %v err=%v", settings, err)
	}

	// No file yet: a new one holding just the profile.
	fresh, _, err := recordProfile(nil, "genesis")
	if err != nil || string(fresh) != "{\n  \"profile\": \"genesis\"\n}\n" {
		t.Fatalf("new file: %q err=%v", fresh, err)
	}

	for _, bad := range []string{`[]`, `null`, `{"a":`} {
		if _, _, err := recordProfile([]byte(bad), "genesis"); err == nil {
			t.Errorf("%s accepted as Pultik settings", bad)
		}
	}
}

func TestRecordCustomProfileWritesEveryProfileKeyOnce(t *testing.T) {
	fresh, added, err := recordProfile(nil, "custom")
	if err != nil {
		t.Fatal(err)
	}
	var settings map[string]any
	if err := json.Unmarshal(fresh, &settings); err != nil {
		t.Fatal(err)
	}
	if len(added) != len(customProfileKeys) || settings["profile"] != "custom" {
		t.Fatalf("added %v to %s", added, fresh)
	}
	for _, entry := range customProfileKeys {
		got, _ := json.Marshal(settings[entry.key])
		want, _ := json.Marshal(entry.value)
		if !bytes.Equal(got, want) {
			t.Errorf("%s = %s, want the safe default %s", entry.key, got, want)
		}
	}
	for _, unsafe := range []string{"10.8.", "example", "evelinka", "pultik_devbox"} {
		if strings.Contains(string(fresh), unsafe) {
			t.Errorf("the custom profile names %q:\n%s", unsafe, fresh)
		}
	}

	// A key the file already sets is explicit and keeps its value.
	edited, added, err := recordProfile([]byte(existingPultikSettings), "custom")
	if err != nil {
		t.Fatal(err)
	}
	for _, key := range added {
		if key == "hotkey" {
			t.Fatal("custom overwrote an explicit hotkey")
		}
	}
	if !strings.Contains(string(edited), `"hotkey": "cmd+option+space"`) || len(added) != len(customProfileKeys)-1 {
		t.Fatalf("added %v:\n%s", added, edited)
	}
	if got := explicitProfileKeys([]byte(existingPultikSettings)); len(got) != 1 || got[0] != "hotkey" {
		t.Fatalf("explicit keys %v", got)
	}
}

// A Mac whose settings.json predates profiles: the full install neither
// asks nor writes, and leaves no backup behind.
func TestProfileStepLeavesAnExistingMacAlone(t *testing.T) {
	path := isolateAppSettings(t)
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(existingPultikSettings), 0o644); err != nil {
		t.Fatal(err)
	}
	for _, args := range [][]string{nil, {"--no-app"}, {"--app-only"}, {"--dry-run"}} {
		opts, _, err := parseInstallOptions(args)
		if err != nil || !opts.profile {
			t.Fatalf("%v: profile step off or err=%v", args, err)
		}
		if err := runProfileStep(opts); err != nil {
			t.Fatalf("%v: %v", args, err)
		}
	}
	if data, _ := os.ReadFile(path); string(data) != existingPultikSettings {
		t.Fatalf("settings.json changed:\n%s", data)
	}
	if matches, _ := filepath.Glob(path + ".pultik-backup*"); len(matches) != 0 {
		t.Fatalf("an untouched file left backups: %v", matches)
	}
}

func TestProfileStepRecordsTheFlag(t *testing.T) {
	path := isolateAppSettings(t)

	// A dry run on a Mac without settings writes nothing and never asks.
	dry, _, _ := parseInstallOptions([]string{"--dry-run"})
	if err := runProfileStep(dry); err != nil {
		t.Fatal(err)
	}
	dryFlag, _, _ := parseInstallOptions([]string{"--dry-run", "--profile", "genesis"})
	if err := runProfileStep(dryFlag); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(path); !os.IsNotExist(err) {
		t.Fatalf("a dry run created settings.json: %v", err)
	}

	opts, _, _ := parseInstallOptions([]string{"--no-app", "--profile", "genesis"})
	if err := runProfileStep(opts); err != nil {
		t.Fatal(err)
	}
	if data, _ := os.ReadFile(path); string(data) != "{\n  \"profile\": \"genesis\"\n}\n" {
		t.Fatalf("new settings.json: %q", data)
	}

	// Recording over an existing file keeps a backup of what was there.
	opts, _, _ = parseInstallOptions([]string{"--profile=custom", "--cli-only"})
	if err := runProfileStep(opts); err != nil {
		t.Fatal(err)
	}
	if backup, _ := os.ReadFile(path + ".pultik-backup"); string(backup) != "{\n  \"profile\": \"genesis\"\n}\n" {
		t.Fatalf("backup: %q", backup)
	}
	var settings map[string]any
	data, _ := os.ReadFile(path)
	if err := json.Unmarshal(data, &settings); err != nil || settings["profile"] != "custom" || settings["hlidacURL"] != "" {
		t.Fatalf("custom settings %s err=%v", data, err)
	}
	if _, err := os.Stat(os.Getenv("PULTIK_SETTINGS")); !os.IsNotExist(err) {
		t.Fatalf("the step wrote PULTIK_SETTINGS, which the app never reads: %v", err)
	}
}

// captureUI collects what a step prints.
func captureUI(t *testing.T) *bytes.Buffer {
	t.Helper()
	var out bytes.Buffer
	previous := uiOut
	uiOut = &out
	t.Cleanup(func() { uiOut = previous })
	return &out
}

// A settings.json symlinked to a missing file is refused: writing would
// replace the link with a regular file.
func TestProfileStepRefusesADanglingSymlink(t *testing.T) {
	path := isolateAppSettings(t)
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	target := filepath.Join(t.TempDir(), "dotfiles", "settings.json")
	if err := os.Symlink(target, path); err != nil {
		t.Fatal(err)
	}
	for _, args := range [][]string{{"--profile", "genesis"}, nil} {
		opts, _, _ := parseInstallOptions(args)
		var dangling danglingSettings
		if err := runProfileStep(opts); !errors.As(err, &dangling) || dangling.target != target ||
			!strings.Contains(err.Error(), "which does not exist: create that file or remove the link") {
			t.Fatalf("%v: err=%v, want the dangling-link refusal", args, err)
		}
	}
	dry, _, _ := parseInstallOptions([]string{"--dry-run", "--profile", "genesis"})
	out := captureUI(t)
	if err := runProfileStep(dry); err != nil || !strings.Contains(out.String(), "which does not exist; the install would stop here") {
		t.Fatalf("a dry run only warns, as installClaudeHooks does: %v\n%s", err, out.String())
	}
	if info, err := os.Lstat(path); err != nil || info.Mode()&os.ModeSymlink == 0 {
		t.Fatalf("the link was replaced: %v %v", info, err)
	}
	if _, err := os.Stat(target); !os.IsNotExist(err) {
		t.Fatalf("the missing target was created: %v", err)
	}
}

// An empty file reads as {}; a UTF-8 BOM stays in front of the edited text.
func TestRecordProfileTakesAnEmptyFileAndKeepsABOM(t *testing.T) {
	for _, empty := range []string{"", "  \n\t"} {
		edited, _, err := recordProfile([]byte(empty), "genesis")
		if err != nil || string(edited) != "{\n  \"profile\": \"genesis\"\n}\n" {
			t.Errorf("%q: %q err=%v", empty, edited, err)
		}
	}
	bom := string(utf8BOM)
	edited, _, err := recordProfile([]byte(bom+`{"a":1}`), "genesis")
	if err != nil || string(edited) != bom+`{"a":1,"profile":"genesis"}` {
		t.Fatalf("BOM file: %q err=%v", edited, err)
	}
	empty, _, err := recordProfile([]byte(bom), "custom")
	if err != nil || !strings.HasPrefix(string(empty), bom+"{") {
		t.Fatalf("BOM-only file: %q err=%v", empty, err)
	}
}

// The step reads a file's profile the way the app does, and never calls a
// file it could not parse "example (names none)".
func TestReadProfileStateReadsLikeTheApp(t *testing.T) {
	cases := []struct {
		name, text, current string
		unreadable          bool
		// says is what the note must print; "" checks nothing more.
		says string
	}{
		{"named", `{"profile": "genesis"}`, "genesis", false, "profile genesis (recorded in"},
		{"none", `{"hotkey": "cmd+space"}`, "", false, "profile example ("},
		{"null", `{"profile": null}`, "", false, "profile example ("},
		{"wrong type", `{"profile": 3}`, "custom", false,
			"records profile 3, which is not a known profile (example, genesis, custom), so the app reads custom"},
		{"mixed case", `{"profile": "Genesis"}`, "custom", false,
			`records profile "Genesis", which is not a known profile (example, genesis, custom), so the app reads custom`},
		{"unknown name", `{"profile": "martin"}`, "custom", false, `records profile "martin", which is not a known`},
		{"BOM", string(utf8BOM) + `{"profile": "genesis"}`, "genesis", false, "profile genesis (recorded in"},
		{"empty", " \n", "", false, "profile example ("},
		{"trailing comma", "{\"profile\": \"genesis\",}", "genesis", true, "the app reads profile genesis from it"},
		{"broken, no profile", `{"hotkey": `, "", true, "the app reads profile example (it names no profile)"},
		{"broken, odd profile", `{"profile": 3,}`, "custom", true, "records profile 3, which is not a known profile"},
		{"broken, mixed case", `{"profile": "Genesis",}`, "custom", true,
			`records profile "Genesis", which is not a known profile`},
		{"array", `[]`, "", true, "cannot edit"},
	}
	for _, c := range cases {
		path := isolateAppSettings(t)
		if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(path, []byte(c.text), 0o600); err != nil {
			t.Fatal(err)
		}
		state, err := readProfileState()
		if err != nil || !state.exists || state.current != c.current || (state.unreadable != nil) != c.unreadable {
			t.Errorf("%s: current=%q unreadable=%v err=%v", c.name, state.current, state.unreadable, err)
			continue
		}
		out := captureUI(t)
		if err := installProfileStep(state, "", false); err != nil {
			t.Errorf("%s: %v", c.name, err)
		}
		if c.unreadable && (strings.Contains(out.String(), "names none") || !strings.Contains(out.String(), "cannot edit")) {
			t.Errorf("%s: %s", c.name, out.String())
		}
		if !strings.Contains(out.String(), c.says) {
			t.Errorf("%s: missing %q in:\n%s", c.name, c.says, out.String())
		}
		if c.current == "custom" && strings.Contains(out.String(), "profile Genesis") {
			t.Errorf("%s: names the raw value as the profile:\n%s", c.name, out.String())
		}
		if data, _ := os.ReadFile(path); string(data) != c.text {
			t.Errorf("%s: the file changed: %q", c.name, data)
		}
	}
}

func TestPeekProfileTextMatchesTheApp(t *testing.T) {
	for text, want := range map[string][2]string{
		`{"profile": "genesis",}`:              {"genesis", ""},
		`{"a": 1, "profile":"custom"`:          {"custom", ""},
		`{"profile": "Genesis",}`:              {"custom", `"Genesis"`},
		`{"profile": 3,}`:                      {"custom", "3"},
		`{"profile": null,}`:                   {"", ""},
		`{"hotkey": "option+space",}`:          {"", ""},
		`{"servers": [], "profile" : "example"`: {"example", ""},
	} {
		if current, recorded := peekProfileText([]byte(text)); current != want[0] || recorded != want[1] {
			t.Errorf("%s: %q %q, want %q", text, current, recorded, want)
		}
	}
}

// Recording a profile names the keys and lists that keep their values.
func TestRecordingNamesWhatKeepsPointingAtHostsAndRepos(t *testing.T) {
	out := captureUI(t)
	noteKeptProfileKeys("genesis", []byte(`{"hotkey": "x", "servers": [{"name": "a", "ref": "a"}], "projects": [],`+
		` "pinnedRepos": ["o/r"]}`))
	text := out.String()
	for _, want := range []string{"already sets hotkey, servers, projects", "servers, pinnedRepos keep pointing at the hosts and repos"} {
		if !strings.Contains(text, want) {
			t.Errorf("missing %q in:\n%s", want, text)
		}
	}
	out.Reset()
	noteKeptProfileKeys("genesis", []byte(`{"pinnedRepos": []}`))
	if out.Len() != 0 {
		t.Errorf("nothing to note, printed:\n%s", out.String())
	}
}

func TestParseInstallOptionsProfile(t *testing.T) {
	cases := []struct {
		args    []string
		profile bool
		name    string
	}{
		{nil, true, ""},
		{[]string{"--no-app"}, true, ""},
		{[]string{"--app-only"}, true, ""},
		{[]string{"--cli-only"}, false, ""},
		{[]string{"--hooks-only"}, false, ""},
		{[]string{"--profile", "genesis"}, true, "genesis"},
		{[]string{"--profile=custom"}, true, "custom"},
		{[]string{"--profile", "example", "--hooks-only"}, true, "example"},
		{[]string{"--cli-only", "--profile", "genesis"}, true, "genesis"},
	}
	for _, c := range cases {
		opts, help, err := parseInstallOptions(c.args)
		if err != nil || help || opts.profile != c.profile || opts.profileName != c.name {
			t.Errorf("%v: profile=%v name=%q err=%v", c.args, opts.profile, opts.profileName, err)
		}
	}
	hooks, _, _ := parseInstallOptions([]string{"--profile", "example", "--hooks-only"})
	if hooks.app || hooks.cli || !hooks.hooks {
		t.Errorf("--profile widened a focused mode: %+v", hooks)
	}
	for _, args := range [][]string{{"--profile"}, {"--profile", "--no-app"}, {"--profile", "wat"}, {"--profile="}} {
		if _, _, err := parseInstallOptions(args); err == nil {
			t.Errorf("%v accepted", args)
		}
	}
}

// Every key the custom profile writes is one the app resolves through its
// profile, so the file it hands the user is the one the app reads.
func TestCustomProfileKeysMatchPreferencesSwift(t *testing.T) {
	src, err := os.ReadFile("../../Apps/Pultik/Sources/Store/Preferences.swift")
	if err != nil {
		t.Fatal(err)
	}
	for _, entry := range customProfileKeys {
		if !bytes.Contains(src, []byte("forKey: ."+entry.key+")")) {
			t.Errorf("Preferences.init(from:) does not decode %s", entry.key)
		}
		if _, ok := topLevelKinds[entry.key]; !ok {
			t.Errorf("topLevelKinds misses %s", entry.key)
		}
	}
	if _, ok := topLevelKinds["profile"]; !ok {
		t.Error("topLevelKinds misses profile")
	}
}

func TestPublicMirrorIncludesTheProfileFiles(t *testing.T) {
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
	included := map[string]bool{}
	for _, path := range manifest.Include {
		included[path] = true
	}
	for _, path := range []string{
		"tools/pultik/profile.go",
		"tools/pultik/profile_test.go",
		"Apps/Pultik/Sources/Models/Profile.swift",
		"Apps/Pultik/Sources/Support/ExecutableSearch.swift",
	} {
		if !included[path] {
			t.Errorf("public mirror omits %s", path)
		}
	}
}

// `pultik prod` reads settings.json the way the app does: only example's
// defaults name deployments or a Hlídač.
func TestProdReadsTheProfilesDefaults(t *testing.T) {
	example, err := readSettings([]byte(`{"projects":[{"key":"exampleapp"}]}`))
	if err != nil || len(example.pointers) == 0 {
		t.Fatalf("example lost its shipped pointers: %+v err=%v", example.pointers, err)
	}
	for _, doc := range []string{`{"profile":"genesis"}`, `{"profile":"genesis","projects":[{"key":"exampleapp"}]}`,
		`{"profile":"custom","projects":null}`} {
		view, err := readSettings([]byte(doc))
		if err != nil || len(view.pointers) != 0 {
			t.Errorf("%s: pointers %+v err=%v", doc, view.pointers, err)
		}
	}
	if _, err := readSettings([]byte(`{"profile":3}`)); err == nil {
		t.Error("a non-string profile must fail the decode, as in the app")
	}
	// A present "" is custom in the app (PultikProfile.named): no shipped
	// pointers, no Hlídač. Only an absent profile is example.
	empty, err := readSettings([]byte(`{"profile":"","projects":[{"key":"exampleapp"}]}`))
	if err != nil || empty.profile != "custom" || len(empty.pointers) != 0 {
		t.Errorf(`{"profile":""}: profile %q pointers %+v err=%v, want custom and none`, empty.profile, empty.pointers, err)
	}
	for doc, want := range map[string]bool{`{"hlidacURL":""}`: true, `{"hlidacURL":null}`: false, `{}`: false} {
		view, err := readSettings([]byte(doc))
		if err != nil || view.hlidacSet != want {
			t.Errorf("%s: hlidacSet %v err=%v, want %v", doc, view.hlidacSet, err, want)
		}
	}
	for profile, want := range map[string]string{"": defaultHlidacURL, "example": defaultHlidacURL, "genesis": "", "custom": ""} {
		if got := profileHlidacURL(profile); got != want {
			t.Errorf("profileHlidacURL(%q) = %q, want %q", profile, got, want)
		}
	}
}
