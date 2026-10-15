import Foundation

/// Instant PromQL queries against the central Prometheus on the WireGuard
/// mesh (192.0.2.10:9090 — BuildServer; holds node/cadvisor/blackbox series for
/// every host, the remote-written ones labelled `cluster`). No auth; off-mesh
/// every call fails fast and the rails hide.
actor MetricsClient {
    static let shared = MetricsClient()
    /// The mesh host the estate's rules are read from — Now's identity for them.
    static let origin = "192.0.2.10"

    private let base = URL(string: "http://\(MetricsClient.origin):9090")!
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

    /// The Loki ruler on the same host — its LogQL rules fire here, not in
    /// Prometheus, and its rules API speaks Prometheus's alert shape.
    private let lokiBase = URL(string: "http://192.0.2.10:3100")!

    /// Both rule evaluators' alerts (the right rail's alert rows). nil when
    /// Prometheus does not answer; a Loki that does not answer drops only its
    /// own alerts, logged — the rail still shows what Prometheus knows.
    /// `answered` says which evaluators replied, so the notification watch
    /// never reads a silent Loki as its rules resolving.
    func firingAlerts() async -> (alerts: [FiringAlert], answered: Set<FiringAlert.Source>)? {
        guard let prometheus = await alerts(at: base.appending(path: "api/v1/alerts"), source: .prometheus) else {
            return nil
        }
        let loki = await alerts(at: lokiBase.appending(path: "prometheus/api/v1/alerts"), source: .loki)
        if loki == nil { NSLog("pultik: loki ruler alerts unavailable") }
        return (prometheus + (loki ?? []), loki == nil ? [.prometheus] : [.prometheus, .loki])
    }

    private func alerts(at url: URL, source: FiringAlert.Source) async -> [FiringAlert]? {
        do {
            let (data, response) = try await session.data(from: url)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            return FiringAlert.decode(data, source: source)
        } catch {
            return nil
        }
    }

    /// Where a Prometheus alert's row opens: its rules page narrowed to it.
    /// Loki has no UI of its own — its rows open nothing.
    nonisolated func alertsPage(for name: String) -> URL? {
        var components = URLComponents(url: base.appending(path: "alerts"), resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "search", value: name)]
        return components?.url
    }

    /// A host or one of its guests: `instance`, plus `vm_host` for a guest —
    /// both BuildServers run a guest named `firefly-vm`.
    struct Machine: Hashable {
        let instance: String
        let vmHost: String?
    }

    /// machine → value, for a query returning one sample per instance.
    private func instantByMachine(_ query: String) async throws -> [Machine: Double] {
        Dictionary(try await instantSeries(query).compactMap { sample in
            guard let instance = sample.labels["instance"] else { return nil }
            return (Machine(instance: instance, vmHost: sample.labels["vm_host"]), sample.value)
        }, uniquingKeysWith: { _, last in last })
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

    /// Stay in Pultík D7: the jobs our CI runs right now (one series each,
    /// carrying its run link) and each lane's backlog — two instant queries,
    /// the CI watch's whole read. Throws when Prometheus does not answer:
    /// the watch must not read silence as "every job finished".
    func liveJobs() async throws -> (jobs: [CIJob], queued: [String: Int]) {
        async let jobsQuery = instantSeries("ci_runner_job_info == 1")
        async let queuedQuery = instantSeries("sum by (lane) (ci_jobs_queued)")
        let (jobSeries, queuedSeries) = try await (jobsQuery, queuedQuery)
        let jobs = jobSeries.compactMap { series -> CIJob? in
            let labels = series.labels
            guard let lane = labels["lane"] else { return nil }
            return CIJob(org: labels["org"] ?? "", repo: labels["repo"] ?? "?", lane: lane,
                         workflow: labels["workflow"] ?? "", jobName: labels["job_name"] ?? "",
                         runURL: labels["run_url"].flatMap(URL.init(string:)),
                         since: labels["since"].flatMap(Double.init).map(Date.init(timeIntervalSince1970:)))
        }
        var queued: [String: Int] = [:]
        for series in queuedSeries {
            if let lane = series.labels["lane"] { queued[lane] = Int(series.value) }
        }
        return (jobs, queued)
    }

    /// Every host's JIT fleet, lane by lane, each lane tagged with the host
    /// whose Firefly runs it. Runners are per-job and nameless since
    /// 2026-08-30, so the stable unit is the controller instance
    /// (`ci_kvm_controller_up`), its occupancy the collector's per-job series
    /// (`ci_runner_job_info`, link included) and its backlog
    /// `ci_jobs_queued`. `ci_lane_info` carries each lane's repo, tier and job
    /// kind; lanes have no ceilings since 2026-09-26 — each host's pool comes
    /// from its own Semafor (`SemaforClient`). Jobs on lanes that are not
    /// ours (`github-hosted`, `unknown`) are kept aside as `elsewhere`.
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

        var laneInfo: [String: (tier: Int?, kind: String?, repo: String?)] = [:]
        func byRunner(_ samples: [(labels: [String: String], value: Double)]?) -> [String: Double] {
            Dictionary((samples ?? []).compactMap { sample in
                guard let runner = sample.labels["runner"], sample.value.isFinite, sample.value >= 0 else { return nil }
                return (runner, sample.value)
            }, uniquingKeysWith: { first, _ in first })
        }
        let cpuByRunner = byRunner(runnerCPU)
        let memoryByRunner = byRunner(runnerMemory)
        for series in info ?? [] {
            if let lane = series.labels["lane"] {
                laneInfo[lane] = (series.labels["tier"].flatMap(Int.init), series.labels["kind"], series.labels["repo"])
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
            // scrape target's own `instance` — the host whose Firefly runs
            // the lane — and moves the lane to `exported_instance` on the
            // way in. Never the hostname: the live box reports
            // build-server-next's.
            let exported = series.labels["exported_instance"]
            guard let name = exported ?? series.labels["instance"] else { continue }
            known.insert(name)
            board.lanes.append(CILane(
                name: name,
                backend: series.labels["backend"] ?? "",
                trustGroup: series.labels["trust_group"] ?? "",
                up: series.value > 0,
                host: exported == nil ? series.labels["cluster"] : series.labels["instance"],
                repo: laneInfo[name]?.repo,
                tier: laneInfo[name]?.tier,
                kind: laneInfo[name]?.kind,
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

    /// Every configured server, each followed by the VM guests whose
    /// `vm_host` is its instance (devbox-c and firefly-vm under
    /// build-server-next) — found in the same queries' answers, at no extra
    /// query. Guests are split per host, never merged across hosts.
    func serverMetrics(servers: [(name: String, instance: String)]) async -> [ServerMetrics] {
        async let cores = try? instantByMachine(#"count by (instance, vm_host) (node_cpu_seconds_total{mode="idle"})"#)
        async let cpu = try? instantByMachine(
            #"100 * (1 - avg by (instance, vm_host) (rate(node_cpu_seconds_total{mode="idle"}[5m])))"#
        )
        async let ram = try? instantByMachine(
            #"100 * (1 - node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes)"#
        )
        async let disk = try? instantByMachine(
            #"100 * (1 - node_filesystem_avail_bytes{mountpoint="/",fstype!~"tmpfs|overlay"} / node_filesystem_size_bytes{mountpoint="/",fstype!~"tmpfs|overlay"})"#
        )
        // Absolute bytes as well as the percentage: the footer reads "18/32 GB",
        // which a ratio alone can't answer.
        async let ramUsed = try? instantByMachine(
            #"node_memory_MemTotal_bytes - node_memory_MemAvailable_bytes"#
        )
        async let ramTotal = try? instantByMachine(#"node_memory_MemTotal_bytes"#)
        async let diskUsed = try? instantByMachine(
            #"node_filesystem_size_bytes{mountpoint="/",fstype!~"tmpfs|overlay"} - node_filesystem_avail_bytes{mountpoint="/",fstype!~"tmpfs|overlay"}"#
        )
        async let diskTotal = try? instantByMachine(
            #"node_filesystem_size_bytes{mountpoint="/",fstype!~"tmpfs|overlay"}"#
        )
        // build-server-next's ZFS observer (build-server-infra decisions row 33):
        // pool fill and the quota'd datasets; absent on every other host.
        async let poolUsed = try? instantSeries("zfs_pool_allocated_bytes")
        async let poolSize = try? instantSeries("zfs_pool_size_bytes")
        async let datasetUsed = try? instantSeries("zfs_dataset_used_bytes")
        async let datasetQuota = try? instantSeries("zfs_dataset_quota_bytes > 0")
        let (cpuMap, ramMap, diskMap) = await (cpu, ram, disk)
        let coreMap = await cores
        let (ramUsedMap, ramTotalMap, diskUsedMap, diskTotalMap) =
            await (ramUsed, ramTotal, diskUsed, diskTotal)
        let pools = await Self.zfs(used: poolUsed, total: poolSize, name: "pool")
        let datasets = await Self.zfs(used: datasetUsed, total: datasetQuota, name: "dataset")
        guard cpuMap != nil || ramMap != nil || diskMap != nil else { return [] }

        func metrics(_ name: String, _ machine: Machine) -> ServerMetrics {
            ServerMetrics(
                name: name,
                instance: machine.instance,
                vmHost: machine.vmHost,
                cpu: cpuMap?[machine],
                ram: ramMap?[machine],
                disk: diskMap?[machine],
                ramUsedBytes: ramUsedMap?[machine],
                ramTotalBytes: ramTotalMap?[machine],
                diskUsedBytes: diskUsedMap?[machine],
                diskTotalBytes: diskTotalMap?[machine],
                cpuCount: coreMap?[machine].map(Int.init),
                pools: machine.vmHost == nil ? pools[machine.instance] ?? [] : [],
                datasets: machine.vmHost == nil ? datasets[machine.instance] ?? [] : []
            )
        }
        let hosts = Set(servers.map(\.instance))
        let guests = Set([coreMap, ramMap].compactMap { $0 }.flatMap(\.keys))
            .filter { $0.vmHost.map(hosts.contains) ?? false }
        return servers.flatMap { server in
            [metrics(server.name, Machine(instance: server.instance, vmHost: nil))]
                + guests.filter { $0.vmHost == server.instance }
                .sorted { $0.instance < $1.instance }
                .map { metrics($0.instance, $0) }
        }
    }

    /// instance → its pools or datasets, largest first; a guest has none.
    private static func zfs(used: [(labels: [String: String], value: Double)]?,
                            total: [(labels: [String: String], value: Double)]?,
                            name label: String) -> [String: [ZFSUsage]] {
        var totals: [String: Double] = [:]
        for sample in total ?? [] {
            guard let instance = sample.labels["instance"], let name = sample.labels[label] else { continue }
            totals["\(instance)\u{0}\(name)"] = sample.value
        }
        var byInstance: [String: [ZFSUsage]] = [:]
        for sample in used ?? [] where sample.labels["vm_host"] == nil {
            guard let instance = sample.labels["instance"], let name = sample.labels[label],
                  let total = totals["\(instance)\u{0}\(name)"], total > 0 else { continue }
            byInstance[instance, default: []].append(ZFSUsage(name: name, usedBytes: sample.value, totalBytes: total))
        }
        return byInstance.mapValues { $0.sorted { $0.totalBytes > $1.totalBytes } }
    }

    func serviceStatuses(services: [(name: String, probe: String, host: String?, job: String?)]) async -> [ServiceStatus] {
        async let up = try? instantSeries("probe_success")
        async let duration = try? instantSeries("probe_duration_seconds")
        let (upSeries, durationSeries) = await (up, duration)
        guard let upSeries else { return [] }
        let upMap = Self.byJobInstance(upSeries)
        let durationMap = Self.byJobInstance(durationSeries ?? [])
        return services.map { service in
            ServiceStatus(
                name: service.name,
                probe: service.probe,
                host: service.host,
                up: Self.pick(upMap, instance: service.probe, job: service.job, worst: min).map { $0 > 0 },
                latencySeconds: Self.pick(durationMap, instance: service.probe, job: service.job, worst: max)
            )
        }
    }

    /// One probe instance can sit in several blackbox jobs (`https://exampleapp.app`
    /// is in blackbox-http AND blackbox-ssl). Keyed by instance alone the last
    /// series silently won, so a tile could show the certificate check's
    /// answer instead of the site's.
    private struct JobInstance: Hashable {
        let job: String
        let instance: String
    }

    private static func byJobInstance(_ series: [(labels: [String: String], value: Double)]) -> [JobInstance: Double] {
        Dictionary(series.compactMap { sample in
            guard let instance = sample.labels["instance"] else { return nil }
            return (JobInstance(job: sample.labels["job"] ?? "", instance: instance), sample.value)
        }, uniquingKeysWith: { first, _ in first })
    }

    /// The service's own job when it names one; otherwise every non-ssl job
    /// probing that instance, reduced to the worst value — a site is only up
    /// when every probe of it says so.
    private static func pick(_ map: [JobInstance: Double], instance: String, job: String?,
                             worst: (Double, Double) -> Double) -> Double? {
        if let job { return map[JobInstance(job: job, instance: instance)] }
        return map.filter { $0.key.instance == instance && !$0.key.job.hasSuffix("ssl") }
            .values.reduce(nil) { acc, value in acc.map { worst($0, value) } ?? value }
    }
}
