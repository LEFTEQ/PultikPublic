import Foundation

/// The eight destinations on ⌘1–8 (copilot shell D9; Mac joined Estate as
/// This Mac in vt-7727 D1). The order is the strip's order and the shortcut
/// digit; it never changes per state.
enum PanelModule: String, CaseIterable, Identifiable, Codable, Sendable {
    case home, prs, ci, prod, devbox, work, sessions, estate

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
    /// (vt-7727 D1, D5). Timeline joins CI first and Estate after Machines,
    /// and Map after it, once the shared renderer lands (D12).
    var views: [ModuleView] {
        switch self {
        case .ci: [.live, .runs, .workflows, .failures, .fleet]
        case .estate: [.machines, .backups]
        default: []
        }
    }
}

/// One of a module's bodies (vt-7727 D1): Semafor's views, kept per module
/// by `ModuleRouter` and restored with its place.
enum ModuleView: String, Codable, Sendable {
    case live, runs, workflows, failures, fleet
    case machines, backups

    var title: String {
        switch self {
        case .live: "Live"
        case .runs: "Runs"
        case .workflows: "Workflows"
        case .failures: "Failures"
        case .fleet: "Fleet"
        case .machines: "Machines"
        case .backups: "Backups"
        }
    }
}
