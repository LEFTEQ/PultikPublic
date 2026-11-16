import SwiftUI

/// The expiry radar: watches things that die on a date — TLS certs (probed),
/// tokens and renewals (typed) — and, once an expiry enters its lead window,
/// raises it in Now and lists it under Estate's renewals (it no longer books
/// a vitrinka todo: the vitrinka integration retired 2026-11-16).
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
    }

    private(set) var items: [Preferences.ExpiryWatchItem]
    private(set) var states: [String: ItemState] = [:]
    private var timer: Timer?

    private static let stateURL = Preferences.directory.appending(path: "expiry-radar.json")
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
            states[item.id] = state
        }
        saveStates()
        recordNowNeeds()
    }

    /// The watchlist with each item's known expiry and lead window — what
    /// Now ranks and Estate lists, under the item's id.
    var watched: [NowInputs.Expiry] {
        items.map { item in
            NowInputs.Expiry(id: item.id, label: item.label, expiry: states[item.id]?.expiry,
                             lead: Self.seconds(item.lead) ?? Self.defaultLead)
        }
    }

    /// The watchlist as Now reads it — local and cheap, so every tick and
    /// every summon records it: a window opens on the clock, not on a probe.
    func recordNowNeeds(now: Date = Date()) {
        NowStore.shared.record(NowAdapters.expiries(watched, now: now), now: now)
    }

    /// An item whose `lead` does not parse watches three weeks out.
    private static let defaultLead: TimeInterval = 21 * 86400

    /// The lead grammar: digits then a unit, repeated (`21d`, `1w2d`, `90m`).
    private static func seconds(_ duration: String) -> TimeInterval? {
        let units: [Character: TimeInterval] = [
            "m": 60, "h": 3600, "d": 86400, "w": 604_800, "y": 31_536_000,
        ]
        var total: TimeInterval = 0
        var digits = ""
        for ch in duration {
            if ch.isNumber {
                digits.append(ch)
            } else if let unit = units[ch], let n = Double(digits) {
                total += n * unit
                digits = ""
            } else {
                return nil
            }
        }
        return digits.isEmpty && total > 0 ? total : nil
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
        if let broken = radar.items.first(where: { radar.states[$0.id]?.lastError != nil }),
           let why = radar.states[broken.id]?.lastError {
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
                        if let error = state?.lastError {
                            Text(error).font(.caption2).foregroundStyle(.red).lineLimit(1)
                        } else if let expiry = state?.expiry {
                            Text(expiry.formatted(date: .abbreviated, time: .omitted))
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.secondary)
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
                Text("Certs are probed daily (one TLS handshake). When an expiry enters its lead window it shows in Now and under Estate's renewals.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Blank means the radar's default, three weeks.
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
