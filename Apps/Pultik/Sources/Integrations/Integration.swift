import SwiftUI

/// One row in the Integrations pane: where the connection stands, rendered
/// from state Pultík already holds — opening Settings never probes anything.
enum IntegrationStatus: Equatable {
    /// Working, with an optional one-liner ("last sync 09:12").
    case connected(String? = nil)
    /// Configured but currently degraded — a ProbeGate pause, a stale sync.
    case attention(String)
    /// Configured and definitively broken (rejected credentials, failed test).
    case error(String)
    /// Never set up; the hint says what's missing.
    case notConfigured(String? = nil)
    /// Deliberately switched off.
    case off
    /// A Test is in flight.
    case testing

    var dotColor: Color {
        switch self {
        case .connected: .green
        case .attention: .orange
        case .error: .red
        case .notConfigured, .off: .secondary.opacity(0.4)
        case .testing: .blue
        }
    }

    var line: String {
        switch self {
        case .connected(let detail): detail ?? "connected"
        case .attention(let why): why
        case .error(let why): why
        case .notConfigured(let hint): hint ?? "not connected"
        case .off: "off"
        case .testing: "testing…"
        }
    }
}

/// An outside thing Pultík talks to. Each conformer is one file; the pane
/// renders the registry generically, so integration #9 never edits the pane.
@MainActor
protocol Integration: AnyObject, Identifiable {
    var id: String { get }
    var title: String { get }
    var symbol: String { get }
    var status: IntegrationStatus { get }
    /// Whether the row offers a Test button (one on-demand probe, reported
    /// through ProbeGate — Settings is not a side channel around the breaker).
    var canTest: Bool { get }
    func test() async
    /// The expanded content: fields, actions, watchlists.
    var detail: AnyView { get }
}

/// The pane's data source. Built once per Settings window; integrations that
/// need app stores get them here.
@MainActor
@Observable
final class IntegrationRegistry {
    let all: [any Integration]

    init(store: StatusStore) {
        all = [
            GitHubIntegration(store: store),
            SentryIntegration(store: store),
            ProbeIntegration.metrics(),
            ExpiryRadarIntegration(),
            FocusIntegration(),
        ]
    }
}

/// A credential an integration row can edit inline.
///
/// Shared by every row that holds a secret (Sentry) so the save rule is
/// written once: ⏎, the Save button, blur, and closing Settings all persist.
/// A token pasted and tabbed away from must not silently revert on next open.
struct TokenSlot {
    let placeholder: String
    let footnote: String
    let read: @MainActor () -> String?
    /// Returns nil on success, or a message to show the operator. A store
    /// that can only log its failure must not be reported back as saved.
    let write: @MainActor (String) -> String?
}

/// The editor for one `TokenSlot`. Prefilled from the store, change-guarded on
/// every save path — the setters kick a full refresh, so a no-op blur (or the
/// onDisappear sweep when a row collapses) must not cost one.
struct TokenEditor: View {
    let slot: TokenSlot

    @State private var draft = ""
    @State private var justSaved = false
    @State private var failure: String?
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                SecureField(slot.placeholder, text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .focused($focused)
                    .onSubmit { saveIfChanged() }
                Button("Save") { saveIfChanged() }
                    .disabled(!hasChange)
            }
            if let failure {
                Text(failure)
                    .font(.caption)
                    .foregroundStyle(.red)
            } else if justSaved {
                Text("Saved.")
                    .font(.caption)
                    .foregroundStyle(.green)
            }
            Text(slot.footnote)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .onAppear { draft = slot.read() ?? "" }
        .onChange(of: draft) { justSaved = false; failure = nil }
        // Losing focus is a save. So is closing Settings mid-edit.
        .onChange(of: focused) { wasFocused, _ in if wasFocused { saveIfChanged() } }
        .onDisappear { saveIfChanged() }
    }

    private var hasChange: Bool {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmed.isEmpty ? nil : trimmed) != slot.read()
    }

    private func saveIfChanged() {
        guard hasChange else { return }
        failure = slot.write(draft)
        justSaved = failure == nil
    }
}
