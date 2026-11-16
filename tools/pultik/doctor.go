package main

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"time"
)

type doctorCheck struct {
	Name    string `json:"name"`
	Status  string `json:"status"`
	Summary string `json:"summary"`
}

type doctorReport struct {
	OK     bool          `json:"ok"`
	Checks []doctorCheck `json:"checks"`
}

func doctorCmd(args []string) error {
	asJSON := false
	for _, arg := range args {
		switch arg {
		case "--json":
			asJSON = true
		case "--help", "-h":
			doctorUsage()
			return nil
		default:
			return fmt.Errorf("unknown flag %q", arg)
		}
	}
	report := runDoctor()
	if asJSON {
		if err := printJSON(report); err != nil {
			return err
		}
		if !report.OK {
			return fmt.Errorf("doctor found required installation problems")
		}
		return nil
	}
	for _, check := range report.Checks {
		icon := "✓"
		if check.Status == "warning" {
			icon = "!"
		}
		if check.Status == "error" {
			icon = "✕"
		}
		fmt.Fprintf(uiOut, "%s %-10s %s\n", icon, check.Name, check.Summary)
	}
	if !report.OK {
		return fmt.Errorf("doctor found required installation problems")
	}
	return nil
}

func doctorUsage() {
	fmt.Print(`pultik doctor — diagnose the local Pultik installation

FLAGS
  --json     print a stable machine-readable report

Doctor is read-only. A missing fan helper is a warning; missing CLI
integration or an invalid Claude settings file is an error.
`)
}

func printJSON(v any) error {
	enc := json.NewEncoder(os.Stdout)
	enc.SetIndent("", "  ")
	return enc.Encode(v)
}

func runDoctor() doctorReport {
	checks := []doctorCheck{
		checkPlatform(), checkCLI(), checkApp(),
		checkHelper(), checkSkills(), checkHooks(), checkHammerspoon(), checkGitHubAuth(),
	}
	ok := true
	for _, check := range checks {
		if check.Status == "error" {
			ok = false
		}
	}
	return doctorReport{OK: ok, Checks: checks}
}

func checkPlatform() doctorCheck {
	if runtime.GOOS != "darwin" {
		return doctorCheck{"platform", "error", runtime.GOOS + " is unsupported"}
	}
	return doctorCheck{"platform", "ok", "macOS"}
}

func checkCLI() doctorCheck {
	binDir, err := pultikBinDir()
	if err != nil {
		return doctorCheck{"cli", "error", err.Error()}
	}
	path := filepath.Join(binDir, "pultik")
	info, err := os.Stat(path)
	if err != nil || info.Mode()&0o111 == 0 {
		return doctorCheck{"cli", "error", "missing executable at " + path}
	}
	found, err := exec.LookPath("pultik")
	if err != nil {
		return doctorCheck{"cli", "error", path + " exists but pultik is not on PATH"}
	}
	foundInfo, foundErr := os.Stat(found)
	expectedInfo, expectedErr := os.Stat(path)
	if foundErr != nil || expectedErr != nil || !os.SameFile(foundInfo, expectedInfo) {
		return doctorCheck{"cli", "error", "PATH resolves " + found + " instead of " + path}
	}
	return doctorCheck{"cli", "ok", found}
}

func checkApp() doctorCheck {
	candidates, err := appCandidates()
	if err != nil {
		return doctorCheck{"app", "error", err.Error()}
	}
	for _, app := range candidates {
		if info, err := os.Stat(app); err == nil && info.IsDir() {
			if err := validateApp(app); err != nil {
				return doctorCheck{"app", "warning", app + ": " + err.Error()}
			}
			return doctorCheck{"app", "ok", app}
		}
	}
	return doctorCheck{"app", "warning", "Pultik.app is not installed"}
}

func checkHelper() doctorCheck {
	binary := "/usr/local/sbin/pultik-fan-control-helper"
	plist := "/Library/LaunchDaemons/dev.example.pultik.fan-helper.plist"
	if _, err := os.Stat(binary); err != nil {
		return doctorCheck{"fan-helper", "warning", "not installed (fan controls remain disabled)"}
	}
	if _, err := os.Stat(plist); err != nil {
		return doctorCheck{"fan-helper", "warning", "binary exists but launch daemon is missing"}
	}
	if _, err := os.Stat("/var/run/pultik-fan-control.sock"); err != nil {
		return doctorCheck{"fan-helper", "warning", "installed but socket is unavailable"}
	}
	return doctorCheck{"fan-helper", "ok", "installed and socket present"}
}

// checkSkills: the todo skills come from the vitrinka plugin, so the only
// wrong state is a leftover pultik-managed copy shadowing them.
func checkSkills() doctorCheck {
	stale, err := legacyManagedSkills()
	if err != nil {
		return doctorCheck{"skills", "error", err.Error()}
	}
	if len(stale) > 0 {
		return doctorCheck{"skills", "warning", "stale pultik-managed copies shadow the vitrinka plugin — pultik install --skills-only retires: " + strings.Join(stale, ", ")}
	}
	return doctorCheck{"skills", "ok", "/todo* and /remind come from the vitrinka plugin"}
}

// checkHooks wants none of the SessionStart hooks older installs wrote:
// vitrinka's own SessionStart hook prints the todo and reminder cues, and a
// leftover pultik hook prints the todo cue a second time.
func checkHooks() doctorCheck {
	configDir, err := claudeConfigDir()
	if err != nil {
		return doctorCheck{"hooks", "error", err.Error()}
	}
	path := filepath.Join(configDir, "settings.json")
	raw, err := os.ReadFile(path)
	if os.IsNotExist(err) {
		return doctorCheck{"hooks", "ok", "no Claude settings.json, so no retired pultik SessionStart hook"}
	} else if err != nil {
		return doctorCheck{"hooks", "error", "cannot read " + path}
	}
	if !json.Valid(raw) {
		return doctorCheck{"hooks", "error", "invalid settings JSON"}
	}
	if retired := pultikHookCommands(raw); len(retired) > 0 {
		return doctorCheck{"hooks", "warning", fmt.Sprintf("%d retired pultik SessionStart hook(s) double vitrinka's todo cue — pultik install --hooks-only removes them", len(retired))}
	}
	return doctorCheck{"hooks", "ok", "no retired pultik SessionStart hooks (vitrinka's own hook prints the todo and reminder cues)"}
}

func checkGitHubAuth() doctorCheck {
	gh, err := exec.LookPath("gh")
	if err != nil {
		return doctorCheck{"github", "warning", "gh is not installed"}
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, gh, "auth", "status")
	if err := cmd.Run(); err != nil {
		return doctorCheck{"github", "warning", "gh is not authenticated"}
	}
	return doctorCheck{"github", "ok", "gh authenticated"}
}
