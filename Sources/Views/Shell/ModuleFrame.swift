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
}

extension ModulePage {
    var listWidth: CGFloat { 480 }
    var minListWidth: CGFloat { 0 }
    var detailScrollsItself: Bool { false }
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

    var body: some View {
        let open = detailOpen ? selection.flatMap { id in objects.first { $0.id == id } } : nil
        ModuleFrame(listWidth: page.listWidth, minListWidth: page.minListWidth,
                    inspectorOpen: inspectorOpen, detail: open) {
            page
        } detailView: { object in
            StackedDetail(stack: stack, onPop: onPop) {
                ObjectDetail(object: object, showsFacts: !inspectorOpen, scrollsItself: page.detailScrollsItself) {
                    page.detailContent(for: object)
                }
            } card: { ref in
                card(ref)
            }
        } inspector: { object in
            ScrollView {
                ContextSections(facts: object.facts)
                    .padding(14)
            }
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
    @ViewBuilder var list: () -> List
    @ViewBuilder var detailView: (ModuleObject) -> Detail
    @ViewBuilder var inspector: (ModuleObject) -> Inspector

    /// The detail never gets narrower than this; the list gives way first.
    static var detailFloor: CGFloat { 420 }
    static var inspectorWidth: CGFloat { 260 }

    var body: some View {
        GeometryReader { geo in
            let inspecting = inspectorOpen && detail != nil
            let room = geo.size.width - (inspecting ? Self.inspectorWidth + 1 : 0) - Self.detailFloor - 1
            let width = detail == nil ? geo.size.width : min(listWidth, max(320, room))
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
                if let detail {
                    divider
                    detailView(detail)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .background(Theme.canvas)
                    if inspecting {
                        divider
                        inspector(detail)
                            .frame(width: Self.inspectorWidth)
                            .frame(maxHeight: .infinity, alignment: .top)
                    }
                }
            }
            .animation(.snappy(duration: 0.2), value: detail == nil)
            .animation(.snappy(duration: 0.2), value: inspecting)
        }
    }

    private var divider: some View {
        Rectangle().fill(Theme.hairline).frame(width: 1)
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
