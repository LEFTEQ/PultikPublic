import XCTest
@testable import Pultik

/// The prod board's contract with Hlídač: the golden digest
/// (Tests/Fixtures/hlidac-digest.json, contracts §5) decodes and formats
/// exactly as the board draws it. Brief AC1, AC8, AC11, AC15.
final class ProdGlanceTests: XCTestCase {
    private static let now = ISO8601DateFormatter().date(from: "2026-10-02T18:41:00Z")!
    private static let utc = TimeZone(identifier: "UTC")!

    private static let pointers = [
        ProdPointer(key: "exampleapp-prod", title: "ExampleApp prod", tier: "critical", order: 1),
        ProdPointer(key: "eve-exampleapp-prod", title: "eve · ExampleApp", tier: "critical", order: 2),
        ProdPointer(key: "booking-sk", title: "Booking SK", tier: "critical", order: 3),
        ProdPointer(key: "booking-cz", title: "Booking CZ", tier: "critical", order: 4),
        ProdPointer(key: "vitrinka", title: "vitrinka", tier: "watch", order: 5),
    ]

    private func golden() throws -> HlidacDigest {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appending(path: "Fixtures/hlidac-digest.json")
        return try XCTUnwrap(HlidacDigest.decode(try Data(contentsOf: url)))
    }

    private func glance(_ digest: HlidacDigest?, unreachableSince: Date? = nil) -> ProdGlance {
        ProdGlance.make(pointers: Self.pointers, digest: digest, unreachableSince: unreachableSince,
                        now: Self.now, timeZone: Self.utc)
    }

    /// AC1: five cards in board order, each with its verdict, chips and lines.
    func testGoldenDigestBecomesFiveCardsInBoardOrder() throws {
        let cards = glance(try golden()).cards
        XCTAssertEqual(cards.map(\.key), ["exampleapp-prod", "eve-exampleapp-prod", "booking-sk", "booking-cz", "vitrinka"])
        XCTAssertEqual(cards.map(\.tone), [.green, .orange, .orange, .hollow, .red])
        XCTAssertEqual(cards.map(\.chips.count), [6, 6, 6, 0, 3])

        let exampleapp = cards[0]
        XCTAssertEqual(exampleapp.chips.first, ProdGlance.Chip(id: "api", label: "API 182 ms", tone: .green))
        XCTAssertEqual(exampleapp.logsLine, "0 err · 818 warn ▾4%")
        XCTAssertEqual(exampleapp.edgeLine, "5xx 0 · 429 340")
        XCTAssertEqual(exampleapp.hours?.count, 24)
        XCTAssertEqual(exampleapp.topIssue?.kind, .sentry)
        XCTAssertEqual(exampleapp.topIssue?.isNew, true)
        XCTAssertEqual(exampleapp.topIssue?.meta, "14× · 3 users · 12m")

        let eve = cards[1]
        XCTAssertEqual(eve.chips.first, ProdGlance.Chip(id: "claude-pool", label: "Claude pool 1/2", tone: .orange))
        XCTAssertEqual(eve.deployment?.pool?.pools.map(\.usable), [1, 2])
        XCTAssertEqual(eve.deployment?.pool?.pools[1].accounts.last?.state, "logged_out")
        // Codex windows are named by length, never by primary/secondary.
        XCTAssertEqual(eve.deployment?.pool?.pools[1].accounts.first?.windows.map(\.name), ["five_hour", "seven_day"])

        let sk = cards[2]
        XCTAssertEqual(sk.topIssue?.kind, .alert)
        XCTAssertEqual(sk.topIssue?.tone, .orange)
        XCTAssertEqual(sk.topIssue?.meta, "6m")
        XCTAssertEqual(sk.logsLine, "2 err · 163 warn ▾6%")

        XCTAssertEqual(cards[4].topIssue?.tone, .red)
        XCTAssertEqual(cards[4].topIssue?.title, "vitrinka p99 10s on /w/{id}/api/v1/projects")
    }

    /// AC8: one dot per card in board order; red pulses until seen, and a
    /// deployment that leaves red forgets it was seen.
    func testDotsPulseRedUntilSeen() throws {
        let board = glance(try golden())
        XCTAssertEqual(board.dots(seenRed: []).map(\.tone), [.green, .orange, .orange, .hollow, .red])
        XCTAssertEqual(board.dots(seenRed: []).filter(\.pulsing).map(\.key), ["vitrinka"])

        let seen = board.redKeys
        XCTAssertTrue(board.dots(seenRed: seen).allSatisfy { !$0.pulsing })
        XCTAssertEqual(ProdGlance.seen(seen, keepingOnly: []), [])
    }

    /// The dots are colour in a raster image, so the status item's label
    /// says the same in words: every deployment that is not ok, in board
    /// order, an unseen red marked, then the ok count.
    func testDotsSpokenForTheStatusItemLabel() throws {
        let board = glance(try golden())
        let titles = board.cards.map(\.title)
        XCTAssertEqual(board.spoken(seenRed: []),
                       "prod: \(titles[1]) degraded · \(titles[2]) degraded · \(titles[3]) not monitored"
                           + " · \(titles[4]) down, unseen · 1 ok")
        XCTAssertEqual(board.spoken(seenRed: board.redKeys)?.contains("unseen"), false)
        let green = ProdGlance(cards: board.cards.filter { $0.tone == .green })
        XCTAssertEqual(green.spoken(seenRed: []), "prod: all 1 ok")
        XCTAssertNil(ProdGlance(cards: []).spoken(seenRed: []))
    }

    /// A live emergency is red on the strip whatever the verdict — a blind
    /// deployment can carry one from Alertmanager (D9). The card keeps its
    /// blind context; a stale card never has `emergency`.
    func testLiveEmergencyIsRedOnTheStripEvenWhenBlind() {
        let siren = ProdGlance.Card(
            key: "exampleapp-prod", title: "ExampleApp prod", tier: "critical", tone: .blind, status: "blind since 18:39",
            emergency: true, stale: false, chips: [], hours: nil, logsLine: nil, edgeLine: nil, topIssue: nil,
            deployment: nil)
        let board = ProdGlance(cards: [siren])
        XCTAssertEqual(board.dots(seenRed: []).map(\.tone), [.red])
        XCTAssertEqual(board.dots(seenRed: []).map(\.pulsing), [true])
        XCTAssertEqual(board.redKeys, ["exampleapp-prod"])
        XCTAssertEqual(board.spoken(seenRed: []), "prod: ExampleApp prod no answer, emergency, unseen")
        XCTAssertEqual(board.dots(seenRed: board.redKeys).map(\.pulsing), [false])
    }

    /// AC11: no answer from Hlídač reads blind with its since-time — never
    /// the cached green, never an emergency.
    func testUnreachableHlidacIsBlindNeverGreen() throws {
        let since = Self.now.addingTimeInterval(-120)
        let cached = glance(try golden(), unreachableSince: since).cards
        XCTAssertTrue(cached.allSatisfy { $0.tone == .blind })
        XCTAssertTrue(cached.allSatisfy { $0.status == "blind since 18:39" })
        XCTAssertTrue(cached.allSatisfy { !$0.emergency })

        let cold = glance(nil, unreachableSince: since).cards
        XCTAssertEqual(cold.count, 5)
        XCTAssertTrue(cold.allSatisfy { $0.tone == .blind && $0.status == "blind since 18:39" })
        XCTAssertEqual(glance(nil).cards.first?.status, "waiting for Hlídač")
    }

    /// AC11, Hlídač's side: its own blind verdict (Prometheus silent) reads
    /// blind with Hlídač's since-time, and a check without a series is a
    /// blind chip — never a green one.
    func testHlidacBlindVerdictIsBlindWithItsSinceAndBlindChips() throws {
        let json = #"""
        {"generatedAt": "2026-10-02T18:41:00Z",
         "sources": {"prometheus": {"ok": false, "since": "2026-10-02T18:30:00Z", "error": "timeout"}},
         "deployments": [{"key": "exampleapp-prod", "project": "exampleapp", "title": "ExampleApp prod", "tier": "critical",
           "verdict": "blind", "blindSince": "2026-10-02T18:30:00Z", "emergency": false,
           "checks": [{"id": "api", "title": "API", "status": null, "value": null, "page": true}],
           "logs": {"hours": null, "today": null, "yesterday": null}, "edge": null,
           "sentry": [], "alerts": [], "pool": null, "links": []}]}
        """#
        let digest = try XCTUnwrap(HlidacDigest.decode(Data(json.utf8)))
        let card = try XCTUnwrap(glance(digest).cards.first)
        XCTAssertEqual(card.tone, .blind)
        XCTAssertEqual(card.status, "blind since 18:30")
        XCTAssertFalse(card.emergency)
        XCTAssertEqual(card.chips, [ProdGlance.Chip(id: "api", label: "API", tone: .blind)])
    }

    /// AC15: Booking CZ is explicit about its blind spot — Sentry only.
    func testBookingCZIsNotMonitoredWithSentryOnly() throws {
        let cz = try XCTUnwrap(glance(try golden()).cards.first { $0.key == "booking-cz" })
        XCTAssertEqual(cz.tone, .hollow)
        XCTAssertEqual(cz.status, "not monitored")
        XCTAssertTrue(cz.chips.isEmpty)
        XCTAssertNil(cz.hours)
        XCTAssertNil(cz.logsLine)
        XCTAssertEqual(cz.topIssue?.kind, .sentry)
        XCTAssertEqual(cz.topIssue?.title, #"NotificationChannels\Telegram\Exceptions\CouldNotSendNotification"#)
    }

    /// A pointer Hlídač does not know is a config issue row, never a crash;
    /// an unknown verdict from a newer Hlídač is never read as healthy.
    func testUnknownPointerAndUnknownVerdict() throws {
        let board = ProdGlance.make(pointers: [ProdPointer(key: "voke-prod")], digest: try golden(),
                                    unreachableSince: nil, now: Self.now, timeZone: Self.utc)
        XCTAssertEqual(board.cards.first?.status, "unknown to Hlídač — add it to deployments.yaml")
        XCTAssertEqual(board.cards.first?.tone, .blind)

        XCTAssertEqual(try JSONDecoder().decode([HlidacDigest.Verdict].self, from: Data(#"["paging"]"#.utf8)),
                       [.blind])
    }

    // MARK: - `.h` overview matrix (D4 B)

    /// Columns come from check ids, never deployment keys: ExampleApp's api lands
    /// in Probe, modules+deps in App, eve's two pools in Queues/pool.
    /// The row's accessible label keeps what the collapsed row shows: the
    /// deployment and its state, the subtitle, then every non-empty cell
    /// with its column, a non-green tone in words.
    func testMatrixRowSpokenKeepsEveryCell() throws {
        let rows = ProdMatrix.rows(glance(try golden()))
        let exampleapp = try XCTUnwrap(rows.first { $0.key == "exampleapp-prod" })
        let spoken = exampleapp.spoken
        XCTAssertTrue(spoken.hasPrefix("ExampleApp prod, ok"), spoken)
        XCTAssertTrue(spoken.contains("Probe 182ms"), spoken)
        XCTAssertTrue(spoken.contains("Sentry 1 new, alert"), spoken)
        XCTAssertTrue(spoken.contains("Logs 24h 0·818"), spoken)
        XCTAssertTrue(spoken.contains("Backup 16h"), spoken)
        XCTAssertFalse(spoken.contains("Firing"), spoken)
    }

    func testMatrixColumnsAreDerivedFromCheckIds() throws {
        let rows = ProdMatrix.rows(glance(try golden()))
        let exampleapp = try XCTUnwrap(rows.first { $0.key == "exampleapp-prod" })
        XCTAssertEqual(exampleapp.cells[.probe], ProdMatrix.Cell(tone: .green, text: "182ms"))
        XCTAssertEqual(exampleapp.cells[.app], ProdMatrix.Cell(tone: .green, text: "9/9·7/7"))
        XCTAssertEqual(exampleapp.cells[.backup], ProdMatrix.Cell(tone: .green, text: "16h"))
        XCTAssertEqual(exampleapp.cells[.sentry], ProdMatrix.Cell(tone: .red, text: "1 new"))
        XCTAssertEqual(exampleapp.cells[.firing], ProdMatrix.Cell.empty)
        XCTAssertEqual(exampleapp.cells[.logs], ProdMatrix.Cell(tone: nil, text: "0·818"))

        let eve = try XCTUnwrap(rows.first { $0.key == "eve-exampleapp-prod" })
        // The unhealthy pools lead the column; the healthy any-pool waits.
        XCTAssertEqual(eve.cells[.pool], ProdMatrix.Cell(tone: .orange, text: "1/2·2/4"))
        // Compact, never ellipsized: "4.1 s · 3m" reads "4.1s·3m".
        XCTAssertEqual(eve.cells[.probe]?.text, "4.1s·3m")
        XCTAssertEqual(ProdMatrix.compact("16.2 h"), "16.2h")

        let sk = try XCTUnwrap(rows.first { $0.key == "booking-sk" })
        XCTAssertEqual(sk.cells[.firing], ProdMatrix.Cell(tone: .orange, text: "1 warn", textTone: .orange))
        XCTAssertEqual(sk.cells[.logs], ProdMatrix.Cell(tone: nil, text: "2·163", textTone: .red))

        let vitrinka = try XCTUnwrap(rows.first { $0.key == "vitrinka" })
        XCTAssertEqual(vitrinka.cells[.probe], ProdMatrix.Cell(tone: .red, text: "10.2s"))

        let cz = try XCTUnwrap(rows.first { $0.key == "booking-cz" })
        XCTAssertNil(cz.cells[.probe])
        XCTAssertEqual(cz.cells[.logs], ProdMatrix.Cell(tone: nil, text: "not shipped"))
        XCTAssertEqual(ProdMatrix.column(forCheck: "something-new"), .app)
    }

    /// The eve accounts table: states, binding-window resets, the cooldown
    /// countdown and the dimmed stale/logged-out rows.
    func testAccountsTableRows() throws {
        let eve = try XCTUnwrap(try golden().deployments.first { $0.key == "eve-exampleapp-prod" })
        let rows = ProdAccountRow.rows(try XCTUnwrap(eve.pool), now: Self.now, timeZone: Self.utc)
        XCTAssertEqual(rows.map(\.account), ["claude-1", "claude-2", "codex-a", "codex-b", "codex-c", "codex-d"])
        // Ids carry the gateway: two gateways may reuse an account name.
        XCTAssertEqual(rows.first?.id, "anthropic/claude-1")
        XCTAssertEqual(rows.last?.id, "codex/codex-d")
        XCTAssertEqual(rows.map(\.tone), [.green, .orange, .green, .green, .orange, .red])

        let claude2 = rows[1]
        XCTAssertEqual(claude2.pool, "Claude")
        XCTAssertEqual(claude2.cooldown, "back 19:14 · 33m")
        XCTAssertEqual(claude2.cooldownAt, "back 19:14")
        XCTAssertEqual(claude2.cooldownIn, "33m")
        XCTAssertEqual(claude2.resets, "19:14")
        XCTAssertEqual(claude2.fiveHour, 1.0)
        XCTAssertEqual(claude2.fableLeft, "21%")
        XCTAssertFalse(claude2.stale)

        // The binding window is the one closest to its limit: claude-1's
        // Fable weekly (62%) resets next Friday — shown as how far off it
        // is, complete; the clock form is the tooltip's.
        XCTAssertEqual(rows[0].resets, "6d 17h")
        XCTAssertEqual(rows[0].resetsAt, "9 Oct")
        XCTAssertEqual(rows[2].resets, "3d 5h")
        XCTAssertEqual(rows[2].resetsAt, "Tue 00:00")
        XCTAssertNil(rows[0].cooldown)
        XCTAssertEqual(rows[2].fableLeft, nil)
        XCTAssertEqual(rows[2].sevenDay, 0.40)

        let codexD = rows[5]
        XCTAssertEqual(codexD.state, "logged out")
        XCTAssertTrue(codexD.stale)
        XCTAssertNil(codexD.asOf)
    }

    /// While the card is stale (Hlídač not answering) the expanded detail
    /// reads blind too: no cached account or lane stays green — the
    /// last-known text still shows, dimmed.
    func testStaleCardBlindsAccountsAndLane() throws {
        let eve = try XCTUnwrap(try golden().deployments.first { $0.key == "eve-exampleapp-prod" })
        let rows = ProdAccountRow.rows(try XCTUnwrap(eve.pool), now: Self.now, timeZone: Self.utc, blind: true)
        XCTAssertEqual(Set(rows.map(\.tone)), [.blind])
        XCTAssertTrue(rows.allSatisfy(\.stale))
        XCTAssertEqual(rows[1].cooldown, "back 19:14 · 33m")
        XCTAssertEqual(ProdAccountRow.laneTone(usable: 2, total: 2, blind: false), .green)
        XCTAssertEqual(ProdAccountRow.laneTone(usable: 1, total: 2, blind: false), .orange)
        XCTAssertEqual(ProdAccountRow.laneTone(usable: 0, total: 2, blind: false), .red)
        XCTAssertEqual(ProdAccountRow.laneTone(usable: 2, total: 2, blind: true), .blind)
    }

    /// F2: while Hlídač is unreachable every chip and matrix cell reads
    /// blind — the last-known text stays, a stale green or red never does.
    func testUnreachableBlindsChipsAndCells() throws {
        let since = Self.now.addingTimeInterval(-300)
        let stale = glance(try golden(), unreachableSince: since)
        let chipTones = Set(stale.cards.flatMap(\.chips).map(\.tone))
        XCTAssertFalse(chipTones.contains(.green))
        XCTAssertFalse(chipTones.contains(.red))
        XCTAssertTrue(stale.cards.allSatisfy(\.stale))
        XCTAssertNotEqual(stale.cards.first { $0.key == "exampleapp-prod" }?.topIssue?.tone, .red)

        let cells = ProdMatrix.rows(stale).flatMap(\.cells.values)
        XCTAssertFalse(cells.contains { $0.tone == .green || $0.tone == .red })
        XCTAssertFalse(cells.contains { $0.textTone != nil })
        let exampleapp = try XCTUnwrap(ProdMatrix.rows(stale).first { $0.key == "exampleapp-prod" })
        XCTAssertEqual(exampleapp.cells[.probe], ProdMatrix.Cell(tone: .blind, text: "182ms", dimmed: true))
    }

    /// F7 / AC S5: the filter `.h` carries resolves to one deployment.
    func testExpandedKeyResolvesTheFilter() throws {
        let rows = ProdMatrix.rows(glance(try golden())).map { (key: $0.key, title: $0.title) }
        XCTAssertEqual(ProdMatrix.expandedKey(filter: "sk", rows: rows), "booking-sk")
        XCTAssertEqual(ProdMatrix.expandedKey(filter: "eve", rows: rows), "eve-exampleapp-prod")
        XCTAssertEqual(ProdMatrix.expandedKey(filter: "ExampleApp", rows: rows), "exampleapp-prod")
        XCTAssertNil(ProdMatrix.expandedKey(filter: " ", rows: rows))
        XCTAssertNil(ProdMatrix.expandedKey(filter: "nomatch", rows: rows))
    }

    /// F10: no pointers and nothing from Hlídač still leaves one blind row.
    func testEmptyBoardWaitsOrReadsBlind() {
        let waiting = ProdGlance.make(pointers: [], digest: nil, unreachableSince: nil, now: Self.now, timeZone: Self.utc)
        XCTAssertTrue(waiting.cards.isEmpty)
        XCTAssertEqual(waiting.waiting, "waiting for Hlídač")
        let since = ISO8601DateFormatter().date(from: "2026-10-02T18:30:00Z")!
        let blind = ProdGlance.make(pointers: [], digest: nil, unreachableSince: since, now: Self.now, timeZone: Self.utc)
        XCTAssertEqual(blind.waiting, "blind since 18:30")
    }

    /// Live-shaped account (the 2026-10-03 hand test truncated these): a
    /// long id, logged out, its binding window resetting 1d 4h away — every
    /// field complete, nothing to ellipsize.
    func testRealShapedAccountFormatsComplete() {
        let resets = Self.now.addingTimeInterval(28 * 3600)
        let account = HlidacDigest.Account(
            id: "lukas-max-subscription-2", state: "logged_out", cooldownUntil: nil, demotedUntil: nil,
            windows: [HlidacDigest.Window(name: "seven_day", usedRatio: 0.97, resetsAt: resets),
                      HlidacDigest.Window(name: "five_hour", usedRatio: 0.12, resetsAt: Self.now.addingTimeInterval(7200))],
            turns24h: 0, observedAt: Self.now.addingTimeInterval(-26 * 3600))
        let row = ProdAccountRow.row(account, gateway: "anthropic", now: Self.now, timeZone: Self.utc)
        XCTAssertEqual(row.id, "anthropic/lukas-max-subscription-2")
        XCTAssertEqual(row.state, "logged out")
        XCTAssertEqual(row.tone, .red)
        XCTAssertEqual(row.resets, "1d 4h")
        XCTAssertEqual(row.resetsAt, "Sat 22:41")
        XCTAssertTrue(row.stale)
        XCTAssertEqual(ProdAccountRow.resetText(Self.now.addingTimeInterval(6 * 3600), now: Self.now,
                                                timeZone: Self.utc), "6h")
        XCTAssertEqual(ProdAccountRow.resetText(Self.now.addingTimeInterval(48 * 3600), now: Self.now,
                                                timeZone: Self.utc), "2d")
    }

    func testCooldownCountdownAndPoolSummary() throws {
        let start = Self.now
        XCTAssertEqual(ProdAccountRow.countdown(from: start, to: start.addingTimeInterval(33 * 60)), "33m")
        XCTAssertEqual(ProdAccountRow.countdown(from: start, to: start.addingTimeInterval(65 * 60)), "1h 5m")
        XCTAssertEqual(ProdAccountRow.countdown(from: start, to: start.addingTimeInterval(-60)), "0m")

        let eve = try XCTUnwrap(try golden().deployments.first { $0.key == "eve-exampleapp-prod" })
        XCTAssertEqual(eve.pool?.summary(now: Self.now), "Claude 1/2 · Codex 2/4 · canary 3m")
    }
}
