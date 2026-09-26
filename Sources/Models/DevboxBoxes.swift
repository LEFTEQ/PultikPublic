import Foundation

// MARK: - One devbox over several guests (spec 2026-09-25)
//
// The devbox CLI drives every guest in its `boxes.yaml` as ONE box; Pultík
// polls each guest's overview and shows the estate as one devbox. Pure
// values, Foundation-only, so the devbox-contract harness tests discovery,
// the merge and the row tagging without the app. `DevboxClient` runs the
// processes; nothing here spawns one.

/// Project names and slot slugs arrive in `devbox status --json` — over the
/// network, from a machine — and end up interpolated into shell commands. One
/// of those shells runs on THIS Mac (the Warp launch config), so a crafted
/// payload would be remote JSON turning into local code execution.
///
/// They are VALIDATED, not escaped. Every name devbox mints is
/// `[A-Za-z0-9._-]`, so anything else is refused outright — "quote it
/// cleverly" is the approach that eventually loses.
enum DevboxName {
    static func isValid(_ value: String) -> Bool {
        !value.isEmpty
            && value.count <= 64
            && value.range(of: "^[A-Za-z0-9._-]+$", options: .regularExpression) != nil
    }

    /// "devbox up" + project + optional slug, or nil if either is unsafe.
    static func command(_ verb: String, _ project: String, _ slug: String?) -> String? {
        guard isValid(project) else {
            NSLog("pultik: refusing devbox command — unsafe project name")
            return nil
        }
        guard let slug, !slug.isEmpty else { return "\(verb) \(project)" }
        guard isValid(slug) else {
            NSLog("pultik: refusing devbox command — unsafe slug")
            return nil
        }
        return "\(verb) \(project) \(slug)"
    }
}

/// Where one guest's forced-command sshd listens. `sshAlias` is the Mac's
/// full-shell alias for the same guest — only a human's Warp attach uses it;
/// the poll addresses `host:port` directly with Pultík's dedicated key.
struct DevboxEndpoint: Hashable, Sendable {
    let name: String
    let sshAlias: String
    let host: String
    let port: Int

    /// Today's single guest — what Pultík polls when discovery has never
    /// answered (an older CLI without `devbox boxes`, or none on this Mac).
    static let fallback = DevboxEndpoint(name: "a", sshAlias: "devops", host: "192.0.2.11", port: 2222)

    /// The forced-command key is authorized for the unprivileged `devbox`
    /// user on every guest; the login never comes from the user's config.
    var destination: String {
        "devbox@\(host)"
    }
}

/// `devbox boxes --json` → the boxes to poll, and `ssh -G <alias>` → where
/// each one listens. Every value crosses a process boundary into ssh's argv,
/// so each is validated to the same allowlist as a workspace name.
enum DevboxDiscovery {
    /// Rediscovered at launch and then this often; a failed discovery keeps
    /// the last good list.
    static let interval: TimeInterval = 600
    /// Each box costs an ssh poll every cycle and an `ssh -G` per discovery;
    /// a registry past this is a typo, not an estate. Rows past it are
    /// dropped (and logged), never the list.
    static let boxLimit = 8

    /// A registry row worth polling: state is anything but `off`.
    struct Candidate: Equatable {
        let name: String
        let sshAlias: String
    }

    private struct Envelope: Decodable {
        let ok: Bool
        let verb: String?
        let data: Payload?
    }

    private struct Payload: Decodable {
        let boxes: [Row]?
    }

    private struct Row: Decodable {
        let name: String
        let ssh: String
        let state: String
    }

    /// nil = no usable answer (older CLI's `CLI_UNKNOWN_VERB`, a failed
    /// envelope, unreadable output, or no box left to poll) — the caller keeps
    /// what it had. An invalid name or alias drops that row, never the list.
    static func candidates(fromBoxesJSON data: Data) -> [Candidate]? {
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: data),
              envelope.ok, envelope.verb == "boxes",
              let rows = envelope.data?.boxes
        else { return nil }
        var seen = Set<String>()
        let candidates = rows.compactMap { row -> Candidate? in
            guard row.state != "off" else { return nil }
            guard isSafeWord(row.name), isSafeWord(row.ssh), seen.insert(row.name).inserted else {
                NSLog("pultik: devbox discovery refused box row with an unsafe name or alias")
                return nil
            }
            return Candidate(name: row.name, sshAlias: row.ssh)
        }
        if candidates.count > boxLimit {
            NSLog("pultik: devbox discovery keeps the first %d of %d boxes", boxLimit, candidates.count)
        }
        return candidates.isEmpty ? nil : Array(candidates.prefix(boxLimit))
    }

    /// `ssh -G <alias>` prints the resolved config; only `hostname` and `port`
    /// are read — identity never comes from the user's config (the poll runs
    /// with `-F /dev/null`). nil when either is missing or unsafe.
    static func endpoint(for candidate: Candidate, sshConfig: String) -> DevboxEndpoint? {
        var host: String?
        var port: Int?
        for line in sshConfig.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            switch parts[0].lowercased() {
            case "hostname" where host == nil: host = parts[1]
            case "port" where port == nil: port = Int(parts[1])
            default: continue
            }
        }
        guard let host, isSafeHost(host), let port, (1 ... 65535).contains(port) else {
            NSLog("pultik: devbox discovery refused box %@ — alias resolves to no usable host:port",
                  candidate.name)
            return nil
        }
        return DevboxEndpoint(name: candidate.name, sshAlias: candidate.sshAlias, host: host, port: port)
    }

    /// Discovered wins; a failed discovery keeps the last good list; with
    /// neither, today's single endpoint.
    static func resolve(discovered: [DevboxEndpoint]?, previous: [DevboxEndpoint]?) -> [DevboxEndpoint] {
        if let discovered, !discovered.isEmpty { return discovered }
        if let previous, !previous.isEmpty { return previous }
        return [.fallback]
    }

    /// A workspace-name word that also cannot be read as an ssh option.
    static func isSafeWord(_ value: String) -> Bool {
        DevboxName.isValid(value) && !value.hasPrefix("-")
    }

    /// An IPv4 literal or a DNS name: `[A-Za-z0-9.-]`, never an option.
    static func isSafeHost(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 253 && !value.hasPrefix("-")
            && value.range(of: "^[A-Za-z0-9.-]+$", options: .regularExpression) != nil
    }
}

// MARK: - The merged estate

/// One box's overview answer, untagged — the merge stamps its rows.
struct DevboxSnapshot {
    let endpoint: DevboxEndpoint
    /// The BOX-side stamp — nil when the payload carried none.
    let generated: Date?
    let workspaces: [DevboxWorkspace]
    let summary: DevboxOverviewSummary
}

/// One discovered box in the per-box breakdown: its free memory above the
/// floor, or silent when it did not answer.
struct DevboxBoxShare: Equatable {
    let name: String
    /// MemAvailable above the floor; negative below it; nil while silent.
    let headroomBytes: Double?
    let pressure: DevboxOverviewSummary.Pressure?

    var isSilent: Bool {
        headroomBytes == nil
    }

    /// "24G free" · "−2G free" · "silent".
    var freeText: String {
        guard let headroomBytes else { return "silent" }
        let free = headroomBytes < 0
            ? "\u{2212}\(DevboxGlance.compact(-headroomBytes))"
            : DevboxGlance.compact(headroomBytes)
        return "\(free)G free"
    }

    /// "a 24G free" · "b silent".
    var label: String {
        "\(name) \(freeText)"
    }
}

/// What the Devbox surfaces show: every answering box's rows, tagged with
/// their box, and one summary. With one discovered box that box's own
/// summary passes through untouched — the single-box panel is exactly
/// today's. With several, totals are summed and `boxes` carries the
/// breakdown, silent boxes included.
struct DevboxEstate {
    let workspaces: [DevboxWorkspace]
    let summary: DevboxOverviewSummary?
    /// The OLDEST box-side stamp among the answers: the estate is only as
    /// fresh as its stalest part.
    let generated: Date?

    init(boxes: [DevboxEndpoint], snapshots: [DevboxSnapshot]) {
        let answered = boxes.compactMap { box in snapshots.first { $0.endpoint.name == box.name } }
        workspaces = answered.flatMap { snapshot in
            snapshot.workspaces.map { row in
                var tagged = row
                tagged.box = snapshot.endpoint
                return tagged
            }
        }
        generated = answered.compactMap(\.generated).min()
        if boxes.count <= 1 {
            summary = answered.first?.summary
        } else if answered.isEmpty {
            summary = nil
        } else {
            let shares = boxes.map { box in
                let summary = answered.first { $0.endpoint.name == box.name }?.summary
                return DevboxBoxShare(
                    name: box.name,
                    headroomBytes: summary.map { $0.memoryAvailableBytes - Double($0.floorGB) * DevboxGlance.gib },
                    pressure: summary?.pressure
                )
            }
            summary = DevboxOverviewSummary(merging: answered.map(\.summary), boxes: shares)
        }
    }
}

extension DevboxOverviewSummary {
    /// Counts, cores, memory, swap, disk and floors add up; pressure is the
    /// worst box's; CPU % is core-weighted. A figure no box reported stays
    /// absent rather than becoming zero.
    init(merging parts: [DevboxOverviewSummary], boxes: [DevboxBoxShare]) {
        func sum(_ value: (DevboxOverviewSummary) -> Int?) -> Int? {
            let present = parts.compactMap(value)
            return present.isEmpty ? nil : present.reduce(0, +)
        }
        let identities = parts.compactMap(\.identities)
        let cpuParts = parts.filter { $0.cpuUsagePercent != nil && $0.cpus > 0 }
        let cpuCores = cpuParts.reduce(0) { $0 + $1.cpus }
        let diskParts = parts.filter { $0.diskUsedBytes != nil && $0.diskTotalBytes != nil }
        self.init(
            identitySlots: parts.reduce(0) { $0 + $1.identitySlots },
            targetHot: parts.reduce(0) { $0 + $1.targetHot },
            hotCeiling: parts.reduce(0) { $0 + $1.hotCeiling },
            claimed: parts.reduce(0) { $0 + $1.claimed },
            running: parts.reduce(0) { $0 + $1.running },
            identities: identities.isEmpty ? nil : DevboxOverviewIdentities(
                saved: sum { $0.identities?.saved },
                runtimeLeases: sum { $0.identities?.runtimeLeases },
                portsUsed: sum { $0.identities?.portsUsed },
                portCapacity: sum { $0.identities?.portCapacity }
            ),
            parked: parts.reduce(0) { $0 + $1.parked },
            floorGB: parts.reduce(0) { $0 + $1.floorGB },
            pressureSome: parts.map(\.pressureSome).max() ?? 0,
            pressureFull: parts.map(\.pressureFull).max() ?? 0,
            cpus: parts.reduce(0) { $0 + $1.cpus },
            load1: parts.reduce(0) { $0 + $1.load1 },
            cpuUsagePercent: cpuCores > 0
                ? cpuParts.reduce(0) { $0 + ($1.cpuUsagePercent ?? 0) * Double($1.cpus) } / Double(cpuCores)
                : nil,
            diskTotalBytes: diskParts.isEmpty ? nil : diskParts.reduce(0) { $0 + ($1.diskTotalBytes ?? 0) },
            diskUsedBytes: diskParts.isEmpty ? nil : diskParts.reduce(0) { $0 + ($1.diskUsedBytes ?? 0) },
            memoryTotalBytes: parts.reduce(0) { $0 + $1.memoryTotalBytes },
            memoryAvailableBytes: parts.reduce(0) { $0 + $1.memoryAvailableBytes },
            swapTotalBytes: parts.reduce(0) { $0 + $1.swapTotalBytes },
            swapFreeBytes: parts.reduce(0) { $0 + $1.swapFreeBytes },
            boxes: boxes
        )
    }
}
