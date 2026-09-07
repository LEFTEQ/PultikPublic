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

// MARK: - Right rail: runner grid (BuildServer CI fleet)

/// One cell per runner, sectioned by slot class — the fleet at a glance
/// (spec 2026-08-27, superseding the 2026-07-25 slot bars). Hovering a cell
/// opens a popover with runner facts and a lazily-resolved link to the run
/// executing on it; the kicker keeps the Grafana escape hatch.
struct RunnerGridRail: View {
    // Explicit store, panel convention — this app never injects StatusStore
    // into the SwiftUI environment, and an `@Environment(StatusStore.self)`
    // read fatals at view update (crashed 2.3 on launch, 2026-08-27).
    let store: StatusStore
    let cells: [RunnerCell]

    private var sections: [(klass: String, cells: [RunnerCell])] {
        // Cells arrive sorted class→lane→name (MetricsClient) — chunk into
        // class sections without re-deciding the order here.
        var out: [(String, [RunnerCell])] = []
        for cell in cells {
            if out.last?.0 == cell.klass {
                out[out.count - 1].1.append(cell)
            } else {
                out.append((cell.klass, [cell]))
            }
        }
        return out
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(sections, id: \.klass) { section in
                HStack(alignment: .top, spacing: 6) {
                    Text(section.klass.isEmpty ? "—" : section.klass)
                        .font(.system(size: 9.5, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(width: 40, alignment: .leading)
                        .padding(.top, 1)
                    RunnerCellGrid(store: store, cells: section.cells)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(.white.opacity(0.02), in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }
}

/// The wrapped square grid for one class section.
private struct RunnerCellGrid: View {
    let store: StatusStore
    let cells: [RunnerCell]

    private let columns = [GridItem(.adaptive(minimum: 11, maximum: 11), spacing: 3)]

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 3) {
            ForEach(cells) { cell in
                RunnerCellView(store: store, cell: cell)
            }
        }
    }
}

/// One runner square: green = busy, dim = idle, red outline = offline.
/// Hover briefly to open the detail popover.
private struct RunnerCellView: View {
    let store: StatusStore
    let cell: RunnerCell
    @State private var hovering = false
    @State private var showPopover = false

    private var fill: Color {
        if !cell.online { return .clear }
        return cell.busy ? .green.opacity(0.85) : .white.opacity(0.12)
    }

    private var stateLabel: String {
        if !cell.online { return "offline" }
        return cell.busy ? "busy" : "idle"
    }

    var body: some View {
        RoundedRectangle(cornerRadius: 2.5)
            .fill(fill)
            .overlay(
                RoundedRectangle(cornerRadius: 2.5)
                    .strokeBorder(
                        !cell.online ? Color.red.opacity(0.55)
                            : hovering ? Color.white.opacity(0.5) : .clear,
                        lineWidth: 1
                    )
            )
            .frame(width: 11, height: 11)
            .onHover { inside in
                hovering = inside
                if inside {
                    // Small delay so a sweep across the grid doesn't strobe
                    // popovers; cancelled by the guard when the mouse moved on.
                    Task {
                        try? await Task.sleep(for: .milliseconds(250))
                        if hovering { showPopover = true }
                    }
                }
            }
            .popover(isPresented: $showPopover, arrowEdge: .bottom) {
                RunnerPopover(store: store, cell: cell)
            }
            // The 11 px square is pointer-bait; VoiceOver gets the same
            // information and the same detail popover as an action.
            .accessibilityElement()
            .accessibilityLabel("\(cell.name), \(stateLabel)")
            .accessibilityHint("Runner in the \(cell.lane) lane")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { showPopover = true }
    }
}

/// Popover body: instant Prometheus facts, then the run link once the lazy
/// jobs-API scan answers. The scan only ever runs from here (spec 2026-08-27).
private struct RunnerPopover: View {
    let store: StatusStore
    let cell: RunnerCell
    @State private var job: RunnerJob?? // nil = loading, .some(nil) = no run found

    private var stateLabel: String {
        if !cell.online { return "offline" }
        return cell.busy ? "busy" : "idle"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Circle()
                    .fill(!cell.online ? Color.red.opacity(0.8)
                        : cell.busy ? Color.green.opacity(0.9) : Color.white.opacity(0.35))
                    .frame(width: 6, height: 6)
                Text(cell.name)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                Text(stateLabel)
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Text("\(cell.lane.isEmpty ? "?" : cell.lane) · \(cell.klass.isEmpty ? "?" : cell.klass)")
                .font(.system(size: 9.5, design: .monospaced))
                .foregroundStyle(.secondary)

            if cell.busy {
                Divider()
                switch job {
                case nil:
                    HStack(spacing: 5) {
                        ProgressView().controlSize(.small)
                        Text("finding the run…")
                            .font(.system(size: 9.5))
                            .foregroundStyle(.secondary)
                    }
                case .some(nil):
                    Text("run not found (job may have just finished)")
                        .font(.system(size: 9.5))
                        .foregroundStyle(.tertiary)
                case let .some(.some(job)):
                    VStack(alignment: .leading, spacing: 3) {
                        Text("\(job.repo.split(separator: "/").last.map(String.init) ?? job.repo) · \(job.workflowName ?? job.jobName)")
                            .font(.system(size: 10))
                            .lineLimit(1)
                        if let url = job.htmlUrl.flatMap(URL.init(string:)) {
                            Button {
                                NSWorkspace.shared.open(url)
                            } label: {
                                Label("Open run", systemImage: "arrow.up.forward.square")
                                    .font(.system(size: 10))
                            }
                            .buttonStyle(.link)
                        }
                    }
                }
            }
        }
        .padding(10)
        .frame(minWidth: 170, alignment: .leading)
        .task {
            guard cell.busy else { return }
            job = .some(await store.runnerJob(for: cell))
        }
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

// MARK: - Left rail: devbox workspaces

/// ws-v2 workspaces first, followed only by the shared/stack-slot machinery
/// that still serves the v2 world. Retired isolated tenant slots never enter
/// this view.
struct DevboxRail: View {
    // Explicit store, panel convention (see RunnerGridRail): the card actions
    // need a refresh right after `devbox park`/`up`, not 90 s later.
    let store: StatusStore
    let workspaces: [DevboxWorkspace]
    let projects: [DevboxProject]
    let summary: DevboxOverviewSummary?
    /// When the hub payload was generated on the box — the "as of" stamp the
    /// live-ssh data path promised.
    let fetchedAt: Date?

    /// The kicker counts HOT slots only — parked identities are listed but
    /// are not load, and the number next to "DEVBOX" is the one glanced at
    /// against the ceiling in the line below.
    private var hotCount: Int {
        workspaces.filter(\.isHot).count
    }

    /// The rail's colour is the box's own pressure verdict (thresholds in
    /// `DevboxOverviewSummary.pressure`), never a HUD guess.
    private var pressureTone: Color? {
        switch summary?.pressure {
        case .critical?: return .red
        case .elevated?: return .orange
        case .normal?, nil: return nil
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Kicker(text: "Devbox", count: hotCount, tone: pressureTone ?? .secondary)
                Spacer(minLength: 0)
                if let fetchedAt {
                    Text(fetchedAt, format: .dateTime.hour().minute())
                        .font(.system(size: 8, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .help("When the box generated this snapshot")
                }
            }
            .padding(.horizontal, 2)

            if let summary {
                Text(summary.shortLabel)
                    .font(.system(size: 8.5, design: .monospaced))
                    .foregroundStyle(pressureTone.map(AnyShapeStyle.init) ?? AnyShapeStyle(.tertiary))
                    .padding(.horizontal, 2)
                    .help(summary.helpLabel)
                    .accessibilityLabel(
                        "devbox capacity: \(summary.shortLabel), pressure \(pressureAccessibility(summary))"
                    )
            }

            ForEach(workspaces) { workspace in
                DevboxWorkspaceCard(workspace: workspace, store: store)
            }

            if projects.contains(where: { !$0.visibleSlots.isEmpty }) {
                HStack(spacing: 4) {
                    Image(systemName: "shippingbox")
                        .font(.system(size: 8))
                    Text("SHARED + STACKS")
                        .font(.system(size: 8, weight: .semibold, design: .monospaced))
                        .kerning(0.7)
                    Spacer(minLength: 0)
                }
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 2)
                .padding(.top, 3)
            }

            ForEach(projects.filter { !$0.visibleSlots.isEmpty }) { project in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Image(systemName: "shippingbox")
                            .font(.system(size: 8))
                            .foregroundStyle(.secondary)
                        Text(project.displayName)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 2)
                    .help(project.repoSlug)

                    ForEach(project.visibleSlots) { slot in
                        DevboxSlotCard(project: project.name, slot: slot)
                    }
                }
            }
        }
        // Matches ServiceRail's uniform padding(10) — the devbox kicker used to
        // inherit its top inset from the servers rail stacked above it, and sat
        // higher than SERVICES once that rail was removed.
        .padding(10)
    }

    private func pressureAccessibility(_ summary: DevboxOverviewSummary) -> String {
        switch summary.pressure {
        case .normal: return "normal"
        case .elevated: return "elevated"
        case .critical: return "critical"
        }
    }
}

/// One ws-v2 workspace, designed for the many-app worst case (spec
/// 2026-09-01): the collapsed card is three fixed lines — name, identity,
/// aggregate — and can never grow wider than the rail. Everything per-app
/// (chips, units, containers, sources) lives behind the disclosure.
private struct DevboxWorkspaceCard: View {
    let workspace: DevboxWorkspace
    let store: StatusStore
    @State private var hovering = false
    @State private var expanded = false
    /// A lifecycle verb is in flight (park ~2 s, revive ~16 s, cold up
    /// minutes). The card says which, and refuses a second click meanwhile.
    @State private var busyLabel: String?
    /// Park is the one action that stops something: the first click arms,
    /// the second within a few seconds runs. Inline rather than a modal —
    /// the panel is a floating HUD and a sheet on it is never right.
    @State private var confirmingPark = false
    @State private var lastActionFailed = false

    init(workspace: DevboxWorkspace, store: StatusStore) {
        self.workspace = workspace
        self.store = store
        #if DEBUG
            _expanded = State(initialValue:
                ProcessInfo.processInfo.environment["PULTIK_EXPAND_WORKSPACE"] == workspace.name)
        #endif
    }

    private var tone: Color {
        if workspace.isParked { return .secondary.opacity(0.45) }
        if workspace.failedApps > 0 { return .orange }
        return workspace.isRunning ? .green : .secondary
    }

    /// Parked cards dim as a whole: identity stays legible, but nothing on
    /// them is live and the eye should skip to the hot ones.
    private var cardOpacity: Double {
        workspace.isParked ? 0.62 : 1
    }

    private var canExpand: Bool {
        !workspace.apps.isEmpty || !workspace.unitApps.isEmpty
            || !workspace.stats.isEmpty || !workspace.sources.isEmpty
    }

    /// The identity line below already names the project, so the title drops
    /// that shared prefix — siblings differ at the tail, and the prefix is the
    /// part that truncation would keep. Full name stays in the tooltip and
    /// the accessibility label.
    private var displayName: String {
        guard let project = workspace.project,
              workspace.name.count > project.count + 1,
              workspace.name.hasPrefix("\(project)-")
        else { return workspace.name }
        return String(workspace.name.dropFirst(project.count + 1))
    }

    private var accessibilityState: String {
        if workspace.isParked {
            return workspace.hold ? "\(workspace.parkedLabel), held" : workspace.parkedLabel
        }
        if workspace.failedApps > 0 {
            return "\(workspace.failedApps) app\(workspace.failedApps == 1 ? "" : "s") failed"
        }
        let base = workspace.isRunning ? "running" : "units down"
        return workspace.hold ? "\(base), held" : base
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                HStack(spacing: 6) {
                    Circle().fill(tone).frame(width: 6, height: 6)
                    Text(displayName)
                        .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                        .lineLimit(1)
                    if workspace.hold {
                        chip("hold", tone: .orange)
                            .help("devbox hold — exempt from the park sweep until unhold")
                    }
                    if canExpand {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 7, weight: .semibold))
                            .foregroundStyle(.tertiary)
                            .rotationEffect(.degrees(expanded ? 90 : 0))
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(workspace.name), \(accessibilityState)")
                .accessibilityAddTraits(canExpand ? .isButton : [])
                .accessibilityValue(canExpand ? (expanded ? "expanded" : "collapsed") : "")
                .accessibilityAction {
                    guard canExpand else { return }
                    withAnimation(.easeOut(duration: 0.14)) { expanded.toggle() }
                }
                Spacer(minLength: 4)
                if let source = workspace.sources.first {
                    sourceActions(source.path)
                        .opacity(hovering ? 1 : 0)
                        .frame(height: 16)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                guard canExpand else { return }
                withAnimation(.easeOut(duration: 0.14)) { expanded.toggle() }
            }

            Text(identityText)
                .font(.system(size: 8.5, design: .monospaced))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.leading, 12)

            // Aggregate line: state/units + footprint on the left, the
            // lifecycle verbs on the right (hover-revealed, in place — the
            // rail never jumps). Busy and failure feedback take that slot.
            HStack(spacing: 6) {
                if workspace.isParked {
                    chip(workspace.parkedLabel, tone: .secondary)
                        .help("Stopped by the park sweep or `devbox park`; identity and ports kept. Revive with ▶ (~16 s).")
                }
                Text(summaryText)
                    .font(.system(size: 8.5, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .help(workspace.footprintHelp)
                Spacer(minLength: 4)
                ZStack(alignment: .trailing) {
                    if let busyLabel {
                        HStack(spacing: 4) {
                            ProgressView().controlSize(.mini)
                            Text(busyLabel)
                                .font(.system(size: 8.5, design: .monospaced))
                                .foregroundStyle(.tertiary)
                        }
                    } else if lastActionFailed {
                        Text("failed · see log")
                            .font(.system(size: 8.5, design: .monospaced))
                            .foregroundStyle(.red)
                    } else {
                        // Never fully hidden: a keyboard or VoiceOver user
                        // does not hover, and a control at opacity 0 is one
                        // they cannot see and may not be offered. Quiet at
                        // rest, full on hover — same footprint either way.
                        lifecycleActions.opacity(hovering ? 1 : 0.4)
                    }
                }
                .frame(height: 14)
            }
            .padding(.leading, 12)

            if expanded {
                if !workspace.apps.isEmpty, !workspace.isParked {
                    WorkspaceAppChipsRow(apps: workspace.apps)
                        .padding(.leading, 12)
                }
                if !workspace.isParked {
                    unitRows
                    containerRows
                }
                sourceRows
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(hovering ? Color.primary.opacity(0.06) : .clear,
                    in: RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .opacity(cardOpacity)
        .onHover { inside in
            hovering = inside
            if !inside { confirmingPark = false }
        }
        .help(workspaceHelp)
    }

    private func chip(_ text: String, tone: Color) -> some View {
        Text(text)
            .font(.system(size: 8, weight: .medium, design: .monospaced))
            .foregroundStyle(tone)
            .lineLimit(1)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(tone.opacity(0.12), in: Capsule())
    }

    // MARK: Lifecycle verbs

    /// Hot: park (two-click) and hold/unhold. Parked: revive and hold/unhold.
    /// Never `down`, never `gc` — the reversible verbs only.
    @ViewBuilder
    private var lifecycleActions: some View {
        HStack(spacing: 7) {
            if workspace.isParked {
                if let macPath = workspace.macPath,
                   DevboxLauncher.localDirectory(macPath, quiet: true) != nil
                {
                    iconButton("play.circle", "Revive — devbox up from \(macPath)") {
                        runAction("reviving") {
                            await DevboxClient.shared.up(workspace: workspace.name, macPath: macPath)
                        }
                    }
                } else {
                    Image(systemName: "play.circle")
                        .font(.system(size: 10))
                        .foregroundStyle(.quaternary)
                        .help(workspace.macPath.map { "Cannot revive from here — \($0) is not on this Mac" }
                            ?? "Cannot revive from here — the box recorded no Mac path")
                        .accessibilityLabel("Revive unavailable")
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
                    iconButton("parkingsign.circle", "Park — stop, keep hot; up revives in ~16 s") {
                        confirmingPark = true
                        Task {
                            try? await Task.sleep(for: .seconds(4))
                            await MainActor.run { confirmingPark = false }
                        }
                    }
                }
            }
            if workspace.hold {
                iconButton("pin.slash", "Unhold — return to auto-parking") {
                    runAction("unholding") {
                        await DevboxClient.shared.run(.unhold, workspace: workspace.name)
                    }
                }
            } else {
                iconButton("pin", "Hold — exempt from the park sweep") {
                    runAction("holding") {
                        await DevboxClient.shared.run(.hold, workspace: workspace.name)
                    }
                }
            }
        }
    }

    /// One verb at a time per card; the box is refreshed straight after so
    /// the card flips within the same breath, not at the next poll.
    ///
    /// Deliberately NOT generation-scoped (cf. the warm-panel rule in
    /// `.claude/memory/`): the busy flag is card-local truth about a verb
    /// that is still running on the box, not a per-open presentation. The
    /// panel being dismissed and reopened mid-revive must still end with the
    /// flag cleared — gating the clear on the presenting generation would
    /// leave the card stuck on "reviving" forever. Concurrency is bounded by
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

    private var identityText: String {
        switch (workspace.project, workspace.branch) {
        case let (project?, branch?): return "\(project) · \(branch)"
        case let (project?, nil): return project
        case let (nil, branch?): return branch
        default: return "committed workspace"
        }
    }

    /// The whole fleet in one line — this is all the collapsed card says
    /// about apps; the chips are behind the disclosure. Footprint reads
    /// "<live> · peak <peak>" (parked: peak only — nothing is live).
    private var summaryText: String {
        if workspace.isParked {
            return workspace.footprintLabel ?? ""
        }
        let units: String
        if !workspace.unitApps.isEmpty {
            units = "\(workspace.activeApps)/\(workspace.unitApps.count) up"
        } else if !workspace.apps.isEmpty {
            units = "\(workspace.apps.count) app\(workspace.apps.count == 1 ? "" : "s")"
        } else {
            units = "—"
        }
        var parts = [units]
        if let footprint = workspace.footprintLabel { parts.append(footprint) }
        if !workspace.stats.isEmpty { parts.append(workspace.cpuLabel) }
        return parts.joined(separator: " · ")
    }

    private var workspaceHelp: String {
        var lines = [workspace.name, identityText]
        if workspace.isParked, let parkedAt = workspace.parkedAt {
            lines.append("parked \(parkedAt.formatted(date: .abbreviated, time: .shortened))")
        }
        if workspace.hold { lines.append("held — exempt from auto-parking") }
        if let window = workspace.portWindowLabel { lines.append("ports \(window)") }
        if let macPath = workspace.macPath { lines.append("mac \(macPath)") }
        if let created = workspace.created {
            lines.append("created \(created.formatted(date: .abbreviated, time: .shortened))")
        }
        return lines.joined(separator: "\n")
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
            iconButton("terminal", "Open workspace in Warp") {
                DevboxLauncher.summonWorkspaceWarp(workspace.name)
            }
            iconButton("folder", "Reveal in Finder") {
                DevboxLauncher.revealLocalPath(path)
            }
            iconButton("chevron.left.forwardslash.chevron.right", "Open in Cursor") {
                DevboxLauncher.openLocalCursor(path)
            }
            iconButton("doc.on.doc", "Copy path") {
                DevboxLauncher.copyLocalPath(path)
            }
        }
    }

    private func iconButton(_ symbol: String, _ help: String,
                            action: @escaping () -> Void) -> some View
    {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 10))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(help)
        .accessibilityLabel(help)
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

/// One flat dense row per slot (redesign 2026-07-29): dot · slug ···· stats.
/// Hovering swaps the stats for the action icons IN PLACE — same footprint,
/// so the rail never jumps.
private struct DevboxSlotCard: View {
    let project: String
    let slot: DevboxSlot
    @State private var hovering = false
    @State private var busy = false
    /// Container drill-down, toggled by clicking the row — the shared slot's
    /// postgres/mongo/openldap tier is the case this exists for, but every
    /// slot with stats can expand.
    @State private var expanded = false

    private var tone: Color {
        slot.running ? .green : .secondary
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                // The tap gesture is invisible to VoiceOver; this leading
                // group announces as the disclosure control. Scoped to the
                // dot+slug+chevron ONLY — combining the whole row would
                // swallow the action buttons into one opaque element.
                HStack(spacing: 6) {
                    Circle().fill(tone).frame(width: 6, height: 6)
                    Text(slot.isShared ? "shared" : slot.slug)
                        .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                        .lineLimit(1)
                    // Decision D9=C: git state is ONE dot at rest. The rail is
                    // 280pt and the routed-host chips below already spend that
                    // width on names; drawing repo names too put the same word
                    // ("ai-ms") on the card twice in two meanings — a chip that
                    // opens a URL, and a row that reports uncommitted work.
                    if !slot.dirtyRepos.isEmpty {
                        Circle()
                            .fill(Color.orange)
                            .frame(width: 5, height: 5)
                            .help(dirtySummary)
                            .accessibilityLabel("uncommitted work in \(slot.dirtyRepos.count) repo(s)")
                    }
                    if canExpand {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 7, weight: .semibold))
                            .foregroundStyle(.tertiary)
                            .rotationEffect(.degrees(expanded ? 90 : 0))
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(canExpand ? .isButton : [])
                .accessibilityValue(canExpand ? (expanded ? "expanded" : "collapsed") : "")
                .accessibilityHint(canExpand ? "Shows per-container CPU and memory" : "")
                // The outer row's tap gesture is not reachable through this
                // combined element — VoiceOver activation needs its own action.
                .accessibilityAction {
                    guard canExpand else { return }
                    withAnimation(.easeOut(duration: 0.14)) { expanded.toggle() }
                }
                Spacer(minLength: 4)
                ZStack(alignment: .trailing) {
                    Text(statsText)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .opacity(hovering ? 0 : 1)
                    actionRow.opacity(hovering ? 1 : 0)
                }
                .frame(height: 16)
            }
            // The row toggles the drill-down; the action icons sit on top of
            // this gesture and win, so hover-actions keep working unchanged.
            .contentShape(Rectangle())
            .onTapGesture {
                guard canExpand else { return }
                withAnimation(.easeOut(duration: 0.14)) { expanded.toggle() }
            }

            if expanded, let stats = slot.stats {
                ForEach(stats) { container in
                    HStack(spacing: 4) {
                        Circle()
                            .fill(containerTone(container))
                            .frame(width: 4, height: 4)
                        Text(shortName(container.name))
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        Text(container.isUp
                            ? "\(Int(container.cpuPercent.rounded()))% · \(container.memoryLabel)"
                            : "stopped")
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.leading, 12)
                    .help(container.status)
                    // The dot is the only health signal and .help is
                    // hover-only — VoiceOver gets the state in words.
                    .accessibilityElement(children: .combine)
                    .accessibilityValue(
                        container.isUnhealthy ? "unhealthy"
                            : container.isUp ? "up" : "stopped"
                    )
                }
            }

            // Behind the chevron since D9=C — at rest the amber dot on the
            // slug carries this, and the routed-host chips get the width back.
            if expanded {
                ForEach(slot.dirtyRepos) { repo in
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.trianglehead.branch")
                            .font(.system(size: 8))
                            .foregroundStyle(.tertiary)
                        Text(repo.name.replacingOccurrences(of: "pwf-", with: ""))
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        if repo.dirty > 0 {
                            Text("●\(repo.dirty)").font(.system(size: 9, design: .monospaced))
                                .foregroundStyle(.orange)
                        }
                        if repo.ahead > 0 {
                            Text("↑\(repo.ahead)").font(.system(size: 9, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                        if repo.behind > 0 {
                            Text("↓\(repo.behind)").font(.system(size: 9, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.leading, 12)
                    .help("\(repo.name) on \(repo.branch)")
                }
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(hovering ? Color.primary.opacity(0.06) : .clear,
                    in: RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .help(slot.running
            ? "\(project) · \(slot.slug) — \(slot.containers) containers"
            : "\(project) · \(slot.slug) — stopped")
    }

    /// A slot is expandable when it has EITHER container stats or dirty repos:
    /// since D9=C moved the repo breakdown behind the chevron, a stopped slot
    /// with uncommitted work has something to show and no stats to show it with.
    private var canExpand: Bool {
        !(slot.stats ?? []).isEmpty || !slot.dirtyRepos.isEmpty
    }

    /// What the amber dot means, in words — the whole breakdown without the
    /// click, for the case where you only need the headline.
    private var dirtySummary: String {
        let dirty = slot.dirtyRepos.reduce(0) { $0 + $1.dirty }
        let ahead = slot.dirtyRepos.reduce(0) { $0 + $1.ahead }
        var parts = ["\(slot.dirtyRepos.count) repo\(slot.dirtyRepos.count == 1 ? "" : "s") need attention"]
        if dirty > 0 { parts.append("\(dirty) uncommitted") }
        if ahead > 0 { parts.append("\(ahead) unpushed") }
        return parts.joined(separator: " · ") + "\n" +
            slot.dirtyRepos.map { "\($0.name) (\($0.branch))" }.joined(separator: "\n")
    }

    /// "pwf-shared-postgresdb" → "postgresdb": the card already names the
    /// slot, repeating its prefix per row wastes the rail's width.
    private func shortName(_ name: String) -> String {
        let prefix = slot.containerPrefix + "-"
        return name.hasPrefix(prefix) ? String(name.dropFirst(prefix.count)) : name
    }

    private func containerTone(_ container: DevboxContainerStat) -> Color {
        if container.isUnhealthy { return .orange }
        return container.isUp ? .green : .red
    }

    /// A stackless tenant serves from a process, so a container count of 0
    /// next to a green dot would read as broken — it says "serving" instead.
    private var statsText: String {
        guard slot.running else { return "stopped" }
        guard slot.containers > 0 else { return "serving" }
        return "\(slot.containers)c · \(slot.memoryLabel) · \(slot.cpuLabel)"
    }

    private var actionRow: some View {
        HStack(spacing: 7) {
            iconButton("terminal", "Warp + tmux") {
                DevboxLauncher.summonWarp(project: project, slug: slot.slug)
            }
            if slot.running {
                iconButton("safari", "Open Portal") {
                    DevboxLauncher.openPortal(port: slot.entrypointPort)
                }
                iconButton("stop.circle", "Stop the stack") {
                    runAction { await DevboxClient.shared.down(project: project, slug: slot.slug) }
                }
            } else {
                iconButton("play.circle", "Start the stack") {
                    runAction { await DevboxClient.shared.up(project: project, slug: slot.slug) }
                }
            }
        }
        .opacity(busy ? 0.4 : 1)
        .disabled(busy)
    }

    private func iconButton(_ symbol: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 11))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(help)
    }

    /// `up` and `pull` take tens of seconds; without the busy flag the card
    /// looks inert and invites a second click that would race the first.
    private func runAction(_ work: @escaping () async -> Bool) {
        busy = true
        Task {
            _ = await work()
            await MainActor.run { busy = false }
        }
    }
}
