package main

// Hammerspoon package installation: symlink ~/.hammerspoon/init.lua to the
// managed package so `pultik install` on a fresh machine yields the full grid +
// organize setup, while a repo checkout keeps save-and-reload ergonomics.
//
// The symlink target is resolved by a ladder, most capable first:
//  1. PULTIK_REPO env (install-time hint only — nothing at runtime depends on
//     the environment, per the vault lesson in CLAUDE.md),
//  2. walking up from the running binary (source bootstrap runs from the repo),
//  3. the already-installed symlink, when it still points at a live checkout,
//  4. otherwise the embedded copies materialized under Application Support.
// organize.lua always ships beside init.lua: init.lua dofile()s its resolved
// sibling, so a target directory with only one file is a broken install.

//go:generate cp ../../hammerspoon/init.lua ../../hammerspoon/organize.lua installassets/hammerspoon/

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

var hammerspoonFiles = []string{"init.lua", "organize.lua"}

func hammerspoonLinkPath() (string, error) {
	home, err := os.UserHomeDir()
	if err != nil {
		return "", fmt.Errorf("find home directory: %w", err)
	}
	return filepath.Join(home, ".hammerspoon", "init.lua"), nil
}

func hammerspoonManagedDir() (string, error) {
	home, err := os.UserHomeDir()
	if err != nil {
		return "", fmt.Errorf("find home directory: %w", err)
	}
	return filepath.Join(home, "Library", "Application Support", "Pultik", "hammerspoon"), nil
}

// hammerspoonRepoDir returns the checkout's hammerspoon directory, or "" when
// no live checkout is detectable.
func hammerspoonRepoDir() string {
	isCheckout := func(dir string) bool {
		if dir == "" {
			return false
		}
		for _, name := range hammerspoonFiles {
			if _, err := os.Stat(filepath.Join(dir, name)); err != nil {
				return false
			}
		}
		return true
	}
	if repo := os.Getenv("PULTIK_REPO"); repo != "" {
		if dir := filepath.Join(repo, "hammerspoon"); isCheckout(dir) {
			return dir
		}
	}
	if executable, err := os.Executable(); err == nil {
		if resolved, err := filepath.EvalSymlinks(executable); err == nil {
			for dir := filepath.Dir(resolved); dir != "/" && dir != "."; dir = filepath.Dir(dir) {
				// tools/pultik must exist too, or any directory that happens to
				// hold two lua files would claim to be the repo.
				candidate := filepath.Join(dir, "hammerspoon")
				if isCheckout(candidate) {
					if _, err := os.Stat(filepath.Join(dir, "tools", "pultik")); err == nil {
						return candidate
					}
				}
			}
		}
	}
	linkPath, err := hammerspoonLinkPath()
	if err != nil {
		return ""
	}
	managed, err := hammerspoonManagedDir()
	if err != nil {
		return ""
	}
	if target, err := os.Readlink(linkPath); err == nil {
		if !filepath.IsAbs(target) { // relative targets resolve against the link's dir
			target = filepath.Join(filepath.Dir(linkPath), target)
		}
		dir := filepath.Dir(target)
		if dir != managed && isCheckout(dir) {
			return dir
		}
	}
	return ""
}

func installHammerspoon() error {
	linkPath, err := hammerspoonLinkPath()
	if err != nil {
		return err
	}
	targetDir := hammerspoonRepoDir()
	if targetDir == "" {
		targetDir, err = hammerspoonManagedDir()
		if err != nil {
			return err
		}
		for _, name := range hammerspoonFiles {
			data, err := installAssets.ReadFile("installassets/hammerspoon/" + name)
			if err != nil {
				return err
			}
			if err := writeFileAtomic(filepath.Join(targetDir, name), data, 0o644); err != nil {
				return err
			}
		}
	}
	target := filepath.Join(targetDir, "init.lua")

	if info, err := os.Lstat(linkPath); err == nil {
		if info.Mode()&os.ModeSymlink != 0 {
			if current, err := os.Readlink(linkPath); err == nil && current == target {
				ok("hammerspoon config already linked → %s", target)
				return nil
			}
		} else {
			if info.IsDir() {
				return fmt.Errorf("%s is a directory; move it aside first", linkPath)
			}
			// A hand-written config is user property: keep a copy the same way
			// installClaudeHooks keeps settings.json.pultik-backup.
			if err := copyFileAtomic(linkPath, linkPath+".pultik-backup", 0o644); err != nil {
				return fmt.Errorf("back up existing init.lua: %w", err)
			}
			step("backed up existing init.lua → " + linkPath + ".pultik-backup")
		}
		if err := os.Remove(linkPath); err != nil {
			return err
		}
	} else if !os.IsNotExist(err) {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(linkPath), 0o755); err != nil {
		return err
	}
	if err := os.Symlink(target, linkPath); err != nil {
		return err
	}
	ok("hammerspoon config → %s", target)
	return nil
}

func checkHammerspoon() doctorCheck {
	linkPath, err := hammerspoonLinkPath()
	if err != nil {
		return doctorCheck{"hammerspoon", "error", err.Error()}
	}
	info, err := os.Lstat(linkPath)
	if os.IsNotExist(err) {
		return doctorCheck{"hammerspoon", "warning", "not installed (run pultik install --hammerspoon-only)"}
	}
	if err != nil {
		return doctorCheck{"hammerspoon", "error", "unreadable: " + linkPath}
	}
	if info.Mode()&os.ModeSymlink == 0 {
		return doctorCheck{"hammerspoon", "warning", linkPath + " exists but is not installer-managed"}
	}
	target, err := os.Readlink(linkPath)
	if err != nil {
		return doctorCheck{"hammerspoon", "error", "unreadable symlink: " + linkPath}
	}
	// Readlink returns the target as stored: a relative target resolves against
	// the LINK's directory, not the process cwd (a hand-made relative link would
	// otherwise fail this check from any other directory).
	if !filepath.IsAbs(target) {
		target = filepath.Join(filepath.Dir(linkPath), target)
	}
	missing := []string{}
	for _, name := range hammerspoonFiles {
		if _, err := os.Stat(filepath.Join(filepath.Dir(target), name)); err != nil {
			missing = append(missing, name)
		}
	}
	if len(missing) > 0 {
		return doctorCheck{"hammerspoon", "error", "symlink target is missing " + strings.Join(missing, ", ") + " (reinstall with --hammerspoon-only)"}
	}
	return doctorCheck{"hammerspoon", "ok", target}
}
