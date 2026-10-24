package main

// `pultik install --profile`: whose defaults the app gets
// (docs/specs/2026-10-23-pultik-profiles-decisions.md). The app reads
// settings.json `profile`; absent means example, so a Mac whose settings
// predate profiles is never asked. The installer records a choice in place
// (settings_edit.go): every other byte kept, no key sorting, no HTML escaping.

import (
	"bufio"
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
)

var installProfiles = []string{"example", "genesis", "custom"}

var profileBlurbs = map[string]string{
	"example":  "the estate Pultik was written for: its hosts, devbox, repos, option+space, login item",
	"genesis": "control+space, no login item, no estate host; devbox only with its CLI and key",
	"custom":  "no estate host, ssh key, login item or repos, option+space; settings.json gets every profile key to edit",
}

// profileKey is one settings.json key a profile supplies, at the custom
// profile's own default: no host, no ssh key, no login item, no repos, and
// the app's default hotkey.
type profileKey struct {
	key   string
	value any
}

// customProfileKeys must name what Apps/Pultik/Sources/Store/Preferences.swift
// resolves through the profile (TestCustomProfileKeysMatchPreferencesSwift).
var customProfileKeys = []profileKey{
	{"hotkey", "option+space"},
	{"loginItemOnFirstRun", false},
	{"prometheusURL", ""},
	{"lokiURL", ""},
	{"hlidacURL", ""},
	{"eveURL", ""},
	{"sentryURL", ""},
	{"shelfURL", ""},
	{"devboxIdentityFile", ""},
	{"devboxExecutable", ""},
	{"devboxFallbackBoxes", []any{}},
	{"servers", []any{}},
	{"services", []any{}},
	{"projects", []any{}},
	{"sentryProjects", []any{}},
	{"repoOrder", []any{}},
}

// profileState is what the profile step found before anything is written.
type profileState struct {
	path    string // settings.json as the user knows it
	file    string // the file a symlinked settings.json points to
	exists  bool
	raw     []byte
	current string // the profile the app reads from the file, "" when it names none
	// recorded is the file's `profile` as written when it is no known
	// profile ("Genesis", 3): the app reads custom, and the step says why.
	recorded string
	// unreadable is why the file is no JSON object (after a BOM and an empty
	// file read as {}); such a file is never edited.
	unreadable error
}

var utf8BOM = []byte{0xEF, 0xBB, 0xBF}

// danglingSettings: Pultik's settings.json is a symlink whose target is
// missing. Writing would replace the link with a regular file, so the step
// refuses, the way installClaudeHooks refuses Claude's (a dry run warns).
type danglingSettings struct{ path, target string }

func (d danglingSettings) Error() string {
	return fmt.Sprintf("%s links to %s, which does not exist: create that file or remove the link, then rerun",
		d.path, d.target)
}

// appSettingsFile is the file the app reads, always under $HOME:
// PULTIK_SETTINGS (a `pultik prod` test override) does not move the app.
func appSettingsFile() (string, error) {
	home, err := os.UserHomeDir()
	if err != nil {
		return "", fmt.Errorf("find home directory: %w", err)
	}
	return filepath.Join(home, "Library", "Application Support", "Pultik", "settings.json"), nil
}

// readProfileState reads the app's settings.json, through a symlink.
func readProfileState() (profileState, error) {
	path, err := appSettingsFile()
	if err != nil {
		return profileState{}, err
	}
	state := profileState{path: path, file: path}
	if info, err := os.Lstat(path); err == nil && info.Mode()&fs.ModeSymlink != 0 {
		resolved, err := filepath.EvalSymlinks(path)
		if err != nil {
			target, _ := os.Readlink(path)
			return state, danglingSettings{path, target}
		}
		state.file = resolved
	}
	raw, err := os.ReadFile(state.file)
	switch {
	case os.IsNotExist(err):
		return state, nil
	case err != nil:
		return state, err
	}
	state.exists, state.raw = true, raw
	var top map[string]json.RawMessage
	if err := json.Unmarshal(settingsBody(raw), &top); err != nil || top == nil {
		if err == nil {
			err = errors.New("not a JSON object")
		}
		state.unreadable = err
		state.current, state.recorded = peekProfileText(raw)
		return state, nil
	}
	if value, set := top["profile"]; set && !isNull(value) {
		var name string
		switch {
		case json.Unmarshal(value, &name) != nil:
			// The app reads a profile of another type as custom.
			state.current, state.recorded = "custom", string(bytes.TrimSpace(value))
		case validProfile(name):
			state.current = name
		default:
			// Names match exactly, as in the app: "Genesis" is custom.
			state.current, state.recorded = "custom", strconv.Quote(name)
		}
	}
	return state, nil
}

// settingsBody is the JSON the editor works on: a UTF-8 BOM set aside, and
// an empty or whitespace-only file read as {}.
func settingsBody(raw []byte) []byte {
	body := bytes.TrimPrefix(raw, utf8BOM)
	if len(bytes.TrimSpace(body)) == 0 {
		return []byte("{}\n")
	}
	return body
}

var (
	knownProfileText = regexp.MustCompile(`"profile"\s*:\s*"(example|genesis|custom)"`)
	nullProfileText  = regexp.MustCompile(`"profile"\s*:\s*null`)
	anyProfileText   = regexp.MustCompile(`"profile"\s*:\s*("[^"]*"|[^\s,}]+)?`)
)

// peekProfileText mirrors PultikProfile.peek for a file that is no JSON:
// the first known `"profile": "<name>"`, custom for a profile key holding
// anything else, "" (example) for none. recorded is that other value as
// written, when it can be read.
func peekProfileText(raw []byte) (current, recorded string) {
	if match := knownProfileText.FindSubmatch(raw); match != nil {
		return string(match[1]), ""
	}
	match := anyProfileText.FindSubmatch(raw)
	if match == nil || nullProfileText.Match(raw) {
		return "", ""
	}
	return "custom", string(match[1])
}

// unknownProfileNote says why the app reads custom from a profile value
// that names no profile.
func unknownProfileNote(path, recorded string) string {
	if recorded == "" {
		recorded = "a value"
	}
	return fmt.Sprintf("%s records profile %s, which is not a known profile (%s), so the app reads custom",
		path, recorded, strings.Join(installProfiles, ", "))
}

// chooseProfile decides what the step records, before any other step runs,
// so a run that cannot go on fails first. "" records nothing: a Mac whose
// settings.json exists keeps it as it is (no profile key reads as example)
// and is never asked. Without settings.json the profile is required: a
// terminal gets a numbered pick, anything else fails with the flag to pass.
func chooseProfile(flag string, exists, tty bool, pick func() (string, error)) (string, error) {
	if flag != "" {
		if !validProfile(flag) {
			return "", fmt.Errorf("unknown profile %q: use %s", flag, strings.Join(installProfiles, ", "))
		}
		return flag, nil
	}
	if exists {
		return "", nil
	}
	if !tty {
		return "", fmt.Errorf("Pultik has no settings.json on this Mac yet, so it needs a profile: rerun with "+
			"--profile example|genesis|custom (example: %s; genesis: %s; custom: %s)",
			profileBlurbs["example"], profileBlurbs["genesis"], profileBlurbs["custom"])
	}
	return pick()
}

func validProfile(name string) bool {
	for _, known := range installProfiles {
		if name == known {
			return true
		}
	}
	return false
}

// pickProfile asks on a terminal: a number or a name, three tries.
func pickProfile(in io.Reader, out io.Writer) (string, error) {
	fmt.Fprintln(out, "Pultik has no settings on this Mac yet. Which profile should fill its defaults?")
	for i, name := range installProfiles {
		fmt.Fprintf(out, "  %d) %-8s %s\n", i+1, name, profileBlurbs[name])
	}
	reader := bufio.NewReader(in)
	for try := 0; try < 3; try++ {
		fmt.Fprintf(out, "profile [1-%d]: ", len(installProfiles))
		line, err := reader.ReadString('\n')
		if name := profileAnswer(strings.TrimSpace(line)); name != "" {
			return name, nil
		}
		if err != nil {
			break
		}
		fmt.Fprintln(out, "type 1, 2 or 3, or the profile's name")
	}
	return "", fmt.Errorf("no profile chosen: rerun with --profile example|genesis|custom")
}

func profileAnswer(answer string) string {
	for i, name := range installProfiles {
		if answer == fmt.Sprint(i+1) || strings.EqualFold(answer, name) {
			return name
		}
	}
	return ""
}

// recordProfile returns raw with `profile` set to name, in place; custom
// also appends every profile key the file does not set yet, at the custom
// profile's own default. A key the file sets is never touched: an explicit
// value wins. raw must be a JSON object; nil, empty or whitespace is {}, and
// a UTF-8 BOM stays in front of the edited text.
func recordProfile(raw []byte, name string) (edited []byte, added []string, err error) {
	bom := bytes.HasPrefix(raw, utf8BOM)
	defer func() {
		if err == nil && bom {
			edited = append(append([]byte{}, utf8BOM...), edited...)
		}
	}()
	raw = settingsBody(raw)
	var top map[string]json.RawMessage
	if err := json.Unmarshal(raw, &top); err != nil {
		return nil, nil, fmt.Errorf("invalid JSON: %w", err)
	}
	if top == nil {
		return nil, nil, fmt.Errorf("settings must be a JSON object")
	}
	edited, err = setTopLevelMember(raw, "profile", name, true)
	if err != nil {
		return nil, nil, err
	}
	if name != "custom" {
		return edited, nil, nil
	}
	for _, entry := range customProfileKeys {
		if _, set := top[entry.key]; set {
			continue
		}
		if edited, err = setTopLevelMember(edited, entry.key, entry.value, false); err != nil {
			return nil, nil, err
		}
		added = append(added, entry.key)
	}
	return edited, added, nil
}

// explicitProfileKeys lists the profile keys raw already sets: they keep
// their values whatever profile is recorded.
func explicitProfileKeys(raw []byte) []string {
	var top map[string]json.RawMessage
	if json.Unmarshal(settingsBody(raw), &top) != nil {
		return nil
	}
	var keys []string
	for _, entry := range customProfileKeys {
		if _, set := top[entry.key]; set {
			keys = append(keys, entry.key)
		}
	}
	return keys
}

// setTopLevelMember sets one key of the root object in place: an existing
// member's value is replaced when replace is true, a missing one appended.
func setTopLevelMember(raw []byte, key string, value any, replace bool) ([]byte, error) {
	rootStart := skipJSONSpace(raw, 0)
	root := byteSpan{rootStart, jsonValueEnd(raw, rootStart)}
	members := jsonObjectMembers(raw, root)
	style := documentStyle(raw, root, members)
	if member, found := lastJSONMember(members, key); found {
		if !replace {
			return raw, nil
		}
		return replaceJSONValue(raw, member, value, style)
	}
	return insertJSONMember(raw, root, members, key, value, style)
}

// installProfileStep records the chosen profile, or says which one the
// app reads. choice is chooseProfile's answer.
func installProfileStep(state profileState, choice string, dryRun bool) error {
	if choice == "" {
		switch {
		case !state.exists:
			// Only a dry run gets here: it never asks.
			fmt.Fprintf(uiOut, "%s! no %s yet: a run on a terminal asks for a profile, any other run needs --profile example|genesis|custom%s\n",
				yellow, state.path, reset)
		case state.unreadable != nil:
			read := "example (it names no profile)"
			if state.current != "" {
				read = state.current
			}
			fmt.Fprintf(uiOut, "%s! the installer cannot edit %s (%v), so it is left as it is; the app reads profile %s from it%s\n",
				yellow, state.path, state.unreadable, read, reset)
			if state.current == "custom" && !knownProfileText.Match(state.raw) {
				fmt.Fprintf(uiOut, "%s! %s%s\n", yellow, unknownProfileNote(state.path, state.recorded), reset)
			}
		case state.current == "":
			ok("profile example (%s names none)", state.path)
		case state.recorded != "":
			fmt.Fprintf(uiOut, "%s! %s; rerun with --profile example|genesis|custom to record one%s\n",
				yellow, unknownProfileNote(state.path, state.recorded), reset)
		default:
			ok("profile %s (recorded in %s)", state.current, state.path)
		}
		return nil
	}
	edited, added, err := recordProfile(state.raw, choice)
	if err != nil {
		return fmt.Errorf("%s: %w", state.path, err)
	}
	if state.exists && string(edited) == string(state.raw) {
		ok("profile %s already recorded in %s", choice, state.path)
		noteKeptProfileKeys(choice, state.raw)
		return nil
	}
	if dryRun {
		step("would record profile " + choice + " in " + state.path)
		if len(added) > 0 {
			step("would add the custom profile's keys for editing: " + strings.Join(added, ", "))
		}
		noteKeptProfileKeys(choice, state.raw)
		return nil
	}
	mode := fs.FileMode(0o600)
	if info, err := os.Stat(state.file); err == nil {
		mode = info.Mode().Perm()
	}
	if state.exists {
		backup, err := placeBackup(state.path, func(candidate string) error {
			return copyFileExclusive(state.file, candidate, 0o600)
		})
		if err != nil {
			return fmt.Errorf("back up %s: %w", state.path, err)
		}
		step("backed up " + state.path + " → " + backup)
	}
	if err := writeFileAtomic(state.file, edited, mode); err != nil {
		return err
	}
	ok("profile %s recorded in %s", choice, state.path)
	if len(added) > 0 {
		ok("custom profile keys to edit in %s: %s", state.path, strings.Join(added, ", "))
	}
	noteKeptProfileKeys(choice, state.raw)
	return nil
}

// noteKeptProfileKeys names the profile keys the file already sets, and the
// lists that keep naming hosts and repos whatever profile is recorded.
func noteKeptProfileKeys(choice string, raw []byte) {
	if kept := explicitProfileKeys(raw); len(kept) > 0 {
		fmt.Fprintf(uiOut, "%s! settings.json already sets %s: an explicit key wins over the %s default; delete one to take the default%s\n",
			yellow, strings.Join(kept, ", "), choice, reset)
	}
	if lists := pointingLists(raw); len(lists) > 0 {
		fmt.Fprintf(uiOut, "%s! %s keep pointing at the hosts and repos they name now, whatever the profile%s\n",
			yellow, strings.Join(lists, ", "), reset)
	}
}

// pointingLists: servers, projects and pinnedRepos when the file sets them
// to a non-empty list.
func pointingLists(raw []byte) []string {
	var top map[string]json.RawMessage
	if json.Unmarshal(settingsBody(raw), &top) != nil {
		return nil
	}
	var lists []string
	for _, key := range []string{"servers", "projects", "pinnedRepos"} {
		var items []json.RawMessage
		if value, set := top[key]; set && json.Unmarshal(value, &items) == nil && len(items) > 0 {
			lists = append(lists, key)
		}
	}
	return lists
}
