# Pultík (public source)

A macOS menu-bar command center: GitHub activity, notes, display presets,
calendar events, fan control, and adapters for an operator's backend services.

This is a **generated, sanitized mirror**. Changes are made in the private
source repository and rendered through an explicit file allowlist, replacements,
and a deny scan. Private Git history, operating notes, memory, CI logs, release
credentials, and infrastructure addresses are not copied here. Do not hand-edit
generated files.

## Build

Requires macOS 14+, Xcode, and Tuist:

```sh
tuist generate --no-open
xcodebuild -workspace Pultik.xcworkspace -scheme Pultik -configuration Debug build
```

The optional Go CLI builds separately with Go 1.26+:

```sh
cd tools/pultik
go build ./...
go test ./...
go vet ./...
```

## Integration boundaries

This is source for adaptation, not a ready-to-install hosted service. Infrastructure
defaults use reserved `example.invalid` names and `192.0.2.x` documentation
addresses. Backend clients, workspace URL validation, project defaults and the
Hammerspoon layout must be adapted to your environment. GitHub uses your existing
`gh` sign-in; other integrations need their respective services and credentials.
The CLI's download/publishing endpoint is a placeholder too; set `PULTIK_BASE`
to your own compatible service. There is no bundled public release installer.

Settings live in `~/Library/Application Support/Pultik/settings.json`.
PR search keeps bounded metadata in `~/Library/Caches/Pultik/GitHub/`, separated
by credential identity. Saved matches render before network work and remain available
during throttling; query results and confirmed number misses suppress repeat requests.
Recent history warms gradually, so an unseen historical PR still needs a first fetch.
Requests share a paced queue with foreground priority. Run the focused Foundation
contracts with `bash tools/test-foundation.sh` without launching a native app host.

Native Debug checks use `tools/panel-drive.sh`. Its `open` command and the
`PULTIK_OPEN_PANEL=<delay-seconds>` launch hook prefer a connected Studio Display,
falling back to the focused screen. `frame` reports the monitor name and bounds.
Ordinary hotkey and menu-bar summons continue to follow the user's screen.

The current implementation persists optional Sentry/Eve token overrides in that
local JSON file; do not commit or share it. An empty override falls back to the
existing local credential sources. The public tree contains no runtime settings.
Fan control needs the privileged helper and explicit elevation. Build and review
before installing it on a machine you depend on.

## Provenance

The SMC bridge and helper retain their GenesisFanControl provenance headers.
Public visibility alone does not grant a license; no open-source license is
declared until ownership and licensing of all included code are confirmed.
