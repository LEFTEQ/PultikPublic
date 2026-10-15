import ProjectDescription
import ProjectDescriptionHelpers

// ── Rust build seam (workbench WP3b) ───────────────────────────────────────────────────
//
// Highlighting, symbols, search and the diff model are crates/code-core, reached through its
// C ABI (crates/code-core-ffi, include/code_core.h) and Packages/CodeCore's Swift wrappers.
// CODE_CORE_CARGO_TARGET_DIR follows $CARGO_TARGET_DIR when xcodebuild inherits it, else
// <repo>/target. CODE_CORE_LIB is the static library the app links: one slice per arch built.
let codeCoreSettings: SettingsDictionary = [
    "CODE_CORE_CARGO_TARGET_DIR": "$(CARGO_TARGET_DIR:default=$(SRCROOT)/../../target)",
    "CODE_CORE_LIB": "$(DERIVED_FILE_DIR)/libcode_core_ffi.a",
]

/// Builds libcode_core_ffi for every arch in $ARCHS before Swift compiles (Debug: the active
/// one; Release: arm64 and x86_64, since Pultík ships universal), then joins the slices. The
/// host's arch builds without `--target`, so it shares <repo>/target/<profile> with every
/// other cargo run. cargo does its own up-to-date check, so this runs every build. Release
/// uses the `ffi-release` profile: release, but unwinding, so a panic in the core reaches
/// Swift as an error instead of ending the app.
let cargoBuild = TargetScript.pre(
    script: """
    set -eu
    export PATH="$HOME/.cargo/bin:$PATH"
    if ! command -v cargo >/dev/null 2>&1; then
      echo "error: cargo not found on PATH or in ~/.cargo/bin (install rustup; rust-toolchain.toml pins the toolchain)" >&2
      exit 1
    fi
    cd "$SRCROOT/../.."
    export CARGO_TARGET_DIR="$CODE_CORE_CARGO_TARGET_DIR"
    slices=""
    for arch in $ARCHS; do
      if [ "$arch" = "$(uname -m)" ]; then
        cargo build -p code-core-ffi --profile "$CODE_CORE_CARGO_PROFILE"
        slices="$slices $CARGO_TARGET_DIR/$CODE_CORE_CARGO_PROFILE_DIR/libcode_core_ffi.a"
        continue
      fi
      case "$arch" in
        arm64) triple=aarch64-apple-darwin ;;
        x86_64) triple=x86_64-apple-darwin ;;
        *) echo "error: no Rust target for $arch" >&2; exit 1 ;;
      esac
      cargo build -p code-core-ffi --profile "$CODE_CORE_CARGO_PROFILE" --target "$triple"
      slices="$slices $CARGO_TARGET_DIR/$triple/$CODE_CORE_CARGO_PROFILE_DIR/libcode_core_ffi.a"
    done
    mkdir -p "$(dirname "$CODE_CORE_LIB")"
    lipo -create $slices -output "$CODE_CORE_LIB"
    """,
    name: "Build code core (cargo)",
    basedOnDependencyAnalysis: false
)

let project = Project(
    name: "Pultik",
    // Stay in Pultík D8: descriptions render as GitHub-flavoured markdown
    // natively (cmark-gfm under swift-markdown, Apache-2.0).
    packages: [
        .remote(url: "https://github.com/swiftlang/swift-markdown.git", requirement: .upToNextMinor(from: "0.9.0")),
        // Workbench WP3b: highlighting, symbols, search and the diff model from the Rust
        // code core, over its C ABI (Packages/CodeCore/README.md).
        .local(path: "../../Packages/CodeCore"),
        // Workbench WP4: every code theme from one definition file, shared
        // with the Rust core (Packages/Theme/README.md).
        .local(path: "../../Packages/Theme"),
        // Workbench WP6: every pultik:// and session link, built and parsed in one place
        // (Packages/Links/README.md).
        .local(path: "../../Packages/Links"),
    ],
    settings: .settings(
        base: codeCoreSettings,
        configurations: [
            .debug(name: .debug, settings: [
                "CODE_CORE_CARGO_PROFILE": "dev",
                "CODE_CORE_CARGO_PROFILE_DIR": "debug",
            ]),
            .release(name: .release, settings: [
                "CODE_CORE_CARGO_PROFILE": "ffi-release",
                "CODE_CORE_CARGO_PROFILE_DIR": "ffi-release",
            ]),
        ]
    ),
    targets: [
        .target(
            name: "Pultik",
            destinations: .macOS,
            product: .app,
            // Fresh id for the rename. (Historical: "dev.example.hubbar" is burned —
            // macOS 26's status-item service holds broken per-bundle-id state for it,
            // the item scene never leaves "reconnecting". 2026-07-20.)
            bundleId: "dev.example.pultik",
            deploymentTargets: .macOS("26.0"),
            infoPlist: .extendingDefault(with: [
                "LSUIElement": true,
                "CFBundleDisplayName": "Pultík",
                // The release train's version (Tuist/ProjectDescriptionHelpers/Release.swift).
                "CFBundleShortVersionString": .string(Release.version),
                "CFBundleVersion": .string(Release.build),
                // pultik://pr/<owner>/<repo>/<n> opens a PR's detail (Packages/Links' PultikLink).
                "CFBundleURLTypes": [
                    ["CFBundleURLName": "dev.example.pultik", "CFBundleURLSchemes": ["pultik"]],
                ],
                // The agent shell whose sessions Pultík opens (SessionShell): its link scheme,
                // from the shell's brand file. The public mirror writes "" here (no shell).
                "PultikSessionShellScheme": "",
                // EventKit read grant (Integrations → Calendar access).
                "NSCalendarsFullAccessUsageDescription":
                    "Pultík shows today's events beside the schedule agenda. Read-only.",
            ]),
            // The daemon is its own target — the app must not compile its
            // top-level main.swift (two `main`s in one binary).
            sources: [.glob("Sources/**", excluding: ["Sources/Helper/**"])],
            scripts: [
                cargoBuild,
                // Ride the helper into Contents/MacOS, next to the app binary,
                // which is exactly where HelperInstaller looks for it.
                .post(
                    script: """
                    set -e
                    cp "$BUILT_PRODUCTS_DIR/pultik-fan-control-helper" \
                       "$TARGET_BUILD_DIR/$CONTENTS_FOLDER_PATH/MacOS/"
                    """,
                    name: "Embed fan helper",
                    inputPaths: ["$(BUILT_PRODUCTS_DIR)/pultik-fan-control-helper"],
                    outputPaths: ["$(TARGET_BUILD_DIR)/$(CONTENTS_FOLDER_PATH)/MacOS/pultik-fan-control-helper"],
                    basedOnDependencyAnalysis: true
                )
            ],
            dependencies: [
                .target(name: "PultikFanHelper"), .package(product: "Markdown"),
                .package(product: "CodeCore"), .package(product: "CodeThemes"), .package(product: "Links"),
            ],
            settings: .settings(base: [
                "CODE_SIGN_IDENTITY": "-",
                "CODE_SIGN_STYLE": "Automatic",
                // The cargo phase writes to <repo>/target, outside Xcode's script sandbox.
                "ENABLE_USER_SCRIPT_SANDBOXING": "NO",
                "OTHER_LDFLAGS": ["$(inherited)", "$(CODE_CORE_LIB)"],
            ])
        ),
        // Focused unit tests for pure logic (path repair, …). Not a UI lane:
        // the panel is verified by running it (tools/panel-drive.sh).
        .target(
            name: "PultikTests",
            destinations: .macOS,
            product: .unitTests,
            bundleId: "dev.example.pultik.tests",
            deploymentTargets: .macOS("26.0"),
            sources: ["Tests/**"],
            dependencies: [.target(name: "Pultik")],
            settings: .settings(base: [
                "CODE_SIGN_IDENTITY": "-",
                "CODE_SIGN_STYLE": "Automatic",
            ])
        ),
        // Privileged daemon: root, launchd-managed, owns every SMC write and
        // the 1 Hz re-assertion of pinned fans. Shares the SMC bridge with the
        // app; carries none of the UI.
        .target(
            name: "PultikFanHelper",
            destinations: .macOS,
            product: .commandLineTool,
            productName: "pultik-fan-control-helper",
            bundleId: "dev.example.pultik.fan-helper",
            deploymentTargets: .macOS("26.0"),
            sources: ["Sources/SMC/**", "Sources/Helper/**"],
            settings: .settings(base: [
                "CODE_SIGN_IDENTITY": "-",
                "CODE_SIGN_STYLE": "Automatic",
            ])
        )
    ]
)
