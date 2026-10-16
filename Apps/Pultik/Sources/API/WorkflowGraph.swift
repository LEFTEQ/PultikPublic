import Foundation

/// A run's job graph (stay in Pultík D11): the `needs:` of its workflow
/// file at the run's head, read from the git mirror, as waves — every job
/// in a wave needs only jobs in earlier ones. Without the file (no mirror,
/// a deleted workflow) the jobs' start times make the waves. The run card
/// orders its jobs column by it and draws it as the mini graph beside its
/// title. Foundation-only: `Tests/WorkflowGraphTests.swift`.
struct WorkflowGraph: Codable, Equatable, Sendable {
    /// One job of the workflow file: its key, display name and needs.
    struct Node: Codable, Equatable, Sendable {
        let key: String
        let name: String?
        let needs: [String]
    }

    let nodes: [Node]

    /// Just enough YAML for `jobs.<key>.name` and `jobs.<key>.needs` (a
    /// scalar, a flow list or a block list). Anything else is skipped.
    static func parse(_ yaml: String) -> WorkflowGraph {
        var nodes: [Node] = []
        var inJobs = false
        var jobIndent: Int?
        var current: (key: String, name: String?, needs: [String])?
        /// The indent of the current job's own keys (its first line's).
        var propertyIndent: Int?
        var readingNeeds: Int?
        func flush() {
            if let job = current { nodes.append(Node(key: job.key, name: job.name, needs: job.needs)) }
            current = nil
        }
        for raw in yaml.components(separatedBy: .newlines) {
            let line = raw.replacingOccurrences(of: "\t", with: "  ")
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            let indent = line.prefix { $0 == " " }.count
            if indent == 0 {
                flush()
                inJobs = trimmed == "jobs:"
                jobIndent = nil
                continue
            }
            guard inJobs else { continue }
            if jobIndent == nil { jobIndent = indent }
            if indent == jobIndent, trimmed.hasSuffix(":") {
                flush()
                current = (unquoted(String(trimmed.dropLast())), nil, [])
                readingNeeds = nil
                propertyIndent = nil
                continue
            }
            guard current != nil, let jobIndent, indent > jobIndent else { continue }
            if propertyIndent == nil { propertyIndent = indent }
            if let needsIndent = readingNeeds {
                if indent > needsIndent, trimmed.hasPrefix("- ") {
                    current?.needs.append(unquoted(String(trimmed.dropFirst(2))))
                    continue
                }
                readingNeeds = nil
            }
            if trimmed.hasPrefix("name:"), indent == propertyIndent, current?.name == nil {
                current?.name = unquoted(String(trimmed.dropFirst(5)))
            } else if trimmed.hasPrefix("needs:"), indent == propertyIndent {
                let value = (trimmed.dropFirst(6).split(separator: "#", maxSplits: 1).first.map(String.init) ?? "")
                    .trimmingCharacters(in: .whitespaces)
                if value.isEmpty {
                    readingNeeds = indent
                } else if value.hasPrefix("[") {
                    current?.needs = value.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
                        .split(separator: ",").map { unquoted(String($0)) }.filter { !$0.isEmpty }
                } else {
                    current?.needs = [unquoted(value)]
                }
            }
        }
        flush()
        return WorkflowGraph(nodes: nodes)
    }

    private static func unquoted(_ text: String) -> String {
        let value = text.trimmingCharacters(in: .whitespaces)
        let bare = value.split(separator: "#", maxSplits: 1).first.map(String.init)?
            .trimmingCharacters(in: .whitespaces) ?? value
        return bare.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
    }

    /// Each node's wave: 0 for a job that needs nothing, else one past its
    /// latest need. A cycle or an unknown need counts as wave 0.
    var waves: [String: Int] {
        let byKey = Dictionary(nodes.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        var memo: [String: Int] = [:]
        func wave(_ key: String, _ seen: Set<String>) -> Int {
            if let known = memo[key] { return known }
            guard let node = byKey[key], !seen.contains(key) else { return 0 }
            let value = node.needs.filter { byKey[$0] != nil }.map { wave($0, seen.union([key])) + 1 }.max() ?? 0
            memo[key] = value
            return value
        }
        for node in nodes { _ = wave(node.key, []) }
        return memo
    }

    /// The node a run's job belongs to: its display name is the node's name
    /// or key, or that followed by a matrix suffix (`test (ubuntu, 18)`).
    func node(for jobName: String) -> Node? {
        nodes.first { $0.name == jobName || $0.key == jobName }
            ?? nodes.first { node in [node.name, node.key].compactMap { $0 }.contains { jobName.hasPrefix("\($0) (") } }
    }

    /// Jobs into waves, by the graph; a job it does not know joins wave 0.
    func ordered(_ jobs: [CIRunJob]) -> [[CIRunJob]] {
        let waves = waves
        let grouped = Dictionary(grouping: jobs) { job in node(for: job.name).flatMap { waves[$0.key] } ?? 0 }
        return grouped.keys.sorted().map { grouped[$0]!.sorted(by: Self.started) }
    }

    /// No graph: jobs that started within `gap` of the wave's first are
    /// one wave; a job that never started closes the list.
    static func timingWaves(_ jobs: [CIRunJob], gap: TimeInterval = 20) -> [[CIRunJob]] {
        var waves: [[CIRunJob]] = []
        var waveStart: Date?
        for job in jobs.filter({ $0.startedAt != nil }).sorted(by: started) {
            if let start = waveStart, let at = job.startedAt, at.timeIntervalSince(start) <= gap {
                waves[waves.count - 1].append(job)
            } else {
                waves.append([job])
                waveStart = job.startedAt
            }
        }
        let pending = jobs.filter { $0.startedAt == nil }
        if !pending.isEmpty { waves.append(pending) }
        return waves
    }

    /// The job a card reads first: one that failed, else one still running,
    /// else the first wave's first.
    static func firstToRead(_ detail: CIRunDetail, waves: [[CIRunJob]]) -> CIRunJob? {
        detail.failingJob ?? detail.jobs.first { $0.status != .completed } ?? waves.first?.first
    }

    private static func started(_ lhs: CIRunJob, _ rhs: CIRunJob) -> Bool {
        (lhs.startedAt ?? .distantFuture, lhs.name) < (rhs.startedAt ?? .distantFuture, rhs.name)
    }
}
