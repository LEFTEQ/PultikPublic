import Foundation

/// Instant PromQL queries against the central Prometheus on the WireGuard
/// mesh (192.0.2.10:9090 — BuildServer; holds node/cadvisor/blackbox series for
/// BOTH VPSes). No auth; off-mesh every call fails fast and the rails hide.
actor MetricsClient {
    static let shared = MetricsClient()

    private let base = URL(string: "http://192.0.2.10:9090")!
    private let session: URLSession

    init() {
        session = PollingSession.make(timeout: 5)
    }

    /// One request, no series, no parsing — the half-open probe `ProbeGate`
    /// runs when a pause expires. A refresh fans out a dozen queries; asking
    /// all twelve just to find out the mesh is still down is the storm.
    func reachable() async -> Bool {
        var components = URLComponents(
            url: base.appending(path: "api/v1/query"), resolvingAgainstBaseURL: false
        )!
        components.queryItems = [URLQueryItem(name: "query", value: "1")]
        guard let (_, response) = try? await session.data(from: components.url!) else { return false }
        return (response as? HTTPURLResponse)?.statusCode == 200
    }

    /// instance label → value, for a query returning one sample per instance.
    private func instantByInstance(_ query: String) async throws -> [String: Double] {
        var components = URLComponents(
            url: base.appending(path: "api/v1/query"), resolvingAgainstBaseURL: false
        )!
        components.queryItems = [URLQueryItem(name: "query", value: query)]
        let (data, response) = try await session.data(from: components.url!)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dataField = body["data"] as? [String: Any],
              let results = dataField["result"] as? [[String: Any]]
        else { throw URLError(.badServerResponse) }

        var values: [String: Double] = [:]
        for result in results {
            guard let metric = result["metric"] as? [String: Any],
                  let instance = metric["instance"] as? String,
                  let value = result["value"] as? [Any],
                  let raw = value.last as? String,
                  let number = Double(raw)
            else { continue }
            values[instance] = number
        }
        return values
    }


    /// Full label sets for an instant query — for series whose identity spans
    /// several labels (bk_slot_held carries class/slot/label).
    private func instantSeries(_ query: String) async throws -> [(labels: [String: String], value: Double)] {
        var components = URLComponents(
            url: base.appending(path: "api/v1/query"), resolvingAgainstBaseURL: false
        )!
        components.queryItems = [URLQueryItem(name: "query", value: query)]
        let (data, response) = try await session.data(from: components.url!)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dataField = body["data"] as? [String: Any],
              let results = dataField["result"] as? [[String: Any]]
        else { throw URLError(.badServerResponse) }

        var series: [(labels: [String: String], value: Double)] = []
        for result in results {
            guard let metric = result["metric"] as? [String: Any],
                  let value = result["value"] as? [Any],
                  let raw = value.last as? String,
                  let number = Double(raw)
            else { continue }
            let labels = metric.compactMapValues { $0 as? String }
            series.append((labels: labels, value: number))
        }
        return series
    }

    /// BuildServer runner fleet for the grid: one cell per runner. The watchdog
    /// exporter only labels `{repo, runner}`, so lane/class ride in via a
    /// PromQL join against `ci_runner_lane_info` — the manifest-derived
    /// inventory metric. The join also scopes the grid to the hot fleet:
    /// ephemeral `ci-jit-*` bastion runners have no inventory row and drop
    /// out here, as decided. The bk-lock slot series are no longer rendered —
    /// the grid supersedes the slot bars (spec 2026-08-27).
    func runnerGrid() async -> [RunnerCell] {
        async let onlineQuery = try? instantSeries(
            "github_runner_online * on(runner) group_left(lane, class) ci_runner_lane_info")
        async let busyQuery = try? instantSeries("github_runner_busy == 1")
        let (online, busy) = await (onlineQuery, busyQuery)
        guard let online, !online.isEmpty else { return [] }

        let busyRunners = Set((busy ?? []).compactMap { $0.labels["runner"] })
        let classOrder = ["build", "small", "e2e"]
        return online.compactMap { series -> RunnerCell? in
            guard let runner = series.labels["runner"] else { return nil }
            return RunnerCell(
                fullName: runner,
                lane: series.labels["lane"] ?? "",
                klass: series.labels["class"] ?? "",
                busy: busyRunners.contains(runner),
                online: series.value > 0)
        }
        .sorted {
            let left = (classOrder.firstIndex(of: $0.klass) ?? classOrder.count, $0.lane, $0.name)
            let right = (classOrder.firstIndex(of: $1.klass) ?? classOrder.count, $1.lane, $1.name)
            return left < right
        }
    }

    func serverMetrics(servers: [(name: String, instance: String)]) async -> [ServerMetrics] {
        async let cpu = try? instantByInstance(
            #"100 * (1 - avg by (instance) (rate(node_cpu_seconds_total{mode="idle"}[5m])))"#
        )
        async let ram = try? instantByInstance(
            #"100 * (1 - node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes)"#
        )
        async let disk = try? instantByInstance(
            #"100 * (1 - node_filesystem_avail_bytes{mountpoint="/",fstype!~"tmpfs|overlay"} / node_filesystem_size_bytes{mountpoint="/",fstype!~"tmpfs|overlay"})"#
        )
        // Absolute bytes as well as the percentage: the footer reads "18/32 GB",
        // which a ratio alone can't answer.
        async let ramUsed = try? instantByInstance(
            #"node_memory_MemTotal_bytes - node_memory_MemAvailable_bytes"#
        )
        async let ramTotal = try? instantByInstance(#"node_memory_MemTotal_bytes"#)
        async let diskUsed = try? instantByInstance(
            #"node_filesystem_size_bytes{mountpoint="/",fstype!~"tmpfs|overlay"} - node_filesystem_avail_bytes{mountpoint="/",fstype!~"tmpfs|overlay"}"#
        )
        async let diskTotal = try? instantByInstance(
            #"node_filesystem_size_bytes{mountpoint="/",fstype!~"tmpfs|overlay"}"#
        )
        let (cpuMap, ramMap, diskMap) = await (cpu, ram, disk)
        let (ramUsedMap, ramTotalMap, diskUsedMap, diskTotalMap) =
            await (ramUsed, ramTotal, diskUsed, diskTotal)
        guard cpuMap != nil || ramMap != nil || diskMap != nil else { return [] }
        return servers.map { server in
            ServerMetrics(
                name: server.name,
                instance: server.instance,
                cpu: cpuMap?[server.instance],
                ram: ramMap?[server.instance],
                disk: diskMap?[server.instance],
                ramUsedBytes: ramUsedMap?[server.instance],
                ramTotalBytes: ramTotalMap?[server.instance],
                diskUsedBytes: diskUsedMap?[server.instance],
                diskTotalBytes: diskTotalMap?[server.instance]
            )
        }
    }

    func serviceStatuses(services: [(name: String, probe: String, host: String?)]) async -> [ServiceStatus] {
        async let up = try? instantByInstance("probe_success")
        async let duration = try? instantByInstance("probe_duration_seconds")
        let (upMap, durationMap) = await (up, duration)
        guard upMap != nil else { return [] }
        return services.map { service in
            ServiceStatus(
                name: service.name,
                probe: service.probe,
                host: service.host,
                up: upMap?[service.probe].map { $0 > 0 },
                latencySeconds: durationMap?[service.probe]
            )
        }
    }
}
