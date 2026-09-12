import Foundation
import Network
import Observation

/// Every remote thing Pultík polls, one case per HOST-and-credential.
///
/// The unit a server bans is an IP, so the breaker has to trip for a whole
/// host — not for the single query that happened to fail. `prometheus` and
/// `devbox` are separate cases despite sharing a box: one is an HTTP port on
/// the mesh, the other is sshd, and only the second is behind fail2ban.
enum ProbeTarget: String, CaseIterable, Sendable {
    case github
    case prometheus
    case eve
    case sentry
    case vitrinka
    case devbox

    var label: String {
        switch self {
        case .github: return "github"
        case .prometheus: return "server metrics"
        case .eve: return "eve"
        case .sentry: return "sentry"
        case .vitrinka: return "vitrinka"
        case .devbox: return "devbox (ssh)"
        }
    }
}

/// Why a probe came back empty.
///
/// The distinction is the whole point of the breaker: a laptop off the mesh
/// costs the far side nothing, while a refusal is an attempt fail2ban counts —
/// and enough of those in a window get this Mac banned outright.
enum ProbeFailure: Sendable {
    /// Nobody answered: off-mesh, timeout, refused socket, dead tunnel.
    case unreachable(String)
    /// The far side answered and said no — 401/403/429, ssh auth denied — or
    /// the target no longer exists (dead ssh alias, NXDOMAIN). Retrying these
    /// quickly is both pointless and precisely what gets us blocked.
    case rejected(String)

    var reason: String {
        switch self {
        case .unreachable(let why): return why
        case .rejected(let why): return why
        }
    }
}

/// A non-2xx answer, carried with its code so the breaker can tell "the
/// service is broken" (retry soonish) from "the service refused us" (back off
/// hard, before something upstream stops answering us at all).
struct HTTPStatusError: Error {
    let status: Int
}

extension ProbeFailure {
    /// Maps a thrown error onto the two classes. Anything unrecognised is
    /// treated as merely unreachable — the gentler ladder — because guessing
    /// "rejected" would silence a section for half an hour over a hiccup.
    static func classify(_ error: Error) -> ProbeFailure {
        if let http = error as? HTTPStatusError {
            switch http.status {
            case 401, 403, 407, 429: return .rejected("HTTP \(http.status)")
            default: return .unreachable("HTTP \(http.status)")
            }
        }
        if let url = error as? URLError {
            switch url.code {
            case .userAuthenticationRequired: return .rejected("no credential")
            case .cannotFindHost, .dnsLookupFailed: return .rejected("host does not resolve")
            default: return .unreachable(url.localizedDescription)
            }
        }
        if let github = error as? GitHubError {
            switch github {
            case .http(let status, _):
                return status < 0 ? .unreachable("no response") : classify(HTTPStatusError(status: status))
            case .deferred:
                // The client owns the exact deadline; do not turn a local
                // budget pause into a 30-minute credential rejection.
                return .unreachable(github.localizedDescription)
            }
        }
        // A missing or broken `gh` login: every request would fail the same
        // way, and each one re-spawns the CLI to ask again.
        if error is GHTokenError { return .rejected(error.localizedDescription) }
        return .unreachable(error.localizedDescription)
    }
}

/// A probe's answer: the value, or why the far side didn't give one.
///
/// Clients that used to return `[]` for both "nothing to report" and "I never
/// got through" report through this instead — the breaker cannot back off
/// from a failure it can't see.
enum ProbeResult<Value: Sendable>: Sendable {
    case value(Value)
    case failed(ProbeFailure)

    /// For sidecar requests whose failure doesn't decide anything — the
    /// decision belongs to the one call the caller probed with.
    var value: Value? {
        if case .value(let value) = self { return value }
        return nil
    }
}

/// Circuit breaker in front of every remote probe.
///
/// Pultík polls a lot: ~18 connections per refresh, every 30–90s, plus a full
/// refresh on every panel open. That is fine while the far side is answering
/// and actively harmful once it isn't — a failing poll is an authentication or
/// connection attempt repeated ~1000×/day against boxes that ban on exactly
/// that pattern (which is how a fresh VPN-only ssh setup banned this Mac
/// within seconds of Pultík being open).
///
/// So: the first failure of a target pauses that whole target, each further
/// failure pauses it longer, and a refusal skips straight to the long end. A
/// pause that expires buys ONE cheap request to prove the host is back — never
/// the full fan-out, which is what made the storm in the first place.
@MainActor
@Observable
final class ProbeGate {
    static let shared = ProbeGate()

    enum Verdict {
        /// Healthy — do the normal work.
        case go
        /// The pause expired: one cheap request only, to test the water.
        case trial
        /// Still paused. Don't touch the host at all.
        case hold
    }

    struct Pause: Identifiable, Sendable {
        let target: ProbeTarget
        let reason: String
        let until: Date
        /// The far side refused us, as opposed to never answering.
        let rejected: Bool

        var id: String { target.rawValue }
        var remaining: TimeInterval { max(0, until.timeIntervalSinceNow) }
    }

    private(set) var pauses: [ProbeTarget: Pause] = [:]
    private var strikes: [ProbeTarget: Int] = [:]

    /// 2m → 5m → 10m → 20m → 30m → 1h. The first step alone turns a failing
    /// 30-second poll into something no rate limiter notices; the tail is
    /// sized against fail2ban's usual hour-long bantime, so a ban expires
    /// before Pultík knocks enough times to earn another.
    private static let backoff: [TimeInterval] = [120, 300, 600, 1200, 1800, 3600]

    private let pathMonitor = NWPathMonitor()
    private var lastPathRetry: Date?

    private init() {
        // The mesh coming up, or Wi-Fi reconnecting, is the one piece of news
        // worth interrupting a backoff for: without it, plugging back into the
        // VPN means sitting out the rest of an hour before anything reloads.
        pathMonitor.pathUpdateHandler = { [weak self] path in
            guard path.status == .satisfied else { return }
            Task { @MainActor in self?.networkPathBecameUsable() }
        }
        pathMonitor.start(queue: DispatchQueue(label: "dev.example.pultik.probe-path"))
    }

    /// Brings every *unreachable* pause forward to "expired" — so the next
    /// refresh spends ONE trial request per target instead of the full fan-out,
    /// and a target that is still down re-arms further up the ladder rather
    /// than starting over.
    ///
    /// Refusals are deliberately left alone: a 403 or an ssh key the server
    /// won't take has nothing to do with which interface we're on, and a
    /// flapping link must never turn into a retry loop against a host that is
    /// already counting our failures.
    private func networkPathBecameUsable() {
        if let last = lastPathRetry, Date().timeIntervalSince(last) < 60 { return }
        let revivable = pauses.filter { !$0.value.rejected && $0.value.until > Date() }
        guard !revivable.isEmpty else { return }
        lastPathRetry = Date()
        for (target, pause) in revivable {
            pauses[target] = Pause(target: target, reason: pause.reason,
                                   until: Date(), rejected: false)
        }
        NSLog("pultik: network path changed — %d probe(s) eligible to retry", revivable.count)
    }

    var activePauses: [Pause] {
        let now = Date()
        return pauses.values.filter { $0.until > now }.sorted { $0.until < $1.until }
    }

    var isPaused: Bool { !activePauses.isEmpty }

    /// Read-only check, for work that rides along on someone else's probe
    /// (devbox's container metrics need Prometheus; the palette's Sentry
    /// search needs Sentry). Never hands out a trial — only `verdict` does.
    func isPaused(_ target: ProbeTarget) -> Bool {
        (pauses[target]?.until ?? .distantPast) > Date()
    }

    /// May this target be touched right now?
    func verdict(_ target: ProbeTarget) -> Verdict {
        guard let pause = pauses[target] else { return .go }
        if pause.until > Date() { return .hold }
        // Re-arm before handing out the trial. A caller that forgets to record
        // its outcome then costs one request a minute — not one per poll,
        // which is the storm this class exists to prevent.
        pauses[target] = Pause(
            target: target,
            reason: pause.reason,
            until: Date().addingTimeInterval(60),
            rejected: pause.rejected
        )
        return .trial
    }

    func succeeded(_ target: ProbeTarget) {
        pauses[target] = nil
        strikes[target] = nil
    }

    func failed(_ target: ProbeTarget, _ failure: ProbeFailure) {
        let rejected: Bool
        switch failure {
        case .rejected: rejected = true
        case .unreachable: rejected = false
        }
        var count = (strikes[target] ?? 0) + 1
        // A refusal skips the gentle end of the ladder outright: those are the
        // attempts that get counted against us, so the second one must not
        // arrive two minutes later.
        if rejected { count = max(count, 5) }
        strikes[target] = count

        let wait = Self.backoff[min(count - 1, Self.backoff.count - 1)]
        pauses[target] = Pause(
            target: target,
            reason: failure.reason,
            until: Date().addingTimeInterval(wait),
            rejected: rejected
        )
        NSLog("pultik: probe %@ paused for %.0fs — %@", target.rawValue, wait, failure.reason)
    }

    /// The user asked, explicitly (the footer's refresh button). Every breaker
    /// closes and the next refresh probes for real — the one path allowed to
    /// knock on a host that just refused us, because a person decided to.
    func resumeAll() {
        pauses.removeAll()
        strikes.removeAll()
    }

    /// One line per paused target — the footer indicator's tooltip.
    var summary: String {
        activePauses
            .map { "\($0.target.label): \($0.reason) — retry in \(Self.compact($0.remaining))" }
            .joined(separator: "\n")
    }

    private static func compact(_ interval: TimeInterval) -> String {
        let seconds = Int(interval.rounded(.up))
        return seconds >= 60 ? "\(seconds / 60)m" : "\(seconds)s"
    }
}
