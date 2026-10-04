// pultik prod — the AI-facing door to prod watch. Check definitions live in
// build-server-infra (recording rules + apps/hlidac/deployments.yaml); the app's
// settings.json only points at Hlídač deployments (projects[].prod) and says
// how to present them. This command prints that pointer schema, proves the
// pointers against the live Hlídač digest, and adds a pointer without
// disturbing any other key — the running app hot-reloads the file.
//
// Contract: docs/specs/2026-10-03-prod-watch-contracts.md §5–§6.
package main

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"time"
)

const defaultHlidacURL = "https://hlidac.ops.example.invalid"

// Exit codes of `pultik prod validate` (documented in prodUsage). Ordered by
// precedence: local settings problems first, then Hlídač, then data.
const (
	exitProdSettings    = 5 // settings.json missing, or a shape the app cannot decode at all
	exitProdSkipped     = 7 // entries the app's lenient decode skips or misreads
	exitProdDuplicate   = 8 // one deployment pointed at twice
	exitProdUnreachable = 4 // Hlídač unreachable, not a digest, or its Prometheus is down
	exitProdUnknown     = 3 // a pointer names a key Hlídač does not know
	exitProdBlind       = 6 // a pointed deployment has no data (rules missing?)
)

// shippedProdPointers mirrors Preferences.defaultProdPointers: a project
// whose `prod` key is absent gets these on the app's first load; an explicit
// [] means none. Keep in step with Sources/Store/Preferences.swift.
var shippedProdPointers = map[string][]prodPointer{
	"exampleapp": {{Key: "exampleapp-prod", Title: "ExampleApp prod", Tier: "critical", Order: intPtr(1)}},
	"eve":   {{Key: "eve-exampleapp-prod", Title: "eve · ExampleApp", Tier: "critical", Order: intPtr(2)}},
	"booking": {
		{Key: "booking-sk", Title: "Booking SK", Tier: "critical", Order: intPtr(3)},
		{Key: "booking-cz", Title: "Booking CZ", Tier: "critical", Order: intPtr(4)},
	},
	"vitrinka": {{Key: "vitrinka", Title: "vitrinka", Tier: "watch", Order: intPtr(5)}},
}

// shippedProjectOrder is the app's defaultProjects order, used when
// settings.json carries no projects at all.
var shippedProjectOrder = []string{"exampleapp", "booking", "eve", "vitrinka"}

func intPtr(n int) *int { return &n }

// exitError carries a specific process exit code through main's error path.
type exitError struct {
	code int
	err  error
}

func (e *exitError) Error() string { return e.err.Error() }
func (e *exitError) Unwrap() error { return e.err }

var prodKeyRe = regexp.MustCompile(`^[a-z0-9][a-z0-9-]{0,62}$`)

var prodTiers = map[string]bool{"critical": true, "important": true, "watch": true}

// prodPointer mirrors the app's ProdPointer (Sources/Models/Models.swift).
type prodPointer struct {
	Key   string `json:"key"`
	Title string `json:"title,omitempty"`
	Tier  string `json:"tier,omitempty"`
	Order *int   `json:"order,omitempty"`
}

// The subset of Hlídač's digest that validation reads.
type hlidacDigest struct {
	GeneratedAt string                  `json:"generatedAt"`
	Sources     map[string]hlidacSource `json:"sources"`
	Deployments []hlidacDeployment      `json:"deployments"`
}

type hlidacSource struct {
	OK    bool    `json:"ok"`
	Since *string `json:"since"`
	Error *string `json:"error"`
}

type hlidacDeployment struct {
	Key        string        `json:"key"`
	Project    string        `json:"project"`
	Title      string        `json:"title"`
	Verdict    string        `json:"verdict"`
	BlindSince *string       `json:"blindSince"`
	Emergency  bool          `json:"emergency"`
	Checks     []hlidacCheck `json:"checks"`
}

type hlidacCheck struct {
	ID     string   `json:"id"`
	Title  string   `json:"title"`
	Status *float64 `json:"status"`
	Value  *string  `json:"value"`
}

// settingsFile resolves the app's settings.json. PULTIK_SETTINGS overrides it
// (tests, a scratch copy) — same contract as PULTIK_NOTES.
func settingsFile() string {
	if v := os.Getenv("PULTIK_SETTINGS"); v != "" {
		return v
	}
	home, _ := os.UserHomeDir()
	return filepath.Join(home, "Library", "Application Support", "Pultik", "settings.json")
}

func prodCmd(args []string) error {
	if len(args) == 0 {
		prodUsage()
		return fmt.Errorf("prod needs a subcommand")
	}
	switch args[0] {
	case "schema":
		return printJSON(prodSchema())
	case "validate":
		return prodValidate(args[1:])
	case "add":
		return prodAdd(args[1:])
	case "--help", "-h", "help":
		prodUsage()
		return nil
	default:
		prodUsage()
		return fmt.Errorf("unknown prod subcommand %q", args[0])
	}
}

func prodUsage() {
	fmt.Fprint(uiOut, `pultik prod — prod watch pointers (settings.json projects[].prod)

USAGE
  pultik prod schema                 JSON Schema of the pointers + hlidacURL
  pultik prod validate [--json] [--url <hlidac>]
                                     prove every pointer against Hlídač's digest
  pultik prod add <project> <key> [--title <t>] [--tier critical|important|watch]
                  [--order <n>] [--dry-run]
                                     add a pointer (atomic; the app hot-reloads)

Checks, thresholds and emergencies are NOT configured here: they live in
build-server-infra (recording rules + apps/hlidac/deployments.yaml). Add the
deployment there, restart hlidac (docker compose restart hlidac) once that
PR deploys, then point at it with pultik prod add.

A project with no prod key gets the app's shipped pointers; prod: [] means
none. With no pointers at all the board shows every deployment Hlídač
reports, in Hlídač's order.

VALIDATE EXIT CODES (first that applies)
  0  every pointer is valid, known to Hlídač and has data
  5  settings.json missing, or a shape the app cannot decode at all
  7  an entry the app skips or misreads (wrong-typed field, unknown tier)
  8  one deployment pointed at twice
  4  Hlídač unreachable, not a digest, or its Prometheus is down
  3  a pointer names a key Hlídač does not know
  6  a pointed deployment is blind (no series — recording rules missing?)

CONFIG
  PULTIK_SETTINGS     settings.json path (default ~/Library/Application Support/Pultik/settings.json)
  PULTIK_HLIDAC_URL   Hlídač base URL for this command (else settings hlidacURL,
                      else `+defaultHlidacURL+`)
`)
}

func prodSchema() map[string]any {
	return map[string]any{
		"$schema":     "https://json-schema.org/draft/2020-12/schema",
		"$id":         "pultik://settings/prod",
		"title":       "Pultík prod watch pointers",
		"description": "settings.json keys read by prod watch. Pointers only: checks, thresholds and emergencies live in build-server-infra (recording rules + apps/hlidac/deployments.yaml).",
		"type":        "object",
		"properties": map[string]any{
			"hlidacURL": map[string]any{
				"type": "string", "format": "uri", "default": defaultHlidacURL,
				"description": "Hlídač base URL; the panel reads GET /api/v1/prod from it.",
			},
			"projects": map[string]any{
				"type": "array",
				"items": map[string]any{
					"type":     "object",
					"required": []string{"key"},
					"properties": map[string]any{
						"key": map[string]any{"type": "string"},
						"prod": map[string]any{
							"type": "array", "items": map[string]any{"$ref": "#/$defs/prodPointer"},
							"description": "Absent = the app seeds its shipped pointers on first load; use [] for none.",
						},
					},
				},
			},
		},
		"$defs": map[string]any{
			"prodPointer": map[string]any{
				"type":     "object",
				"required": []string{"key"},
				"properties": map[string]any{
					"key":   map[string]any{"type": "string", "pattern": prodKeyRe.String(), "description": "Hlídač deployment key (apps/hlidac/deployments.yaml)"},
					"title": map[string]any{"type": "string", "description": "card title; Hlídač's title when absent"},
					"tier":  map[string]any{"enum": []string{"critical", "important", "watch"}, "default": "critical", "description": "a red on a critical deployment (and every emergency) posts a Time Sensitive notification; reds on other tiers post normal banners"},
					"order": map[string]any{"type": "integer", "description": "board position; lower first"},
				},
			},
		},
	}
}

// ── validate ────────────────────────────────────────────────────────────

type pointerRef struct {
	Project string      `json:"project"`
	Pointer prodPointer `json:"pointer"`
	Shipped bool        `json:"shipped,omitempty"` // seeded by the app, not in the file
}

// settingsView is what the app's lenient decode makes of settings.json:
// the pointers the board will show, and every entry it skips or misreads.
type settingsView struct {
	pointers  []pointerRef
	hlidacURL string
	issues    []string // entries the app skips or misreads → exit 7
	notes     []string // how the app fills gaps (shipped pointers)
}

type pointerResult struct {
	Project    string   `json:"project"`
	Key        string   `json:"key"`
	Known      bool     `json:"known"`
	Verdict    string   `json:"verdict,omitempty"`
	BlindSince *string  `json:"blindSince,omitempty"`
	Emergency  bool     `json:"emergency,omitempty"`
	Failing    []string `json:"failing,omitempty"`
}

type validateReport struct {
	Hlidac      string                  `json:"hlidac"`
	GeneratedAt string                  `json:"generatedAt,omitempty"`
	Sources     map[string]hlidacSource `json:"sources,omitempty"`
	Pointers    []pointerResult         `json:"pointers"`
	Unknown     []string                `json:"unknown"`
	Unshown     []string                `json:"unshown"`
	Duplicates  []string                `json:"duplicates"`
	Issues      []string                `json:"issues"`
	Notes       []string                `json:"notes"`
	Error       string                  `json:"error,omitempty"`
	ExitCode    int                     `json:"exitCode"`
}

// readSettings decodes settings.json the way the app does
// (Sources/Models/Models.swift ProjectSpec + LossyArray, Preferences):
//   - a shape that fails the whole Preferences decode is an error (exit 5):
//     a top-level field of the wrong JSON kind (topLevelKinds); the element
//     shapes of displayPresets, expiryWatch, fanCurves and workspaces are
//     the app's alone;
//   - a project or pointer LossyArray skips is an issue line (exit 7);
//   - a project with no prod key gets the shipped pointers, as on the app's
//     first load.
func readSettings(raw []byte) (settingsView, error) {
	var view settingsView
	var top map[string]json.RawMessage
	if err := json.Unmarshal(raw, &top); err != nil {
		return view, fmt.Errorf("settings.json is not a JSON object: %w", err)
	}
	if top == nil {
		return view, errors.New("settings.json is null, not a JSON object — the app cannot decode it at all")
	}
	if err := checkTopLevelKinds(top); err != nil {
		return view, err
	}
	if rawURL, ok := top["hlidacURL"]; ok && !isNull(rawURL) {
		var url string
		if json.Unmarshal(rawURL, &url) != nil {
			return view, fmt.Errorf("hlidacURL is not a string — the app cannot decode settings.json at all")
		}
		view.hlidacURL = strings.TrimSpace(url)
	}
	rawProjects, ok := top["projects"]
	if !ok || isNull(rawProjects) {
		for _, key := range shippedProjectOrder {
			for _, p := range shippedProdPointers[key] {
				view.pointers = append(view.pointers, pointerRef{Project: key, Pointer: p, Shipped: true})
			}
		}
		view.notes = append(view.notes, "no projects in settings.json — the app shows its shipped projects and pointers")
		return view, nil
	}
	var projects []json.RawMessage
	if json.Unmarshal(rawProjects, &projects) != nil {
		return view, fmt.Errorf("projects is not an array — the app cannot decode settings.json at all")
	}
	for i, rawProject := range projects {
		key, pointers, prodSet, issues, err := decodeProject(i, rawProject)
		view.issues = append(view.issues, issues...)
		if err != nil {
			view.issues = append(view.issues, fmt.Sprintf("projects[%d]: %v — the app skips this project", i, err))
			continue
		}
		if !prodSet {
			shipped := shippedProdPointers[key]
			for _, p := range shipped {
				view.pointers = append(view.pointers, pointerRef{Project: key, Pointer: p, Shipped: true})
			}
			if len(shipped) > 0 {
				view.notes = append(view.notes, fmt.Sprintf("%s: no prod key — the app seeds its shipped pointers (%s); use [] for none", key, pointerKeys(shipped)))
			}
			continue
		}
		for _, p := range pointers {
			view.pointers = append(view.pointers, pointerRef{Project: key, Pointer: p})
		}
	}
	return view, nil
}

// decodeProject mirrors ProjectSpec.init(from:): `key` is required, the
// optional fields must have their declared types or the whole project is
// skipped, and links/prod are lossy arrays whose bad elements are skipped.
func decodeProject(i int, raw json.RawMessage) (key string, pointers []prodPointer, prodSet bool, issues []string, err error) {
	var m map[string]json.RawMessage
	if json.Unmarshal(raw, &m) != nil {
		return "", nil, false, nil, errors.New("not an object")
	}
	if key, err = requiredString(m, "key"); err != nil {
		return "", nil, false, nil, err
	}
	if err = optionalString(m, "title"); err != nil {
		return key, nil, false, nil, err
	}
	for _, field := range []string{"repos", "sentryProjects", "services"} {
		if err = optionalStrings(m, field); err != nil {
			return key, nil, false, nil, err
		}
	}
	links, err := optionalArray(m, "links")
	if err != nil {
		return key, nil, false, nil, err
	}
	for j, link := range links {
		var lm map[string]json.RawMessage
		if json.Unmarshal(link, &lm) != nil {
			issues = append(issues, fmt.Sprintf("projects[%d].links[%d]: not an object — skipped", i, j))
			continue
		}
		for _, field := range []string{"title", "url"} {
			if _, ferr := requiredString(lm, field); ferr != nil {
				issues = append(issues, fmt.Sprintf("projects[%d].links[%d]: %v — skipped", i, j, ferr))
				break
			}
		}
	}
	rawProd, ok := m["prod"]
	if !ok || isNull(rawProd) {
		return key, nil, false, issues, nil
	}
	elements, err := optionalArray(m, "prod")
	if err != nil {
		return key, nil, false, issues, err
	}
	for j, element := range elements {
		p, perr := decodePointer(element)
		if perr != nil {
			issues = append(issues, fmt.Sprintf("projects[%d].prod[%d] (%s): %v — the app skips this pointer", i, j, key, perr))
			continue
		}
		if p.Tier != "" && !prodTiers[p.Tier] {
			issues = append(issues, fmt.Sprintf("projects[%d].prod[%d] (%s): tier %q is not critical|important|watch — the app keeps it but never treats it as critical", i, j, key, p.Tier))
		}
		pointers = append(pointers, p)
	}
	return key, pointers, true, issues, nil
}

// decodePointer mirrors the synthesized ProdPointer decode: key String
// required, title/tier String?, order Int? — a wrong type skips the pointer.
func decodePointer(raw json.RawMessage) (prodPointer, error) {
	var p prodPointer
	var m map[string]json.RawMessage
	if json.Unmarshal(raw, &m) != nil {
		return p, errors.New("not an object")
	}
	var err error
	if p.Key, err = requiredString(m, "key"); err != nil {
		return p, err
	}
	for _, field := range []string{"title", "tier"} {
		if err = optionalString(m, field); err != nil {
			return p, err
		}
	}
	_ = json.Unmarshal(m["title"], &p.Title)
	_ = json.Unmarshal(m["tier"], &p.Tier)
	if rawOrder, ok := m["order"]; ok && !isNull(rawOrder) {
		// A JSON number literal only: json.Number would also take the
		// string "5", which Swift's Int decode rejects.
		order, convErr := strconv.Atoi(string(bytes.TrimSpace(rawOrder)))
		if convErr != nil {
			return p, errors.New("expected Int at order")
		}
		p.Order = &order
	}
	return p, nil
}

func isNull(raw json.RawMessage) bool {
	return bytes.Equal(bytes.TrimSpace(raw), []byte("null"))
}

type jsonKind string

const (
	kindString      jsonKind = "a string"
	kindBool        jsonKind = "a boolean"
	kindNumber      jsonKind = "a number"
	kindInteger     jsonKind = "an integer"
	kindStringArray jsonKind = "an array of strings"
	kindArray       jsonKind = "an array"
	kindObject      jsonKind = "an object"
)

// topLevelKinds is every field Preferences.init(from:) decodes, with the JSON
// kind its Swift type needs: any other kind throws, and the app keeps its
// last good config. null is absent to decodeIfPresent; unknown keys are
// ignored. TestTopLevelKindsMatchPreferencesSwift holds it to the Swift.
var topLevelKinds = map[string]jsonKind{
	"pinnedRepos": kindStringArray, "loginItemConfiguredFor": kindString, "sentryToken": kindString,
	"eveToken": kindString, "sentryProjects": kindStringArray, "hotkey": kindString,
	"hiddenSections": kindStringArray, "servers": kindArray, "services": kindArray, "projects": kindArray,
	"hlidacURL": kindString, "repoOrder": kindStringArray, "visibleAlertLanes": kindStringArray,
	"notifyFiring": kindBool, "activeFanCurve": kindString, "fanCurves": kindObject,
	"fanCurveSmoothing": kindNumber, "expiryWatch": kindArray, "focusHoldsNotifications": kindBool,
	"vaultPath": kindString, "todoProject": kindString, "collapsedRails": kindStringArray,
	"leftRailTab": kindString, "leftRailSplit": kindNumber, "vitrinkaWorkspace": kindString,
	"workspaces": kindObject, "displayPresets": kindArray, "externalBrightnessOffset": kindInteger,
	"dimBrightness": kindNumber, "neverSleep": kindBool,
}

func checkTopLevelKinds(top map[string]json.RawMessage) error {
	keys := make([]string, 0, len(top))
	for key := range top {
		keys = append(keys, key)
	}
	sort.Strings(keys)
	for _, key := range keys {
		want, known := topLevelKinds[key]
		if !known || isNull(top[key]) || hasKind(top[key], want) {
			continue
		}
		return fmt.Errorf("%s is not %s — the app cannot decode settings.json at all", key, want)
	}
	return nil
}

func hasKind(raw json.RawMessage, kind jsonKind) bool {
	switch kind {
	case kindString:
		var s string
		return json.Unmarshal(raw, &s) == nil
	case kindBool:
		var b bool
		return json.Unmarshal(raw, &b) == nil
	case kindNumber:
		var f float64
		return json.Unmarshal(raw, &f) == nil
	case kindInteger:
		var i int64
		return json.Unmarshal(raw, &i) == nil
	case kindStringArray:
		var ss []string
		if json.Unmarshal(raw, &ss) != nil {
			return false
		}
		var elems []json.RawMessage
		_ = json.Unmarshal(raw, &elems)
		for _, e := range elems {
			if isNull(e) { // Go reads null as "", Swift's [String] refuses it
				return false
			}
		}
		return true
	case kindArray:
		var a []json.RawMessage
		return json.Unmarshal(raw, &a) == nil
	case kindObject:
		var o map[string]json.RawMessage
		return json.Unmarshal(raw, &o) == nil
	}
	return false
}

func requiredString(m map[string]json.RawMessage, field string) (string, error) {
	raw, ok := m[field]
	if !ok {
		return "", fmt.Errorf("missing %s", field)
	}
	var s string
	if isNull(raw) || json.Unmarshal(raw, &s) != nil {
		return "", fmt.Errorf("expected String at %s", field)
	}
	return s, nil
}

func optionalString(m map[string]json.RawMessage, field string) error {
	raw, ok := m[field]
	if !ok || isNull(raw) {
		return nil
	}
	var s string
	if json.Unmarshal(raw, &s) != nil {
		return fmt.Errorf("expected String at %s", field)
	}
	return nil
}

func optionalStrings(m map[string]json.RawMessage, field string) error {
	raw, ok := m[field]
	if !ok || isNull(raw) {
		return nil
	}
	// Element by element: Go turns a null element into "" where Swift fails.
	var elements []json.RawMessage
	if json.Unmarshal(raw, &elements) != nil {
		return fmt.Errorf("expected [String] at %s", field)
	}
	for _, element := range elements {
		var s string
		if isNull(element) || json.Unmarshal(element, &s) != nil {
			return fmt.Errorf("expected [String] at %s", field)
		}
	}
	return nil
}

func optionalArray(m map[string]json.RawMessage, field string) ([]json.RawMessage, error) {
	raw, ok := m[field]
	if !ok || isNull(raw) {
		return nil, nil
	}
	var elements []json.RawMessage
	if json.Unmarshal(raw, &elements) != nil {
		return nil, fmt.Errorf("expected Array at %s", field)
	}
	return elements, nil
}

func pointerKeys(pointers []prodPointer) string {
	keys := make([]string, len(pointers))
	for i, p := range pointers {
		keys[i] = p.Key
	}
	return strings.Join(keys, ", ")
}

// duplicatePointers lists every deployment key pointed at more than once,
// with the projects pointing at it.
func duplicatePointers(pointers []pointerRef) []string {
	owners := map[string][]string{}
	var order []string
	for _, ref := range pointers {
		if _, seen := owners[ref.Pointer.Key]; !seen {
			order = append(order, ref.Pointer.Key)
		}
		owners[ref.Pointer.Key] = append(owners[ref.Pointer.Key], ref.Project)
	}
	var dups []string
	for _, key := range order {
		if len(owners[key]) > 1 {
			dups = append(dups, fmt.Sprintf("%s pointed at by %s", key, strings.Join(owners[key], " and ")))
		}
	}
	return dups
}

func fetchDigest(ctx context.Context, base string) (hlidacDigest, error) {
	var digest hlidacDigest
	url := strings.TrimRight(base, "/") + "/api/v1/prod"
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return digest, err
	}
	req.Header.Set("Accept", "application/json")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return digest, fmt.Errorf("GET %s: %w", url, err)
	}
	defer resp.Body.Close()
	body, err := io.ReadAll(io.LimitReader(resp.Body, 8<<20))
	if err != nil {
		return digest, fmt.Errorf("GET %s: reading body: %w", url, err)
	}
	if resp.StatusCode != http.StatusOK {
		return digest, fmt.Errorf("GET %s: HTTP %d: %s", url, resp.StatusCode, oneLine(string(body), 160))
	}
	if err := json.Unmarshal(body, &digest); err != nil {
		return digest, fmt.Errorf("GET %s: not a digest: %w", url, err)
	}
	// A 200 from the wrong service (a proxy page, another API) can still be
	// JSON: a digest always names its time and lists its deployments.
	var shape struct {
		Deployments json.RawMessage `json:"deployments"`
	}
	_ = json.Unmarshal(body, &shape)
	if len(shape.Deployments) == 0 || isNull(shape.Deployments) || strings.TrimSpace(digest.GeneratedAt) == "" {
		return digest, fmt.Errorf("GET %s: not a digest (no deployments or generatedAt)", url)
	}
	return digest, nil
}

// buildValidateReport is the pure core of validate: settings view × digest.
func buildValidateReport(view settingsView, digest hlidacDigest) validateReport {
	pointers := view.pointers
	report := validateReport{
		GeneratedAt: digest.GeneratedAt, Sources: digest.Sources,
		Unknown: []string{}, Unshown: []string{}, Duplicates: duplicatePointers(pointers),
		Issues: append([]string{}, view.issues...), Notes: append([]string{}, view.notes...),
	}
	if report.Duplicates == nil {
		report.Duplicates = []string{}
	}
	if len(pointers) == 0 {
		report.Notes = append(report.Notes, "no pointers — the board shows every deployment Hlídač reports, in Hlídač's order")
		// Judge what the board shows (ProdGlance.make's selection).
		for _, d := range digest.Deployments {
			pointers = append(pointers, pointerRef{Project: d.Project, Pointer: prodPointer{Key: d.Key}})
		}
	}
	byKey := map[string]hlidacDeployment{}
	for _, d := range digest.Deployments {
		byKey[d.Key] = d
	}
	shown := map[string]bool{}
	for _, ref := range pointers {
		shown[ref.Pointer.Key] = true
		d, known := byKey[ref.Pointer.Key]
		result := pointerResult{Project: ref.Project, Key: ref.Pointer.Key, Known: known}
		if !known {
			report.Unknown = append(report.Unknown, ref.Pointer.Key)
			report.Pointers = append(report.Pointers, result)
			continue
		}
		result.Verdict, result.BlindSince, result.Emergency = d.Verdict, d.BlindSince, d.Emergency
		for _, c := range d.Checks {
			if c.Status != nil && *c.Status >= 1 {
				continue
			}
			label := c.ID
			if c.Value != nil && *c.Value != "" {
				label += " " + *c.Value
			}
			if c.Status == nil {
				label += " (no data)"
			}
			result.Failing = append(result.Failing, label)
		}
		report.Pointers = append(report.Pointers, result)
	}
	for _, d := range digest.Deployments {
		if !shown[d.Key] {
			report.Unshown = append(report.Unshown, d.Key)
		}
	}
	switch {
	case len(report.Issues) > 0:
		report.ExitCode = exitProdSkipped
	case len(report.Duplicates) > 0:
		report.ExitCode = exitProdDuplicate
	case anyBlind(report.Pointers) && prometheusDown(digest):
		report.ExitCode = exitProdUnreachable
	case len(report.Unknown) > 0:
		report.ExitCode = exitProdUnknown
	case anyBlind(report.Pointers):
		report.ExitCode = exitProdBlind
	}
	return report
}

// prometheusDown says Hlídač answered but its own Prometheus did not, so a
// blind card is an upstream outage, not a missing rule.
func prometheusDown(digest hlidacDigest) bool {
	source, ok := digest.Sources["prometheus"]
	return ok && !source.OK
}

func prometheusSince(digest hlidacDigest) string {
	if source, ok := digest.Sources["prometheus"]; ok && source.Since != nil {
		return *source.Since
	}
	return "unknown"
}

func anyBlind(results []pointerResult) bool {
	for _, r := range results {
		if r.Verdict == "blind" {
			return true
		}
	}
	return false
}

func prodValidate(args []string) error {
	asJSON, urlFlag := false, ""
	for i := 0; i < len(args); i++ {
		switch args[i] {
		case "--json":
			asJSON = true
		case "--url":
			if i+1 >= len(args) {
				return &exitError{2, fmt.Errorf("--url needs a value")}
			}
			i++
			urlFlag = args[i]
		case "--help", "-h":
			prodUsage()
			return nil
		default:
			return &exitError{2, fmt.Errorf("unknown flag %q", args[i])}
		}
	}

	report := validateReport{Pointers: []pointerResult{}, Unknown: []string{}, Unshown: []string{}, Duplicates: []string{}, Issues: []string{}, Notes: []string{}}
	finish := func(code int, err error) error {
		report.ExitCode = code
		if err != nil {
			report.Error = err.Error()
		}
		if asJSON {
			if jerr := printJSON(report); jerr != nil {
				return jerr
			}
		} else {
			printValidateReport(report)
		}
		if code == 0 {
			return nil
		}
		if err == nil {
			err = fmt.Errorf("prod validate failed (exit %d)", code)
		}
		return &exitError{code, err}
	}

	raw, err := os.ReadFile(settingsFile())
	if err != nil {
		return finish(exitProdSettings, fmt.Errorf("reading %s: %w", settingsFile(), err))
	}
	view, err := readSettings(raw)
	if err != nil {
		return finish(exitProdSettings, err)
	}
	report.Issues, report.Notes = append(report.Issues, view.issues...), append(report.Notes, view.notes...)
	base := firstNonEmpty(urlFlag, os.Getenv("PULTIK_HLIDAC_URL"), view.hlidacURL, defaultHlidacURL)
	report.Hlidac = base

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	digest, err := fetchDigest(ctx, base)
	if err != nil {
		code := exitProdUnreachable
		if len(report.Issues) > 0 {
			code = exitProdSkipped
		} else if dups := duplicatePointers(view.pointers); len(dups) > 0 {
			report.Duplicates, code = dups, exitProdDuplicate
		}
		return finish(code, err)
	}
	report = buildValidateReport(view, digest)
	report.Hlidac = base
	var cause error
	switch report.ExitCode {
	case exitProdSkipped:
		cause = fmt.Errorf("settings.json has %d entr(ies) the app skips or misreads — fix them first", len(report.Issues))
	case exitProdDuplicate:
		cause = fmt.Errorf("pointed at twice: %s", strings.Join(report.Duplicates, "; "))
	case exitProdUnreachable:
		cause = fmt.Errorf("upstream outage: Hlídač's Prometheus is not answering (since %s) — pointed deployments read blind", prometheusSince(digest))
	case exitProdUnknown:
		cause = fmt.Errorf("unknown to Hlídač: %s — add them to build-server-infra apps/hlidac/deployments.yaml, then restart hlidac (docker compose restart hlidac) once that PR deploys", strings.Join(report.Unknown, ", "))
	case exitProdBlind:
		cause = fmt.Errorf("blind deployments have no series — check their recording rules in build-server-infra")
	}
	return finish(report.ExitCode, cause)
}

func printValidateReport(r validateReport) {
	if r.Hlidac != "" {
		fmt.Fprintf(uiOut, "%sHlídač%s %s", bold, reset, r.Hlidac)
		if r.GeneratedAt != "" {
			fmt.Fprintf(uiOut, " · generated %s", r.GeneratedAt)
		}
		fmt.Fprintln(uiOut)
	}
	if len(r.Sources) > 0 {
		names := make([]string, 0, len(r.Sources))
		for name := range r.Sources {
			names = append(names, name)
		}
		sort.Strings(names)
		parts := make([]string, 0, len(names))
		for _, name := range names {
			mark := "✓"
			if !r.Sources[name].OK {
				mark = "✕"
			}
			parts = append(parts, name+" "+mark)
		}
		fmt.Fprintf(uiOut, "  sources: %s\n", strings.Join(parts, " · "))
	}
	for _, p := range r.Pointers {
		name := p.Project + "/" + p.Key
		if !p.Known {
			fmt.Fprintf(uiOut, "%s✕ %-28s unknown to Hlídač%s\n", red, name, reset)
			continue
		}
		mark, colour := "✓", green
		switch p.Verdict {
		case "degraded", "blind":
			mark, colour = "!", yellow
		case "down":
			mark, colour = "✕", red
		case "unmonitored":
			mark, colour = "·", dim
		}
		line := fmt.Sprintf("%s %-28s %s", mark, name, p.Verdict)
		if p.BlindSince != nil {
			line += " since " + *p.BlindSince
		}
		if p.Emergency {
			line += " · EMERGENCY"
		}
		if len(p.Failing) > 0 {
			line += "  " + strings.Join(p.Failing, " · ")
		}
		fmt.Fprintf(uiOut, "%s%s%s\n", colour, line, reset)
	}
	for _, key := range r.Unshown {
		fmt.Fprintf(uiOut, "%s? %-28s on Hlídač, no pointer shows it%s\n", dim, key, reset)
	}
	for _, dup := range r.Duplicates {
		fmt.Fprintf(uiOut, "%s✕ duplicate: %s%s\n", red, dup, reset)
	}
	for _, issue := range r.Issues {
		fmt.Fprintf(uiOut, "%s✕ settings.json %s%s\n", red, issue, reset)
	}
	for _, note := range r.Notes {
		fmt.Fprintf(uiOut, "%s· %s%s\n", dim, note, reset)
	}
	// r.Error reaches stderr through main; --json carries it in the object.
}

func firstNonEmpty(values ...string) string {
	for _, v := range values {
		if strings.TrimSpace(v) != "" {
			return strings.TrimSpace(v)
		}
	}
	return ""
}

// ── add ─────────────────────────────────────────────────────────────────

type addOptions struct {
	project, key, title, tier string
	order                     *int
	dryRun                    bool
}

func parseAddOptions(args []string) (addOptions, error) {
	var opts addOptions
	var positional []string
	for i := 0; i < len(args); i++ {
		flagValue := func() (string, error) {
			if i+1 >= len(args) {
				return "", fmt.Errorf("%s needs a value", args[i])
			}
			i++
			return args[i], nil
		}
		switch args[i] {
		case "--title":
			v, err := flagValue()
			if err != nil {
				return opts, err
			}
			opts.title = v
		case "--tier":
			v, err := flagValue()
			if err != nil {
				return opts, err
			}
			if !prodTiers[v] {
				return opts, fmt.Errorf("--tier must be critical, important or watch, not %q", v)
			}
			opts.tier = v
		case "--order":
			v, err := flagValue()
			if err != nil {
				return opts, err
			}
			n, err := strconv.Atoi(v)
			if err != nil {
				return opts, fmt.Errorf("--order must be an integer, not %q", v)
			}
			opts.order = &n
		case "--dry-run":
			opts.dryRun = true
		default:
			if strings.HasPrefix(args[i], "-") {
				return opts, fmt.Errorf("unknown flag %q", args[i])
			}
			positional = append(positional, args[i])
		}
	}
	if len(positional) != 2 {
		return opts, fmt.Errorf("usage: pultik prod add <project> <key> [--title t] [--tier critical|important|watch] [--order n] [--dry-run]")
	}
	opts.project, opts.key = positional[0], positional[1]
	if !prodKeyRe.MatchString(opts.key) {
		return opts, fmt.Errorf("key %q must match %s", opts.key, prodKeyRe)
	}
	return opts, nil
}

// addPointer returns settings.json with the pointer appended to the named
// project's prod array. Every value it does not touch is carried as the
// original raw JSON, so unknown keys survive; keys come out sorted, the same
// order the app's encoder writes. A project without a prod key first gets
// its shipped pointers written out, or adding one would silently drop them.
func addPointer(raw []byte, opts addOptions) (out []byte, note string, err error) {
	view, err := readSettings(raw)
	if err != nil {
		return nil, "", fmt.Errorf("%w — fix settings.json first", err)
	}
	for _, ref := range view.pointers {
		if ref.Pointer.Key == opts.key {
			shipped := ""
			if ref.Shipped {
				shipped = " (its shipped pointer)"
			}
			return nil, "", fmt.Errorf("%q is already pointed at by project %s%s", opts.key, ref.Project, shipped)
		}
	}
	out, materialized, err := appendPointer(raw, opts)
	if err != nil {
		return nil, "", err
	}
	if materialized > 0 {
		note = fmt.Sprintf("%s had no prod key: wrote its %d shipped pointer(s) first", opts.project, materialized)
	}
	return out, note, nil
}

func appendPointer(raw []byte, opts addOptions) ([]byte, int, error) {
	var top map[string]json.RawMessage
	if err := json.Unmarshal(raw, &top); err != nil {
		return nil, 0, fmt.Errorf("settings.json is not a JSON object: %w", err)
	}
	var projects []json.RawMessage
	if rawProjects, ok := top["projects"]; ok {
		if err := json.Unmarshal(rawProjects, &projects); err != nil {
			return nil, 0, fmt.Errorf("settings.json projects: %w", err)
		}
	}
	target, known := -1, []string{}
	for i, rawProject := range projects {
		var head struct {
			Key string `json:"key"`
		}
		if json.Unmarshal(rawProject, &head) != nil {
			continue
		}
		known = append(known, head.Key)
		if head.Key == opts.project {
			target = i
		}
	}
	if target < 0 {
		return nil, 0, fmt.Errorf("no project %q in settings.json (projects: %s)", opts.project, strings.Join(known, ", "))
	}
	var project map[string]json.RawMessage
	if err := json.Unmarshal(projects[target], &project); err != nil {
		return nil, 0, fmt.Errorf("project %q: %w", opts.project, err)
	}
	var pointers []json.RawMessage
	materialized := 0
	if rawProd, ok := project["prod"]; ok && !isNull(rawProd) {
		if err := json.Unmarshal(rawProd, &pointers); err != nil {
			return nil, 0, fmt.Errorf("project %q prod: %w", opts.project, err)
		}
	} else {
		for _, shipped := range shippedProdPointers[opts.project] {
			rawShipped, err := marshalRaw(shipped, false)
			if err != nil {
				return nil, 0, err
			}
			pointers = append(pointers, rawShipped)
			materialized++
		}
	}
	pointer, err := marshalRaw(prodPointer{Key: opts.key, Title: opts.title, Tier: opts.tier, Order: opts.order}, false)
	if err != nil {
		return nil, 0, err
	}
	pointers = append(pointers, pointer)
	if project["prod"], err = marshalRaw(pointers, false); err != nil {
		return nil, 0, err
	}
	if projects[target], err = marshalRaw(project, false); err != nil {
		return nil, 0, err
	}
	if top["projects"], err = marshalRaw(projects, false); err != nil {
		return nil, 0, err
	}
	out, err := marshalRaw(top, true)
	if err != nil {
		return nil, 0, err
	}
	return append(out, '\n'), materialized, nil
}

// marshalRaw encodes without HTML escaping: json.Marshal would rewrite every
// `&`, `<` and `>` inside the preserved raw values as unicode escapes, which
// is not the file the user wrote.
func marshalRaw(v any, indent bool) ([]byte, error) {
	var buf bytes.Buffer
	enc := json.NewEncoder(&buf)
	enc.SetEscapeHTML(false)
	if indent {
		enc.SetIndent("", "  ")
	}
	if err := enc.Encode(v); err != nil {
		return nil, err
	}
	return bytes.TrimRight(buf.Bytes(), "\n"), nil
}

func prodAdd(args []string) error {
	if len(args) > 0 && (args[0] == "--help" || args[0] == "-h") {
		prodUsage()
		return nil
	}
	opts, err := parseAddOptions(args)
	if err != nil {
		return &exitError{2, err}
	}
	path := settingsFile()
	raw, err := os.ReadFile(path)
	if err != nil {
		return fmt.Errorf("reading %s: %w", path, err)
	}
	next, note, err := addPointer(raw, opts)
	if err != nil {
		return err
	}
	if note != "" {
		fmt.Fprintf(uiOut, "%s· %s%s\n", dim, note, reset)
	}
	if opts.dryRun {
		printDiff(path, raw, next)
		return nil
	}
	if err := writeSettingsIfUnchanged(path, raw, next); err != nil {
		return err
	}
	ok("pointed %s at %s — the running panel hot-reloads; prove it with pultik prod validate", opts.project, opts.key)
	return nil
}

// writeSettingsIfUnchanged swaps the file in atomically, but only when it
// still holds what was read: the app writes the same file and a lost update
// would silently drop its change.
func writeSettingsIfUnchanged(path string, read, next []byte) error {
	info, err := os.Stat(path)
	if err != nil {
		return err
	}
	current, err := os.ReadFile(path)
	if err != nil {
		return err
	}
	if sha256.Sum256(current) != sha256.Sum256(read) {
		return errors.New("settings.json changed while pultik was editing it — run the command again")
	}
	return writeFileAtomic(path, next, info.Mode()&fs.ModePerm)
}

// printDiff shows a unified diff through the system diff when available,
// else the whole proposed file.
func printDiff(path string, before, after []byte) {
	dir, err := os.MkdirTemp("", "pultik-prod-diff-")
	if err == nil {
		defer os.RemoveAll(dir)
		a, b := filepath.Join(dir, "before.json"), filepath.Join(dir, "after.json")
		if os.WriteFile(a, normalizeJSON(before), 0o600) == nil && os.WriteFile(b, after, 0o600) == nil {
			out, _ := exec.Command("diff", "-u", "--label", path, "--label", path+" (proposed)", a, b).Output()
			if len(out) > 0 {
				fmt.Fprint(uiOut, string(out))
				return
			}
		}
	}
	fmt.Fprint(uiOut, string(after))
}

// normalizeJSON re-indents the original the way the proposal is written, so
// the diff shows the added pointer instead of whitespace churn.
func normalizeJSON(raw []byte) []byte {
	var top map[string]json.RawMessage
	if json.Unmarshal(raw, &top) != nil {
		return raw
	}
	out, err := marshalRaw(top, true)
	if err != nil {
		return raw
	}
	return append(out, '\n')
}
