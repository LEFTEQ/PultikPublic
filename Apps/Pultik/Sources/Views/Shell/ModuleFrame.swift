import SwiftUI

/// One selectable object in a module's list (D1): what ↑/↓ walk, what ↵
/// opens as the detail and ⌘↵ opens in the real browser (D7).
struct ModuleObject: Identifiable {
    /// One line of the object's context sections: a micro label and a value.
    struct Fact: Identifiable {
        let label: String
        let value: String
        var id: String { label }
    }

    /// Stable across refreshes (`run:123`, `deployment:exampleapp-prod`) — the
    /// router holds selection by it, never by index.
    let id: String
    let title: String
    /// The object's own id, leading the detail's meta line (`#412`). Never ellipsized.
    var label: String?
    var status: Chip?
    var meta: String?
    var symbol = "square.grid.2x2.fill"
    /// Tints the detail's glyph (`ProjectGlyph`); the hue never leaves it.
    var project: String?
    var url: URL?
    /// The page's safe verbs, after `Open ⌘↵`. A destructive verb confirms
    /// in its own view; ↵ never mutates.
    var verbs: [DetailVerb] = []
    /// The context band under the header: related objects as chips.
    var context: [Chip] = []
    /// The context sections below the content, or in the ⌘I inspector.
    var facts: [Fact] = []
    /// A bulk verb can take it (bulk actions D1): ⌘-click, ⇧-click, ⇧↑/⇧↓
    /// and ⌘A mark it. A lane, a running job or the fans row never are.
    var markable = false
}

/// A module's list as the shell hosts it (D4-B): the page draws its rows —
/// the selected one with `RowBackground` — and lists its objects in the
/// order it draws them. A module plugs in by conforming its list view and
/// returning it from the panel's `modulePage(_:)`; the shell, the router and
/// the keyboard never learn its types.
@MainActor
protocol ModulePage: View {
    associatedtype DetailContent: View = EmptyView
    /// The selectable objects in drawn order — exactly what ↑/↓ walk.
    var objects: [ModuleObject] { get }
    /// What the list keeps beside an open detail; the detail takes the rest.
    var listWidth: CGFloat { get }
    /// The narrowest the list draws without losing a column: its fixed-width
    /// table. 0 = the rows reflow. Narrower than this (the 1240 pt panel with
    /// a detail and ⌘I's inspector) the list scrolls sideways, never clips.
    var minListWidth: CGFloat { get }
    /// The object's own expanded content, drawn under the detail header.
    @ViewBuilder func detailContent(for object: ModuleObject) -> DetailContent
    /// The content brings its own scroller (a long, lazily drawn body like a
    /// PR's diff): the header stays pinned above it and the context sections
    /// live in ⌘I's inspector. A lazy stack only stays lazy as the scroll
    /// view's direct content.
    var detailScrollsItself: Bool { get }
    /// The content draws the whole detail, its header included (the PR
    /// workbench's compact roll-up, D7): the shell adds nothing around it.
    var detailOwnsHeader: Bool { get }
    /// What the marked rows can take, in the bulk pane's order (bulk D2).
    /// Read on the main actor when the pane draws and when a verb runs.
    var bulkVerbs: [BulkVerb] { get }
    /// The shell keeps the selection's detail built before the key that
    /// shows it, and its neighbours' while it is open (`DetailStaging`,
    /// focus D23): ↵ and ↑/↓ are then a flip, not a build. For a detail that
    /// is expensive to build and draws from memory. Such a detail is mounted
    /// off screen with `\.bodyShown` false, and must then write no shared
    /// state, start no watch and claim no key. It reads the router's key
    /// requests through `Heard` (read bare, every key re-runs it), and its
    /// text fields are `stagedField()`s.
    var stagesDetails: Bool { get }
}

extension ModulePage {
    var listWidth: CGFloat { 480 }
    var minListWidth: CGFloat { 0 }
    var detailScrollsItself: Bool { false }
    var detailOwnsHeader: Bool { false }
    var bulkVerbs: [BulkVerb] { [] }
    var stagesDetails: Bool { false }
}

extension ModulePage where DetailContent == EmptyView {
    func detailContent(for _: ModuleObject) -> EmptyView { EmptyView() }
}

/// Hosts a module page in the frame, its detail resolved from the selection
/// — a selection the list no longer holds draws no detail — with the
/// detail's card stack over it (stay in Pultík D2). The inputs are explicit:
/// the displayed module passes the router's, a warm hidden one its frozen
/// ones (`ModuleWarmth`), and `objects` comes memoised (`ModulePageMemo`).
struct ModuleHost<Page: ModulePage>: View {
    let page: Page
    let objects: [ModuleObject]
    var selection: String?
    var detailOpen = false
    var inspectorOpen = false
    var stack: [DetailRef] = []
    var onPop: () -> Void = {}
    var card: (DetailRef) -> AnyView = { _ in AnyView(EmptyView()) }
    /// The bulk pane (bulk D2): while rows are marked it holds the detail's place.
    var bulk: AnyView?
    /// A staged detail left the screen and stays built (focus D23): the panel
    /// takes back the keys a field of it may hold.
    var onDetailLeft: () -> Void = {}
    /// The details a staging page keeps built (`DetailStaging`, focus D23).
    @State private var staged: [String] = []
    /// This module's body is the one displayed (D4).
    @Environment(\.bodyShown) private var bodyShown

    var body: some View {
        let _ = PROpenProbe.pass("host")
        let open = detailOpen && bulk == nil ? selection.flatMap { id in objects.first { $0.id == id } } : nil
        if page.stagesDetails {
            stagedFrame(open)
        } else {
            ModuleFrame(listWidth: page.listWidth, minListWidth: page.minListWidth,
                        inspectorOpen: inspectorOpen, detail: open, bulk: bulk) {
                page
            } detailView: { object in
                StackedDetail(stack: stack, onPop: onPop) {
                    detail(object)
                } card: { ref in
                    card(ref)
                }
            } inspector: { object in
                inspector(object)
            }
        }
    }

    /// The frame of a page that stages its details (focus D23). Every staged
    /// detail is mounted at full size in the slot, keyed by its object id:
    /// the selection's is the one drawn, and only the open one is on screen
    /// (hit testing, accessibility, `\.bodyShown`, the card stack). A step
    /// onto a staged neighbour therefore changes which one is drawn and
    /// builds nothing.
    private func stagedFrame(_ open: ModuleObject?) -> some View {
        let ids = objects.map(\.id)
        let isOpen = open != nil
        // Only the displayed module stages, and never under the bulk pane:
        // nothing can open there until the marks are gone.
        let wanted = bodyShown && bulk == nil ? DetailStaging.wanted(selection: selection, open: isOpen, in: ids) : []
        let mounted = DetailStaging.mounted(staged: staged, selection: selection, open: isOpen, in: ids)
        return StagedModuleFrame(listWidth: page.listWidth, minListWidth: page.minListWidth,
                                 inspectorOpen: inspectorOpen, detail: open, bulk: bulk) {
            page
        } slot: {
            ZStack(alignment: .topLeading) {
                ForEach(mounted.compactMap { id in objects.first { $0.id == id } }) { object in
                    let onScreen = object.id == open?.id
                    StackedDetail(stack: onScreen ? stack : [], onPop: onPop) {
                        detail(object)
                    } card: { ref in
                        card(ref)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    // Drawn, under the selection's opaque one: a view at
                    // opacity 0 is not rendered, so a step paid its first
                    // render; covered, a neighbour is already drawn.
                    .background(Theme.canvas)
                    .environment(\.bodyShown, onScreen && bodyShown)
                    .allowsHitTesting(onScreen)
                    .accessibilityHidden(!onScreen)
                    // On top, as the displayed warm body is: no staged
                    // detail's AppKit view lies over the one on screen.
                    .zIndex(object.id == selection ? 1 : 0)
                }
            }
        } inspector: { object in
            inspector(object)
        }
        // The set follows the selection after the frame that drew the key,
        // one detail a turn and only from an idle main thread: a key never
        // waits for a neighbour to be built.
        .task(id: wanted) {
            var wait = DetailStaging.delay(staged: staged, wanted: wanted, open: isOpen)
            while Set(staged) != Set(wanted) {
                do { try await Task.sleep(for: wait) } catch { return }
                await DetailStaging.idle()
                guard !Task.isCancelled else { return }
                staged = DetailStaging.step(from: staged, toward: wanted, open: isOpen)
                wait = DetailStaging.turn
            }
        }
        // A detail that leaves the screen is still built, and so is a field
        // of it that held the keys (a thread's reply, the tree's filter):
        // left there, every key would be typed into a detail nobody sees.
        .onChange(of: open?.id) { old, _ in
            if old != nil { onDetailLeft() }
        }
    }

    /// An object's detail: the page's own content, under the shell's header
    /// unless the page draws it.
    @ViewBuilder
    private func detail(_ object: ModuleObject) -> some View {
        if page.detailOwnsHeader {
            page.detailContent(for: object)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            ObjectDetail(object: object, showsFacts: !inspectorOpen, scrollsItself: page.detailScrollsItself) {
                page.detailContent(for: object)
            }
        }
    }

    private func inspector(_ object: ModuleObject) -> some View {
        ScrollView {
            ContextSections(facts: object.facts)
                .padding(14)
        }
    }
}

/// Each module page's objects, computed once per input and kept until a
/// value they read changes (D4 "precompute"): the keyboard reads them per
/// keystroke and the host per body, and neither recomputes a list nobody
/// changed. Invalidation rides Observation, so a page that reads a new
/// store needs no wiring here.
@MainActor
@Observable
final class ModulePageMemo {
    /// Bumped after an invalidation: a reader that hit the memo read no
    /// store property, so this is what redraws it.
    private(set) var revision = 0
    @ObservationIgnored private var entries: [PanelModule: (inputs: String, objects: [ModuleObject])] = [:]
    /// Marked from Observation's `onChange`, which may run off the main actor.
    @ObservationIgnored private let stale = StaleModules()

    func objects(_ module: PanelModule, inputs: String, compute: () -> [ModuleObject]) -> [ModuleObject] {
        _ = revision
        if stale.take(module) { entries[module] = nil }
        if let entry = entries[module], entry.inputs == inputs { return entry.objects }
        let stale = stale
        let objects = withObservationTracking(compute) { [weak self] in
            stale.mark(module)
            Task { @MainActor in self?.revision &+= 1 }
        }
        entries[module] = (inputs, objects)
        return objects
    }
}

private final class StaleModules: @unchecked Sendable {
    private let lock = NSLock()
    private var modules: Set<PanelModule> = []

    func mark(_ module: PanelModule) {
        lock.withLock { _ = modules.insert(module) }
    }

    func take(_ module: PanelModule) -> Bool {
        lock.withLock { modules.remove(module) != nil }
    }
}

/// D4-B: a list and a wide detail, the context folded into the detail, and
/// ⌘I's inspector on demand. With no detail open the list takes the frame.
struct ModuleFrame<List: View, Detail: View, Inspector: View>: View {
    var listWidth: CGFloat
    /// `ModulePage.minListWidth`: below it the list scrolls sideways.
    var minListWidth: CGFloat = 0
    var inspectorOpen: Bool
    let detail: ModuleObject?
    /// The bulk pane, drawn where the detail would be.
    var bulk: AnyView?
    @ViewBuilder var list: () -> List
    @ViewBuilder var detailView: (ModuleObject) -> Detail
    @ViewBuilder var inspector: (ModuleObject) -> Inspector

    var body: some View {
        GeometryReader { geo in
            let inspecting = inspectorOpen && detail != nil
            let paned = detail != nil || bulk != nil
            let width = paned ? ModuleColumns.list(listWidth, in: geo.size.width, inspecting: inspecting) : geo.size.width
            HStack(spacing: 0) {
                // Always the same scroller, so the page keeps its state when
                // the detail or inspector narrows it: it only scrolls once the
                // budget is under the page's table, which then keeps every
                // column and its row actions instead of losing the trailing ones.
                ScrollView(.horizontal) {
                    list()
                        .frame(width: max(width, minListWidth))
                }
                .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
                .frame(width: width)
                if let bulk {
                    divider
                    bulk
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .background(Theme.canvas)
                } else if let detail {
                    divider
                    detailView(detail)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .background(Theme.canvas)
                    if inspecting {
                        divider
                        inspector(detail)
                            .frame(width: ModuleColumns.inspector)
                            .frame(maxHeight: .infinity, alignment: .top)
                    }
                }
            }
            // A detail opens in one step: its first frame is the whole of it,
            // never 200 ms of the list narrowing under it. Closing still moves.
            .animation(paned ? nil : .snappy(duration: 0.2), value: paned)
            .animation(.snappy(duration: 0.2), value: inspecting)
        }
    }

    private var divider: some View {
        Rectangle().fill(Theme.hairline).frame(width: 1)
    }
}

/// The frame's column widths (D4-B), one rule for both frames.
enum ModuleColumns {
    /// The detail never gets narrower than this; the list gives way first.
    static let detailFloor: CGFloat = 420
    static let inspector: CGFloat = 260

    /// The list's width beside a detail or the bulk pane: the page's, less
    /// where the detail (beside ⌘I's inspector) would go under its floor.
    static func list(_ listWidth: CGFloat, in total: CGFloat, inspecting: Bool) -> CGFloat {
        min(listWidth, max(320, total - (inspecting ? inspector + 1 : 0) - detailFloor - 1))
    }
}

/// `ModuleFrame` for a page that stages its details (focus D23). The detail
/// slot is always in the tree, at the width a detail opens at, so what is
/// staged in it is built and laid out before the key. Closed, it is parked
/// past the frame's trailing edge and clipped; ↵ narrows the list and moves
/// the slot in — the same views, nothing rebuilt. The bulk pane and ⌘I's
/// inspector hold the places they hold in `ModuleFrame`, and nothing here
/// sizes the frame: it fills what the panel gives it.
struct StagedModuleFrame<List: View, Slot: View, Inspector: View>: View {
    var listWidth: CGFloat
    /// `ModulePage.minListWidth`: below it the list scrolls sideways.
    var minListWidth: CGFloat = 0
    var inspectorOpen: Bool
    /// The open detail's object; nil parks the slot.
    let detail: ModuleObject?
    /// The bulk pane, drawn where the detail would be.
    var bulk: AnyView?
    @ViewBuilder var list: () -> List
    @ViewBuilder var slot: () -> Slot
    @ViewBuilder var inspector: (ModuleObject) -> Inspector

    var body: some View {
        GeometryReader { geo in
            let total = geo.size.width
            let open = detail != nil
            let inspecting = inspectorOpen && open
            let paned = open || bulk != nil
            // Parked, the slot already has the width ↵ gives it: ⌘I's column
            // is taken off while the inspector is on, open or not.
            let beside = ModuleColumns.list(listWidth, in: total, inspecting: inspectorOpen)
            let slotWidth = max(0, total - beside - 1 - (inspectorOpen ? ModuleColumns.inspector + 1 : 0))
            let width = open ? beside : bulk != nil ? ModuleColumns.list(listWidth, in: total, inspecting: false) : total
            ZStack(alignment: .topLeading) {
                // The same scroller as `ModuleFrame`'s, for the same reason.
                ScrollView(.horizontal) {
                    list()
                        .frame(width: max(width, minListWidth))
                }
                .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
                .frame(width: width)
                // Closed, the full-width list covers the parked slot: the
                // staged detail is drawn beneath it, so ↵ only narrows the
                // list over a detail already rendered (clipped past the edge,
                // it was not rendered until it came in).
                .background(Theme.canvas)
                .zIndex(open ? 0 : 1)
                divider.offset(x: width).zIndex(1)
                slot()
                    .frame(width: slotWidth, height: geo.size.height, alignment: .topLeading)
                    .background(Theme.canvas)
                    .offset(x: beside + 1)
                    .allowsHitTesting(open)
                    .accessibilityHidden(!open)
                if let bulk {
                    bulk
                        .frame(width: max(0, total - width - 1), height: geo.size.height, alignment: .topLeading)
                        .background(Theme.canvas)
                        .offset(x: width + 1)
                }
                if inspecting, let detail {
                    divider.offset(x: total - ModuleColumns.inspector - 1)
                    inspector(detail)
                        .frame(width: ModuleColumns.inspector)
                        .frame(maxHeight: .infinity, alignment: .top)
                        .offset(x: total - ModuleColumns.inspector)
                }
            }
            .frame(width: total, height: geo.size.height, alignment: .topLeading)
            .clipped()
            // As in `ModuleFrame`: a detail opens in one step, closing moves —
            // the widening list pushes the slot out past the edge.
            .animation(paned ? nil : .snappy(duration: 0.2), value: paned)
            .animation(.snappy(duration: 0.2), value: inspecting)
        }
    }

    private var divider: some View {
        Rectangle().fill(Theme.hairline).frame(width: 1)
    }
}

extension View {
    /// A text field inside a detail a page stages (focus D23): while its
    /// detail is off screen it takes no focus. Opacity 0 leaves a field in
    /// the key-view loop, so ⇥ from a field on screen would land in one
    /// nobody sees. On the field alone: disabling the whole detail would
    /// re-draw every control of two workbenches inside a step's own frame.
    func stagedField() -> some View {
        modifier(StagedField())
    }
}

private struct StagedField: ViewModifier {
    @Environment(\.bodyShown) private var onScreen

    func body(content: Content) -> some View {
        content.disabled(!onScreen)
    }
}

/// The generic detail every module starts from (WP3): the header with its
/// verbs, the context band, the object's own content, then its context
/// sections. Later slices replace it module by module.
struct ObjectDetail<Content: View>: View {
    let object: ModuleObject
    /// False while ⌘I's inspector carries the sections instead.
    var showsFacts = true
    /// `ModulePage.detailScrollsItself`: the header is pinned and the
    /// content scrolls itself, with its own 14 pt edges.
    var scrollsItself = false
    @ViewBuilder var content: () -> Content

    var body: some View {
        if scrollsItself {
            VStack(alignment: .leading, spacing: 12) {
                // One box: `heading` is two siblings, and padding on it would
                // land on the band too.
                VStack(alignment: .leading, spacing: 12) { heading }
                    .padding([.horizontal, .top], 14)
                content()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    heading
                    content()
                    if showsFacts, !object.facts.isEmpty {
                        ContextSections(facts: object.facts)
                            .kitTile()
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollEdgeEffectStyle(.soft, for: .top)
        }
    }

    @ViewBuilder private var heading: some View {
        DetailHeader(title: object.title, status: object.status, meta: metaLine, verbs: verbs) {
            ProjectGlyph(project: object.project ?? "", symbol: object.symbol)
        }
        if !object.context.isEmpty {
            ContextBand(onOpen: object.url.map { url in { OverviewURL.open(url) } }) {
                ForEach(Array(object.context.enumerated()), id: \.offset) { _, chip in chip }
            }
        }
    }

    private var metaLine: Text? {
        let line = [object.label, object.meta].compactMap { $0 }.joined(separator: " · ")
        return line.isEmpty ? nil : Text(line)
    }

    /// `Open ⌘↵` leads wherever the object has a page, then the page's own.
    /// A page verb that is primary (CI's Re-run failed) leads instead: one
    /// primary per header, Open follows it as a normal verb.
    private var verbs: [DetailVerb] {
        let pagePrimary = object.verbs.filter { $0.role == .primary }
        let open = object.url.map { url in
            DetailVerb(title: "Open", symbol: "arrow.up.right", kbd: "⌘↵",
                       role: pagePrimary.isEmpty ? .primary : .normal,
                       help: url.absoluteString) { OverviewURL.open(url) }
        }
        return pagePrimary + (open.map { [$0] } ?? []) + object.verbs.filter { $0.role != .primary }
    }
}

/// The object's context sections: micro labels beside monospaced values.
struct ContextSections: View {
    let facts: [ModuleObject.Fact]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Context").microLabel()
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 5) {
                ForEach(facts) { fact in
                    GridRow {
                        Text(fact.label).microLabel()
                        Text(fact.value)
                            .font(Theme.Typo.figure)
                            .foregroundStyle(Theme.ink2)
                            .lineLimit(3)
                            .textSelection(.enabled)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A module list's scroller: arrowing past the viewport pulls the selected
/// row in (rows carry `.id(objectID)`; a lazy stack would need its
/// `ForEach` ids instead).
struct SelectionScrollView<Content: View>: View {
    let selection: String?
    @ViewBuilder var content: () -> Content

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView { content() }
                .onChange(of: selection) { _, id in
                    guard let id else { return }
                    withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(id) }
                }
        }
    }
}
