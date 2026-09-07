import SwiftUI
import UserNotifications

/// Holds Pultík's notifications while a macOS Focus is on and flushes them
/// when it lifts.
///
/// There is no public "is Focus active" API; this reads the DoNotDisturb
/// assertions store, which records *manually* enabled Focus modes. Scheduled
/// Focus periods don't write assertions — a documented limit of the approach,
/// stated in the row rather than papered over. If the file is unreadable the
/// gate reports that and never holds anything.
@MainActor
@Observable
final class FocusGate {
    static let shared = FocusGate()

    /// One held notification, in a form that survives a relaunch.
    ///
    /// The queue MUST be durable: callers stamp their own "already announced"
    /// ledgers (TodoStore's notified.json) the moment they hand a
    /// notification over, so a queue lost to a quit would leave a durable
    /// record of a delivery that never happened — and Focus is most often on
    /// exactly when a laptop reboots overnight.
    struct Held: Codable, Hashable {
        let title: String
        let body: String
        let url: String?
    }

    private(set) var queued: [Held] = []
    /// Submitted, awaiting the notification centre's completion. Items stay
    /// in `queued` until then, so without this a second flush — the visible
    /// "Flush now" button, or the toggle's flush racing the timer — would
    /// re-submit them and double the banner.
    private var inFlight: Set<Held> = []
    private static let queueURL = Preferences.directory.appending(path: "focus-queue.json")
    var holdEnabled: Bool {
        didSet {
            var prefs = Preferences.load()
            prefs.focusHoldsNotifications = holdEnabled
            prefs.save()
            if !holdEnabled { flush() }
        }
    }

    private var flushTimer: Timer?
    private static let assertionsURL = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: "Library/DoNotDisturb/DB/Assertions.json")

    private init() {
        holdEnabled = Preferences.load().focusHoldsNotifications
        if let data = try? Data(contentsOf: Self.queueURL),
           let saved = try? JSONDecoder().decode([Held].self, from: data) {
            queued = saved
        }
        // Anything held by a previous run is delivered as soon as this one
        // finds Focus off — late, which is the promise, rather than lost.
        if !queued.isEmpty {
            if case .active = focusState, holdEnabled {
                armFlushTimer()
            } else {
                flush()
            }
        }
    }

    private func saveQueue() {
        if queued.isEmpty {
            try? FileManager.default.removeItem(at: Self.queueURL)
            return
        }
        if let data = try? JSONEncoder().encode(queued) {
            try? data.write(to: Self.queueURL, options: .atomic)
        }
    }

    enum FocusState {
        case active, inactive
        /// The assertions file can't be read — never hold on a guess.
        case unknown(String)
    }

    var focusState: FocusState {
        guard let data = try? Data(contentsOf: Self.assertionsURL) else {
            return .unknown("assertions file unreadable — Focus detection unavailable")
        }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let records = root["data"] as? [[String: Any]]
        else { return .unknown("assertions file unparseable") }
        let active = records.contains {
            (($0["storeAssertionRecords"] as? [[String: Any]])?.isEmpty == false)
        }
        return active ? .active : .inactive
    }

    /// Called by Notifier for every outgoing notification. True = queued.
    func holdIfNeeded(title: String, body: String, url: String?) -> Bool {
        guard holdEnabled, case .active = focusState else { return false }
        let held = Held(title: title, body: body, url: url)
        // A caller whose ledger already stamped this must not stack copies of
        // it every tick.
        if !queued.contains(held) {
            queued.append(held)
            saveQueue()
        }
        armFlushTimer()
        return true
    }

    /// While anything is queued, look for Focus lifting once a minute.
    private func armFlushTimer() {
        guard flushTimer == nil else { return }
        flushTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in
            Task { @MainActor in
                let gate = FocusGate.shared
                if case .active = gate.focusState { return }
                gate.flush()
            }
        }
    }

    func flush() {
        flushTimer?.invalidate()
        flushTimer = nil
        guard !queued.isEmpty else { return }
        // Each item leaves the queue only once the notification centre has
        // ACCEPTED it. Clearing up front made a submission failure — revoked
        // authorization, most plausibly — silently discard the very
        // reminders this queue exists to keep.
        for held in queued where !inFlight.contains(held) {
            inFlight.insert(held)
            let content = UNMutableNotificationContent()
            content.title = held.title
            content.body = held.body
            content.sound = .default
            if let url = held.url { content.userInfo = ["url": url] }
            UNUserNotificationCenter.current().add(
                UNNotificationRequest(identifier: UUID().uuidString,
                                      content: content, trigger: nil)
            ) { error in
                Task { @MainActor in
                    FocusGate.shared.settle(held, error: error)
                }
            }
        }
    }

    /// One delivery came back. Success drops it from the durable queue;
    /// failure keeps it and re-arms, so the next lift tries again.
    private func settle(_ held: Held, error: (any Error)?) {
        inFlight.remove(held)
        if let error {
            NSLog("pultik: held notification not delivered (%@) — keeping it queued",
                  error.localizedDescription)
            armFlushTimer()
            return
        }
        queued.removeAll { $0 == held }
        saveQueue()
    }
}

@MainActor
@Observable
final class FocusIntegration: Integration {
    let id = "focus"
    let title = "Focus"
    let symbol = "moon"
    let canTest = false

    private let gate = FocusGate.shared

    func test() async {}

    var status: IntegrationStatus {
        guard gate.holdEnabled else { return .off }
        switch gate.focusState {
        case .unknown(let why): return .error(why)
        case .active:
            return .attention("Focus on — holding \(gate.queued.count) notification(s)")
        case .inactive:
            return .connected("watching for Focus")
        }
    }

    var detail: AnyView { AnyView(FocusDetail(gate: gate)) }

    fileprivate struct FocusDetail: View {
        @Bindable var gate: FocusGate

        var body: some View {
            VStack(alignment: .leading, spacing: 8) {
                Toggle("Hold notifications during Focus", isOn: $gate.holdEnabled)
                if !gate.queued.isEmpty {
                    HStack {
                        Text("\(gate.queued.count) queued")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button("Flush now") { gate.flush() }
                            .controlSize(.small)
                    }
                }
                Text("Detects manually enabled Focus modes (no public API — scheduled Focus periods are invisible to it). Queued notifications flush within a minute of Focus lifting.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
