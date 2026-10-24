package main

import (
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"gopkg.in/yaml.v3"
)

func TestTrainAppsResolvesATrain(t *testing.T) {
	var m manifest
	src := `
version_cmd: echo 4.0.0
platform: macos
channel: stable
apps:
  - app: pultik
    build: ./tools/dist-macos.sh pultik
    artifact: dist/Pultik.zip
  - app: workshop
    hold: true
    channel: beta
    artifact: dist/Workshop.zip
`
	if err := yaml.Unmarshal([]byte(src), &m); err != nil {
		t.Fatal(err)
	}
	apps, err := trainApps(m, "release.yaml", "")
	if err != nil {
		t.Fatal(err)
	}
	if len(apps) != 2 || apps[0].App != "pultik" || apps[1].App != "workshop" {
		t.Fatalf("apps = %+v", apps)
	}
	if apps[0].Platform != "macos" || apps[0].Channel != "stable" || apps[0].Name != "pultik" || apps[0].Audience != "public" {
		t.Fatalf("pultik did not inherit the top level: %+v", apps[0])
	}
	if !apps[1].Hold || apps[1].Channel != "beta" {
		t.Fatalf("workshop lost its own hold or channel: %+v", apps[1])
	}

	only, err := trainApps(m, "release.yaml", "workshop")
	if err != nil || len(only) != 1 || only[0].App != "workshop" {
		t.Fatalf("--app workshop = %+v, %v", only, err)
	}
	if _, err := trainApps(m, "release.yaml", "nope"); err == nil || !strings.Contains(err.Error(), "pultik, workshop") {
		t.Fatalf("an unknown --app must name the train's apps, got %v", err)
	}

	m.Apps[1].VersionCmd = "echo 0.1.0"
	if _, err := trainApps(m, "release.yaml", ""); err == nil {
		t.Fatal("an app with its own version on a train was accepted")
	}
}

func TestTrainAppsKeepsASingleAppManifest(t *testing.T) {
	apps, err := trainApps(manifest{App: "eve", Artifact: "dist/eve.zip"}, "release.yaml", "")
	if err != nil || len(apps) != 1 || apps[0].Name != "eve" || apps[0].Audience != "public" || apps[0].GitHubOrg != "" {
		t.Fatalf("apps = %+v, %v", apps, err)
	}
	if _, err := trainApps(manifest{App: "eve"}, "release.yaml", ""); err == nil {
		t.Fatal("a manifest without an artifact was accepted")
	}
}

func TestTrainAppsValidatesAudience(t *testing.T) {
	for _, tc := range []struct {
		name, audience, org string
		valid               bool
	}{
		{"default", "", "", true},
		{"public", "public", "", true},
		{"team", "team", "sample-team", true},
		{"unknown", "internal", "", false},
		{"missing org", "team", "", false},
		{"public org", "public", "sample-team", false},
		{"implicit public org", "", "sample-team", false},
		{"path", "team", "sample/team", false},
		{"double hyphen", "team", "sample--team", false},
		{"leading hyphen", "team", "-sample", false},
		{"trailing hyphen", "team", "sample-", false},
		{"too long", "team", strings.Repeat("a", 40), false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			m := manifest{App: "workshop", Artifact: "app.zip", Audience: tc.audience, GitHubOrg: tc.org}
			_, err := trainApps(m, "release.yaml", "")
			if (err == nil) != tc.valid {
				t.Fatalf("valid=%v, err=%v", tc.valid, err)
			}
		})
	}
	m := manifest{Audience: "team", GitHubOrg: "sample-team", Apps: []manifest{{App: "workshop", Artifact: "app.zip"}}}
	if _, err := trainApps(m, "release.yaml", ""); err == nil {
		t.Fatal("train-wide audience policy was accepted instead of per-app policy")
	}
}

func TestShipTeamCapabilityFailsClosedBeforeAnyUpload(t *testing.T) {
	for _, tc := range []struct {
		name string
		code int
		body string
	}{
		{"missing", 404, "not found"},
		{"server error", 500, "error"},
		{"redirect", 302, ""},
		{"html", 200, "<html>sign in</html>"},
		{"empty", 200, "{}"},
		{"malformed", 200, `{"version":`},
		{"wrong version", 200, `{"version":2,"team_access":true,"policies":{"workshop":{"audience":"team","github_org":"sample-team"}}}`},
		{"disabled", 200, `{"version":1,"team_access":false,"policies":{"workshop":{"audience":"team","github_org":"sample-team"}}}`},
		{"missing policy", 200, `{"version":1,"team_access":true,"policies":{}}`},
		{"wrong org", 200, `{"version":1,"team_access":true,"policies":{"workshop":{"audience":"team","github_org":"other-team"}}}`},
		{"wrong audience", 200, `{"version":1,"team_access":true,"policies":{"workshop":{"audience":"public","github_org":"sample-team"}}}`},
		{"trailing data", 200, `{"version":1,"team_access":true,"policies":{"workshop":{"audience":"team","github_org":"sample-team"}}} {}`},
	} {
		t.Run(tc.name, func(t *testing.T) {
			requests := 0
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				requests++
				if r.Method != http.MethodGet || r.URL.Path != "/api/releases/capabilities" || r.Header.Get("Authorization") != "Bearer fixture-publisher" {
					t.Errorf("unexpected request: %s %s", r.Method, r.URL.Path)
				}
				w.WriteHeader(tc.code)
				_, _ = io.WriteString(w, tc.body)
			}))
			defer server.Close()
			t.Setenv("PULTIK_BASE", server.URL)
			t.Setenv("PULTIK_TOKEN", "fixture-publisher")
			dir := t.TempDir()
			file := filepath.Join(dir, "release.yaml")
			body := "version: 1.0.0\napps:\n  - app: public-app\n    artifact: missing.zip\n  - app: workshop\n    artifact: missing.zip\n    audience: team\n    github_org: sample-team\n"
			if err := os.WriteFile(file, []byte(body), 0o600); err != nil {
				t.Fatal(err)
			}
			err := ship([]string{"-f", file, "--skip-build", "--allow-overwrite", "--notes", "fixture notes", "--yes"})
			if err == nil || !strings.Contains(err.Error(), "team audience unsupported") || requests != 1 {
				t.Fatalf("err=%v, requests=%d; must refuse the whole train before artifact resolution/upload", err, requests)
			}
		})
	}
	t.Run("transport error", func(t *testing.T) {
		server := httptest.NewServer(http.HandlerFunc(func(http.ResponseWriter, *http.Request) {}))
		server.Close()
		t.Setenv("PULTIK_BASE", server.URL)
		t.Setenv("PULTIK_TOKEN", "fixture-publisher")
		if err := requireTeamAudience(manifest{App: "workshop", Audience: "team", GitHubOrg: "sample-team"}); err == nil {
			t.Fatal("transport failure was accepted")
		}
	})
}

func TestShipPropagatesAudienceAndKeepsHeldAndDryRuns(t *testing.T) {
	for _, tc := range []struct {
		name, audience string
		held, dryRun   bool
	}{
		{"public", "public", false, false},
		{"team", "team", false, false},
		{"dry run", "team", false, true},
		{"held team", "team", true, false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			var uploaded release
			capabilities, artifacts, metadata := 0, 0, 0
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				if r.Header.Get("Authorization") != "Bearer fixture-publisher" {
					t.Errorf("publisher request missing bearer: %s", r.URL.Path)
				}
				switch {
				case r.Method == http.MethodGet && r.URL.Path == "/api/releases/capabilities":
					capabilities++
					_, _ = io.WriteString(w, `{"version":1,"team_access":true,"audience":["public","team"],"github_org":"sample-team","policies":{"workshop":{"audience":"team","github_org":"sample-team"}}}`)
				case r.Method == http.MethodPut && strings.Contains(r.URL.Path, "/artifact/"):
					artifacts++
					payload, _ := io.ReadAll(r.Body)
					if string(payload) != "fixture artifact" {
						t.Errorf("artifact=%q", payload)
					}
				case r.Method == http.MethodPut && r.URL.Path == "/api/releases/workshop/1.0.0":
					metadata++
					if err := json.NewDecoder(r.Body).Decode(&uploaded); err != nil {
						t.Error(err)
					}
				default:
					t.Errorf("unexpected request %s %s", r.Method, r.URL.Path)
					w.WriteHeader(404)
				}
			}))
			defer server.Close()
			t.Setenv("PULTIK_BASE", server.URL)
			t.Setenv("PULTIK_TOKEN", "fixture-publisher")
			dir := t.TempDir()
			if err := os.WriteFile(filepath.Join(dir, "app.zip"), []byte("fixture artifact"), 0o600); err != nil {
				t.Fatal(err)
			}
			m := manifest{App: "workshop", Artifact: "app.zip", Audience: tc.audience, Hold: tc.held}
			if tc.held {
				if err := os.Remove(filepath.Join(dir, "app.zip")); err != nil {
					t.Fatal(err)
				}
				m.Build = "printf 'fixture artifact' > app.zip"
			}
			if tc.audience == "team" {
				m.GitHubOrg = "sample-team"
			}
			apps, err := trainApps(m, "release.yaml", "")
			if err != nil {
				t.Fatal(err)
			}
			o := shipOpts{allowOverwrite: true, notesGiven: true, notesMode: "fixture notes", yes: true, dryRun: tc.dryRun}
			job, err := prepareShip(apps[0], "1.0.0", dir, o)
			if err != nil {
				t.Fatal(err)
			}
			result, err := publishShip(job, "1.0.0", dir, o)
			if err != nil {
				t.Fatal(err)
			}
			if result.Audience != tc.audience || result.GitHubOrg != m.GitHubOrg || result.Held != tc.held || result.DryRun != tc.dryRun || result.Sha256 == "" {
				t.Fatalf("result=%+v", result)
			}
			encoded, err := json.Marshal(result)
			if err != nil {
				t.Fatal(err)
			}
			var decoded map[string]json.RawMessage
			if err := json.Unmarshal(encoded, &decoded); err != nil {
				t.Fatal(err)
			}
			if string(decoded["audience"]) != `"`+tc.audience+`"` || (len(decoded["github_org"]) > 0) != (tc.audience == "team") {
				t.Fatalf("audience keys missing or incorrect in JSON: %s", encoded)
			}
			if tc.held || tc.dryRun {
				if artifacts != 0 || metadata != 0 {
					t.Fatalf("held/dry run uploaded: artifacts=%d metadata=%d", artifacts, metadata)
				}
			} else if artifacts != 1 || metadata != 1 || uploaded.Audience != tc.audience || uploaded.GitHubOrg != m.GitHubOrg {
				t.Fatalf("artifacts=%d metadata=%d release=%+v", artifacts, metadata, uploaded)
			}
			wantCapabilities := 0
			if tc.audience == "team" && !tc.held {
				wantCapabilities = 1
			}
			if capabilities != wantCapabilities {
				t.Fatalf("capabilities=%d, want=%d", capabilities, wantCapabilities)
			}
		})
	}
}

func TestTeamPublisherReadsAreSeparateFromPublicReads(t *testing.T) {
	publisherReads, publicReads := 0, 0
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/api/releases/publisher" {
			publisherReads++
			if r.Header.Get("Authorization") != "Bearer fixture-publisher" {
				t.Error("publisher inventory missing bearer")
			}
			_, _ = io.WriteString(w, `{"apps":[{"id":"workshop","releases":[{"version":"0.9.0","ts":10,"commit":"old"},{"version":"1.0.0","ts":20,"commit":"current"}]}]}`)
			return
		}
		publicReads++
		if r.Header.Get("Authorization") != "" {
			t.Error("publisher bearer leaked to reader path")
		}
		switch r.URL.Path {
		case "/api/releases":
			_, _ = io.WriteString(w, `{"apps":[{"id":"sample","releases":[{"version":"1.0.0"}]}]}`)
		case "/api/releases/sample/latest":
			_, _ = io.WriteString(w, `{"app":"sample","version":"1.0.0","commit":"public"}`)
		default:
			t.Errorf("unexpected reader path %s", r.URL.Path)
			w.WriteHeader(404)
		}
	}))
	defer server.Close()
	t.Setenv("PULTIK_BASE", server.URL)
	t.Setenv("PULTIK_TOKEN", "fixture-publisher")
	if !alreadyShipped("workshop", "1.0.0", "team") || alreadyShipped("workshop", "2.0.0", "team") {
		t.Fatal("team overwrite state did not use publisher inventory")
	}
	if latest := lastShipped("workshop", "team"); latest.Commit != "current" {
		t.Fatalf("latest=%+v", latest)
	}
	if !alreadyShipped("sample", "1.0.0") || lastShipped("sample").Commit != "public" {
		t.Fatal("legacy public reads changed")
	}
	if publisherReads != 3 || publicReads != 2 {
		t.Fatalf("publisher=%d public=%d", publisherReads, publicReads)
	}
}
