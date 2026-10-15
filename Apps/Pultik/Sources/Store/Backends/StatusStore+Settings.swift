import Foundation

extension StatusStore {
    // MARK: - settings.json hot reload

    /// Directory-level watch, like NoteStore's: atomic writes replace the
    /// file's inode, so only the containing directory reliably reports them.
    func startWatchingSettings() {
        guard settingsWatcher == nil else { return }
        let fd = Darwin.open(Preferences.directory.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write], queue: .main)
        source.setEventHandler { [weak self] in self?.settingsDirectoryChanged() }
        source.setCancelHandler { close(fd) }
        source.resume()
        settingsWatcher = source
    }

    /// Cheap `stat` first: notes.json and links.json share the directory, and
    /// the app's own `Preferences.save()` must not bounce back as a reload.
    func settingsDirectoryChanged() {
        let stamp = SettingsFile.stamp(of: Preferences.fileURL)
        guard stamp != settingsSeenStamp else { return }
        settingsSeenStamp = stamp
        if let stamp, stamp == Preferences.memory.lastWritten { return }
        settingsReload?.cancel()
        settingsReload = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            self?.reloadSettings()
        }
    }

    /// Swap in an outside edit (an AI, `pultik prod add`, a hand edit). A
    /// file that no longer decodes keeps the copy in use and says why.
    func reloadSettings() {
        let snapshot = Preferences.loadSnapshot()
        configIssues = snapshot.issues
        settingsWritable = snapshot.writable
        // Not clean, the snapshot is the last good copy with any skipped
        // entries standing in — still the best view, just never written.
        preferences = snapshot.value
        if pinned != snapshot.value.pinnedRepos {
            // `pinned`'s didSet writes back: the same value, one harmless save
            // (refused while the file is not clean).
            pinned = snapshot.value.pinnedRepos
        }
        NSLog("pultik: settings.json reloaded%@",
              snapshot.issues.isEmpty ? "" : " with \(snapshot.issues.count) issue(s)")
        onChange?()
    }

    func enableLoginItemOnFirstRun() {
        let bundleId = Bundle.main.bundleIdentifier ?? "pultik"
        // A cache standing in for an unclean file may lack the opt-out that
        // the real file records — never re-enable on its say-so.
        guard settingsWritable else { return }
        guard preferences.loginItemConfiguredFor != bundleId else { return }
        LoginItem.setEnabled(true)
        mutate { $0.loginItemConfiguredFor = bundleId }
    }

    // MARK: - Sections, projects & config

    var projects: [ProjectSpec] {
        preferences.projects
    }

    func isSectionVisible(_ key: String) -> Bool {
        !preferences.hiddenSections.contains(key)
    }

    /// Configured VPSes — `/ssh` resolves its argument against these.
    var servers: [Preferences.NamedRef] {
        preferences.servers
    }

    /// Server display names in configured order — the services rail groups by
    /// these, so an unconfigured host never invents a heading of its own.
    var serverNames: [String] {
        preferences.servers.map(\.name)
    }

    var vitrinkaWorkspace: String { preferences.vitrinkaWorkspace ?? VitrinkaClient.shared.workspace ?? "" }
    /// Rail and palette derive their data from this pick, including when a
    /// refresh finishes after a switch or the picked workspace is unavailable.
    func setVitrinkaWorkspace(_ value: String) {
        mutate { $0.vitrinkaWorkspace = value }
    }

    /// Right-rail collapse state (decision D11). Persisted, so a folded rail
    /// stays folded across relaunches.
    func isRailCollapsed(_ key: String) -> Bool {
        preferences.collapsedRails.contains(key)
    }

    func setRail(_ key: String, collapsed: Bool) {
        mutate {
            $0.collapsedRails.removeAll { $0 == key }
            if collapsed { $0.collapsedRails.append(key) }
        }
    }

    /// The vitrinka project the panel's own writers file into (a promoted
    /// note, an expiry-radar reminder); nil = unset, and they refuse.
    var todoProject: String? {
        preferences.todoProject
    }

    /// Settings ▸ General ▸ Todos.
    func setTodoProject(_ slug: String?) {
        mutate { $0.todoProject = slug }
    }

    var codeEditor: String? {
        preferences.codeEditor
    }

    /// `/editor <name>` and the Settings picker; nil = autodetect.
    func setCodeEditor(_ id: String?) {
        mutate { $0.codeEditor = id }
    }

    /// Settings ▸ Modules, normalized: every module once, Home first.
    var moduleSettings: [ModuleSetting] {
        Preferences.normalizedModules(preferences.modules)
    }

    /// The strip's order — ⌘1–9 and ←/→ follow it (D4).
    var moduleOrder: [PanelModule] {
        moduleSettings.compactMap(\.module)
    }

    var keepHotModules: Set<PanelModule> {
        Set(moduleSettings.filter(\.keepHot).compactMap(\.module))
    }

    func setModuleSettings(_ settings: [ModuleSetting]) {
        mutate { $0.modules = Preferences.normalizedModules(settings) }
    }

    /// Hidden longer than this, a summon opens on Home (D1).
    var homeAfter: TimeInterval {
        TimeInterval(max(1, preferences.homeAfterMinutes ?? 15)) * 60
    }

    func setHomeAfterMinutes(_ minutes: Int) {
        mutate { $0.homeAfterMinutes = minutes == 15 ? nil : max(1, minutes) }
    }

    func setSection(_ key: String, visible: Bool) {
        mutate {
            $0.hiddenSections.removeAll { $0 == key }
            if !visible { $0.hiddenSections.append(key) }
        }
    }

    func isAlertLaneVisible(_ lane: String) -> Bool {
        preferences.visibleAlertLanes.contains(lane)
    }

    func setAlertLane(_ lane: String, visible: Bool) {
        mutate {
            $0.visibleAlertLanes.removeAll { $0 == lane }
            if visible { $0.visibleAlertLanes.append(lane) }
        }
        onChange?()
    }

    /// Query → project, matched on key/title prefix ("fix" → ExampleApp).
    func matchProject(_ query: String) -> ProjectSpec? {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard q.count >= 2 else { return nil }
        return preferences.projects.first {
            $0.key.lowercased().hasPrefix(q) || $0.title.lowercased().hasPrefix(q)
        }
    }

    // MARK: - Sentry settings

    /// The Sentry token lives in the login keychain (service `pultik-sentry`).
    /// A token found in settings.json — where it sat in plaintext before the
    /// integrations hub — is migrated in and blanked on first read, so old
    /// installs upgrade themselves without losing access mid-poll.
    var sentryToken: String? {
        if let token = Keychain.read(service: "pultik-sentry", account: "token") {
            return token
        }
        guard let legacy = preferences.sentryToken else { return nil }
        if let failure = Keychain.write(service: "pultik-sentry", account: "token", value: legacy) {
            NSLog("pultik: sentry token migration failed (%@) — keeping settings.json copy", failure)
            return legacy
        }
        mutate { $0.sentryToken = nil }
        NSLog("pultik: sentry token migrated from settings.json to the keychain")
        return legacy
    }

    /// Read-only view for the Integrations pane (preferences itself stays
    /// private — every mutation goes through a store method). What is
    /// actually swept, so the pane's "watching …" matches the rail.
    var sentryProjects: [String] {
        preferences.allSentryProjects
    }

    /// Returns nil on success, or the keychain's complaint — the Settings
    /// editor shows it rather than reporting a token as saved that is not.
    @discardableResult
    func setSentryToken(_ token: String?) -> String? {
        let trimmed = token?.trimmingCharacters(in: .whitespacesAndNewlines)
        let failure: String? = if let trimmed, !trimmed.isEmpty {
            Keychain.write(service: "pultik-sentry", account: "token", value: trimmed)
        } else {
            Keychain.delete(service: "pultik-sentry", account: "token")
        }
        if let failure {
            // A failed write leaves the keychain WITHOUT the new token, so the
            // legacy plaintext copy may be the only credential left — blanking
            // it here would log the user out of Sentry with nothing to fall
            // back on. Same for a failed delete: the old keychain value is
            // still live, so the caller has not actually been cleared.
            NSLog("pultik: sentry token keychain write failed: %@", failure)
        } else if preferences.sentryToken != nil {
            // Only once the keychain really holds the truth may the legacy
            // copy go — it must not linger to shadow the keychain value.
            mutate { $0.sentryToken = nil }
        }
        lastSentryRefresh = nil
        Task { await refresh() }
        return failure.map { "keychain refused the token: \($0)" }
    }

    // MARK: - eve settings

    var eveToken: String? {
        preferences.eveToken
    }

    /// nil on success, matching `setSentryToken` — settings.json writes have
    /// no failure channel of their own, so this one is always nil today.
    @discardableResult
    func setEveToken(_ token: String?) -> String? {
        let trimmed = token?.trimmingCharacters(in: .whitespacesAndNewlines)
        mutate { $0.eveToken = (trimmed?.isEmpty ?? true) ? nil : trimmed }
        Task { await refresh() }
        return nil
    }
}
