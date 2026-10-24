import Foundation

/// Finds a CLI a GUI app cannot rely on its PATH for (launchd hands it
/// `/usr/bin:/bin:/usr/sbin:/sbin`): an explicitly configured path first,
/// then the app's preferred locations (the copy it always ran), then each
/// absolute `PATH` entry, then the other install locations, in that order.
/// A later candidate is reached only when every earlier one is missing or
/// not executable. Never a shell. Foundation-only for the contract harness.
enum ExecutableSearch {
    /// nil = nothing usable. A configured path is explicit: when it is
    /// relative, missing or not executable the answer is nil, never a
    /// different copy found later (`usable` says which).
    static func find(_ name: String, configured: String?, preferred: [String] = [], fallbacks: [String],
                     environment: [String: String] = ProcessInfo.processInfo.environment,
                     isExecutable: (String) -> Bool = FileManager.default.isExecutableFile(atPath:)) -> String? {
        if let configured = expand(configured) {
            return usable(configured, isExecutable: isExecutable) ? configured : nil
        }
        return (preferred + onPath(name, environment: environment) + fallbacks).first(where: isExecutable)
    }

    /// A configured path the app may run: absolute and executable.
    static func usable(_ path: String,
                       isExecutable: (String) -> Bool = FileManager.default.isExecutableFile(atPath:)) -> Bool {
        path.hasPrefix("/") && isExecutable(path)
    }

    /// `name` in each absolute PATH entry, in order. A relative entry ("",
    /// ".") would resolve against whatever the app's working directory is.
    static func onPath(_ name: String, environment: [String: String]) -> [String] {
        (environment["PATH"] ?? "").split(separator: ":")
            .filter { $0.hasPrefix("/") }
            .map { "\($0.hasSuffix("/") ? String($0.dropLast()) : String($0))/\(name)" }
    }

    /// A settings path, tilde expanded; nil only for none or "" (not
    /// configured). A relative path comes back as written: it is configured
    /// but unusable, so it fails instead of resolving against whatever the
    /// app's working directory is, and never falls through to a search.
    static func expand(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return (trimmed as NSString).expandingTildeInPath
    }
}
