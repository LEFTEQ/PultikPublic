import SwiftUI

/// A service whose liveness Pultík already tracks through `ProbeGate`.
///
/// The row is passive: status is read off the breaker's pauses — opening
/// Settings costs zero requests. Test runs the service's one cheap probe and
/// reports the outcome to the gate exactly like a scheduled poll would, so a
/// test that fails backs the service off instead of hammering it.
@MainActor
@Observable
final class ProbeIntegration: Integration {
    let id: String
    let title: String
    let symbol: String
    let blurb: String
    let canTest = true

    private let target: ProbeTarget
    /// nil = success; the failure otherwise. The closure does NOT report to
    /// the gate — `test()` owns that, so it happens exactly once.
    private let probe: @MainActor () async -> ProbeFailure?
    /// A credential this service needs, editable in the row. nil for the
    /// services whose reachability is all there is to configure.
    private let token: TokenSlot?

    private var testVerdict: IntegrationStatus?
    private var isTesting = false

    init(id: String, title: String, symbol: String, blurb: String,
         target: ProbeTarget, token: TokenSlot? = nil,
         probe: @escaping @MainActor () async -> ProbeFailure?) {
        self.id = id
        self.title = title
        self.symbol = symbol
        self.blurb = blurb
        self.target = target
        self.token = token
        self.probe = probe
    }

    var status: IntegrationStatus {
        if isTesting { return .testing }
        if let testVerdict { return testVerdict }
        if let pause = ProbeGate.shared.pauses[target], pause.until > Date() {
            let wait = Int(max(1, pause.remaining / 60))
            return pause.rejected
                ? .error("refused: \(pause.reason)")
                : .attention("paused \(wait)m — \(pause.reason)")
        }
        return .connected("no recent failures")
    }

    func test() async {
        isTesting = true
        defer { isTesting = false }
        if let failure = await probe() {
            ProbeGate.shared.failed(target, failure)
            testVerdict = .error(failure.reason)
        } else {
            ProbeGate.shared.succeeded(target)
            testVerdict = .connected("test passed \(Date.now.formatted(date: .omitted, time: .shortened))")
        }
    }

    var detail: AnyView {
        AnyView(
            VStack(alignment: .leading, spacing: 8) {
                Text(blurb)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if case .error = status {
                    Text("Backed off by the probe breaker — Test retries once and re-arms it.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let token {
                    TokenEditor(slot: token)
                }
            }
        )
    }
}

extension ProbeIntegration {
    static func eve(store: StatusStore) -> ProbeIntegration {
        ProbeIntegration(
            id: "eve", title: "eve", symbol: "sparkles",
            blurb: "Alerts, PR sessions and /ask — assistant-service over the WireGuard mesh.",
            target: .eve,
            token: TokenSlot(
                placeholder: "evk_ token",
                footnote: "Sent as a bearer token on every eve call once eve's RBAC gate is on. Blank falls back to PULTIK_EVE_TOKEN in ~/.claude/.env.",
                read: { store.eveToken },
                write: { store.setEveToken($0) }
            )
        ) {
            // The client classifies for us — a 401 on the configured token is a
            // refusal, not silence, and must re-arm the breaker as one.
            await EveClient.shared.probeHealth(settingsToken: store.eveToken)
        }
    }

    static func vitrinka() -> ProbeIntegration {
        ProbeIntegration(
            id: "vitrinka", title: "vitrinka", symbol: "dot.radiowaves.left.and.right",
            blurb: "Annotation-board listeners and the todo engine (open todos, ripe reminders) — read with the CLI's sign-in.",
            target: .vitrinka
        ) {
            if case .failed(let failure) = await VitrinkaClient.shared.tray() {
                return failure
            }
            return nil
        }
    }

    static func devbox() -> ProbeIntegration {
        ProbeIntegration(
            id: "devbox", title: "devbox (ssh)", symbol: "terminal",
            blurb: "Remote ws-v2 workspaces on BuildServer, over ssh. Failures here back off hard — sshd sits behind fail2ban.",
            target: .devbox
        ) {
            if case .failed(let failure) = await DevboxClient.shared.status() {
                return failure
            }
            return nil
        }
    }

    static func metrics() -> ProbeIntegration {
        ProbeIntegration(
            id: "metrics", title: "Server metrics", symbol: "chart.xyaxis.line",
            blurb: "Prometheus on BuildServer — server gauges, service probes, runner lanes.",
            target: .prometheus
        ) {
            await MetricsClient.shared.reachable()
                ? nil : .unreachable("prometheus not answering (mesh down?)")
        }
    }
}
