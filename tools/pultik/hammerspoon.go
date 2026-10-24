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
// Modules always ship beside init.lua: init.lua dofile()s its resolved
// sibling, so a target directory with only one file is a broken install.

//go:generate cp ../../hammerspoon/init.lua ../../hammerspoon/organize.lua ../../hammerspoon/cmux.lua installassets/hammerspoon/

import (
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"strings"
)

var hammerspoonFiles = []string{"init.lua", "organize.lua", "cmux.lua"}

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
		if dir != managed && isPultikCheckoutDir(dir) {
			return dir
		}
	}
	return ""
}

// installHammerspoonStep is the install's Hammerspoon step. A full install
// links a fresh machine and refreshes pultik's own link, but keeps a config
// someone else wrote; --hammerspoon-force replaces that one too, with a backup.
func installHammerspoonStep(opts installOptions) error {
	if foreign, found := foreignHammerspoonConfig(); found && !opts.replaceHammerspoon {
		fmt.Fprintf(uiOut, "%s! kept your own Hammerspoon config (%s); `pultik install --hammerspoon-force` replaces it and keeps the old one as a backup%s\n", yellow, foreign, reset)
		return nil
	}
	if opts.dryRun {
		step("would link ~/.hammerspoon/init.lua (dry run)")
		return nil
	}
	return installHammerspoon()
}

// foreignHammerspoonConfig reports an init.lua that pultik did not put there:
// a hand-written file, or a symlink to somebody else's config.
func foreignHammerspoonConfig() (string, bool) {
	linkPath, err := hammerspoonLinkPath()
	if err != nil {
		return "", false
	}
	info, err := os.Lstat(linkPath)
	if err != nil {
		return "", false
	}
	if info.Mode()&os.ModeSymlink == 0 {
		return linkPath, true
	}
	target, err := os.Readlink(linkPath)
	if err != nil {
		return linkPath, true
	}
	if !filepath.IsAbs(target) {
		target = filepath.Join(filepath.Dir(linkPath), target)
	}
	if isPultikHammerspoonTarget(target) {
		return "", false
	}
	return linkPath + " → " + target, true
}

// isPultikHammerspoonTarget recognizes every link pultik writes: into the
// managed copies, into a checkout's hammerspoon package, and into a checkout
// that has since moved. A moved checkout's link dangles, so only its exact
// shape counts: <dir named pultik>/hammerspoon/init.lua, and only when the
// target is gone (ENOENT). Any other dangling or unreadable target, such as
// a dotfiles link on an unmounted volume, is the user's and is preserved.
func isPultikHammerspoonTarget(target string) bool {
	if filepath.Base(target) != "init.lua" {
		return false
	}
	dir := filepath.Dir(target)
	if managed, err := hammerspoonManagedDir(); err == nil && dir == managed {
		return true
	}
	if isPultikCheckoutDir(dir) {
		return true
	}
	if _, err := os.Stat(target); !errors.Is(err, fs.ErrNotExist) {
		return false
	}
	return filepath.Base(dir) == "hammerspoon" && strings.EqualFold(filepath.Base(filepath.Dir(dir)), "pultik")
}

// isPultikCheckoutDir is a checkout's hammerspoon package: the three modules
// with tools/pultik beside the directory, so a dotfiles folder that copied
// the modules is not taken for a checkout.
func isPultikCheckoutDir(dir string) bool {
	for _, name := range hammerspoonFiles {
		if _, err := os.Stat(filepath.Join(dir, name)); err != nil {
			return false
		}
	}
	_, err := os.Stat(filepath.Join(filepath.Dir(dir), "tools", "pultik"))
	return err == nil
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
		} else if info.IsDir() {
			return fmt.Errorf("%s is a directory; move it aside first", linkPath)
		}
		if _, foreign := foreignHammerspoonConfig(); foreign {
			// A hand-written config, or a link to one, is user property: keep
			// it under a name no earlier backup holds (a second link or hard
			// link, created exclusively), then drop the original name.
			backup, err := placeBackup(linkPath, func(candidate string) error {
				if info.Mode()&os.ModeSymlink != 0 {
					target, err := os.Readlink(linkPath)
					if err != nil {
						return err
					}
					return os.Symlink(target, candidate)
				}
				return os.Link(linkPath, candidate)
			})
			if err != nil {
				return fmt.Errorf("back up existing init.lua: %w", err)
			}
			if err := os.Remove(linkPath); err != nil {
				return err
			}
			step("backed up existing init.lua → " + backup)
		} else if err := os.Remove(linkPath); err != nil {
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
