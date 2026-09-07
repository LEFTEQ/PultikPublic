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
            ProbeIntegration.eve(store: store),
            ProbeIntegration.vitrinka(),
            ProbeIntegration.devbox(),
            ProbeIntegration.metrics(),
            EventKitIntegration(),
            ExpiryRadarIntegration(),
            FocusIntegration(),
        ]
    }
}

/// Shared helper: run the vitrinka CLI — the writer for todos (`todo add`,
/// `schedule`) when the panel itself needs to file one. Blocking — call from a
/// background task.
///
/// The shim `vitrinka install` writes is preferred: the bun/npm launcher is
/// a JavaScript file that needs a runtime on PATH, and a GUI app launched
/// from Finder has almost no PATH. The runtime dirs are appended for the
/// launcher case anyway — the same hedge, never the plan.
enum VitrinkaCLI {
    static let searchPaths = [
        NSHomeDirectory() + "/.local/bin/vitrinka",
        NSHomeDirectory() + "/.bun/bin/vitrinka",
        "/opt/homebrew/bin/vitrinka",
        "/usr/local/bin/vitrinka",
    ]

    static var path: String? {
        searchPaths.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static let installHint =
        "vitrinka CLI not found — bun add -g @vitrinka/cli, then vitrinka install"

    static let projectHint =
        "no todo project — set one in Settings ▸ General ▸ Todos"

    struct Output: Sendable {
        let status: Int32
        let stdout: String
        let stderr: String
        var trimmedError: String { stderr.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    /// `run` off the main actor. Every caller on `@MainActor` must use this:
    /// `run` blocks in `waitUntilExit()` and synchronous pipe reads, and a
    /// write goes over the mesh to vitrinka — long enough to freeze the panel
    /// and the status item if it runs inline.
    static func runAsync(_ args: [String], stdin: String? = nil) async -> Output? {
        await Task.detached(priority: .utility) { run(args, stdin: stdin) }.value
    }

    /// Runs `vitrinka <args>`, optionally piping stdin. Never throws for a
    /// non-zero exit — the caller reads `status` and surfaces stderr.
    static func run(_ args: [String], stdin: String? = nil) -> Output? {
        guard let path else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        var environment = ProcessInfo.processInfo.environment
        let runtimeDirs = [NSHomeDirectory() + "/.bun/bin", "/opt/homebrew/bin", "/usr/local/bin"]
        environment["PATH"] = (runtimeDirs + [environment["PATH"] ?? "/usr/bin:/bin"]).joined(separator: ":")
        process.environment = environment
        let outPipe = Pipe(), errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        if let stdin {
            let inPipe = Pipe()
            process.standardInput = inPipe
            inPipe.fileHandleForWriting.write(Data(stdin.utf8))
            inPipe.fileHandleForWriting.closeFile()
        }
        do { try process.run() } catch { return Output(status: -1, stdout: "", stderr: "\(error)") }
        process.waitUntilExit()
        let out = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return Output(status: process.terminationStatus, stdout: out, stderr: err)
    }
}

/// A credential an integration row can edit inline.
///
/// Shared by every row that holds a secret (Sentry, eve) so the save rule is
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
