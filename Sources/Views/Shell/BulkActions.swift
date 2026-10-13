import SwiftUI

/// A verb a module runs on its marked rows (bulk actions, spec 2026-10-13
/// D2): the page declares it beside its objects (`ModulePage.bulkVerbs`), the
/// bulk pane draws it with the count it applies to, and `BulkRuns` runs it.
/// A destructive verb names every target and runs only on an explicit
/// Confirm; no bulk verb ever runs on ↵ alone.
struct BulkVerb: Identifiable {
    /// Settles one row as the run reaches it.
    typealias Report = @MainActor (String, BulkRowState) -> Void

    let id: String
    let title: String
    var symbol: String?
    /// What one target is called in the confirm: "finding", "workspace".
    var noun = "row"
    /// Stops, parks or clears something: the pane names every target first.
    var destructive = false
    var help: String?
    /// The confirm's one line on what happens and what stays.
    var caution: String?
    /// Why a marked object cannot take this verb; nil = it can.
    let skip: @MainActor (String) -> String?
    /// What the confirm names for one target — its processes, its box.
    var describe: @MainActor (String) -> String? = { _ in nil }
    /// Runs on the eligible ids in drawn order, settling each through `report`.
    let run: @MainActor ([String], @escaping Report) async -> Void

    func nouns(_ count: Int) -> String {
        "\(count) \(noun)\(count == 1 ? "" : "s")"
    }
}

/// One marked row in a batch.
enum BulkRowState: Equatable {
    case queued
    case running
    /// It took — what happened, in the backend's own words.
    case done(String)
    case failed(String)
    /// The verb does not apply to it, or the backend's re-check declined.
    case skipped(String)

    var settled: Bool {
        switch self {
        case .queued, .running: false
        case .done, .failed, .skipped: true
        }
    }
}

/// The batch each module last ran (bulk D3). It lives outside the view tree,
/// so a long Revive or Stop lands through a hidden pane and the 30 s tree
/// release, and its outcomes outlive the rows a refresh takes away.
@MainActor
@Observable
final class BulkRuns {
    static let shared = BulkRuns()

    struct Row: Identifiable, Equatable {
        let id: String
        let title: String
        var label: String?
        var state: BulkRowState
    }

    struct Batch: Equatable {
        /// Which run this is: a late report from an older run never lands on it.
        let serial: Int
        let verb: String
        var rows: [Row]
        /// Esc hid the pane while it ran: the batch is dropped once it settles.
        var shown = true
        /// The run has not returned — its rows may all be settled while it
        /// still re-reads the backend. No second batch starts meanwhile.
        var running = true

        /// `5 stopped · 1 refused · 1 skipped`, or what is still to come.
        var summary: String {
            let left = rows.count { !$0.state.settled }
            if left > 0 { return "\(left) of \(rows.count) to go" }
            let done = rows.count { if case .done = $0.state { true } else { false } }
            let failed = rows.count { if case .failed = $0.state { true } else { false } }
            let skipped = rows.count { if case .skipped = $0.state { true } else { false } }
            return [done > 0 ? "\(done) done" : nil, failed > 0 ? "\(failed) failed" : nil,
                    skipped > 0 ? "\(skipped) skipped" : nil].compactMap { $0 }.joined(separator: " · ")
        }
    }

    private(set) var batches: [PanelModule: Batch] = [:]
    private var serial = 0

    func batch(_ module: PanelModule) -> Batch? {
        batches[module]
    }

    func states(_ module: PanelModule) -> [String: BulkRowState] {
        Dictionary((batches[module]?.rows ?? []).map { ($0.id, $0.state) }) { first, _ in first }
    }

    /// Runs `verb` on `marked`; the ones it skips settle at once. One batch
    /// per module at a time.
    func start(_ verb: BulkVerb, on marked: [ModuleObject], in module: PanelModule) {
        guard batches[module]?.running != true else { return }
        var rows: [Row] = []
        var eligible: [String] = []
        for object in marked {
            let reason = verb.skip(object.id)
            rows.append(Row(id: object.id, title: object.title, label: object.label,
                            state: reason.map(BulkRowState.skipped) ?? .queued))
            if reason == nil { eligible.append(object.id) }
        }
        serial += 1
        let serial = serial
        batches[module] = Batch(serial: serial, verb: verb.title, rows: rows)
        Task {
            await verb.run(eligible) { id, state in self.set(state, for: id, in: module, serial: serial) }
            finish(module, serial: serial)
        }
    }

    /// Esc, or a plain click elsewhere: a settled batch goes, a running one
    /// only leaves the screen — its rows keep their spinners.
    func dismiss(_ module: PanelModule) {
        guard var batch = batches[module] else { return }
        if batch.running {
            batch.shown = false
            batches[module] = batch
        } else {
            batches[module] = nil
        }
    }

    private func set(_ state: BulkRowState, for id: String, in module: PanelModule, serial: Int) {
        guard var batch = batches[module], batch.serial == serial,
              let index = batch.rows.firstIndex(where: { $0.id == id }) else { return }
        batch.rows[index].state = state
        batches[module] = batch
    }

    /// The run returned: a row it never answered is not left spinning.
    private func finish(_ module: PanelModule, serial: Int) {
        guard var batch = batches[module], batch.serial == serial else { return }
        for index in batch.rows.indices where !batch.rows[index].state.settled {
            batch.rows[index].state = .failed("no answer")
        }
        batch.running = false
        batches[module] = batch.shown ? batch : nil
    }
}

/// The detail's place while rows are marked (bulk D2): what is marked, each
/// verb with the count it takes, a destructive verb's confirm naming every
/// target, then the batch's outcomes. ⇥ walks the verbs (Confirm and Cancel
/// while confirming) and ↵ on the focused one is its click.
struct BulkPane: View {
    let module: PanelModule
    /// The marked rows the list draws, in its order.
    let marked: [ModuleObject]
    /// Every markable row the list draws.
    let markable: Int
    let verbs: [BulkVerb]
    let router: ModuleRouter
    var runs = BulkRuns.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var batch: BulkRuns.Batch? {
        runs.batch(module).flatMap { $0.shown || marked.isEmpty ? $0 : nil }
    }

    private var confirmingVerb: BulkVerb? {
        guard !marked.isEmpty else { return nil }
        return router.confirming.flatMap { id in verbs.first { $0.id == id } }
    }

    /// The verbs at least one marked row can take, with that count.
    private var offered: [(verb: BulkVerb, count: Int)] {
        verbs.compactMap { verb in
            let count = marked.count { verb.skip($0.id) == nil }
            return count > 0 ? (verb, count) : nil
        }
    }

    private var targets: [String] {
        if confirmingVerb != nil { return ["bulk:confirm", "bulk:cancel"] }
        guard !marked.isEmpty else { return [] }
        let running = runs.batch(module)?.running == true
        return (running ? [] : offered.map { "bulk:\($0.verb.id)" }) + ["bulk:unmark"]
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if marked.isEmpty, let batch {
                    outcomes(batch)
                } else {
                    header
                    if let verb = confirmingVerb { confirm(verb) }
                    markedList
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollEdgeEffectStyle(.soft, for: .top)
        // Re-asserted whenever they differ: moving the cursor while marking
        // (⇧↓, ⌘-click) drops the router's targets with the old row's stack.
        .onChange(of: [targets, router.focusTargets], initial: true) { _, pair in
            if pair[0] != pair[1] { router.setFocusTargets(pair[0]) }
        }
        .onChange(of: router.activated) { _, target in
            guard let target, target.hasPrefix("bulk:") else { return }
            router.consumeActivation()
            activate(String(target.dropFirst(5)))
        }
        .onChange(of: marked.map(\.id)) { _, ids in if ids.isEmpty { router.confirm(nil) } }
        .onDisappear { router.setFocusTargets([]) }
    }

    private func activate(_ id: String) {
        switch id {
        case "confirm":
            if let verb = confirmingVerb { start(verb) }
        case "cancel":
            router.confirm(nil)
        case "unmark":
            router.clearMarks()
        default:
            guard let verb = offered.first(where: { $0.verb.id == id })?.verb else { return }
            if verb.destructive {
                withAnimation(Theme.Motion.focus(reduceMotion)) { router.confirm(verb.id) }
            } else {
                start(verb)
            }
        }
    }

    /// The batch takes the pane: the marks it ran on are spent.
    private func start(_ verb: BulkVerb) {
        runs.start(verb, on: marked, in: module)
        router.confirm(nil)
        router.clearMarks()
    }

    // MARK: - Marks

    private var header: some View {
        let running = runs.batch(module)?.running == true
        return VStack(alignment: .leading, spacing: 10) {
            DetailHeader(title: "\(marked.count) marked", secondary: "of \(markable)",
                         status: running ? Chip("a batch is running", .neutral) : nil,
                         meta: Text("⌘-click · ⇧-click · ⇧↑↓ · ⌘A all shown · esc unmarks")) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 32, height: 32)
            }
            FlowRow(hSpacing: 8, vSpacing: 8) {
                if !running {
                    ForEach(offered, id: \.verb.id) { verb, count in
                        VerbButton(verb: DetailVerb(title: "\(verb.title) \(count)\(verb.destructive ? "…" : "")",
                                                    symbol: verb.symbol, help: verb.help) { activate(verb.id) })
                            .focusRing(router.focus == "bulk:\(verb.id)", radius: 12)
                    }
                }
                VerbButton(verb: DetailVerb(title: "Unmark all", kbd: "esc") { router.clearMarks() })
                    .focusRing(router.focus == "bulk:unmark", radius: 12)
            }
            if offered.isEmpty, !running {
                Text("None of the marked rows takes a bulk verb here.")
                    .font(Theme.Typo.meta)
                    .foregroundStyle(Theme.ink3)
            }
        }
    }

    private func confirm(_ verb: BulkVerb) -> some View {
        let eligible = marked.filter { verb.skip($0.id) == nil }
        let skipped = marked.compactMap { object in verb.skip(object.id).map { (object, $0) } }
        return VStack(alignment: .leading, spacing: 8) {
            Text("\(verb.title) \(verb.nouns(eligible.count))?")
                .font(Theme.Typo.body.weight(.semibold))
                .foregroundStyle(Theme.ink)
            if let caution = verb.caution {
                Text(caution)
                    .font(Theme.Typo.meta)
                    .foregroundStyle(Theme.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 3) {
                ForEach(eligible) { object in
                    targetLine(object.title, detail: verb.describe(object.id) ?? object.label)
                }
            }
            if !skipped.isEmpty {
                Text("Left out").microLabel()
                    .padding(.top, 2)
                ForEach(skipped, id: \.0.id) { object, reason in
                    targetLine(object.title, detail: reason, quiet: true)
                }
            }
            HStack(spacing: 8) {
                Spacer()
                VerbButton(verb: DetailVerb(title: "Cancel", kbd: "esc") { router.confirm(nil) })
                    .focusRing(router.focus == "bulk:cancel", radius: 12)
                // A solid capsule, not a prominent style: those draw as
                // inactive whenever the panel is not the key window.
                Button(role: .destructive) { start(verb) } label: {
                    Text("\(verb.title) \(eligible.count)")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.ink)
                        .padding(.horizontal, 12)
                        .frame(height: 24)
                        .background(Theme.danger, in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help("\(verb.title) \(verb.nouns(eligible.count)) now")
                .focusRing(router.focus == "bulk:confirm", radius: 12)
            }
            .padding(.top, 4)
        }
        .padding(12)
        .background(Theme.danger.opacity(0.07), in: RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous))
        .transition(.opacity)
    }

    private func targetLine(_ title: String, detail: String?, quiet: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(title)
                .font(Theme.Typo.meta.weight(.medium))
                .foregroundStyle(quiet ? Theme.ink3 : Theme.ink)
                .lineLimit(1)
                .truncationMode(.middle)
            if let detail {
                Text(detail)
                    .font(Theme.Typo.meta)
                    .foregroundStyle(Theme.ink3)
                    .lineLimit(2)
                    .textSelection(.enabled)
            }
        }
    }

    private var markedList: some View {
        let states = runs.states(module)
        return VStack(alignment: .leading, spacing: 2) {
            Text("Marked").microLabel()
                .padding(.bottom, 4)
            ForEach(marked) { object in
                HStack(spacing: 8) {
                    if let state = states[object.id] {
                        BulkStateGlyph(state: state)
                    } else {
                        Button { router.toggleMark(object.id) } label: {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 11))
                                .foregroundStyle(Theme.accent)
                        }
                        .buttonStyle(.plain)
                        .help("Unmark")
                    }
                    Text(object.title)
                        .font(Theme.Typo.body)
                        .foregroundStyle(Theme.ink)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let label = object.label ?? object.meta {
                        Text(label).font(Theme.Typo.meta).foregroundStyle(Theme.ink3).lineLimit(1)
                    }
                    Spacer(minLength: 6)
                    if let status = object.status { status }
                }
                .frame(minHeight: 24)
            }
        }
    }

    // MARK: - Outcomes

    private func outcomes(_ batch: BulkRuns.Batch) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            DetailHeader(title: batch.verb, secondary: "\(batch.rows.count) marked",
                         status: Chip(batch.summary, batch.running ? .neutral
                             : batch.rows.contains { if case .failed = $0.state { true } else { false } } ? .warn : .ok),
                         meta: Text(batch.running ? "Running — the batch lands even if the panel hides" : "esc dismisses")) {
                BulkStateGlyph(state: batch.running ? .running : .done(""))
                    .font(.system(size: 20))
                    .frame(width: 32, height: 32)
            }
            VStack(alignment: .leading, spacing: 6) {
                ForEach(batch.rows) { row in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        BulkStateGlyph(state: row.state)
                        VStack(alignment: .leading, spacing: 1) {
                            HStack(spacing: 6) {
                                Text(row.title)
                                    .font(Theme.Typo.body)
                                    .foregroundStyle(Theme.ink)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                if let label = row.label {
                                    Text(label).font(Theme.Typo.figure).foregroundStyle(Theme.ink3).lineLimit(1)
                                }
                            }
                            if let message = Self.message(row.state) {
                                Text(message.text)
                                    .font(Theme.Typo.meta)
                                    .foregroundStyle(message.tone)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .textSelection(.enabled)
                            }
                        }
                    }
                }
            }
        }
    }

    private static func message(_ state: BulkRowState) -> (text: String, tone: Color)? {
        switch state {
        case .queued: ("waiting", Theme.ink3)
        case .running: nil
        case let .done(said): said.isEmpty ? nil : (said, Theme.ok)
        case let .failed(why): (why, Theme.danger)
        case let .skipped(why): ("skipped — \(why)", Theme.ink3)
        }
    }
}

/// A row's place in a batch, where its glyph was: a spinner while it runs,
/// then what became of it — by shape as well as tone.
struct BulkStateGlyph: View {
    let state: BulkRowState

    var body: some View {
        switch state {
        case .queued:
            Image(systemName: "circle.dotted").foregroundStyle(Theme.ink3)
        case .running:
            ProgressView().controlSize(.mini).frame(width: 11, height: 11)
        case .done:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.ok)
        case .failed:
            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(Theme.danger)
        case .skipped:
            Image(systemName: "minus.circle").foregroundStyle(Theme.ink3)
        }
    }
}
