// swift-tools-version: 6.0
import PackageDescription

// The deep links between the apps: `pultik://` (a PR's detail, a panel rail) and the agent
// shell's session links, built and parsed here and nowhere else. Foundation only, and it
// names no shell: the app that owns the shell's brand passes its scheme in. README.md.
let package = Package(
    name: "Links",
    platforms: [.macOS(.v14)],
    products: [.library(name: "Links", targets: ["Links"])],
    targets: [
        .target(name: "Links"),
        .testTarget(name: "LinksTests", dependencies: ["Links"]),
    ]
)
