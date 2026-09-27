import SwiftUI

// MARK: - Right rail: services

/// Probes filed under the box they RUN on (decision D8=A, 2026-08-27).
///
/// Grouping by host rather than by product because the failure that matters
/// most is a whole box going dark, and a product-shaped list scatters that
/// across four groups — the one shape that hides the cause. The group header
/// carries the verdict for the box: red the moment every service on it is down.
///
/// Host is where the service runs, NOT where the prober lives: api.example.invalid is
/// probed from BuildServer and served from AppServer, and filing it under the
/// prober would have made the grouping a lie.
struct ServiceRail: View {
    let statuses: [ServiceStatus]
    /// Configured server order, so the groups read in the same sequence as the
    /// vitals dock's estate tier rather than alphabetically.
    let hostOrder: [String]

    /// Grouped and ordered. Services with no host land in a trailing group
    /// rather than vanishing — an unfiled probe is still a probe.
    private var groups: [(host: String?, services: [ServiceStatus])] {
        var byHost: [String?: [ServiceStatus]] = [:]
        for service in statuses {
            byHost[service.host, default: []].append(service)
        }
        var ordered = hostOrder.compactMap { host -> (String?, [ServiceStatus])? in
            guard let found = byHost[host], !found.isEmpty else { return nil }
            return (host, found)
        }
        // Hosts present on a service but absent from the server list — a
        // hand-edited settings.json can do this, and silently dropping the
        // tile would look like the probe disappeared.
        let known = Set(hostOrder)
        for (host, services) in byHost where host != nil && !known.contains(host!) {
            ordered.append((host, services))
        }
        if let unfiled = byHost[nil], !unfiled.isEmpty { ordered.append((nil, unfiled)) }
        return ordered.map { (host: $0.0, services: $0.1) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(groups.enumerated()), id: \.offset) { _, group in
                VStack(alignment: .leading, spacing: 5) {
                    ServiceGroupHeader(host: group.host, services: group.services)
                    ForEach(group.services) { service in
                        ServiceTile(service: service)
                    }
                }
            }
        }
    }
}

/// The box name plus its verdict. The dot is deliberately NOT "any service
/// down" — one failing probe is that tile's problem. It goes red only when
/// every service on the box is down, which is the shape of a box being gone.
private struct ServiceGroupHeader: View {
    let host: String?
    let services: [ServiceStatus]

    private var allDown: Bool {
        !services.isEmpty && services.allSatisfy { $0.up == false }
    }

    private var anyUnknown: Bool {
        services.contains { $0.up == nil }
    }

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(allDown ? Color.red : anyUnknown ? Color.secondary.opacity(0.5) : Color.green)
                .frame(width: 5, height: 5)
            Text((host ?? "elsewhere").uppercased())
                .kerning(0.9)
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 2)
        .padding(.top, 2)
        .help(allDown ? "\(host ?? "Unfiled") — every probe is down"
            : "\(services.count) service\(services.count == 1 ? "" : "s") on \(host ?? "no configured host")")
    }
}

struct ServiceTile: View {
    let service: ServiceStatus
    @State private var hovering = false

    private var down: Bool {
        service.up == false
    }

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(service.up == nil ? Color.secondary : down ? .red : .green)
                .frame(width: 6, height: 6)
            Text(service.name)
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(.primary)
                .lineLimit(1)
            Spacer(minLength: 4)
            Text(down ? "down" : service.latencyLabel)
                .font(.system(size: 9, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(down ? .red : .secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(.white.opacity(hovering ? 0.06 : 0.035), in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(down ? Color.red.opacity(0.35) : Theme.hairline, lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture {
            // Container-internal probes aren't openable — fall back to Grafana.
            let target = service.probe.hasPrefix("https") ? service.probe : "https://grafana.ops.example.invalid"
            if let url = URL(string: target) {
                NSWorkspace.shared.open(url)
            }
        }
        .help(service.probe)
    }
}

// MARK: - Right rail: eve alerts

/// Recent eve alerts in the visible lanes — what lands in the Telegram
/// Incidents/Priority/ExampleApp-Prod topics, mirrored here. Unread rows read at
/// full strength with an accent bar; seen ones recede. Severity is the dot:
/// red critical, amber warning, neutral otherwise.
struct AlertsRail: View {
    let alerts: [EveAlert]
    let unread: Set<Int>

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(alerts.prefix(8)) { alert in
                AlertRow(alert: alert, unread: unread.contains(alert.id))
            }
        }
    }
}

private struct AlertRow: View {
    let alert: EveAlert
    let unread: Bool
    @State private var hovering = false

    private var tone: Color {
        switch alert.severity {
        case .critical: .red
        case .warning: .orange
        case nil: .secondary
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Circle()
                .fill(tone.opacity(alert.severity == nil ? 0.5 : 0.9))
                .frame(width: 6, height: 6)
                .padding(.top, 3)
            VStack(alignment: .leading, spacing: 1) {
                Text(alert.title)
                    .font(.system(size: 10.5, weight: unread ? .medium : .regular))
                    .foregroundStyle(unread ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                    .lineLimit(1)
                HStack(spacing: 4) {
                    Text(alert.category)
                        .font(.system(size: 8.5, design: .monospaced))
                        .foregroundStyle(.tertiary)
                    Spacer(minLength: 4)
                    Text(alert.ts.shortAge)
                        .font(.system(size: 8.5, design: .monospaced))
                        .monospacedDigit()
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(unread ? Color.primary.opacity(hovering ? 0.08 : 0.05)
            : hovering ? Color.primary.opacity(0.06) : .clear,
            in: RoundedRectangle(cornerRadius: 7))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .help("\(alert.category) · \(alert.flow) — \(alert.ts.shortAge) ago\n\(alert.body)")
    }
}

// MARK: - Right rail: saved links

/// Bookmarks, ordered by how much they've been used this week.
///
/// The order is the feature: a static list becomes a thing you scan, whereas a
/// list that floats what you actually opened becomes a thing you reach for.
struct LinksRail: View {
    let links: [SavedLink]
    let onOpen: (SavedLink) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(links) { link in
                LinkRow(link: link) { onOpen(link) }
            }
        }
    }
}

private struct LinkRow: View {
    let link: SavedLink
    let onOpen: () -> Void
    @State private var hovering = false

    private var weeklyOpens: Int {
        link.recentOpens(since: Date().addingTimeInterval(-7 * 24 * 60 * 60))
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "link")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
            Text(link.title)
                .font(.system(size: 10.5))
                .foregroundStyle(.primary)
                .lineLimit(1)
            Spacer(minLength: 4)
            if weeklyOpens > 0 {
                Text("\(weeklyOpens)")
                    .font(.system(size: 9, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(hovering ? Color.primary.opacity(0.06) : .clear,
                    in: RoundedRectangle(cornerRadius: 7))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: onOpen)
        .help("\(link.url)\n\(link.totalOpens) opens all time — /rm-link \(link.title) to remove")
    }
}

// MARK: - Right rail: scratch notes

/// Notes, newest first — one truncated line each, capped at five.
///
/// The cap is structural, not cosmetic: a rail that grows with the note count
/// pushes Links and Vitrinka off-screen no matter how short each row is. The
/// overflow row hands the rest to `.notes`, which is also where removal lives —
/// the row body reads, it doesn't destroy (⌥-click still removes in place).
struct NotesRail: View {
    let notes: [SavedNote]
    let onRemove: (SavedNote) -> Void
    let onOpenAll: () -> Void
    /// Ephemeral by design (a note reopens collapsed on the next panel summon),
    /// but owned by the panel so Esc can fold it — the window's
    /// `cancelOperation` would otherwise close everything instead.
    @Binding var expandedID: String?

    static let railCap = 5

    private var shown: ArraySlice<SavedNote> {
        notes.prefix(Self.railCap)
    }

    private var overflow: Int {
        max(0, notes.count - Self.railCap)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(shown) { note in
                NoteRow(
                    note: note,
                    style: .rail,
                    expanded: expandedID == note.id,
                    onToggle: {
                        withAnimation(.easeOut(duration: 0.16)) {
                            expandedID = expandedID == note.id ? nil : note.id
                        }
                    },
                    onRemove: { onRemove(note) }
                )
            }
            if overflow > 0 {
                Button(action: onOpenAll) {
                    HStack(spacing: 4) {
                        Text("+\(overflow) more")
                        Image(systemName: "arrow.right")
                            .font(.system(size: 8, weight: .semibold))
                        Spacer(minLength: 0)
                    }
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Open .notes — every note, searchable")
            }
        }
    }
}

// MARK: - Devbox: workspace verbs, the stale clear, workspace detail

/// One workspace's lifecycle verbs (spec 2026-09-14 decisions 6–7, moved
/// onto the `.devbox` page by spec 2026-09-23 D8): hot — park (two-click),
/// hold / unhold, Warp; parked — revive, clear (two-click `devbox reap`,
/// refused by the box while the branch is alive), hold / unhold. Never
/// `down`. The icons show only while `revealed`; a running verb's progress
/// and a failure show regardless, in the same fixed-height slot, so the row
/// never changes height or count while a verb runs. The slot overlays the
/// row's trailing columns, so whatever it shows sits on its own material
/// pill; an empty slot draws nothing.
struct DevboxVerbs: View {
    let workspace: DevboxWorkspace
    let store: StatusStore
    let revealed: Bool
    /// A lifecycle verb is in flight (park ~2 s, revive ~16 s, cold up
    /// minutes). The slot says which, and refuses a second click meanwhile.
    @State private var busyLabel: String?
    /// Park and clear are the verbs that stop or remove something: the first
    /// click arms, the second within a few seconds runs. Inline rather than a
    /// modal — the panel is a floating HUD and a sheet on it is never right.
    @State private var confirmingPark = false
    @State private var confirmingClear = false
    @State private var lastActionFailed = false

    var body: some View {
        HStack(spacing: 8) {
            if let busyLabel {
                ProgressView().controlSize(.mini)
                Text(busyLabel)
                    .font(.system(size: 8.5, design: .monospaced))
                    .foregroundStyle(.tertiary)
            } else if lastActionFailed {
                Text("failed · see log")
                    .font(.system(size: 8.5, design: .monospaced))
                    .foregroundStyle(.red)
            } else if revealed {
                lifecycleActions
            }
        }
        .frame(height: 14)
        .padding(.horizontal, showsSomething ? 7 : 0)
        .padding(.vertical, showsSomething ? 2 : 0)
        .background(showsSomething ? AnyShapeStyle(.regularMaterial) : AnyShapeStyle(.clear), in: Capsule())
        .onChange(of: revealed) { _, shown in
            guard !shown else { return }
            confirmingPark = false
            confirmingClear = false
        }
    }

    private var showsSomething: Bool {
        busyLabel != nil || lastActionFailed || revealed
    }

    @ViewBuilder
    private var lifecycleActions: some View {
        if workspace.isParked {
            if let macPath = workspace.macPath,
               DevboxLauncher.localDirectory(macPath, quiet: true) != nil
            {
                devboxIconButton("play.circle", "Revive", "Revive — devbox up from \(macPath)") {
                    runAction("reviving") {
                        await DevboxClient.shared.up(workspace: workspace.name, macPath: macPath)
                    }
                }
            } else {
                devboxVerbGlyph("play.circle")
                    .foregroundStyle(.quaternary)
                    .help(workspace.macPath.map { "Cannot revive from here — \($0) is not on this Mac" }
                        ?? "Cannot revive from here — the box recorded no Mac path")
                    .accessibilityLabel("Revive unavailable")
            }
            if confirmingClear {
                Button {
                    confirmingClear = false
                    runAction("clearing") {
                        await DevboxClient.shared.run(.reap, workspace: workspace.name)
                    }
                } label: {
                    Text("clear?")
                        .font(.system(size: 8.5, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.red)
                }
                .buttonStyle(.plain)
                .help("Click again to reap this workspace (devbox reap — fails while its branch is still alive)")
                .accessibilityLabel("Confirm clear")
            } else {
                devboxIconButton("trash", "Clear", "Clear — devbox reap: tear the workspace down; refused while its branch is alive") {
                    confirmingClear = true
                    Task {
                        try? await Task.sleep(for: .seconds(4))
                        await MainActor.run { confirmingClear = false }
                    }
                }
            }
        } else {
            if confirmingPark {
                Button {
                    confirmingPark = false
                    runAction("parking") {
                        await DevboxClient.shared.run(.park, workspace: workspace.name)
                    }
                } label: {
                    Text("park?")
                        .font(.system(size: 8.5, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.orange)
                }
                .buttonStyle(.plain)
                .help("Click again to park (stops the stack, keeps identity and ports)")
                .accessibilityLabel("Confirm park")
            } else {
                devboxIconButton("parkingsign.circle", "Park", "Park — stop, keep hot; up revives in ~16 s") {
                    confirmingPark = true
                    Task {
                        try? await Task.sleep(for: .seconds(4))
                        await MainActor.run { confirmingPark = false }
                    }
                }
            }
        }
        if workspace.hold {
            devboxIconButton("pin.slash", "Unhold", "Unhold — return to auto-parking") {
                runAction("unholding") {
                    await DevboxClient.shared.run(.unhold, workspace: workspace.name)
                }
            }
        } else {
            devboxIconButton("pin", "Hold", "Hold — exempt from the park sweep") {
                runAction("holding") {
                    await DevboxClient.shared.run(.hold, workspace: workspace.name)
                }
            }
        }
        if !workspace.isParked, !workspace.sources.isEmpty {
            devboxIconButton("terminal", "Warp", "Open workspace in Warp") {
                DevboxLauncher.summonWorkspaceWarp(workspace.name, on: workspace.box)
            }
        }
    }

    /// One verb at a time per workspace; the box is refreshed straight after
    /// so the row flips within the same breath, not at the next poll.
    ///
    /// Deliberately NOT generation-scoped (cf. the warm-panel rule in
    /// `.claude/memory/`): the busy flag is row-local truth about a verb
    /// that is still running on the box, not a per-open presentation. The
    /// panel being dismissed and reopened mid-revive must still end with the
    /// flag cleared — gating the clear on the presenting generation would
    /// leave the row stuck on "reviving" forever. Concurrency is bounded by
    /// the `busyLabel == nil` guard, so no later action can be stomped.
    private func runAction(_ label: String, _ work: @escaping () async -> Bool) {
        guard busyLabel == nil else { return }
        busyLabel = label
        lastActionFailed = false
        Task {
            let ok = await work()
            await store.refreshDevboxNow()
            await MainActor.run { busyLabel = nil }
            guard !ok else { return }
            await MainActor.run { lastActionFailed = true }
            try? await Task.sleep(for: .seconds(6))
            await MainActor.run { lastActionFailed = false }
        }
    }
}

/// The page-level "clear" (`devbox gc --retire-stale`): a trash glyph that
/// arms on the first click and runs on the second, then refreshes the box
/// straight after so the reaped rows leave within the same breath.
struct DevboxClearStale: View {
    let store: StatusStore
    @State private var confirming = false
    @State private var clearing = false
    @State private var failed = false

    var body: some View {
        if clearing {
            HStack(spacing: 4) {
                ProgressView().controlSize(.mini)
                Text("clearing")
                    .font(RailRowMetrics.metaFont)
                    .foregroundStyle(.tertiary)
            }
            .frame(height: 14)
        } else if failed {
            Text("failed · see log")
                .font(RailRowMetrics.metaFont)
                .foregroundStyle(.red)
                .frame(height: 14)
        } else if confirming {
            Button {
                confirming = false
                clearing = true
                Task {
                    let ok = await DevboxClient.shared.gc()
                    await store.refreshDevboxNow()
                    await MainActor.run { clearing = false }
                    guard !ok else { return }
                    await MainActor.run { failed = true }
                    try? await Task.sleep(for: .seconds(6))
                    await MainActor.run { failed = false }
                }
            } label: {
                Text("clear?")
                    .font(.system(size: 8.5, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.red)
            }
            .buttonStyle(.plain)
            .help("Click again to reap every workspace whose branch is merged or gone (devbox gc --retire-stale)")
            .accessibilityLabel("Confirm clear")
        } else {
            Button {
                confirming = true
                Task {
                    try? await Task.sleep(for: .seconds(4))
                    await MainActor.run { confirming = false }
                }
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .frame(width: 14, height: 14)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Clear — reap every workspace whose branch is merged or gone; live branches stay")
            .accessibilityLabel("Clear dead workspaces")
        }
    }
}

/// Everything per-app about one workspace — app chips, units, containers,
/// and every source with its Warp / Finder / Cursor / Copy verbs — shown
/// under its row on the `.devbox` page once the row is expanded.
struct DevboxWorkspaceDetail: View {
    let workspace: DevboxWorkspace

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if !workspace.apps.isEmpty, !workspace.isParked {
                WorkspaceAppChipsRow(apps: workspace.apps)
            }
            if !workspace.isParked {
                unitRows
                containerRows
            }
            sourceRows
        }
    }

    private var unitRows: some View {
        ForEach(workspace.unitApps) { app in
            HStack(spacing: 4) {
                Circle()
                    .fill(appTone(app))
                    .frame(width: 4, height: 4)
                Text(app.name)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if let port = app.port {
                    Text(":\(port)")
                        .font(.system(size: 8.5, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
                Text(app.active ?? "unknown")
                    .font(.system(size: 8.5, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
            .padding(.leading, 12)
            .accessibilityElement(children: .combine)
        }
    }

    private var containerRows: some View {
        ForEach(workspace.stats) { container in
            HStack(spacing: 4) {
                Circle()
                    .fill(containerTone(container))
                    .frame(width: 4, height: 4)
                Text(shortContainerName(container.name))
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Text(container.isUp
                    ? "\(Int(container.cpuPercent.rounded()))% · \(container.memoryLabel)"
                    : "stopped")
                    .font(.system(size: 8.5, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
            .padding(.leading, 12)
            .help(container.status)
            .accessibilityElement(children: .combine)
            .accessibilityValue(
                container.isUnhealthy ? "unhealthy"
                    : container.isUp ? "up" : "stopped"
            )
        }
    }

    private var sourceRows: some View {
        ForEach(workspace.sources) { source in
            HStack(spacing: 5) {
                Image(systemName: "folder")
                    .font(.system(size: 8))
                    .foregroundStyle(.tertiary)
                Text(source.path)
                    .font(.system(size: 8.5, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 2)
                sourceActions(source.path)
            }
            .padding(.leading, 12)
            .help("\(source.app): \(source.path)")
        }
    }

    private func sourceActions(_ path: String) -> some View {
        HStack(spacing: 7) {
            devboxIconButton("terminal", "Warp", "Open workspace in Warp") {
                DevboxLauncher.summonWorkspaceWarp(workspace.name, on: workspace.box)
            }
            devboxIconButton("folder", "Finder", "Reveal in Finder") {
                DevboxLauncher.revealLocalPath(path)
            }
            devboxIconButton("chevron.left.forwardslash.chevron.right", "Cursor", "Open in Cursor") {
                DevboxLauncher.openLocalCursor(path)
            }
            devboxIconButton("doc.on.doc", "Copy path", "Copy the Mac path") {
                DevboxLauncher.copyLocalPath(path)
            }
        }
    }

    private func appTone(_ app: DevboxWorkspaceApp) -> Color {
        if app.isFailed { return .orange }
        if app.hostUp == false { return .red }
        if app.hostUp == true { return .green }
        return app.isActive ? .green : .secondary
    }

    private func containerTone(_ container: DevboxContainerStat) -> Color {
        if container.isUnhealthy { return .orange }
        return container.isUp ? .green : .red
    }

    private func shortContainerName(_ name: String) -> String {
        guard let project = workspace.project else { return name }
        let prefix = "devbox-\(project)-\(workspace.name)-"
        return name.hasPrefix(prefix) ? String(name.dropFirst(prefix.count)) : name
    }
}

/// A verb is its glyph; the name lives in the tooltip and the accessibility
/// label (spec 2026-09-01 decision 7, revised during the hand test — hover
/// words wrapped inside the 280 pt rail).
private func devboxVerbGlyph(_ symbol: String) -> some View {
    Image(systemName: symbol).font(.system(size: 10))
}

private func devboxIconButton(_ symbol: String, _ word: String, _ help: String,
                              action: @escaping () -> Void) -> some View
{
    Button(action: action) {
        devboxVerbGlyph(symbol)
    }
    .buttonStyle(.plain)
    .foregroundStyle(.secondary)
    .help(help)
    .accessibilityLabel("\(word) — \(help)")
}

/// One-click URLs for both workspace forms: committed apps use their routed
/// domain; per-branch instances use their direct mesh port. Chips wrap — a
/// 20-app workspace is rows, never a 700pt line escaping the rail.
private struct WorkspaceAppChipsRow: View {
    let apps: [DevboxWorkspaceApp]

    var body: some View {
        FlowRow(hSpacing: 4, vSpacing: 4) {
            ForEach(apps) { app in
                if let url = app.url {
                    Button {
                        NSWorkspace.shared.open(url)
                    } label: {
                        appChip(app)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(app.isActive || app.hostUp == true ? .primary : .secondary)
                    .help(appHelp(app))
                    .accessibilityLabel("\(app.name), \(accessibilityState(app))")
                    // Secondary action: the address itself, for a curl or a
                    // teammate. Click stays the open; there is no third verb.
                    .contextMenu {
                        Button("Copy URL") { DevboxLauncher.copyURL(url) }
                        Button("Open in Browser") { NSWorkspace.shared.open(url) }
                    }
                } else {
                    appChip(app)
                        .foregroundStyle(app.isActive ? .primary : .secondary)
                        .help(appHelp(app))
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(
                            "\(app.name), \(accessibilityState(app)), link unavailable"
                        )
                }
            }
        }
    }

    private func appChip(_ app: DevboxWorkspaceApp) -> some View {
        HStack(spacing: 3) {
            Circle()
                .fill(tone(app))
                .frame(width: 4, height: 4)
            Text(app.name)
                .font(.system(size: 8.5, design: .monospaced))
                .lineLimit(1)
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background(Color.primary.opacity(0.06), in: Capsule())
        .contentShape(Capsule())
    }

    private func tone(_ app: DevboxWorkspaceApp) -> Color {
        if app.isFailed { return .orange }
        if app.hostUp == false { return .red }
        if app.hostUp == true { return .green }
        return app.isActive ? .green : .secondary.opacity(0.5)
    }

    private func appHelp(_ app: DevboxWorkspaceApp) -> String {
        let target = app.url?.absoluteString ?? "link unavailable"
        let state = app.active ?? "unknown unit state"
        if app.hostUp == false { return "\(target) — vhost down · \(state)" }
        guard app.url != nil else { return "\(target) — \(state)" }
        return "\(target) — \(state)\nclick opens · right-click copies"
    }

    private func accessibilityState(_ app: DevboxWorkspaceApp) -> String {
        if app.isFailed { return "unit failed" }
        if app.hostUp == false { return "vhost down" }
        if app.hostUp == true { return "vhost up" }
        return app.active.map { "unit \($0)" } ?? "runtime state unknown"
    }
}

/// A left-aligned wrapping row: an HStack that runs out of proposed width
/// starts a new line instead of overflowing its container. Exists because a
/// fixed-width frame CENTERS an oversized child rather than clipping it —
/// overflow here used to bleed across the panel's centre column.
struct FlowRow: Layout {
    var hSpacing: CGFloat = 4
    var vSpacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews,
                      cache: inout ()) -> CGSize
    {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0
        var rowHeight: CGFloat = 0, widest: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                x = 0
                y += rowHeight + vSpacing
                rowHeight = 0
            }
            x += size.width + hSpacing
            rowHeight = max(rowHeight, size.height)
            widest = max(widest, x - hSpacing)
        }
        return CGSize(width: maxWidth.isFinite ? min(widest, maxWidth) : widest,
                      height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize,
                       subviews: Subviews, cache: inout ())
    {
        var x = bounds.minX, y = bounds.minY
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + vSpacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: .unspecified)
            x += size.width + hSpacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
