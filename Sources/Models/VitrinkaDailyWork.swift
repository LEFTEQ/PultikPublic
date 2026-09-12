import Foundation

/// A partial answer can still require host-wide backoff.
struct VitrinkaDailyPoll {
    let snapshots: [VitrinkaWorkspaceSnapshot]
    let failures: [ProbeFailure]
    var rejection: ProbeFailure? {
        failures.first { if case .rejected = $0 { return true }; return false }
    }
}

struct VitrinkaWorkspace: Decodable, Identifiable, Hashable {
    let slug: String
    let name: String
    var id: String { slug }
}

struct VitrinkaWorkTask: Decodable, Identifiable {
    let id: Int64
    let project: String
    let title: String
    let status: String
    let url: URL
    var isOpen: Bool { !["done", "cancelled", "canceled", "completed"].contains(status) }
}

struct VitrinkaMyWork: Decodable {
    struct Gate: Decodable { let task: VitrinkaWorkTask; let why: [String]? }
    var assigned: [VitrinkaWorkTask]?
    var created: [VitrinkaWorkTask]?
    var mentioned: [VitrinkaWorkTask]?
    var overdue: [VitrinkaWorkTask]?
    var gates: [Gate]?
}

struct VitrinkaWorkRow: Identifiable {
    let task: VitrinkaWorkTask
    let reason: String
    var id: Int64 { task.id }
}

struct VitrinkaWorkspaceSnapshot: Identifiable {
    let workspace: VitrinkaWorkspace
    var tray = VitrinkaTray()
    var work = VitrinkaMyWork()
    var ripe: [VitrinkaWorkTask] = []
    var unavailable = false
    var workUnavailable = false
    var id: String { workspace.slug }

    static func selected(in snapshots: [Self], preferring pick: String, defaultWorkspace: String?) -> Self? {
        snapshots.first { $0.id == pick }
            ?? snapshots.first { $0.id == defaultWorkspace }
            ?? snapshots.first
    }

    var today: [VitrinkaWorkRow] {
        var rows: [VitrinkaWorkRow] = []
        var seen: Set<Int64> = []
        func append(_ tasks: [VitrinkaWorkTask], reason: String) {
            for task in tasks where task.isOpen && seen.insert(task.id).inserted {
                rows.append(VitrinkaWorkRow(task: task, reason: reason))
            }
        }
        append(work.gates?.map(\.task) ?? [], reason: "needs you")
        append(work.overdue ?? [], reason: "overdue")
        append(ripe, reason: "due now")
        append(work.assigned ?? [], reason: "assigned to you")
        append((work.created ?? []).filter { $0.status == "in_progress" }, reason: "in progress")
        append(work.mentioned ?? [], reason: "mentioned")
        return rows
    }
}
