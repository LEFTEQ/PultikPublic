// swift-tools-version: 6.0
import PackageDescription

// Code themes for every code surface, from one definition file
// (Sources/CodeThemes/Resources/themes.json). The module is CodeThemes, not
// Theme: an app's own `Theme` (design tokens) keeps that name. README.md.
let package = Package(
    name: "Theme",
    platforms: [.macOS(.v14)],
    products: [.library(name: "CodeThemes", targets: ["CodeThemes"])],
    targets: [
        .target(name: "CodeThemes", resources: [.copy("Resources/themes.json")]),
        .testTarget(name: "CodeThemesTests", dependencies: ["CodeThemes"]),
    ]
)
