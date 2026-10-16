// swift-tools-version: 6.0
import PackageDescription

// The timeline engine for Swift: Semafor's CI, Estate and Backups timelines and the estate map,
// laid out, hit-tested and drawn by the Rust crate timeline through its C ABI
// (crates/timeline-ffi). CTimeline is a module map over that crate's generated header; Timeline
// wraps it in Swift values. The package links nothing: its host links libpultik_ffi.a (Pultík's
// Project.swift builds it with cargo). README.md.
let package = Package(
    name: "Timeline",
    platforms: [.macOS(.v14)],
    products: [.library(name: "Timeline", targets: ["Timeline"])],
    targets: [
        .systemLibrary(name: "CTimeline"),
        .target(name: "Timeline", dependencies: ["CTimeline"]),
    ]
)
