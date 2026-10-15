import EventKit
import SwiftUI

/// EventKit read access. Grants Pultík
/// the day's events so the schedule agenda can interleave them; the app never
/// writes events — the iCloud mirror was retired with the vault (2026-09-05).
@MainActor
@Observable
final class EventKitIntegration: Integration {
    let id = "eventkit"
    let title = "Calendar access"
    let symbol = "calendar"
    let canTest = false

    private let day = CalendarDayStore.shared

    /// EventKit's verdict, snapshotted into observable state. `EKEventStore
    /// .authorizationStatus` is a plain static read — a view that calls it
    /// directly never re-renders when the grant changes, which is why the
    /// row used to keep saying "denied" after a successful grant.
    private(set) var authorization = EKEventStore.authorizationStatus(for: .event)

    /// Granting happens in System Settings, i.e. in another app — coming back
    /// to the front is the only reliable "they might have flipped it" signal.
    /// Owned by the integration, not by the expanded row, so a collapsed row
    /// cannot sit on a stale verdict either.
    // `@ObservationIgnored` because this is bookkeeping, not UI state — no
    // view reads it, and leaving it in the observation graph both invalidates
    // views for nothing and rewrites it into a computed property, which is
    // what made `nonisolated(unsafe)` meaningless here (and plain
    // `nonisolated` illegal: it cannot apply to a mutable stored property).
    // Ignored, it is a real stored property again, so `unsafe` has effect and
    // `deinit` — not main-actor-isolated — may read the token to unregister.
    // The only write is in `init`, on the main actor.
    @ObservationIgnored private nonisolated(unsafe) var activationObserver: (any NSObjectProtocol)?

    init() {
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refreshAuthorization() }
        }
    }

    deinit {
        if let activationObserver {
            NotificationCenter.default.removeObserver(activationObserver)
        }
    }

    func test() async {}

    /// Re-read the grant. Called when the row appears and every time the app
    /// comes back to the front — the System Settings round-trip ends there.
    func refreshAuthorization() {
        let current = EKEventStore.authorizationStatus(for: .event)
        guard current != authorization else { return }
        authorization = current
        day.reload()
    }

    /// macOS prompts for a TCC grant exactly once. After a denial
    /// `requestFullAccessToEvents` returns false without showing anything —
    /// so a denied row must send the operator to System Settings instead of
    /// silently re-asking (the button looked dead otherwise).
    var mustGrantInSystemSettings: Bool {
        authorization == .denied || authorization == .restricted
    }

    func grant() {
        guard !mustGrantInSystemSettings else {
            NSWorkspace.shared.open(URL(
                string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")!)
            return
        }
        Task {
            await day.requestAccess()
            refreshAuthorization()
        }
    }

    var status: IntegrationStatus {
        switch authorization {
        case .fullAccess:
            return .connected("today: \(day.todayEvents.count) event(s)")
        case .denied, .restricted:
            return .error("denied — open System Settings below")
        case .writeOnly:
            return .attention("write-only grant — full access needed to read the day")
        default:
            return .notConfigured("not granted")
        }
    }

    var detail: AnyView { AnyView(EventKitDetail(integration: self, day: day)) }

    fileprivate struct EventKitDetail: View {
        let integration: EventKitIntegration
        @Bindable var day: CalendarDayStore

        var body: some View {
            VStack(alignment: .leading, spacing: 8) {
                if integration.authorization != .fullAccess {
                    Button(integration.mustGrantInSystemSettings
                           ? "Open System Settings → Privacy → Calendars"
                           : "Grant calendar access") { integration.grant() }
                    Text(integration.mustGrantInSystemSettings
                         ? "Access was refused once, and macOS only asks once — flip Pultík on in Privacy & Security → Calendars, then come back; this row re-reads the grant when the app returns to the front."
                         : "Read-only: today's events appear in the .schedule agenda beside ripening todos. The ad-hoc-signed app loses this grant on rebuild — just grant again.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    if day.todayEvents.isEmpty {
                        Text("Nothing on the calendar today.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(day.todayEvents.prefix(6)) { event in
                        HStack(spacing: 6) {
                            Text(event.start.formatted(.dateTime.hour().minute()))
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.secondary)
                            Text(event.title)
                                .font(.caption)
                                .lineLimit(1)
                        }
                    }
                }
            }
            .onAppear { integration.refreshAuthorization() }
        }
    }
}

/// Today's calendar events, read-only, reloaded on EventKit's own change
/// notification. Feeds the settings row and the schedule agenda's today strip.
@MainActor
@Observable
final class CalendarDayStore {
    static let shared = CalendarDayStore()

    struct DayEvent: Identifiable {
        let id: String
        let title: String
        let start: Date
        let end: Date
        let calendar: String
    }

    private(set) var todayEvents: [DayEvent] = []
    private let eventStore = EKEventStore()

    private init() {
        reload()
        NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged, object: eventStore, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.reload() }
        }
    }

    var hasAccess: Bool { EKEventStore.authorizationStatus(for: .event) == .fullAccess }

    /// Async so the caller can re-read the grant once EventKit has answered —
    /// a fire-and-forget request leaves every view showing the stale verdict.
    @discardableResult
    func requestAccess() async -> Bool {
        _ = try? await eventStore.requestFullAccessToEvents()
        reload()
        return hasAccess
    }

    func reload() {
        guard hasAccess else { todayEvents = []; return }
        let start = Calendar.current.startOfDay(for: .now)
        guard let end = Calendar.current.date(byAdding: .day, value: 1, to: start) else { return }
        let predicate = eventStore.predicateForEvents(withStart: start, end: end, calendars: nil)
        // The pultik calendar is the mirror of the vault — showing its events
        // back beside the todos they mirror would double every entry.
        todayEvents = eventStore.events(matching: predicate)
            .filter { !$0.isAllDay && $0.calendar?.title.lowercased() != "pultik" }
            .sorted { $0.startDate < $1.startDate }
            .map {
                DayEvent(id: $0.eventIdentifier ?? UUID().uuidString,
                         title: $0.title ?? "busy",
                         start: $0.startDate, end: $0.endDate,
                         calendar: $0.calendar?.title ?? "")
            }
    }
}
