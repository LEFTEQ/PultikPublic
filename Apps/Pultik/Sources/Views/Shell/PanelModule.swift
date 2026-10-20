import Foundation

/// The nine destinations on ⌘1–9 (copilot shell D9; Mac joined Estate as
/// This Mac in vt-7727 D1; Toolkit is the ninth, docs/specs/2026-10-20-toolkit-module-decisions.md).
/// The order is the strip's default order and the shortcut digit; it never
/// changes per state.
enum PanelModule: String, CaseIterable, Identifiable, Codable, Sendable {
    case home, prs, ci, prod, devbox, work, sessions, estate, toolkit

    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: "Home"
        case .prs: "PRs"
        case .ci: "CI"
        case .prod: "Prod"
        case .devbox: "Devbox"
        case .work: "Work"
        case .sessions: "Sessions"
        case .estate: "Estate"
        case .toolkit: "Toolkit"
        }
    }

    var symbol: String {
        switch self {
        case .home: "house"
        case .prs: "arrow.triangle.pull"
        case .ci: "arrow.triangle.2.circlepath"
        case .prod: "waveform.path.ecg"
        case .devbox: "shippingbox"
        case .work: "checklist"
        case .sessions: "terminal"
        case .estate: "server.rack"
        case .toolkit: "wrench.and.screwdriver"
        }
    }

    /// 1…9, the ⌘ digit, in the strip's order (Settings ▸ Modules).
    func number(in order: [PanelModule] = allCases) -> Int { (order.firstIndex(of: self) ?? 0) + 1 }

    static func numbered(_ digit: Int, in order: [PanelModule] = allCases) -> PanelModule? {
        order.indices.contains(digit - 1) ? order[digit - 1] : nil
    }

    /// The strip's next (`step` 1) or previous (−1) module, wrapping the last
    /// ↔ the first: ←/→ on an empty search field.
    func neighbour(_ step: Int, in order: [PanelModule] = allCases) -> PanelModule {
        let all = order.isEmpty ? Self.allCases : order
        let index = all.firstIndex(of: self) ?? 0
        return all[((index + step) % all.count + all.count) % all.count]
    }

    /// The bodies ⇥/⇧⇥ cycle, in order; empty = the module has one
    /// (vt-7727 D1, D5). Timeline is CI's first; it retired Live (vt-7781 WP6).
    var views: [ModuleView] {
        switch self {
        case .ci: [.timeline, .runs, .workflows, .failures, .fleet]
        case .estate: [.machines, .timeline, .map, .backups]
        case .toolkit: [.overview, .workflows, .skills, .guards]
        default: []
        }
    }

    /// The list a filter slices when the shown view has no rows to filter
    /// (vt-7727 D20): CI's `failed` is Runs' failed runs, so `.c failed`
    /// lands there and typing it on the Timeline shows them.
    func view(filtering filter: String) -> ModuleView? {
        self == .ci && ModuleView.failedRuns(filter) != nil ? .runs : nil
    }
}

/// One of a module's bodies (vt-7727 D1): Semafor's views and Toolkit's,
/// kept per module by `ModuleRouter` and restored with its place.
/// `workflows` is CI's GitHub workflows in CI and the bundled Workflow-tool
/// scripts in Toolkit.
enum ModuleView: String, Codable, Sendable {
    case timeline, runs, workflows, failures, fleet
    case machines, map, backups
    case overview, skills, guards

    var title: String {
        switch self {
        case .overview: "Overview"
        case .skills: "Skills"
        case .guards: "Guards"
        case .timeline: "Timeline"
        case .runs: "Runs"
        case .workflows: "Workflows"
        case .failures: "Failures"
        case .fleet: "Fleet"
        case .machines: "Machines"
        case .map: "Map"
        case .backups: "Backups"
        }
    }

    /// The view holds a canvas the keys can enter (vt-7727 D5): ↵ enters it
    /// and Esc leaves it. Backups' timeline sits above its Pipelines table,
    /// so there ↵ enters it only while no row is selected. nil for the lists.
    var canvas: CanvasKind? {
        switch self {
        case .timeline, .backups: .timeline
        case .map: .map
        default: nil
        }
    }

    /// Runs' failed slice (vt-7727 D20): a filter whose first word is
    /// `failed` lists GitHub's failed runs; the rest still filters them.
    /// nil: any other filter.
    static func failedRuns(_ filter: String) -> String? {
        let words = filter.trimmingCharacters(in: .whitespaces).split(separator: " ", maxSplits: 1)
        guard words.first?.lowercased() == "failed" else { return nil }
        return words.count > 1 ? words[1].trimmingCharacters(in: .whitespaces) : ""
    }
}

/// What an entered canvas does with its arrows (vt-7727 D5, D11): a
/// timeline steps its outcomes, the map walks its nodes.
enum CanvasKind: String, Sendable {
    case timeline, map
}
