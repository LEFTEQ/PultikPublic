package main

import (
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
	if apps[0].Platform != "macos" || apps[0].Channel != "stable" || apps[0].Name != "pultik" {
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
	if err != nil || len(apps) != 1 || apps[0].Name != "eve" {
		t.Fatalf("apps = %+v, %v", apps, err)
	}
	if _, err := trainApps(manifest{App: "eve"}, "release.yaml", ""); err == nil {
		t.Fatal("a manifest without an artifact was accepted")
	}
}
