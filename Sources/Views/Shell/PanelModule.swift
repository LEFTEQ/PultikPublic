import Foundation

/// The nine destinations on ⌘1–9 (copilot shell D9). The order is the strip's
/// order and the shortcut digit; it never changes per state.
enum PanelModule: String, CaseIterable, Identifiable, Codable, Sendable {
    case home, prs, ci, prod, devbox, work, sessions, estate, mac

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
        case .mac: "Mac"
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
        case .mac: "laptopcomputer"
        }
    }

    /// 1…9, the ⌘ digit.
    var number: Int { (Self.allCases.firstIndex(of: self) ?? 0) + 1 }

    static func numbered(_ digit: Int) -> PanelModule? {
        allCases.indices.contains(digit - 1) ? allCases[digit - 1] : nil
    }

    /// The strip's next (`step` 1) or previous (−1) module, wrapping Mac ↔
    /// Home: ←/→ on an empty search field.
    func neighbour(_ step: Int) -> PanelModule {
        let all = Self.allCases
        let index = all.firstIndex(of: self) ?? 0
        return all[((index + step) % all.count + all.count) % all.count]
    }
}
