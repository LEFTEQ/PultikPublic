package main

import (
	"bytes"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
)

func goldenDigest(t *testing.T) []byte {
	t.Helper()
	digest, err := os.ReadFile(filepath.Join("..", "..", "Tests", "Fixtures", "hlidac-digest.json"))
	if err != nil {
		t.Fatalf("golden digest: %v", err)
	}
	return digest
}

// fixtureHlidac serves the golden digest every repo of the prod-watch
// contract tests against (Tests/Fixtures/hlidac-digest.json), optionally
// edited by mutate.
func fixtureHlidac(t *testing.T, mutate ...func(map[string]any)) *httptest.Server {
	t.Helper()
	digest := goldenDigest(t)
	if len(mutate) > 0 {
		var doc map[string]any
		if err := json.Unmarshal(digest, &doc); err != nil {
			t.Fatal(err)
		}
		for _, m := range mutate {
			m(doc)
		}
		digest, _ = json.Marshal(doc)
	}
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/api/v1/prod" {
			http.NotFound(w, r)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		w.Write(digest)
	}))
	t.Cleanup(server.Close)
	return server
}

// writeSettings points the command at a scratch settings.json and captures
// its human output.
func writeSettings(t *testing.T, body string) (string, *bytes.Buffer) {
	t.Helper()
	path := filepath.Join(t.TempDir(), "settings.json")
	if err := os.WriteFile(path, []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PULTIK_SETTINGS", path)
	t.Setenv("PULTIK_HLIDAC_URL", "")
	out := &bytes.Buffer{}
	uiOut = out
	t.Cleanup(func() { uiOut = os.Stdout })
	return path, out
}

// deployment finds one deployment object in a decoded digest.
func deployment(doc map[string]any, key string) map[string]any {
	for _, d := range doc["deployments"].([]any) {
		if m := d.(map[string]any); m["key"] == key {
			return m
		}
	}
	return nil
}

func lineWith(out, needle string) string {
	for _, line := range strings.Split(out, "\n") {
		if strings.Contains(line, needle) {
			return line
		}
	}
	return ""
}

const fivePointers = `{"projects":[
 {"key":"exampleapp","prod":[{"key":"exampleapp-prod"}]},
 {"key":"eve","prod":[{"key":"eve-exampleapp-prod"}]},
 {"key":"booking","prod":[{"key":"booking-sk"},{"key":"booking-cz"}]},
 {"key":"vitrinka","prod":[{"key":"vitrinka","tier":"watch"}]}]}`

func exitCode(err error) int {
	var coded *exitError
	if errors.As(err, &coded) {
		return coded.code
	}
	if err != nil {
		return 1
	}
	return 0
}

func TestProdValidateAgainstGoldenDigest(t *testing.T) {
	server := fixtureHlidac(t)
	_, out := writeSettings(t, fivePointers)
	if code := exitCode(prodValidate([]string{"--url", server.URL})); code != 0 {
		t.Fatalf("all five pointers are known to the golden digest, exit %d:\n%s", code, out)
	}
	eve := lineWith(out.String(), "eve/eve-exampleapp-prod")
	if !strings.Contains(eve, "degraded") || !strings.Contains(eve, "claude-pool 1/2") {
		t.Fatalf("eve line %q", eve)
	}

	writeSettings(t, `{"projects":[{"key":"exampleapp","prod":[{"key":"exampleapp-prod"},{"key":"exampleapp-staging"}]}]}`)
	if code := exitCode(prodValidate([]string{"--url", server.URL})); code != exitProdUnknown {
		t.Fatalf("unknown pointer exit %d, want %d", code, exitProdUnknown)
	}

	if code := exitCode(prodValidate([]string{"--url", "http://127.0.0.1:1"})); code != exitProdUnreachable {
		t.Fatalf("unreachable Hlídač exit %d, want %d", code, exitProdUnreachable)
	}
}

func TestProdValidateBlindNotADigestAndPrometheusOutage(t *testing.T) {
	blind := fixtureHlidac(t, func(doc map[string]any) {
		eve := deployment(doc, "eve-exampleapp-prod")
		eve["verdict"], eve["blindSince"] = "blind", "2026-10-02T18:30:00Z"
	})
	_, out := writeSettings(t, fivePointers)
	if code := exitCode(prodValidate([]string{"--url", blind.URL})); code != exitProdBlind {
		t.Fatalf("blind deployment exit %d, want %d", code, exitProdBlind)
	}
	if line := lineWith(out.String(), "eve/eve-exampleapp-prod"); !strings.Contains(line, "blind since 2026-10-02T18:30:00Z") {
		t.Fatalf("blind line %q", line)
	}

	outage := fixtureHlidac(t, func(doc map[string]any) {
		deployment(doc, "exampleapp-prod")["verdict"] = "blind"
		doc["sources"].(map[string]any)["prometheus"] = map[string]any{"ok": false, "since": "2026-10-02T18:20:00Z", "error": "timeout"}
	})
	err := prodValidate([]string{"--url", outage.URL})
	if exitCode(err) != exitProdUnreachable || !strings.Contains(err.Error(), "since 2026-10-02T18:20:00Z") {
		t.Fatalf("Prometheus outage: %v", err)
	}

	notDigest := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Write([]byte(`{"ok":true}`))
	}))
	t.Cleanup(notDigest.Close)
	if code := exitCode(prodValidate([]string{"--url", notDigest.URL})); code != exitProdUnreachable {
		t.Fatalf("a 200 that is not a digest exit %d, want %d", code, exitProdUnreachable)
	}
}

func TestReadSettingsMirrorsTheAppsLenientDecode(t *testing.T) {
	view, err := readSettings([]byte(`{"projects":[
	 {"key":"exampleapp"},
	 {"key":"eve","title":7,"prod":[{"key":"eve-exampleapp-prod"}]},
	 {"key":"voke","repos":["a",null],"prod":[{"key":"voke-prod"}]},
	 {"key":"vitrinka","prod":[{"key":"vitrinka","order":"5"},{"key":"vitrinka-b","tier":"crit"},{"title":"no key"}]}]}`))
	if err != nil {
		t.Fatal(err)
	}
	keys := []string{}
	for _, ref := range view.pointers {
		keys = append(keys, ref.Pointer.Key)
	}
	// exampleapp: no prod key → its shipped pointer; eve and voke: whole project
	// skipped (wrong-typed title, null in repos); vitrinka: the string order
	// and the keyless pointer are skipped, the unknown tier kept but flagged.
	if strings.Join(keys, ",") != "exampleapp-prod,vitrinka-b" || !view.pointers[0].Shipped {
		t.Fatalf("pointers %v", view.pointers)
	}
	if len(view.issues) != 5 {
		t.Fatalf("want 5 issues, got %d: %v", len(view.issues), view.issues)
	}
	if _, err := readSettings([]byte(`{"hlidacURL":3}`)); err == nil {
		t.Fatal("a non-string hlidacURL fails the app's whole decode")
	}
	digest := hlidacDigest{GeneratedAt: "x", Sources: map[string]hlidacSource{"prometheus": {OK: true}}}
	if code := buildValidateReport(view, digest).ExitCode; code != exitProdSkipped {
		t.Fatalf("skipped entries exit %d, want %d", code, exitProdSkipped)
	}

	dup, _ := readSettings([]byte(`{"projects":[{"key":"exampleapp","prod":[{"key":"booking-sk"}]},{"key":"booking"}]}`))
	report := buildValidateReport(dup, digest)
	if report.ExitCode != exitProdDuplicate || !strings.Contains(strings.Join(report.Duplicates, ""), "booking-sk pointed at by exampleapp and booking") {
		t.Fatalf("duplicate: exit %d %v", report.ExitCode, report.Duplicates)
	}

	none, _ := readSettings([]byte(`{"projects":[{"key":"exampleapp","prod":[]}]}`))
	if notes := buildValidateReport(none, digest).Notes; !strings.Contains(strings.Join(notes, ""), "every deployment Hlídač reports") {
		t.Fatalf("no-pointer note missing: %v", notes)
	}

	// No pointers: the board shows every digest deployment (ProdGlance), so
	// validate judges those — a blind one with Prometheus down is an outage.
	outage := hlidacDigest{GeneratedAt: "x", Sources: map[string]hlidacSource{"prometheus": {OK: false}},
		Deployments: []hlidacDeployment{{Key: "exampleapp-prod", Project: "exampleapp", Verdict: "blind"}}}
	shown := buildValidateReport(none, outage)
	if shown.ExitCode != exitProdUnreachable || len(shown.Pointers) != 1 || len(shown.Unshown) != 0 {
		t.Fatalf("no pointers: exit %d, pointers %v, unshown %v", shown.ExitCode, shown.Pointers, shown.Unshown)
	}
}

func TestReadSettingsRejectsWhatFailsTheAppsWholeDecode(t *testing.T) {
	for _, doc := range []string{`null`, `{"hotkey":7}`, `{"notifyFiring":"false"}`,
		`{"fanCurveSmoothing":"1"}`, `{"externalBrightnessOffset":1.5}`, `{"pinnedRepos":["a",2]}`,
		`{"workspaces":[]}`, `{"displayPresets":{}}`} {
		if _, err := readSettings([]byte(doc)); err == nil {
			t.Errorf("%s passed, but Preferences.init(from:) throws on it", doc)
		}
	}
	// null is absent to decodeIfPresent; unknown keys are ignored.
	if _, err := readSettings([]byte(`{"hotkey":null,"notifyFiring":true,"externalBrightnessOffset":20,"someday":1}`)); err != nil {
		t.Fatal(err)
	}
}

// The kind table must name every field Preferences.init(from:) decodes, with
// the JSON kind its Swift type needs — a new settings field cannot drift.
func TestTopLevelKindsMatchPreferencesSwift(t *testing.T) {
	src, err := os.ReadFile("../../Sources/Store/Preferences.swift")
	if err != nil {
		t.Fatal(err)
	}
	start := bytes.Index(src, []byte("Decoded field-by-field with `decodeIfPresent`"))
	if start < 0 {
		t.Fatal("Preferences.init(from:) anchor moved — update this test")
	}
	body := src[start:]
	body = body[:bytes.Index(body, []byte("\n    }\n"))]
	fields := regexp.MustCompile(`container\.decodeIfPresent\(\s*(.+?)\.self,\s*forKey:\s*\.(\w+)\)`).FindAllSubmatch(body, -1)
	swiftKinds := map[string]jsonKind{"String": kindString, "Bool": kindBool, "Double": kindNumber, "Int": kindInteger,
		"[String]": kindStringArray, "WorkspacesConfig": kindObject, "[String: [CurvePoint]]": kindObject}
	seen := map[string]bool{}
	for _, f := range fields {
		swiftType, key := string(f[1]), string(f[2])
		want, ok := swiftKinds[swiftType]
		if !ok && (strings.HasPrefix(swiftType, "[") || strings.HasPrefix(swiftType, "LossyArray<")) {
			want, ok = kindArray, true
		}
		if !ok {
			t.Errorf("%s: no JSON kind for Swift type %s — extend this test", key, swiftType)
			continue
		}
		if got := topLevelKinds[key]; got != want {
			t.Errorf("topLevelKinds[%q] = %q, Preferences.swift decodes %s (%q)", key, got, swiftType, want)
		}
		seen[key] = true
	}
	for key := range topLevelKinds {
		if !seen[key] {
			t.Errorf("topLevelKinds names %q, which Preferences.init(from:) no longer decodes", key)
		}
	}
}

func TestProdAddPreservesUnknownKeysAndRefusesDuplicates(t *testing.T) {
	path, _ := writeSettings(t, `{
  "displayPresets" : [{"name":"dim","note":"a & b <c>"}],
  "hlidacURL" : "https:\/\/hlidac.ops.example.invalid",
  "projects" : [
    {"key":"exampleapp","links":[{"title":"Status","url":"https:\/\/status.example.invalid"}],"prod":[{"key":"exampleapp-prod","futureField":1}]},
    {"key":"booking","repos":["Booking\/BookingBack"]}
  ]
}`)
	// booking has no prod key: its shipped pointers are written out first,
	// or the add would silently drop SK and CZ from the board.
	if err := prodAdd([]string{"booking", "booking-dz", "--title", "Booking DZ", "--tier", "critical", "--order", "6"}); err != nil {
		t.Fatalf("add: %v", err)
	}
	after, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	for _, kept := range []string{`"a & b <c>"`, `https:\/\/status.example.invalid`, `"futureField": 1`, `Booking\/BookingBack`, `https:\/\/hlidac.ops.example.invalid`} {
		if !strings.Contains(string(after), kept) {
			t.Fatalf("lost %s:\n%s", kept, after)
		}
	}
	view, err := readSettings(after)
	keys := []string{}
	for _, ref := range view.pointers {
		keys = append(keys, ref.Pointer.Key)
	}
	last := view.pointers[len(view.pointers)-1].Pointer
	if err != nil || len(view.issues) != 0 || strings.Join(keys, ",") != "exampleapp-prod,booking-sk,booking-cz,booking-dz" || last.Tier != "critical" || *last.Order != 6 {
		t.Fatalf("after add: %v issues=%v err=%v", keys, view.issues, err)
	}
	if err := prodAdd([]string{"booking", "booking-dz"}); err == nil || !strings.Contains(err.Error(), "already pointed at by project booking") {
		t.Fatalf("duplicate accepted: %v", err)
	}
	if err := prodAdd([]string{"exampleapp", "booking-sk"}); err == nil || !strings.Contains(err.Error(), "already pointed at by project booking") {
		t.Fatalf("cross-project duplicate accepted: %v", err)
	}
	if err := prodAdd([]string{"nope", "voke-prod"}); err == nil {
		t.Fatal("unknown project accepted")
	}
}

func TestWriteSettingsRefusesAConcurrentChange(t *testing.T) {
	path, _ := writeSettings(t, `{"projects":[]}`)
	read, _ := os.ReadFile(path)
	if err := os.WriteFile(path, []byte(`{"projects":[],"pinnedRepos":["x"]}`), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := writeSettingsIfUnchanged(path, read, []byte(`{"projects":[{"key":"x"}]}`)); err == nil {
		t.Fatal("overwrote a file the app changed meanwhile")
	}
	now, _ := os.ReadFile(path)
	if !strings.Contains(string(now), "pinnedRepos") {
		t.Fatalf("the concurrent write was lost: %s", now)
	}
}
