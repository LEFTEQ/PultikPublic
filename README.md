# Pultík (public source)

A macOS menu-bar command center: GitHub activity, notes, display presets,
calendar events, fan control, and adapters for an operator's backend services.

This is a **generated, sanitized mirror**. Changes are made in the private
source repository and rendered through an explicit file allowlist, replacements,
and a deny scan. Private Git history, operating notes, memory, CI logs, release
credentials, and infrastructure addresses are not copied here. Do not hand-edit
generated files.

## Build

Requires macOS 26+, Xcode, Tuist and rustup: `rust-toolchain.toml` pins the Rust
toolchain and its macOS targets, which rustup installs on first use. Nothing else:
no Zig, no system libraries. The app lives in `Apps/Pultik/`; the root
`Workspace.swift` generates the workspace. Its local packages are `Packages/Theme`
(code themes), `Packages/Links` (deep links), and `Packages/CodeCore` and
`Packages/Timeline`, the Swift faces of the Rust core in `crates/`: syntax
highlighting, symbols, code search and diffs (`code-core`), and the zoomable
timelines and estate map on a wgpu renderer (`timeline`, `canvas-*`). The app's
cargo build phase compiles that core into one static library, `libpultik_ffi.a`
(`crates/pultik-ffi`), before Swift compiles, so the first build takes a few
minutes longer.

```sh
tuist generate --no-open
xcodebuild -workspace Pultik.xcworkspace -scheme Pultik -configuration Debug build
```

The Rust core builds and tests on its own, on macOS or Linux, at the versions
`Cargo.lock` pins:

```sh
cargo build --locked -p pultik-ffi
cargo test --locked -p timeline -p canvas-draw
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
Requests share a paced queue with foreground priority.

Native Debug checks use `tools/panel-drive.sh`. Its `open [screen]` command and
the `PULTIK_OPEN_PANEL=<delay-seconds>` launch hook (with `-ToolkitScreen <name>`)
use the named screen when it is connected, falling back to the focused screen;
`size` stays on the screen `open` chose.
`frame` reports the monitor name and bounds.
Ordinary hotkey and menu-bar summons continue to follow the user's screen.

The Sentry and Eve tokens live only in the login keychain (`pultik-sentry`,
`pultik-eve`); an older plaintext copy in that local JSON file moves there on
first read. Do not commit or share that file. The public tree contains no runtime settings.
Fan control needs the privileged helper and explicit elevation. Build and review
before installing it on a machine you depend on.

## Provenance

The SMC bridge and helper retain their GenesisFanControl provenance headers.
The code themes in `Packages/Theme` record each theme's source and licence;
its `NOTICE.md` carries the MIT notices of the third-party palettes.
Public visibility alone does not grant a license; no open-source license is
declared until ownership and licensing of all included code are confirmed.
