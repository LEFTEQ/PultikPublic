import AppKit
import Links

/// The agent shell whose sessions Pultík opens (workbench WP6): Sessions'
/// "Open in …" verb. Its link scheme is Info.plist's `PultikSessionShellScheme`,
/// which `Project.swift` fills from the shell's own brand file, so no shell is
/// named here; its name is the installed app's. No scheme, or no app that
/// handles it, means no shell and no verb.
@MainActor
enum SessionShell {
    struct Shell: Equatable {
        let scheme: String
        /// What the verb calls it: the handling app's display name.
        let name: String
    }

    static let schemeKey = "PultikSessionShellScheme"
    /// LaunchServices is asked at most this often; a page's objects rebuild far more.
    private static let recheck: TimeInterval = 60
    private static var cached: (at: Date, shell: Shell?)?

    /// The shell installed on this Mac, if any.
    static var installed: Shell? {
        if let cached, Date().timeIntervalSince(cached.at) < recheck { return cached.shell }
        let shell = lookUp()
        cached = (Date(), shell)
        return shell
    }

    /// Opens `session` (a harness session id, or an agent's name or id) in
    /// `shell`: its canvas flies to that agent.
    static func open(_ session: String, in shell: Shell) {
        guard let url = SessionLink(scheme: shell.scheme, session: session)?.url else {
            NSLog("pultik: no session link for %@", session)
            return
        }
        NSWorkspace.shared.open(url)
    }

    /// Asks `shell` to resolve pull request `number` of `repo`'s merge (the merge preview's
    /// "Resolve in …", vt-7968 M3): Pultík's preview is read only.
    static func resolveMerge(repo: String, number: Int, in shell: Shell) {
        guard let url = MergeLink(scheme: shell.scheme, repo: repo, number: number)?.url else {
            NSLog("pultik: no merge link for %@#%d", repo, number)
            return
        }
        NSWorkspace.shared.open(url)
    }

    private static func lookUp() -> Shell? {
        guard let scheme = Bundle.main.object(forInfoDictionaryKey: schemeKey) as? String,
              let probe = SessionLink(scheme: scheme, session: "probe")?.url,
              let app = NSWorkspace.shared.urlForApplication(toOpen: probe)
        else { return nil }
        let info = Bundle(url: app)?.infoDictionary
        let name = info?["CFBundleDisplayName"] as? String ?? info?["CFBundleName"] as? String
            ?? app.deletingPathExtension().lastPathComponent
        return Shell(scheme: scheme, name: name)
    }
}
