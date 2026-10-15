import XCTest
@testable import Pultik

/// Every backend's state survives a disk snapshot: encoded with the snapshot
/// coder (sorted keys, default strategies), decoded, and encoded again to
/// the same bytes — while the API decoders keep their own wire shapes.
final class QuerySnapshotCodableTests: XCTestCase {
    private let at = Date(timeIntervalSince1970: 1_791_028_800.123)

    /// encode → decode → encode must be byte-identical; returns the decoded value.
    private func roundTrip<T: Codable>(_ value: T, file: StaticString = #filePath, line: UInt = #line) throws -> T {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let first = try encoder.encode(value)
        let decoded = try JSONDecoder().decode(T.self, from: first)
        XCTAssertEqual(try encoder.encode(decoded), first, file: file, line: line)
        return decoded
    }

    func testProdDigestRoundTrips() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appending(path: "Fixtures/hlidac-digest.json")
        let digest = try XCTUnwrap(HlidacDigest.decode(try Data(contentsOf: url)))
        XCTAssertEqual(try roundTrip(digest), digest)
    }

    func testGitHubRepoStatusRoundTrips() throws {
        let pr = PullRequest(id: 9, number: 641, title: "feat: copilot shell", htmlUrl: "https://github.com/example-org/ExampleApp/pull/641",
                             draft: false, head: .init(sha: "3b8d3fd", ref: "feat/copilot-shell"), updatedAt: at)
        let repo = RepoStatus(
            slug: "example-org/ExampleApp",
            runs: [WorkflowRun(id: 1, name: "CI", headBranch: "main", status: "completed", conclusion: "failure",
                               htmlUrl: "https://github.com/example-org/ExampleApp/actions/runs/1", createdAt: at, updatedAt: at)],
            deploys: [DeployInfo(deployment: Deployment(id: 7, environment: "production", ref: "main", createdAt: at),
                                 state: "in_progress", url: "https://exampleapp.app")],
            prs: [PRInfo(pr: pr, state: .failure, review: .changesRequested)]
        )
        let decoded = try roundTrip([repo, RepoStatus(slug: "example-org/toolkit", error: "HTTP 502")])
        XCTAssertEqual(decoded.map(\.failedCount), [2, 0])
        XCTAssertEqual(decoded.first?.prs.first?.review, .changesRequested)
        XCTAssertEqual(decoded.last?.error, "HTTP 502")
    }

    func testEveSessionsAndAlertsRoundTrip() throws {
        let sessions = [
            EveSession(id: "s1", status: "running", updatedAt: at, source: .init(repo: "example-org/ExampleApp", prNumber: 641), prompt: nil),
            EveSession(id: "s2", status: nil, updatedAt: nil, source: nil, prompt: "Repo: example-org/ExampleApp\nNumber: 642"),
        ]
        let alerts = [
            EveAlert(id: 3, ts: at, flow: "exampleapp_prod", category: "incidents", severity: .critical, title: "API down", body: "5xx spike"),
            EveAlert(id: 4, ts: at, flow: "monitor", category: "priority", severity: nil, title: "Disk", body: ""),
        ]
        XCTAssertEqual(try roundTrip(sessions).map(\.prKey), ["example/exampleapp#641", "example/exampleapp#642"])
        XCTAssertEqual(try roundTrip(alerts).map(\.severity), [.critical, nil])
        let approval = EveApproval(rootID: "r1", title: "Review ExampleApp#641", flow: "pr_review", repo: "example-org/ExampleApp",
                                   prNumber: 641, parked: [.init(id: "c1", title: "open PR", tool: "open_pr",
                                                                 updatedAt: at, stalled: false)])
        XCTAssertEqual(try roundTrip([approval]), [approval])
    }

    func testReleaseLineAndShelfReleasesRoundTrip() throws {
        let deploy = GitHubRelease.Deploy(id: 2, sha: "bbb222", ref: "main", createdAt: at, state: "success",
                                          stateAt: at, creator: "ci", url: "https://exampleapp.app")
        let line = GitHubRelease.Line(
            source: .init(repo: "example-org/ExampleApp", environment: "production"), branch: "main", live: deploy,
            latest: nil, branchHead: "ddd444", waiting: 1, ahead: 0,
            commits: [.init(sha: "ddd444", headline: "fix", author: "lukas", committedAt: at)])
        XCTAssertEqual(try roundTrip(line), line)
        let release = ShelfRelease(key: "Pultík|2.22|2466dc9", name: "Pultík", version: "2.22", channel: "stable", publishedAt: at, commit: "2466dc9",
                                   notes: "Now queue", builds: [.init(appID: "pultik", platform: "macos",
                                                                      url: URL(string: "https://downloads.example.invalid/releases/pultik/2.22/Pultik.zip")!,
                                                                      size: 7_709_777)],
                                   history: 24)
        XCTAssertEqual(try roundTrip([release]), [release])
    }

    /// The shelf's platform builds of one version and commit share a row;
    /// a root-relative artifact resolves against the shelf.
    func testShelfFoldsPlatformBuildsOfOneVersion() throws {
        let index = """
            {"apps": [
              {"id": "vitrinka-cli-darwin-arm64", "name": "Vitrinka CLI (darwin arm64)", "platform": "darwin-arm64",
               "latest": {"version": "5.21.0", "channel": "stable", "ts": 1791626770, "commit": "7eaefec", "notes": "",
                          "size": 10, "url": "/releases/vitrinka-cli-darwin-arm64/5.21.0/vitrinka"}, "releases": [{}, {}]},
              {"id": "vitrinka-cli-linux-amd64", "name": "Vitrinka CLI (linux amd64)", "platform": "linux-amd64",
               "latest": {"version": "5.21.0", "channel": "stable", "ts": 1791626771, "commit": "7eaefec", "notes": "",
                          "size": 11, "url": "/releases/vitrinka-cli-linux-amd64/5.21.0/vitrinka"}},
              {"id": "pultik", "name": "Pultík", "platform": "macos",
               "latest": {"version": "2.22", "channel": "stable", "ts": 1791571626, "commit": "2466dc9", "notes": "n",
                          "size": 12, "url": "/releases/pultik/2.22/Pultik.zip"}},
              {"id": "vitrinka-cli-windows-amd64", "name": "Vitrinka CLI (windows amd64)", "platform": "windows-amd64",
               "latest": {"version": "5.21.0", "channel": "stable", "ts": 1791626700, "commit": "rebuilt", "notes": "",
                          "size": 13, "url": "/releases/vitrinka-cli-windows-amd64/5.21.0/vitrinka.exe"}},
              {"id": "external", "name": "Elsewhere", "platform": "web", "latest": null}]}
            """
        let releases = try ShelfRelease.decodeIndex(Data(index.utf8), origin: URL(string: "https://downloads.example.invalid")!)
        // A platform rebuilt at another commit keeps its own row and id.
        XCTAssertEqual(releases.map(\.id), ["Vitrinka CLI|5.21.0|7eaefec", "Vitrinka CLI|5.21.0|rebuilt", "Pultík|2.22|2466dc9"])
        XCTAssertEqual(releases.first?.builds.map(\.platform), ["darwin-arm64", "linux-amd64"])
        XCTAssertEqual(releases.last?.builds.first?.url.absoluteString, "https://downloads.example.invalid/releases/pultik/2.22/Pultik.zip")
    }

    /// The workbench's activity is persisted (`pr.activity`): every timeline
    /// kind, the pending review and the merge options survive the disk.
    func testChangeRequestActivityRoundTripsEveryTimelineKind() throws {
        let kinds: [TimelineEvent.Kind] = [
            .comment(body: "eve review: approve"), .review(verdict: .changesRequested, body: "Two things.", comments: 2),
            .commit(sha: "471d747", headline: "feat(pool): cooldown"), .forcePush(before: "aa11", after: nil),
            .merged(sha: "f00d"), .merged(sha: nil), .closed, .reopened, .readyForReview, .convertedToDraft,
            .reviewRequested("developers"), .labeled("bug"), .unlabeled("wip"), .assigned("example-org"),
            .renamed(from: "Pool cooldown", to: "Provider pool cooldown"), .baseChanged(from: "release", to: "main"),
        ]
        let person = Person(id: "U_1", login: "example-org", name: "Example User")
        let activity = ChangeRequestActivity(
            nodeID: "PR_1", updatedAt: at, headSHA: "1d9ca50", viewer: "example-org",
            timeline: kinds.enumerated().map {
                TimelineEvent(id: "E\($0.offset)", actor: $0.offset == 0 ? nil : "example-org", at: at,
                              url: $0.offset == 1 ? "https://github.com/o/eve/pull/412#pullrequestreview-1" : nil,
                              kind: $0.element)
            },
            timelineTruncated: true,
            labels: [ChangeRequestLabel(id: "LA_1", name: "bug", color: "d73a4a", description: nil)],
            assignees: [person], milestone: Milestone(id: "MI_1", number: 2, title: "1.8", dueOn: at),
            requestedReviewers: [person, Person(id: "BOT_1", login: "copilot", name: nil, isBot: true)],
            requestedTeams: [Team(id: "T_1", name: "developers", slug: "developers")],
            merge: MergeOptions(methods: [.squash, .rebase], preferred: nil, autoMergeAllowed: true, autoMerge: .squash,
                                deleteBranchOnMerge: true, state: .hasHooks, headRefID: nil, settled: false),
            rights: ViewerRights(canUpdate: true, canMergeAsAdmin: false, canUpdateBranch: true, canDeleteHeadRef: false,
                                 canEnableAutoMerge: false, canDisableAutoMerge: true),
            pendingReview: PendingReview(id: "PRR_1", comments: [
                DraftReviewComment(id: "PRRC_1", path: "src/pool.ts", line: 12, side: .right, startLine: 9,
                                   startSide: .left, body: "This range moved."),
            ]),
            suggestedReviewers: ["livihenderson"])
        XCTAssertEqual(try roundTrip(activity), activity)
        let choices = MetadataChoices(labels: activity.labels, milestones: [Milestone(id: "MI_2", number: 3, title: "2.0", dueOn: nil)],
                                      people: [person], teams: [])
        XCTAssertEqual(try roundTrip(choices), choices)
    }

    func testInfraMetricsLanesAndAlertsRoundTrip() throws {
        let servers = [ServerMetrics(name: "BuildServer-next", instance: "build-server-next", cpu: 12.5, ram: 61, disk: 48.25,
                                     ramUsedBytes: 19.5e9, ramTotalBytes: 32e9, diskUsedBytes: 1.7e12, diskTotalBytes: 3.5e12, cpuCount: 16,
                                     pools: [ZFSUsage(name: "vy", usedBytes: 93e9, totalBytes: 3.4e12)],
                                     datasets: [ZFSUsage(name: "vy/libvirt", usedBytes: 87e9, totalBytes: 1.7e12)]),
                       ServerMetrics(name: "firefly-vm", instance: "firefly-vm", vmHost: "build-server-next", cpu: 3)]
        let services = [ServiceStatus(name: "exampleapp-prod", probe: "https://api.example.invalid/health", host: "AppServer", up: true,
                                      latencySeconds: 0.182)]
        let job = CIJob(org: "example-org", repo: "ExampleApp", lane: "exampleapp-ci", workflow: "CI", jobName: "test",
                        runURL: URL(string: "https://github.com/example-org/ExampleApp/actions/runs/1"), since: at,
                        cpuPercent: 230, memoryBytes: 2.1e9)
        let board = CILaneBoard(
            lanes: [CILane(name: "exampleapp-ci", backend: "docker", trustGroup: "firefly", up: true, host: "build-server-next",
                           repo: "example-org/ExampleApp", tier: 0, kind: "ci", queued: 2, jobs: [job])],
            elsewhere: [job], elsewhereQueued: 1,
            pools: ["build-server-next": CIPool(slotsUsed: 3, slotsMax: 6, reservedMiB: 12288, budgetMiB: 24576,
                         head: CIPoolHead(lane: "exampleapp-ci", tier: 0, kind: "ci", waiting: 2), observedAt: at,
                         bastion: CIPartitionLoad(slotsUsed: 1, slotsMax: 2, reservedMiB: 4096, budgetMiB: 8192),
                         refusals: [CIRefusal(reason: "memory", count: 4)])]
        )
        let throughput = CIThroughput(at: "2026-10-10T09:00:00Z", tz: "Europe/Prague", jobs: 120, yesterdaySameTime: 98,
                                      queue: .init(p50: 4.5, p95: 61), over300sShare: 0.05, hours: [.init(hour: 9, jobs: 14)])
        let firing = [FiringAlert(name: "HighErrorRate", state: "firing", severity: "critical", summary: "5xx over 2%",
                                  description: nil, labels: ["alertname": "HighErrorRate", "app": "exampleapp", "environment": "prod"],
                                  activeAt: at, source: .loki)]
        let decodedServers = try roundTrip(servers)
        XCTAssertEqual(decodedServers.first?.worst, 61)
        XCTAssertEqual(decodedServers.first?.pools, servers.first?.pools)
        XCTAssertEqual(decodedServers.first?.datasets, servers.first?.datasets)
        XCTAssertEqual(decodedServers.map(\.id), ["build-server-next", "build-server-next/firefly-vm"])
        XCTAssertEqual(try roundTrip(services).first?.latencySeconds, 0.182)
        let decodedBoard = try roundTrip(board)
        XCTAssertEqual(decodedBoard.pools, board.pools)
        XCTAssertEqual(decodedBoard.lanes.first?.host, "build-server-next")
        XCTAssertEqual(decodedBoard.lanes.first?.jobs.map(\.id), [job.id])
        XCTAssertEqual(try roundTrip(throughput), throughput)
        XCTAssertEqual(try roundTrip(firing), firing)
    }

    func testVitrinkaWorkspaceAndTodosRoundTrip() throws {
        let task = VitrinkaWorkTask(id: 6556, project: "pultik", title: "Snapshot the queries", status: "in_progress",
                                    url: URL(string: "https://boards.example.invalid/example/p/pultik?task=6556")!)
        let board = VitrinkaBoard(slug: "pultik-qa", title: "Pultik QA", url: "https://boards.example.invalid/b/pultik-qa", project: "pultik")
        let snapshot = VitrinkaWorkspaceSnapshot(
            workspace: VitrinkaWorkspace(slug: "example", name: "example-org"),
            tray: VitrinkaTray(listeners: [VitrinkaListening(id: 42, scope: "pultik-qa", scopeKind: "board", title: "Pultik QA",
                                                             url: board.url, openCount: 3, questionCount: 1, lastSeen: at,
                                                             session: "mac:4242", actor: "claude", activity: nil)],
                               boards: [board]),
            work: VitrinkaMyWork(assigned: [task], mentioned: [], gates: [.init(task: task, why: ["review"])]),
            ripe: [task], workUnavailable: true
        )
        let decoded = try XCTUnwrap(try roundTrip([snapshot]).first)
        XCTAssertEqual(decoded.today.map(\.reason), ["needs you"])
        XCTAssertEqual(decoded.tray.boards, [board])
        XCTAssertEqual(decoded.tray.listeners.map(\.lastSeen), [at])

        // TodoItem's snapshot goes back through its wire decoder.
        let due = Date(timeIntervalSince1970: 1_791_028_800.5)
        let todo = TodoItem(id: 120, project: "example-studio", title: "fix the portal claim bug", status: "in_progress",
                            dueAt: due, priority: "high", milestoneId: 7, createdAt: due, lead: 3600, every: "1w",
                            trigger: "when the PR merges", hasContext: true)
        let todos = try roundTrip([todo, TodoItem(id: 121, project: "p", title: "bare")])
        XCTAssertEqual(todos[0].dueAt, due)
        XCTAssertEqual(todos[0].createdAt, due)
        XCTAssertEqual(todos[0].lead, 3600)
        XCTAssertEqual([todos[0].status, todos[0].priority, todos[0].every, todos[0].trigger],
                       ["in_progress", "high", "1w", "when the PR merges"])
        XCTAssertEqual(todos[0].milestoneId, 7)
        XCTAssertTrue(todos[0].hasContext)
        XCTAssertNil(todos[1].lead)
        XCTAssertFalse(todos[1].hasContext)
    }

    func testDevboxSnapshotRoundTrips() throws {
        let box = DevboxEndpoint(name: "a", sshAlias: "devops", host: "192.0.2.11", port: 2222, state: "drain", primary: false)
        let summary = DevboxOverviewSummary(
            identitySlots: 0, targetHot: 4, hotCeiling: 0, claimed: 3, running: 2,
            identities: DevboxOverviewIdentities(saved: 5, runtimeLeases: 2, portsUsed: 40, portCapacity: 400),
            parked: 1, floorGB: 6, pressureSome: 5.25, pressureFull: 0, cpus: 16, load1: 3.5, cpuUsagePercent: 22.5,
            diskTotalBytes: 1e12, diskUsedBytes: 4e11, memoryTotalBytes: 64 * 1_073_741_824,
            memoryAvailableBytes: 30 * 1_073_741_824, swapTotalBytes: 8e9, swapFreeBytes: 7e9,
            box: "a",
            boxes: [DevboxBoxShare(name: "a", headroomBytes: 24e9, pressure: .elevated, state: "drain"),
                    DevboxBoxShare(name: "c", headroomBytes: nil, pressure: nil, state: "active", primary: true)]
        )
        let workspace = DevboxWorkspace(
            name: "example-studio", project: "example-studio", branch: "main", portBase: 7100, portCount: 10, created: at,
            apps: [DevboxWorkspaceApp(name: "portal", port: 7101, fqdn: "portal.example-studio.ws.example.invalid",
                                      syncPath: "/Volumes/work/forge", active: "active", hostUp: true,
                                      remoteURL: "http://192.0.2.10:7101")],
            stats: [DevboxContainerStat(name: "forge-portal-1", cpuPercent: 12.5, memBytes: 512e6, status: "Up 3 hours (healthy)")],
            memoryBytes: 2.7e9, cpuPercent: 12.5,
            declaredSources: [DevboxWorkspaceSource(app: "portal", path: "/Volumes/work/forge")],
            state: "parked", hold: true, parkedAt: at, macPath: "/Volumes/work/forge", declaredGB: 4, memPeakBytes: 5.5e9,
            drift: "declared 4G, peak 5.5G", box: box
        )
        let decoded = try roundTrip(DevboxSnapshot(endpoint: box, generated: at, workspaces: [workspace], summary: summary))
        XCTAssertEqual(decoded.endpoint, box)
        XCTAssertEqual(decoded.summary.boxes, summary.boxes)
        XCTAssertEqual(decoded.summary.box, "a")
        XCTAssertEqual(decoded.summary.pressure, .elevated)
        XCTAssertEqual(decoded.workspaces.map(\.id), ["a/example-studio"])
        XCTAssertEqual(decoded.workspaces.first?.footprintHelp, workspace.footprintHelp)
        _ = try roundTrip(DevboxHost(workspace: "example-studio", fqdn: "portal.example-studio.ws.example.invalid", port: 7101, up: true))
        _ = try roundTrip(DevboxRepo(name: "forge", branch: "main", dirty: 1, ahead: 2, behind: 0))
    }
}
