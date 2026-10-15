import ProjectDescription
import ProjectDescriptionHelpers

let project = Project(
    name: "Pultik",
    // Stay in Pultík D8: descriptions render as GitHub-flavoured markdown
    // natively (cmark-gfm under swift-markdown, Apache-2.0).
    packages: [
        .remote(url: "https://github.com/swiftlang/swift-markdown.git", requirement: .upToNextMinor(from: "0.9.0")),
        // PR workbench WP2: tree-sitter highlights and tags (MIT). Pinned
        // exactly: JavaScript 0.25 and YAML 0.7.2 drop their scanners from
        // the SwiftPM build; the queries are vendored by
        // tools/vendor-tree-sitter-queries.sh into Resources/Queries.
        .remote(url: "https://github.com/tree-sitter/swift-tree-sitter", requirement: .exact("0.25.0")),
        .remote(url: "https://github.com/tree-sitter/tree-sitter-go", requirement: .exact("0.25.0")),
        .remote(url: "https://github.com/tree-sitter/tree-sitter-typescript", requirement: .exact("0.23.2")),
        .remote(url: "https://github.com/tree-sitter/tree-sitter-javascript", requirement: .exact("0.23.1")),
        .remote(url: "https://github.com/tree-sitter/tree-sitter-html", requirement: .exact("0.23.2")),
        .remote(url: "https://github.com/tree-sitter/tree-sitter-json", requirement: .exact("0.24.8")),
        .remote(url: "https://github.com/tree-sitter-grammars/tree-sitter-yaml", requirement: .exact("0.7.0")),
        .remote(url: "https://github.com/tree-sitter-grammars/tree-sitter-markdown", requirement: .exact("0.5.3")),
        .remote(url: "https://github.com/tree-sitter/tree-sitter-rust", requirement: .exact("0.24.2")),
        .remote(url: "https://github.com/tree-sitter/tree-sitter-bash", requirement: .exact("0.25.1")),
        .remote(url: "https://github.com/tree-sitter/tree-sitter-php", requirement: .exact("0.25.1")),
    ],
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
                // pultik://pr/<owner>/<repo>/<n> opens a PR's detail (PultikLink).
                "CFBundleURLTypes": [
                    ["CFBundleURLName": "dev.example.pultik", "CFBundleURLSchemes": ["pultik"]],
                ],
                // EventKit read grant (Integrations → Calendar access).
                "NSCalendarsFullAccessUsageDescription":
                    "Pultík shows today's events beside the schedule agenda. Read-only.",
            ]),
            // The daemon is its own target — the app must not compile its
            // top-level main.swift (two `main`s in one binary).
            sources: [.glob("Sources/**", excluding: ["Sources/Helper/**"])],
            // Folder references keep `Queries/<language>/` and `Themes/` as
            // directories in the bundle (one highlights.scm per language).
            resources: [.folderReference(path: "Resources/Queries"), .folderReference(path: "Resources/Themes")],
            scripts: [
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
                .package(product: "SwiftTreeSitter"), .package(product: "TreeSitterGo"),
                .package(product: "TreeSitterTypeScript"), .package(product: "TreeSitterJavaScript"),
                .package(product: "TreeSitterHTML"), .package(product: "TreeSitterJSON"),
                .package(product: "TreeSitterYAML"), .package(product: "TreeSitterMarkdown"),
                .package(product: "TreeSitterRust"), .package(product: "TreeSitterBash"),
                .package(product: "TreeSitterPHP"),
            ],
            settings: .settings(base: [
                "CODE_SIGN_IDENTITY": "-",
                "CODE_SIGN_STYLE": "Automatic",
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
