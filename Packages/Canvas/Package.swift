// swift-tools-version: 6.0
import PackageDescription

// Every Rust-drawn surface for Swift (D5, docs/specs/2026-10-17-pr-diff-rust-canvas-decisions.md): the host (CanvasView, a
// CAMetalLayer behind a demand-paused display link, its gestures and mouse forwarded to an
// engine) and every engine over one C ABI, crates/canvas-ffi (Semafor's CI, Estate and Backups
// timelines, the estate map, the PR diff, the merge view), all drawing on one shared GPU device. CCanvas is a module map over
// that crate's generated header; Canvas wraps it in Swift values. The package links nothing: its
// host links libpultik_ffi.a (Pultík's Project.swift builds it with cargo). README.md.
let package = Package(
    name: "Canvas",
    platforms: [.macOS(.v14)],
    products: [.library(name: "Canvas", targets: ["Canvas"])],
    targets: [
        .systemLibrary(name: "CCanvas"),
        .target(name: "Canvas", dependencies: ["CCanvas"]),
    ]
)
