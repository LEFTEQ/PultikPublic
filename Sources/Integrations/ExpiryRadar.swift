import SwiftUI

/// The expiry radar: watches things that die on a date — TLS certs (probed),
/// tokens and renewals (typed) — and, once an expiry enters its lead window,
/// books a scheduled todo through the vitrinka CLI. The reminder then rides the
/// whole existing pipeline: vitrinka, session hook, panel.
///
/// Probing is a TLS handshake against port 443 — no credentials, no request
/// body, once a day per host. Failures are recorded on the item and retried
/// at the next daily tick, never hot-looped.
@MainActor
@Observable
final class ExpiryRadarStore {
    static let shared = ExpiryRadarStore()

    struct ItemState: Codable {
        var expiry: Date?
        var lastProbe: Date?
        /// What the last EVALUATION said — the TLS handshake, or reading a
        /// manual date. Owned by the tick's switch, cleared only by a pass
        /// that actually re-evaluated.
        var lastError: String?
        /// What the last BOOKING said. Separate on purpose: one shared string
        /// meant a successful booking could erase a fresh probe failure and
        /// put a green dot over an unreachable host.
        var bookError: String?
        /// The todo name booked for this expiry — booking is idempotent per
        /// expiry date, so a renewed cert (new date) books a fresh todo.
        var bookedFor: Date?
    }

    private(set) var items: [Preferences.ExpiryWatchItem]
    private(set) var states: [String: ItemState] = [:]
    private var timer: Timer?

    private static let stateURL = Preferences.directory.appending(path: "expiry-radar.json")
    /// Local-offset RFC3339 — what `vitrinka schedule --at` parses directly.
    static let rfc3339: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = .current
        return f
    }()

    private static let dateOnly: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = .current
        return f
    }()

    private init() {
        items = Preferences.load().expiryWatch
        if let data = try? Data(contentsOf: Self.stateURL),
           let saved = try? JSONDecoder().decode([String: ItemState].self, from: data) {
            states = saved
        }
        // On launch and then daily — a radar's clock, not a poller's.
        Task { await tick() }
        timer = Timer.scheduledTimer(withTimeInterval: 24 * 3600, repeats: true) { _ in
            Task { @MainActor in await ExpiryRadarStore.shared.tick() }
        }
    }

    // MARK: - Watchlist edits (persisted straight into settings.json)

    func add(_ item: Preferences.ExpiryWatchItem) {
        guard !items.contains(where: { $0.id == item.id }) else { return }
        items.append(item)
        persistWatchlist()
        Task { await tick() }
    }

    func remove(_ id: String) {
        items.removeAll { $0.id == id }
        states[id] = nil
        persistWatchlist()
        saveStates()
    }

    private func persistWatchlist() {
        Preferences.update { $0.expiryWatch = self.items }
    }

    private func saveStates() {
        if let data = try? JSONEncoder().encode(states) {
            try? data.write(to: Self.stateURL, options: .atomic)
        }
    }

    // MARK: - The daily pass

    /// A pass is already walking the list. `tick` is `@MainActor` but async,
    /// so it is REENTRANT at every handshake await — the launch tick, the
    /// daily timer and `add()` can otherwise interleave mid-list.
    private var ticking = false

    /// `force` is the Test button: it re-probes now, ignoring the daily budget.
    func tick(force: Bool = false) async {
        guard !ticking else { return }
        ticking = true
        defer { ticking = false }
        for item in items {
            var state = states[item.id] ?? ItemState()
            switch item.kind {
            case "tls":
                guard let host = item.host else { continue }
                // One handshake per host per day (decision #6) — the daily
                // timer, every app launch and every watchlist edit all land
                // here, and Pultík launches at login. The budget covers
                // FAILED probes too: an unreachable host is exactly the one
                // that must not be retried on every tick, and the doc's
                // promise is a retry at the next daily tick, not a fast one.
                if !force, let last = state.lastProbe,
                   Date.now.timeIntervalSince(last) < 24 * 3600 {
                    break
                }
                // Take the day's slot BEFORE dialling out, not after: the
                // await below is where another pass could observe a stale
                // lastProbe and open a second handshake to the same host.
                state.lastProbe = .now
                // Only a pass that actually re-probes may clear the last
                // verdict. Clearing it per-pass put a green dot back over an
                // unreachable host on every launch inside the daily budget —
                // an error erased rather than resolved.
                state.lastError = nil
                states[item.id] = state
                do {
                    state.expiry = try await Self.certificateExpiry(host: host)
                } catch {
                    state.lastError = error.localizedDescription
                }
            case "manual":
                // Re-read from settings.json every pass, so this branch does
                // re-evaluate and may clear its verdict.
                state.lastError = nil
                let typed = item.expires?.trimmingCharacters(in: .whitespaces) ?? ""
                if let parsed = Self.dateOnly.date(from: typed) {
                    // A date-only expiry means "dead by that morning".
                    state.expiry = Calendar.current
                        .date(bySettingHour: 9, minute: 0, second: 0, of: parsed) ?? parsed
                } else {
                    // Silence here was a watch item that sat inert behind a
                    // green dot forever.
                    state.expiry = nil
                    state.lastError = typed.isEmpty
                        ? "no expiry date set"
                        : "cannot read \"\(typed)\" as a date (expected yyyy-MM-dd)"
                }
                state.lastProbe = .now
            default:
                continue
            }
            state = await book(item, state)
            states[item.id] = state
        }
        saveStates()
    }

    /// Books the todo once the expiry enters the lead window. The name carries
    /// the expiry DATE, so re-ticks inside one window are no-ops while a
    /// renewed cert (new date) is a new name and books the next round — the
    /// idempotence decision #6 asks for. Without the date the second booking
    /// would hit the CLI's "already exists" on last round's todo and be
    /// recorded as a success that never happened.
    private func book(_ item: Preferences.ExpiryWatchItem, _ state: ItemState) async -> ItemState {
        var state = state
        // An expiry in the PAST still books: a cert that already died is the
        // loudest thing this radar can have to say, and skipping it was how
        // the row stayed green over a dead certificate.
        guard let expiry = state.expiry else { return state }
        let lead = Self.seconds(item.lead) ?? 21 * 86400
        guard Date.now >= expiry.addingTimeInterval(-lead) else { return state }
        if let booked = state.bookedFor, abs(booked.timeIntervalSince(expiry)) < 3600 { return state }
        guard VitrinkaCLI.path != nil else {
            // Returning silently here made the radar a permanent no-op behind
            // a green dot: nothing books, nothing notifies, nothing says why.
            state.bookError = VitrinkaCLI.installHint
            return state
        }
        // A GUI app has no checkout for `vitrinka schedule` to derive a
        // project from; the radar files into the configured one.
        guard let project = StatusStore.shared.todoProject else {
            state.bookError = VitrinkaCLI.projectHint
            return state
        }

        let day = Self.dateOnly.string(from: expiry)
        let subject = item.kind == "tls" ? "tls \(item.host ?? "")" : "\(item.name ?? "")"
        let title = "renew \(subject) \(day)"
        let at = Self.rfc3339.string(from: expiry)
        // Off the main actor: this shells out to the CLI, which talks to
        // vitrinka over the mesh before it returns.
        let output = await VitrinkaCLI.runAsync([
            "schedule", title, "--at", at, "--lead", item.lead, "--priority", "high",
            "--project", project,
            "--body", "Booked by pultik's expiry radar (\(item.label)). Expires \(at).",
        ])
        if let output, output.status == 0 {
            state.bookedFor = expiry
            // Clears the BOOKING verdict only. It must never touch lastError:
            // a probe that failed this pass leaves the PREVIOUS expiry in
            // place (the do/catch only assigns on success), so we reach here
            // with a stale date and would erase a live failure.
            state.bookError = nil
        } else {
            state.bookError = output?.trimmedError ?? VitrinkaCLI.installHint
        }
        return state
    }

    private static func seconds(_ duration: String) -> TimeInterval? {
        TodoDuration.parse(duration)
    }

    // MARK: - TLS probe

    private final class TrustGrabber: NSObject, URLSessionDelegate {
        let onTrust: @Sendable (SecTrust) -> Void
        init(onTrust: @escaping @Sendable (SecTrust) -> Void) { self.onTrust = onTrust }

        func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
            if let trust = challenge.protectionSpace.serverTrust {
                onTrust(trust)
            }
            // The certificate chain is all we came for.
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }

    /// One handshake, leaf cert's notAfter. The request itself is cancelled
    /// at the challenge — no bytes of the site are fetched.
    static func certificateExpiry(host: String) async throws -> Date {
        final class Box: @unchecked Sendable { var expiry: Date? }
        let box = Box()
        let delegate = TrustGrabber { trust in
            guard let leaf = (SecTrustCopyCertificateChain(trust) as? [SecCertificate])?.first,
                  let values = SecCertificateCopyValues(
                      leaf, [kSecOIDX509V1ValidityNotAfter] as CFArray, nil) as? [String: Any],
                  let entry = values[kSecOIDX509V1ValidityNotAfter as String] as? [String: Any],
                  let stamp = entry[kSecPropertyKeyValue as String] as? NSNumber
            else { return }
            box.expiry = Date(timeIntervalSinceReferenceDate: stamp.doubleValue)
        }
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        guard let url = URL(string: "https://\(host)/") else {
            throw URLError(.badURL)
        }
        // The data task "fails" by design (we cancel at the challenge); only a
        // handshake that never happened is a real error.
        _ = try? await session.data(from: url)
        guard let expiry = box.expiry else {
            throw URLError(.secureConnectionFailed,
                           userInfo: [NSLocalizedDescriptionKey: "\(host): TLS handshake failed"])
        }
        return expiry
    }
}

@MainActor
@Observable
final class ExpiryRadarIntegration: Integration {
    let id = "expiry-radar"
    let title = "Expiry radar"
    let symbol = "clock.badge.exclamationmark"
    let canTest = true

    private let radar = ExpiryRadarStore.shared
    private var isTesting = false

    private var newHost = ""
    private var newName = ""
    private var newDate = ""
    private var newLead = "21d"

    var status: IntegrationStatus {
        if isTesting { return .testing }
        guard !radar.items.isEmpty else { return .notConfigured("nothing watched") }
        // A probe verdict outranks a booking verdict: not knowing whether a
        // cert is alive is worse news than knowing and failing to book.
        if let broken = radar.items.first(where: { radar.states[$0.id]?.lastError != nil }),
           let why = radar.states[broken.id]?.lastError {
            return .attention("\(broken.label): \(why)")
        }
        if let broken = radar.items.first(where: { radar.states[$0.id]?.bookError != nil }),
           let why = radar.states[broken.id]?.bookError {
            return .attention("\(broken.label): \(why)")
        }
        let dated = radar.items
            .compactMap { item in radar.states[item.id]?.expiry.map { (item.label, $0) } }
        // Something already dead outranks the next thing due — a green dot
        // over an expired certificate is the one reading this row must never
        // give.
        if let (label, expiry) = dated.filter({ $0.1 <= .now }).min(by: { $0.1 < $1.1 }) {
            let days = Int(Date.now.timeIntervalSince(expiry) / 86400)
            return .error("\(label) EXPIRED \(days)d ago")
        }
        guard let (label, expiry) = dated.filter({ $0.1 > .now }).min(by: { $0.1 < $1.1 }) else {
            return .connected("watching \(radar.items.count)")
        }
        let days = Int(expiry.timeIntervalSinceNow / 86400)
        return .connected("watching \(radar.items.count) · next: \(label) in \(days)d")
    }

    /// Test = run the daily pass now, budget or no budget.
    func test() async {
        isTesting = true
        await radar.tick(force: true)
        isTesting = false
    }

    var detail: AnyView { AnyView(ExpiryRadarDetail(integration: self, radar: radar)) }

    fileprivate struct ExpiryRadarDetail: View {
        @Bindable var integration: ExpiryRadarIntegration
        let radar: ExpiryRadarStore

        var body: some View {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(radar.items) { item in
                    let state = radar.states[item.id]
                    HStack(spacing: 6) {
                        Image(systemName: item.kind == "tls" ? "lock" : "square.and.pencil")
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                        Text(item.label)
                            .font(.caption)
                        Spacer()
                        if let error = state?.lastError ?? state?.bookError {
                            Text(error).font(.caption2).foregroundStyle(.red).lineLimit(1)
                        } else if let expiry = state?.expiry {
                            Text(expiry.formatted(date: .abbreviated, time: .omitted))
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.secondary)
                            if state?.bookedFor != nil {
                                Text("✓ todo").font(.caption2).foregroundStyle(.green)
                            }
                        } else {
                            Text("not probed yet").font(.caption2).foregroundStyle(.secondary)
                        }
                        Button {
                            radar.remove(item.id)
                        } label: {
                            Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Stop watching \(item.label)")
                        .accessibilityHint("Removes this item from the expiry radar")
                    }
                }
                HStack {
                    TextField("host (TLS, :443)", text: $integration.newHost)
                        .textFieldStyle(.roundedBorder)
                    TextField("lead", text: $integration.newLead)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 52)
                    Button("Watch") { integration.addTLS() }
                        .disabled(integration.newHost.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                HStack {
                    TextField("name (manual)", text: $integration.newName)
                        .textFieldStyle(.roundedBorder)
                    TextField("YYYY-MM-DD", text: $integration.newDate)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 96)
                    Button("Watch") { integration.addManual() }
                        .disabled(integration.newName.isEmpty || integration.newDate.isEmpty)
                }
                Text("Certs are probed daily (one TLS handshake). When an expiry enters its lead window, a scheduled todo is booked via the CLI — it then ripens, notifies, and mirrors like any other.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Blank means "use the radar's default", not "use the CLI's": an empty
    /// lead reaches `schedule` without a --lead and lands on its 2h fallback,
    /// which for a certificate is two hours' notice instead of three weeks.
    private var leadOrDefault: String {
        let trimmed = newLead.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? "21d" : trimmed
    }

    private func addTLS() {
        radar.add(.init(kind: "tls", host: newHost.trimmingCharacters(in: .whitespaces),
                        name: nil, expires: nil, lead: leadOrDefault))
        newHost = ""
    }

    private func addManual() {
        radar.add(.init(kind: "manual", host: nil, name: newName.trimmingCharacters(in: .whitespaces),
                        expires: newDate.trimmingCharacters(in: .whitespaces), lead: leadOrDefault))
        newName = ""
        newDate = ""
    }
}
