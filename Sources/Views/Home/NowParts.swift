import SwiftUI

// The parts both Home styles draw the Now queue with (copilot shell D6,
// D12–D15; board cards 77430/77431/77434–77438). They format `NowQueue`
// only — ranking, folding and onsets are the queue's — and hold no state.

/// One line of Home's Now list: a live row, or the tombstone a resolved
/// selection leaves at its old place until the next arrow (contract
/// "Selection": ↵ never silently targets another row).
enum NowHomeRow: Identifiable, Equatable {
    case live(NowRow)
    case tombstone(NowRow)

    var row: NowRow {
        switch self {
        case let .live(row), let .tombstone(row): row
        }
    }

    /// A tombstone has its own id: the same incident can return as a live
    /// row while its tombstone still holds the selection.
    var id: String { isTombstone ? Self.goneID(row.key) : Self.id(row.key) }
    var isTombstone: Bool {
        if case .tombstone = self { return true }
        return false
    }

    static func id(_ key: String) -> String { "now:\(key)" }
    static func goneID(_ key: String) -> String { "now-gone:\(key)" }

    /// Any Home Now row's id, live or tombstone.
    static func owns(_ id: String) -> Bool { id.hasPrefix("now:") || id.hasPrefix("now-gone:") }
}

/// A selected row that left the queue, held in place until the next arrow.
struct NowTombstone: Equatable {
    let row: NowRow
    /// The visible row it draws after; nil = first.
    let after: String?
}

extension NowLane {
    var title: String {
        switch self {
        case .onFire: "On fire"
        case .waitingOnYou: "Waiting on you"
        case .due: "Due"
        case .drifting: "Drifting"
        }
    }

    var symbol: String {
        switch self {
        case .onFire: "flame.fill"
        case .waitingOnYou: "hand.raised.fill"
        case .due: "calendar"
        case .drifting: "arrow.up.right"
        }
    }

    var tone: Color {
        switch self {
        case .onFire: Theme.danger
        case .waitingOnYou, .due: Theme.warn
        case .drifting: Theme.idle
        }
    }
}

extension NowSeverity {
    /// A bar's colour is its severity (the lane is its class): critical and
    /// emergency are danger, a warning warns, normal takes the lane's tone.
    func tone(in lane: NowLane) -> Color {
        switch self {
        case .emergency, .critical: Theme.danger
        case .warning: Theme.warn
        case .normal: lane.tone
        }
    }
}

extension NowKind {
    var symbol: String {
        switch self {
        case .deployment: "waveform.path.ecg"
        case .monitoringBlind: "eye.slash"
        case .sentryIssue: "ladybug.fill"
        case .firingAlert: "bell.fill"
        case .eveNotification: "sparkles"
        case .eveApproval: "checkmark.seal.fill"
        case .sessionWaiting: "terminal.fill"
        case .failedCheck: "xmark.octagon.fill"
        case .reviewRequested: "eye.fill"
        case .stalePR: "arrow.triangle.pull"
        case .reminder: "bell.badge.fill"
        case .overdueTask: "checklist"
        case .staleWorkspace: "shippingbox.fill"
        case .macFinding: "laptopcomputer"
        case .expiry: "key.fill"
        }
    }

    /// Now first's kind tag under the lane: "eve approval", "stale PR".
    var label: String {
        switch self {
        case .deployment: "prod"
        case .monitoringBlind: "monitoring"
        case .sentryIssue: "sentry"
        case .firingAlert: "alert"
        case .eveNotification: "eve"
        case .eveApproval: "eve approval"
        case .sessionWaiting: "session"
        case .failedCheck: "ci · yours"
        case .reviewRequested: "review"
        case .stalePR: "stale PR"
        case .reminder: "reminder"
        case .overdueTask: "overdue"
        case .staleWorkspace: "devbox"
        case .macFinding: "this Mac"
        case .expiry: "expiring"
        }
    }

    /// A fold's noun: "+3 sessions waiting".
    var plural: String {
        switch self {
        case .deployment: "deployments"
        case .monitoringBlind: "blind sources"
        case .sentryIssue: "issues"
        case .firingAlert: "alerts firing"
        case .eveNotification: "eve notifications"
        case .eveApproval: "approvals"
        case .sessionWaiting: "sessions waiting"
        case .failedCheck: "failed checks"
        case .reviewRequested: "reviews requested"
        case .stalePR: "stale PRs"
        case .reminder: "reminders due"
        case .overdueTask: "overdue tasks"
        case .staleWorkspace: "stale workspaces"
        case .macFinding: "Mac findings"
        case .expiry: "expiries"
        }
    }
}

extension NowQueue {
    /// Rank labels as drawn: an incident or ×N row is one rank, a fold
    /// spans the ranks it holds ("6–8") and an open fold's children take
    /// them one by one; a tombstone has none.
    static func ranks(_ rows: [NowHomeRow]) -> [String: String] {
        var next = 1
        var out: [String: String] = [:]
        var children: [String: Int] = [:]
        for item in rows where !item.isTombstone {
            let row = item.row
            if let parent = row.parentKey, let rank = children[parent] {
                out[item.id] = "\(rank)"
                children[parent] = rank + 1
                continue
            }
            let span = row.shape == .fold ? row.incidents.count : 1
            if row.shape == .fold { children[row.key] = next }
            out[item.id] = span > 1 ? "\(next)–\(next + span - 1)" : "\(next)"
            next += span
        }
        return out
    }
}

/// The need's glyph: its kind on a quiet square, its severity as the dot.
struct NowGlyph: View {
    let kind: NowKind
    let tone: Color
    var size: CGFloat = 20

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
            .fill(Theme.surfaceRaised)
            .frame(width: size, height: size)
            .overlay {
                Image(systemName: kind.symbol)
                    .font(.system(size: size * 0.5, weight: .semibold))
                    .foregroundStyle(Theme.ink2)
            }
            .overlay(alignment: .bottomTrailing) {
                Circle().fill(tone).frame(width: 7, height: 7)
                    .overlay(Circle().strokeBorder(Theme.canvas, lineWidth: 1.5))
                    .offset(x: 2, y: 2)
            }
    }
}

// MARK: - The time track

/// Geometry shared by the axis and every row's track: the rolling 24 h
/// (D12) with its magnified last half hour (D13) over `trackWidth`, then a
/// future gutter for deadline diamonds.
struct NowTrackMetrics {
    static let gutter: CGFloat = 46
    let axis: NowAxis
    let width: CGFloat

    var trackWidth: CGFloat { max(0, width - Self.gutter) }

    func x(_ date: Date) -> CGFloat { CGFloat(axis.x(date)) * trackWidth }

    /// Clock hours on a three-hour grid across the linear day, midnight included.
    func hourTicks(calendar: Calendar = .current) -> [Date] {
        guard let first = calendar.nextDate(after: axis.start, matching: DateComponents(minute: 0, second: 0),
                                            matchingPolicy: .nextTime) else { return [] }
        var ticks: [Date] = []
        var tick = first
        let last = axis.breakAt.addingTimeInterval(-40 * 60)
        while tick <= last {
            if calendar.component(.hour, from: tick) % 3 == 0 { ticks.append(tick) }
            tick = tick.addingTimeInterval(3600)
        }
        return ticks
    }

    /// Ten-minute marks inside the magnified half hour.
    func magnifiedTicks(calendar: Calendar = .current) -> [Date] {
        guard let first = calendar.nextDate(after: axis.breakAt, matching: DateComponents(second: 0),
                                            matchingPolicy: .nextTime) else { return [] }
        var ticks: [Date] = []
        var tick = first
        while tick <= axis.now.addingTimeInterval(-6 * 60) {
            if calendar.component(.minute, from: tick) % 10 == 0 { ticks.append(tick) }
            tick = tick.addingTimeInterval(60)
        }
        return ticks
    }

    /// The `//` gap's span.
    var breakRange: ClosedRange<CGFloat> {
        let start = CGFloat(NowAxis.linearShare) * trackWidth
        return start...(start + CGFloat(NowAxis.breakShare) * trackWidth)
    }
}

/// The axis over the track: hours, the `//` break with its ×N chip, ten-
/// minute marks in the magnified half hour, and the now pill.
struct NowAxisHeader: View {
    let now: Date

    var body: some View {
        Canvas { context, size in
            let metrics = NowTrackMetrics(axis: NowAxis(now: now), width: size.width)
            let y = size.height / 2
            let gap = metrics.breakRange
            let pill = context.resolve(Text("NOW \(PultikFormat.clock(now))")
                .font(Theme.Typo.micro).foregroundStyle(Theme.ink))
            let pillSize = pill.measure(in: size)
            let center = min(metrics.trackWidth, size.width - pillSize.width / 2 - 8)
            let rect = CGRect(x: center - pillSize.width / 2 - 7, y: y - 9, width: pillSize.width + 14, height: 18)
            // Labels draw only where they clear their neighbours, the break
            // and the now pill — a narrow track drops marks, never overlaps them.
            var right: CGFloat = -.infinity
            func label(_ text: Text, at x: CGFloat, before limit: CGFloat) {
                let resolved = context.resolve(text)
                let half = resolved.measure(in: size).width / 2
                guard x - half > right + 6, x + half < limit - 4 else { return }
                context.draw(resolved, at: CGPoint(x: x, y: y))
                right = x + half
            }
            for tick in metrics.hourTicks() {
                let hour = Calendar.current.component(.hour, from: tick)
                label(Text(String(format: "%02d", hour)).font(Theme.Typo.micro)
                    .foregroundStyle(hour == 0 ? Theme.ink2 : Theme.ink3), at: metrics.x(tick), before: gap.lowerBound)
            }
            let slash = Text("//").font(Theme.Typo.micro).foregroundStyle(Theme.ink3)
            context.draw(context.resolve(slash), at: CGPoint(x: (gap.lowerBound + gap.upperBound) / 2, y: y))
            let zoom = context.resolve(Text("×\(Int(NowAxis.magnification))").font(Theme.Typo.micro)
                .foregroundStyle(Theme.ink2))
            context.draw(zoom, at: CGPoint(x: gap.upperBound + 4, y: y), anchor: .leading)
            right = gap.upperBound + 4 + zoom.measure(in: size).width
            for tick in metrics.magnifiedTicks() {
                label(Text(PultikFormat.clock(tick)).font(Theme.Typo.micro).foregroundStyle(Theme.ink3),
                      at: metrics.x(tick), before: rect.minX)
            }
            context.fill(Capsule().path(in: rect), with: .color(Theme.accent.opacity(0.22)))
            context.stroke(Capsule().path(in: rect), with: .color(Theme.accent.opacity(0.7)), lineWidth: 1)
            context.draw(pill, at: CGPoint(x: center, y: y))
        }
        .frame(height: 22)
        .accessibilityLabel("Last 24 hours, the last 30 minutes magnified, now \(PultikFormat.clock(now))")
    }
}

/// One row's stretch of the line: the bar from onset into now, its onset
/// mark (hollow when only observed), a chevron and true age when it began
/// before the window, and a deadline diamond in the future gutter. Lane
/// gridlines, the break band and the now line are drawn here too, so rows
/// stack into one continuous chart.
struct NowTrack: View {
    let incident: NowIncident
    let lane: NowLane
    let now: Date
    var compact = false

    var body: some View {
        Canvas { context, size in
            let metrics = NowTrackMetrics(axis: NowAxis(now: now), width: size.width)
            NowTrack.drawGrid(context, size: size, metrics: metrics)
            let bar = metrics.axis.bar(incident)
            let tone = incident.severity.tone(in: lane)
            let y = compact ? size.height / 2 : size.height * 0.64
            let start = CGFloat(bar.start) * metrics.trackWidth
            let end = metrics.trackWidth
            let line = Path(roundedRect: CGRect(x: start, y: y - 2, width: max(2, end - start), height: 4),
                            cornerRadius: 2)
            context.fill(line, with: .color(tone.opacity(bar.hollow ? 0.45 : 0.9)))
            let dot = CGRect(x: start - 4, y: y - 4, width: 8, height: 8)
            if bar.hollow {
                context.fill(Circle().path(in: dot), with: .color(Theme.canvas))
                context.stroke(Circle().path(in: dot), with: .color(tone), lineWidth: 1.5)
            } else {
                context.fill(Circle().path(in: dot), with: .color(tone))
            }
            if let deadline = bar.deadline { NowTrack.drawDeadline(context, deadline, y: y, metrics: metrics) }
            guard !compact else { return }
            let label = context.resolve(onsetLabel(bar))
            let room = label.measure(in: size).width + 10
            let labelY = y - 11
            if bar.pinned || start < room {
                context.draw(label, at: CGPoint(x: bar.pinned ? 4 : start + 8, y: labelY), anchor: .leading)
            } else {
                context.draw(label, at: CGPoint(x: start - 6, y: labelY), anchor: .trailing)
            }
        }
    }

    /// "14:57 jobs stuck"-style: the onset's clock, or "‹ since Oct 2 · 6d"
    /// past the window's edge; "observed" when Pultík only saw it begin.
    private func onsetLabel(_ bar: NowAxis.Bar) -> Text {
        let onset = incident.onset.date
        let lead: Text
        if bar.pinned {
            lead = Text("‹ since \(PultikFormat.date(onset, now: now)) · \(PultikFormat.age(bar.age))")
        } else {
            lead = Text(PultikFormat.clock(onset)).fontWeight(.semibold).foregroundStyle(Theme.ink)
        }
        let tail = incident.onset.isObserved ? " observed" : incident.onset.isFirstSeen ? " first seen" : ""
        return Text("\(lead)\(tail)").font(.system(size: 10.5)).monospacedDigit().foregroundStyle(Theme.ink2)
    }

    /// The hourly gridlines, the break band and the now line.
    static func drawGrid(_ context: GraphicsContext, size: CGSize, metrics: NowTrackMetrics) {
        for tick in metrics.hourTicks() {
            let x = metrics.x(tick)
            context.fill(Path(CGRect(x: x, y: 0, width: 1, height: size.height)), with: .color(Theme.hairline))
        }
        let gap = metrics.breakRange
        context.fill(Path(CGRect(x: gap.lowerBound, y: 0, width: gap.upperBound - gap.lowerBound, height: size.height)),
                     with: .color(Theme.canvasDeep))
        context.fill(Path(CGRect(x: metrics.trackWidth - 0.5, y: 0, width: 1.5, height: size.height)),
                     with: .color(Theme.accent.opacity(0.8)))
    }

    /// A deadline: a diamond in the future gutter with its date, or a tick
    /// on the bar once it has passed.
    static func drawDeadline(_ context: GraphicsContext, _ placement: NowAxis.Placement, y: CGFloat,
                             metrics: NowTrackMetrics) {
        switch placement {
        case let .future(seconds):
            let x = metrics.trackWidth + NowTrackMetrics.gutter / 2
            var dash = Path()
            dash.move(to: CGPoint(x: metrics.trackWidth, y: y))
            dash.addLine(to: CGPoint(x: x - 5, y: y))
            context.stroke(dash, with: .color(Theme.ink3), style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
            var diamond = Path()
            diamond.move(to: CGPoint(x: x, y: y - 5))
            diamond.addLine(to: CGPoint(x: x + 5, y: y))
            diamond.addLine(to: CGPoint(x: x, y: y + 5))
            diamond.addLine(to: CGPoint(x: x - 5, y: y))
            diamond.closeSubpath()
            context.stroke(diamond, with: .color(Theme.ink2), lineWidth: 1.2)
            let at = metrics.axis.now.addingTimeInterval(seconds)
            let label = seconds < 86400 ? PultikFormat.clock(at) : PultikFormat.date(at, now: metrics.axis.now)
            let when = context.resolve(Text(label).font(.system(size: 9.5)).monospacedDigit()
                .foregroundStyle(Theme.ink3))
            context.draw(when, at: CGPoint(x: x, y: y - 12), anchor: .center)
        case let .track(fraction):
            let x = CGFloat(fraction) * metrics.trackWidth
            context.fill(Path(CGRect(x: x - 0.75, y: y - 6, width: 1.5, height: 12)), with: .color(Theme.ink))
        case .pinned:
            break
        }
    }
}

// MARK: - Ranked rows

/// One ranked row: rank · glyph · title over a meta line led by its id ·
/// age · verb. A fold reads "+N sessions waiting" and expands in place; a
/// ×N series carries its count; a tombstone says the object left Now.
struct NowRankedRow: View {
    let item: NowHomeRow
    let rank: String?
    let now: Date
    let selected: Bool
    var expanded = false
    /// Now first's table: the lane and kind as a micro tag after the rank.
    var laneTag = false
    /// Now first's table: a compact track before the age column.
    var trackWidth: CGFloat?

    var body: some View {
        let row = item.row
        let incident = row.lead
        HStack(spacing: 10) {
            Text(rank ?? "")
                .font(Theme.Typo.figure).foregroundStyle(Theme.ink3)
                .frame(width: 30, alignment: .trailing)
            if laneTag {
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.lane.title).microLabel(row.lane.tone)
                    Text(row.kind.label).microLabel()
                }
                .frame(width: 112, alignment: .leading)
            }
            NowGlyph(kind: row.kind, tone: incident.severity.tone(in: row.lane))
                // An open fold's children sit under its header.
                .padding(.leading, row.parentKey == nil ? 0 : 14)
            VStack(alignment: .leading, spacing: 1) {
                title(row)
                meta(row).lineLimit(1).truncationMode(.tail)
            }
            .opacity(item.isTombstone ? 0.5 : 1)
            Spacer(minLength: 8)
            if let trackWidth {
                NowTrack(incident: incident, lane: row.lane, now: now, compact: true)
                    .frame(width: trackWidth, height: 22)
                    .opacity(item.isTombstone ? 0.35 : 1)
            }
            Text(item.isTombstone ? "—" : PultikFormat.age(now.timeIntervalSince(incident.onset.date)))
                .font(Theme.Typo.figure).foregroundStyle(incident.onset.isObserved ? Theme.ink3 : Theme.ink2)
                .frame(width: 58, alignment: .trailing)
            verb(row).frame(width: 150, alignment: .trailing)
        }
        .padding(.horizontal, 6)
        .frame(height: 44)
    }

    @ViewBuilder
    private func title(_ row: NowRow) -> some View {
        switch (item.isTombstone, row.shape) {
        case (true, _):
            Text("Resolved · no longer in Now").font(Theme.Typo.body).foregroundStyle(Theme.ink2).lineLimit(1)
        case (false, .fold):
            Text("\(Text("+\(row.incidents.count)").fontWeight(.semibold)) \(row.kind.plural)")
                .font(Theme.Typo.body).foregroundStyle(Theme.ink).lineLimit(1)
        case (false, .series):
            HStack(spacing: 6) {
                Text(row.lead.lead.title).font(Theme.Typo.body).foregroundStyle(Theme.ink).lineLimit(1)
                Chip("×\(row.incidents.count)", .danger)
            }
        case (false, .incident):
            Text(row.lead.lead.title).font(Theme.Typo.body).foregroundStyle(Theme.ink).lineLimit(1)
        }
    }

    /// Led by the id, which never ellipsizes; the prose after it truncates.
    private func meta(_ row: NowRow) -> some View {
        let need = row.lead.lead
        var parts: [String] = []
        if item.isTombstone {
            parts.append(need.title)
        } else if row.shape == .fold {
            parts.append(row.incidents.prefix(3).map(\.lead.title).joined(separator: " · "))
        } else {
            if let subtitle = need.subtitle, !subtitle.isEmpty { parts.append(subtitle) }
            if row.shape == .series { parts.append("\(row.incidents.count) objects") }
            if row.lead.evidence > 1 { parts.append("\(row.lead.evidence) signals") }
            if need.onset.isObserved { parts.append("observed \(PultikFormat.clock(row.lead.onset.date))") }
            if let deadline = row.lead.deadline {
                parts.append(deadline < now ? "overdue \(PultikFormat.date(deadline, now: now))"
                             : "due \(PultikFormat.date(deadline, now: now))")
            }
        }
        return HStack(spacing: 6) {
            if let id = need.displayID, !item.isTombstone, row.shape != .fold {
                Text(id).font(Theme.Typo.figure).foregroundStyle(Theme.ink2).lineLimit(1).fixedSize().layoutPriority(1)
            }
            Text(parts.joined(separator: " · ")).font(Theme.Typo.meta).monospacedDigit().foregroundStyle(Theme.ink2)
        }
    }

    /// ↵ opens — the selected row says so; every other row names the one
    /// verb its object offers in its module.
    @ViewBuilder
    private func verb(_ row: NowRow) -> some View {
        if item.isTombstone {
            Text("—").font(Theme.Typo.meta).foregroundStyle(Theme.ink3)
        } else if row.shape == .fold {
            HStack(spacing: 5) {
                Text(expanded ? "collapse" : "expand").font(Theme.Typo.meta).foregroundStyle(Theme.ink2)
                KbdHint("↵")
            }
        } else if selected {
            HStack(spacing: 5) {
                Text("Open").font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
                Text("↵").font(.system(size: 9.5, weight: .semibold, design: .monospaced)).foregroundStyle(.white.opacity(0.75))
            }
            .padding(.horizontal, 10)
            .frame(height: 22)
            .background(Theme.accent, in: Capsule())
        } else {
            HStack(spacing: 5) {
                Text(row.lead.lead.verb.title).font(Theme.Typo.meta).foregroundStyle(Theme.ink2).lineLimit(1)
                if let shortcut = row.lead.lead.verb.shortcut { KbdHint(shortcut) }
            }
        }
    }
}

/// Needs cleared within the window (D14): off the line, out of rank and
/// counts, each with the time it cleared.
struct NowHandledSection: View {
    let entries: [ObservationLedger.Entry]

    var body: some View {
        if !entries.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("Handled · 24 h").microLabel()
                    Spacer()
                    Text("\(entries.count)").font(Theme.Typo.meta).monospacedDigit().foregroundStyle(Theme.ink3)
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 8)
                ForEach(entries.prefix(12), id: \.episodeID) { entry in
                    HStack(spacing: 10) {
                        Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.ok)
                            .frame(width: 30, alignment: .trailing)
                        Text(entry.need.title).font(Theme.Typo.body).foregroundStyle(Theme.ink2).lineLimit(1)
                        if let subtitle = entry.need.subtitle {
                            Text(subtitle).font(Theme.Typo.meta).foregroundStyle(Theme.ink3).lineLimit(1)
                        }
                        Spacer(minLength: 8)
                        Text("cleared \(entry.clearedAt.map { PultikFormat.clock($0) } ?? "—")")
                            .font(Theme.Typo.meta).monospacedDigit().foregroundStyle(Theme.ink3)
                    }
                    .padding(.horizontal, 6)
                    .frame(height: 26)
                }
            }
        }
    }
}

// MARK: - Hero

/// The hero strip both styles lead with: the incident count, the four
/// lanes (grouped incidents, raw signals labelled beside them), the CI day
/// and the snapshot's age while restored needs still show.
struct NowHero: View {
    let queue: NowQueue
    let now: Date
    var ci: CIThroughput?
    var ciHost: String?
    var asOf: Date?
    var compact = false

    var body: some View {
        HStack(alignment: .top, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text(asOf.map { "Now · \(PultikFormat.asOf($0))" } ?? "Now · ranked").microLabel()
                HStack(alignment: .lastTextBaseline, spacing: 8) {
                    Text("\(queue.incidentCount)")
                        .font(Theme.Typo.hero).foregroundStyle(Theme.ink)
                        .contentTransition(.numericText()).animation(.snappy, value: queue.incidentCount)
                    Text(queue.incidentCount == 1 ? "needs you" : "need you")
                        .font(Theme.Typo.heroUnit).foregroundStyle(Theme.ink2)
                }
                .opacity(asOf == nil ? 1 : 0.6)
                if !compact {
                    Text("\(queue.needCount) signals grouped").font(Theme.Typo.meta).monospacedDigit()
                        .foregroundStyle(Theme.ink2)
                }
            }
            .frame(minWidth: 150, alignment: .leading)
            ForEach(NowLane.allCases, id: \.self) { lane in
                Rectangle().fill(Theme.hairline).frame(width: 1, height: 52)
                laneCell(queue.summary(lane))
            }
            if let ci {
                Rectangle().fill(Theme.hairline).frame(width: 1, height: 52)
                ciCell(CIThroughputGlance(ci), jobs: ci.jobs)
            }
            Spacer(minLength: 0)
        }
        .kitTile()
    }

    private func laneCell(_ summary: NowLaneSummary) -> some View {
        let lead = queue.rows.first { $0.lane == summary.lane }?.lead
        return VStack(alignment: .leading, spacing: 3) {
            Label(summary.lane.title, systemImage: summary.lane.symbol).labelStyle(.titleAndIcon).microLabel()
            Text("\(summary.incidents)")
                .font(Theme.Typo.stat)
                .foregroundStyle(summary.incidents > 0 ? summary.lane.tone : Theme.ink3)
            if !compact {
                Group {
                    if let lead {
                        Text("\(lead.lead.title) · \(PultikFormat.age(now.timeIntervalSince(lead.onset.date)))")
                    } else {
                        Text("none")
                    }
                }
                .font(Theme.Typo.meta).monospacedDigit().foregroundStyle(Theme.ink2).lineLimit(1)
                .frame(maxWidth: 170, alignment: .leading)
                if summary.folded > 0 || summary.needs > summary.incidents {
                    Text("\(summary.needs) signals\(summary.folded > 0 ? " · \(summary.folded) folded" : "")")
                        .font(Theme.Typo.meta).monospacedDigit().foregroundStyle(Theme.ink3).lineLimit(1)
                }
            }
        }
    }

    private func ciCell(_ glance: CIThroughputGlance, jobs: Int) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(ciHost.map { "CI today · \($0)" } ?? "CI today").microLabel()
            HStack(alignment: .lastTextBaseline, spacing: 4) {
                Text("\(jobs)").font(Theme.Typo.stat).foregroundStyle(Theme.ink)
                Text("jobs").font(Theme.Typo.meta).foregroundStyle(Theme.ink2)
            }
            if !compact, let delta = glance.delta {
                Text("\(delta) vs yesterday").font(Theme.Typo.meta).monospacedDigit().foregroundStyle(Theme.ink2)
            }
        }
    }
}
