// The release train (workbench W10, W16): the monorepo's apps ship together, at one version,
// from one release.yaml. Every Project.swift reads it; release.yaml's version_cmd reads
// `version` from this file; `cargo xtask brand-check` holds the Cargo workspace version
// (Rust's `brand::VERSION`) equal to it. Bump `version` and `build` here before `pultik ship`.

/// The version both apps carry.
public enum Release {
    /// CFBundleShortVersionString of every app and helper, and the Cargo workspace version.
    public static let version = "4.1.0"
    /// CFBundleVersion of every app and helper.
    public static let build = "33"
}
