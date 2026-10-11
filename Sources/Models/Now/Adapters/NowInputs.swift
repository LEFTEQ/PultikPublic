import Foundation

/// The first Now adapters (contract "Sources", the nine with a trustworthy
/// onset today). Each maps one source's fresh read into needs plus how much
/// of the source it saw; a nil input is a read that did not answer
/// (`.failed`: nothing clears). They map only — every threshold and verdict
/// they apply is the source's own or the contract's.
enum NowAdapters {
    /// The source's instant, or the first observation when it has none.
    static func onset(_ date: Date?, now: Date) -> NowOnset {
        date.map(NowOnset.exact) ?? .observed(now)
    }

    static func failed(_ source: NowSource) -> NowRead {
        NowRead(source: source, coverage: .failed, needs: [])
    }
}

/// Inputs for sources whose app types live outside the Foundation harness
/// (AppKit stores, settings): the app builds these from `TodoItem`,
/// `MacHealth` and `ExpiryRadar`, so the adapters never see app types.
enum NowInputs {
    /// One vitrinka `todo` task (`TodoItem`).
    struct Todo: Equatable, Sendable {
        /// `TodoItem.defaultLead`: a todo without a `lead` ripens 2 h early.
        static let defaultLead: TimeInterval = 2 * 3600

        let id: Int64
        /// The task key ("FIX-1365"), when the engine gave one.
        var key: String? = nil
        let project: String
        let title: String
        /// todo · in_progress · done · cancelled
        var status: String = "todo"
        let dueAt: Date?
        var lead: TimeInterval? = nil
        /// `/me/ripe`'s reason: overdue · due · milestone.
        var reason: String? = nil
        /// The server's task URL — never rebuilt, so a click keeps its workspace.
        var url: String? = nil
    }

    /// Toolkit's Mac health report (`MacHealth`).
    struct MacReport: Equatable, Sendable {
        let generatedAt: Date
        let findings: [MacFinding]
    }

    struct MacFinding: Equatable, Sendable {
        enum Severity: String, Sendable {
            case red, amber, info, ok
        }

        let id: String
        let severity: Severity
        let title: String
        let detail: String
        let since: Date
        /// Toolkit offers a stop verb for it.
        let stopSupported: Bool
    }

    /// One watched expiry (`Preferences.ExpiryWatchItem` + `ExpiryRadar.State`).
    struct Expiry: Equatable, Sendable {
        let id: String
        let label: String
        /// Nil while the probe has no date (it failed, or none is set).
        let expiry: Date?
        /// The item's parsed lead window.
        let lead: TimeInterval
    }
}
