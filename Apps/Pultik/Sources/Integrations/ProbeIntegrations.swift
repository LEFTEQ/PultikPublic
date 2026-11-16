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

    private var testVerdict: IntegrationStatus?
    private var isTesting = false

    init(id: String, title: String, symbol: String, blurb: String,
         target: ProbeTarget,
         probe: @escaping @MainActor () async -> ProbeFailure?) {
        self.id = id
        self.title = title
        self.symbol = symbol
        self.blurb = blurb
        self.target = target
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
            }
        )
    }
}

extension ProbeIntegration {
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
