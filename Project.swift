import ProjectDescription

let project = Project(
    name: "Pultik",
    // Stay in Pultík D8: descriptions render as GitHub-flavoured markdown
    // natively (cmark-gfm under swift-markdown, Apache-2.0).
    packages: [
        .remote(url: "https://github.com/swiftlang/swift-markdown.git", requirement: .upToNextMinor(from: "0.9.0")),
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
                "CFBundleShortVersionString": "3.0.2",
                "CFBundleVersion": "29",
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
            dependencies: [.target(name: "PultikFanHelper"), .package(product: "Markdown")],
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
