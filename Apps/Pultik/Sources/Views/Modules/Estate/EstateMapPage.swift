import Canvas
import SwiftUI

/// Above Estate's Map (vt-7781 WP8, vt-7727 D11): what the map holds and
/// the feed. The estate it draws is every host's topology (read with the
/// live map on entering, `enterEstateMap`), the boxes unioned by box (D6)
/// and the backups' copies at the stores (`EstateMapping`); a change hands
/// the engine the estate again (`TimelineStage.feedMap`, a no-op while
/// nothing changed). A word the engine does not know refuses the whole
/// estate: the refusal is logged and named here, never a blank map.
struct EstateMapStrip: View {
    let store: StatusStore

    static func input(_ store: StatusStore) -> EstateMapInput {
        let states = store.semaforStates
        return EstateMapping.input(boxes: store.estateBoxes.map(\.box), topologies: states.compactMap(\.state.topology),
                                   pipelines: states.contains { $0.state.backups != nil } ? store.estatePipelines : nil)
    }

    var body: some View {
        let input = Self.input(store)
        HStack(spacing: 10) {
            if let failure = TimelineStage.shared.mapFailure {
                Label("The map refused Semafor's estate: \(failure)", systemImage: "exclamationmark.triangle.fill")
                    .font(Theme.Typo.meta).foregroundStyle(Theme.warn).lineLimit(2)
            } else if input.boxes.isEmpty && input.nodes.isEmpty {
                Text("Reading each Semafor's topology and live map…").font(Theme.Typo.meta).foregroundStyle(Theme.ink3)
            } else if let asOf = store.estateAsOf {
                Text("Semafor \(PultikFormat.asOf(asOf))").font(Theme.Typo.meta).foregroundStyle(Theme.warn)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .onChange(of: input, initial: true) { _, input in TimelineStage.shared.feedMap(input) }
    }

    /// The header's summary: boxes, apps and links as drawn.
    static func summary(_ store: StatusStore) -> String {
        let input = input(store)
        let apps = input.boxes.reduce(0) { $0 + $1.apps.count }
        guard !input.boxes.isEmpty || !input.nodes.isEmpty else { return "boxes, apps and links" }
        return "\(input.boxes.count) boxes · \(apps) apps · \(input.nodes.count) nodes · \(input.edges.count) links"
    }
}

/// The map's card (↵ on the entered map): a live app's — its state, its
/// box's commit, Semafor's findings about it and its rollouts in the loaded
/// history, ⌘↵ for Semafor's own app page — or another node's from the topology.
struct EstateMapCard: View {
    let store: StatusStore
    /// The selected card: `app:<box>/<app>`, `store:…`, `ext:…`, `box:…`.
    let card: String

    /// (box, app) of an app card.
    static func app(_ card: String) -> (box: String, app: String)? {
        guard card.hasPrefix("app:"), let slash = card.firstIndex(of: "/") else { return nil }
        let box = String(card[card.index(card.startIndex, offsetBy: 4) ..< slash])
        let app = String(card[card.index(after: slash)...])
        return box.isEmpty || app.isEmpty ? nil : (box, app)
    }

    /// Semafor's own page for an app card (⌘↵), on the Semafor that observes its box.
    @MainActor static func url(_ card: String, store: StatusStore) -> URL? {
        guard let named = app(card), let host = store.semaforHost(forBox: named.box),
              let base = store.semaforServers.first(where: { $0.host == host })?.base else { return nil }
        return base.appending(path: "estate/apps").appending(path: named.box).appending(path: named.app)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let named = Self.app(card) {
                appCard(box: named.box, app: named.app)
            } else if let node = store.semaforStates.lazy.compactMap({ $0.state.topology?.nodes.first { $0.id == self.card } }).first {
                nodeCard(node)
            } else {
                RailNote("This card is no longer on the map")
            }
        }
        .padding(14)
    }

    @ViewBuilder
    private func appCard(box name: String, app name2: String) -> some View {
        let owned = store.estateBoxes.first { $0.box.name == name }
        let app = owned?.box.appList.first { $0.name == name2 }
        HStack(spacing: 8) {
            StatusDot(tone: Self.tone(app), style: app?.sync == "live" ? .pulse : .solid)
            Text(name2).font(Theme.Typo.detailTitle).foregroundStyle(Theme.ink).lineLimit(1)
            Text("on \(name)").font(Theme.Typo.body).foregroundStyle(Theme.ink2).lineLimit(1)
            Spacer(minLength: 8)
            KbdHint("⌘↵")
            Text("Semafor").font(Theme.Typo.meta).foregroundStyle(Theme.ink3)
            KbdHint("esc")
        }
        if let app, let box = owned?.box {
            facts(Self.facts(app, on: box))
            NeedsYouBand(items: store.estateFindings.filter { $0.box == name && $0.app == name2 }.map { finding in
                NeedLine(id: finding.id, tone: finding.severity == "stop" ? Theme.danger : Theme.warn, title: finding.title,
                         meta: finding.why,
                         age: SemaforTime.date(finding.since).map { PultikFormat.age(Date().timeIntervalSince($0)) })
            })
            rollouts(box: name, app: name2, host: owned?.host)
        } else {
            RailNote("\(name2) is no longer on \(name)'s live map")
        }
    }

    /// The app's rollouts in the loaded Estate history, newest first.
    @ViewBuilder
    private func rollouts(box: String, app: String, host: String?) -> some View {
        let events = host.flatMap { store.timelineWindow(TimelineKey(host: $0, lens: .estate))?.events } ?? []
        let mine = events.filter { $0.box == box && $0.app == app && !$0.isScheduled }.suffix(8).reversed()
        VStack(alignment: .leading, spacing: 4) {
            Text("Rollouts").microLabel()
            if mine.isEmpty {
                Text("none in the loaded history — open Estate's Timeline to load it")
                    .font(Theme.Typo.meta).foregroundStyle(Theme.ink3)
            }
            ForEach(Array(mine), id: \.id) { event in
                HStack(spacing: 8) {
                    StatusDot(tone: EstateEventCard.tone(event.result))
                    Text(PultikFormat.clock(event.at)).font(Theme.Typo.figure).foregroundStyle(Theme.ink2)
                    Text(event.title).font(Theme.Typo.body).foregroundStyle(Theme.ink).lineLimit(1)
                    Spacer(minLength: 6)
                    Text(event.sha ?? "").font(Theme.Typo.figure).foregroundStyle(Theme.ink3)
                }
            }
        }
        .kitTile()
    }

    @ViewBuilder
    private func nodeCard(_ node: SemaforEstateTopology.Node) -> some View {
        HStack(spacing: 8) {
            Image(systemName: node.kind == "storage" ? "externaldrive" : "server.rack").foregroundStyle(Theme.ink2)
            Text(node.label).font(Theme.Typo.detailTitle).foregroundStyle(Theme.ink).lineLimit(1)
            Text(node.kind).font(Theme.Typo.body).foregroundStyle(Theme.ink2)
            Spacer(minLength: 8)
            KbdHint("esc")
        }
        let links = store.semaforStates.compactMap(\.state.topology).first?.edges.filter { $0.from == node.id || $0.to == node.id } ?? []
        facts(Self.facts(node, links: links))
    }

    static func facts(_ app: SemaforEstateMap.App, on box: SemaforEstateMap.Box) -> [(String, String)] {
        var facts: [(String, String)] = [("sync", app.sync ?? "—"), ("health", app.health ?? "unknown")]
        if let note = app.note { facts.append(("why", note)) }
        facts.append(("box", "\(box.name) · \(box.sync ?? "unknown")"))
        let commit: [String?] = [box.applied?.sha, EstateMapping.subject(box.applied)]
        facts.append(("commit", commit.compactMap { $0 }.joined(separator: " ")))
        if let ahead = box.ahead, ahead > 0 { facts.append(("ahead", "origin/main is \(ahead) ahead")) }
        return facts
    }

    static func facts(_ node: SemaforEstateTopology.Node, links: [SemaforEstateTopology.Edge]) -> [(String, String)] {
        var facts: [(String, String)] = []
        if let detail = node.detail { facts.append(("what", detail)) }
        for (kind, address) in (node.addresses ?? [:]).sorted(by: { $0.key < $1.key }) { facts.append((kind, address)) }
        if let place = node.place { facts.append(("copies", place)) }
        let kinds = Dictionary(grouping: links, by: \.kind).map { "\($0.value.count) \($0.key)" }.sorted()
        facts.append(("links", kinds.isEmpty ? "none" : kinds.joined(separator: " · ")))
        for source in node.sources ?? [] { facts.append(("source", "\(source.repo) \(source.path)")) }
        return facts
    }

    private func facts(_ facts: [(String, String)]) -> some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 5) {
            ForEach(Array(facts.enumerated()), id: \.offset) { _, fact in
                GridRow {
                    Text(fact.0).microLabel()
                    Text(fact.1).font(Theme.Typo.figure).foregroundStyle(Theme.ink2).textSelection(.enabled).lineLimit(3)
                }
            }
        }
        .kitTile()
    }

    /// D4: synced `ok`, pending or held `warn`, an error or a down app `danger`.
    static func tone(_ app: SemaforEstateMap.App?) -> Color {
        guard let app else { return Theme.ink3 }
        if app.sync == "error" || app.health == "down" { return Theme.danger }
        switch app.sync {
        case "synced", "live": return app.health == "degraded" ? Theme.warn : Theme.ok
        case "elsewhere": return Theme.ink3
        default: return Theme.warn
        }
    }
}
