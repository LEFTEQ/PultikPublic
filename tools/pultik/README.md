# pultik — the release counter

`pultik ship` builds the app described by the repo's `release.yaml`, drafts
release notes (via `claude -p` when available — always shown for approval),
and puts the artifact + `release.json` on **downloads.example.invalid**, where the
marketplace homepage picks it up.

```bash
# normal install from the repository root (CLI + app + Claude integration)
./install.sh

# manual CLI-only fallback
mkdir -p ~/.local/bin
(cd tools/pultik && go build -o ~/.local/bin/pultik .)

# onboard a repo (AI drafts the manifest, you approve)
pultik init

# in an app repo with release.yaml
pultik ship                 # build → notes → confirm → upload
pultik ship --dry-run       # everything except upload
pultik ship --skip-build --notes "hotfix: crash on launch" --yes
pultik releases             # what's on the counter
pultik note --help           # scratch notes shown by the panel
                             # todos + reminders: vitrinka todo | vitrinka schedule
pultik install --help        # install/repair app + CLI + Claude integration
pultik doctor [--json]       # read-only local installation diagnosis
```

`pultik install` writes the Claude SessionStart hooks as `vitrinka
hook-context todo|schedule` (binary resolved from `~/.local/bin`, PATH, then
the usual manual-build dirs; `--dry-run` prints the lines). The `/todo*` and
`/remind` skills ship through vitrinka's kit plugin, not this CLI; an old
Obsidian vault moves over once with `vitrinka import pultik`.

## release.yaml

The canonical contract lives at **downloads.example.invalid/docs/shipping**.

```yaml
app: vitrinka          # [a-z0-9._-], marketplace id
name: Vitrinka
icon: "🖼️"             # emoji fallback until the first icon_file ships
icon_file: apps/desktop/marketplace-icon.png   # square full-bleed PNG ≥256px
description: Desktop shell for vitrinka boards.
platform: macos        # macos | android | chrome | …
channel: stable
build: ./apps/desktop/dist.sh            # any shell command, repo-relative
artifact: apps/…/bundle/dmg/*.dmg        # glob, newest match wins
version_cmd: node -p "require('./apps/desktop/src-tauri/tauri.conf.json').version"
notes_paths: [apps/desktop]              # optional — scope AI notes in a monorepo
```

Release notes draft from the commits **since the app's last shipped release**
(server-known, falls back to the last 30); a `RELEASE_NOTES.md` beside the
manifest wins over the AI draft when present.

Config: `PULTIK_TOKEN` (or `~/.config/pultik/token`) — the exampleapp-apps
`DOWNLOADS_UPLOAD_TOKEN`; `PULTIK_BASE` overrides `https://downloads.example.invalid`.

Server contract + marketplace: exampleapp-apps `docs/specs/2026-07-21-marketplace-cli-decisions.md`.
