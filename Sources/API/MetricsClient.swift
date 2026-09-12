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
    /// several labels (`ci_runner_job_info` carries lane/repo/workflow/job).
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

    /// The BuildServer JIT fleet, lane by lane. Runners are per-job and
    /// nameless since 2026-08-30, so the stable unit is the controller
    /// instance (`ci_kvm_controller_up`), its occupancy the collector's
    /// per-job series (`ci_runner_job_info`, link included) and its backlog
    /// `ci_jobs_queued`. Ceilings ride in on `ci_lane_info` when the infra
    /// side exports it; until then `maxRunners` is nil and rows show counts
    /// only (spec 2026-09-09). Jobs on lanes that are not ours
    /// (`github-hosted`, `unknown`) are kept aside as `elsewhere`.
    func laneBoard() async -> CILaneBoard {
        async let controllersQuery = try? instantSeries("ci_kvm_controller_up")
        async let infoQuery = try? instantSeries("ci_lane_info")
        async let runnerCPUQuery = try? instantSeries("100 * rate(ci_runner_cpu_seconds_total[2m]) and on(runner) (time() - ci_runner_observed_timestamp_seconds < 90)")
        async let runnerMemoryQuery = try? instantSeries("ci_runner_memory_bytes and on(runner) (time() - ci_runner_observed_timestamp_seconds < 90)")
        async let jobsQuery = try? instantSeries("ci_runner_job_info == 1")
        async let queuedQuery = try? instantSeries("sum by (lane) (ci_jobs_queued)")
        let (controllers, info, jobs, queued) = await (controllersQuery, infoQuery, jobsQuery, queuedQuery)
        let (runnerCPU, runnerMemory) = await (runnerCPUQuery, runnerMemoryQuery)
        guard let controllers, !controllers.isEmpty else { return CILaneBoard() }

        var ceilings: [String: Int] = [:]
        func byRunner(_ samples: [(labels: [String: String], value: Double)]?) -> [String: Double] {
            Dictionary((samples ?? []).compactMap { sample in
                guard let runner = sample.labels["runner"], sample.value.isFinite, sample.value >= 0 else { return nil }
                return (runner, sample.value)
            }, uniquingKeysWith: { first, _ in first })
        }
        let cpuByRunner = byRunner(runnerCPU)
        let memoryByRunner = byRunner(runnerMemory)
        for series in info ?? [] {
            if let lane = series.labels["lane"], let max = series.labels["max_runners"].flatMap(Int.init) {
                ceilings[lane] = max
            }
        }
        var queuedByLane: [String: Int] = [:]
        for series in queued ?? [] {
            if let lane = series.labels["lane"] { queuedByLane[lane] = Int(series.value) }
        }
        var jobsByLane: [String: [CIJob]] = [:]
        for series in jobs ?? [] {
            let labels = series.labels
            guard let lane = labels["lane"] else { continue }
            let job = CIJob(
                org: labels["org"] ?? "",
                repo: labels["repo"] ?? "?",
                lane: lane,
                workflow: labels["workflow"] ?? "",
                jobName: labels["job_name"] ?? "",
                runURL: labels["run_url"].flatMap(URL.init(string:)),
                since: labels["since"].flatMap(Double.init).map(Date.init(timeIntervalSince1970:)),
                cpuPercent: labels["runner"].flatMap { cpuByRunner[$0] },
                memoryBytes: labels["runner"].flatMap { memoryByRunner[$0] })
            jobsByLane[lane, default: []].append(job)
        }

        let groupOrder = ["firefly", "bastion"]
        var board = CILaneBoard()
        var known = Set<String>()
        for series in controllers {
            // The exporter labels the lane `instance`; Prometheus keeps the
            // scrape target's own `instance` and moves the lane to
            // `exported_instance` on the way in.
            guard let name = series.labels["exported_instance"] ?? series.labels["instance"] else { continue }
            known.insert(name)
            board.lanes.append(CILane(
                name: name,
                backend: series.labels["backend"] ?? "",
                trustGroup: series.labels["trust_group"] ?? "",
                up: series.value > 0,
                maxRunners: ceilings[name],
                queued: queuedByLane[name] ?? 0,
                jobs: (jobsByLane[name] ?? []).sorted { ($0.since ?? .distantPast) < ($1.since ?? .distantPast) }))
        }
        board.lanes.sort {
            let left = (groupOrder.firstIndex(of: $0.trustGroup) ?? groupOrder.count, $0.name)
            let right = (groupOrder.firstIndex(of: $1.trustGroup) ?? groupOrder.count, $1.name)
            return left < right
        }
        for (lane, laneJobs) in jobsByLane where !known.contains(lane) {
            board.elsewhere.append(contentsOf: laneJobs)
        }
        board.elsewhere.sort { ($0.since ?? .distantPast) < ($1.since ?? .distantPast) }
        board.elsewhereQueued = queuedByLane.filter { !known.contains($0.key) }.values.reduce(0, +)
        return board
    }

    func serverMetrics(servers: [(name: String, instance: String)]) async -> [ServerMetrics] {
        async let cores = try? instantByInstance(#"count by (instance) (node_cpu_seconds_total{mode="idle"})"#)
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
        let coreMap = await cores
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
                diskTotalBytes: diskTotalMap?[server.instance],
                cpuCount: coreMap?[server.instance].map(Int.init)
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
