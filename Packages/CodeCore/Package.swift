// swift-tools-version: 6.0
import PackageDescription

// The code core for Swift: highlighting, tags, symbols, search and the diff model, all
// computed by the Rust crate code-core through its C ABI (crates/code-core-ffi). CCodeCore is a
// module map over that crate's generated header; CodeCore wraps it in Swift values and owns
// every allocation. The package links nothing: its host links libcode_core_ffi.a (Pultík's
// Project.swift builds it with cargo). README.md.
let package = Package(
    name: "CodeCore",
    platforms: [.macOS(.v14)],
    products: [.library(name: "CodeCore", targets: ["CodeCore"])],
    targets: [
        .systemLibrary(name: "CCodeCore"),
        .target(name: "CodeCore", dependencies: ["CCodeCore"]),
    ]
)
