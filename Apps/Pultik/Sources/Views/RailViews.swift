import SwiftUI

// MARK: - Right rail: services

/// Probes filed under the box they RUN on (decision D8=A, 2026-08-27).
///
/// Grouping by host rather than by product because the failure that matters
/// most is a whole box going dark, and a product-shaped list scatters that
/// across four groups — the one shape that hides the cause. The group header
/// carries the verdict for the box: red the moment every service on it is down.
///
/// Host is where the service runs, NOT where the prober lives: api.example.invalid is
/// probed from BuildServer and served from AppServer, and filing it under the
/// prober would have made the grouping a lie.
struct ServiceRail: View {
    let statuses: [ServiceStatus]
    /// Configured server order, so the groups read in the same sequence as the
    /// vitals dock's estate tier rather than alphabetically.
    let hostOrder: [String]
    /// The Estate module's keyboard selection (`ServiceRail.objectID`).
    var selectedID: String?
    /// The Estate module's click: select the tile and open its detail.
    var onOpen: ((String) -> Void)?

    static func objectID(_ service: ServiceStatus) -> String { "service:\(service.id)" }

    /// Grouped and ordered. Services with no host land in a trailing group
    /// rather than vanishing — an unfiled probe is still a probe. The order
    /// is stable across polls: the keyboard walks it (`ordered`).
    static func groups(_ statuses: [ServiceStatus], hostOrder: [String]) -> [(host: String?, services: [ServiceStatus])] {
        var byHost: [String?: [ServiceStatus]] = [:]
        for service in statuses {
            byHost[service.host, default: []].append(service)
        }
        var ordered = hostOrder.compactMap { host -> (String?, [ServiceStatus])? in
            guard let found = byHost[host], !found.isEmpty else { return nil }
            return (host, found)
        }
        // Hosts present on a service but absent from the server list — a
        // hand-edited settings.json can do this, and silently dropping the
        // tile would look like the probe disappeared. Sorted: a dictionary's
        // order changes between polls, and the selection walk must not.
        let known = Set(hostOrder)
        let strays = byHost.keys.compactMap { $0 }.filter { !known.contains($0) }.sorted()
        for host in strays {
            ordered.append((host, byHost[host] ?? []))
        }
        if let unfiled = byHost[nil], !unfiled.isEmpty { ordered.append((nil, unfiled)) }
        return ordered.map { (host: $0.0, services: $0.1) }
    }

    /// The services in drawn order.
    static func ordered(_ statuses: [ServiceStatus], hostOrder: [String]) -> [ServiceStatus] {
        groups(statuses, hostOrder: hostOrder).flatMap(\.services)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(Self.groups(statuses, hostOrder: hostOrder).enumerated()), id: \.offset) { _, group in
                VStack(alignment: .leading, spacing: 5) {
                    ServiceGroupHeader(host: group.host, services: group.services)
                    ForEach(group.services) { service in
                        let id = Self.objectID(service)
                        ServiceTile(service: service, selected: selectedID == id,
                                    onOpen: onOpen.map { open in { open(id) } })
                            .id(id)
                    }
                }
            }
        }
    }
}

/// The box name plus its verdict. The dot is deliberately NOT "any service
/// down" — one failing probe is that tile's problem. It goes red only when
/// every service on the box is down, which is the shape of a box being gone.
private struct ServiceGroupHeader: View {
    let host: String?
    let services: [ServiceStatus]

    private var allDown: Bool {
        !services.isEmpty && services.allSatisfy { $0.up == false }
    }

    private var anyUnknown: Bool {
        services.contains { $0.up == nil }
    }

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(allDown ? Color.red : anyUnknown ? Color.secondary.opacity(0.5) : Color.green)
                .frame(width: 5, height: 5)
            Text((host ?? "elsewhere").uppercased())
                .kerning(0.9)
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 2)
        .padding(.top, 2)
        .help(allDown ? "\(host ?? "Unfiled") — every probe is down"
            : "\(services.count) service\(services.count == 1 ? "" : "s") on \(host ?? "no configured host")")
    }
}

struct ServiceTile: View {
    let service: ServiceStatus
    var selected = false
    /// Replaces the click's browser hop (a module opens its detail instead).
    var onOpen: (() -> Void)?
    @State private var hovering = false

    private var down: Bool {
        service.up == false
    }

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(service.up == nil ? Color.secondary : down ? .red : .green)
                .frame(width: 6, height: 6)
            Text(service.name)
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(.primary)
                .lineLimit(1)
            Spacer(minLength: 4)
            Text(down ? "down" : service.latencyLabel)
                .font(.system(size: 9, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(down ? .red : .secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background {
            // The Estate module's selection: the Kit's lift replaces the fill.
            if selected {
                RowBackground(selected: true)
            } else {
                RoundedRectangle(cornerRadius: 8).fill(.white.opacity(hovering ? 0.06 : 0.035))
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(down ? Color.red.opacity(0.35) : Theme.hairline, lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture {
            if let onOpen { return onOpen() }
            // Container-internal probes aren't openable — fall back to Grafana.
            let target = service.probe.hasPrefix("https") ? service.probe : "https://grafana.ops.example.invalid"
            if let url = URL(string: target) {
                NSWorkspace.shared.open(url)
            }
        }
        .help(service.probe)
    }
}

// MARK: - Right rail: what needs you (2026-09-27)

/// Production Sentry issues, moved from the centre's red strip into the rail
/// in the panel's one row grammar: red dot, the error, then product · events
/// · users in mono, last seen at the edge. Resolved ones dim until the next
/// open hides them, as they did in the strip. `.p` lists every issue.
struct ProdRail: View {
    let issues: [ProdIssue]
    let isResolved: (ProdIssue) -> Bool

    static let limit = 4

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(issues.prefix(Self.limit)) { prodIssue in
                let issue = prodIssue.issue
                RailRow(dot: .filled(issue.level == "warning" ? .orange : .red),
                        title: issue.title,
                        subtitle: "\(prodIssue.productLabel) · \(issue.eventCount)× · \(issue.userCount) users",
                        meta: issue.lastSeen.shortAge,
                        help: "\(issue.shortId) — \(issue.culprit ?? issue.title)\nClick opens it in Sentry",
                        action: {
                            if let url = URL(string: issue.permalink) { NSWorkspace.shared.open(url) }
                        })
                        .opacity(isResolved(prodIssue) ? 0.35 : 1)
            }
            if issues.count > Self.limit {
                RailNote("+\(issues.count - Self.limit) more — .p")
            }
        }
    }
}

/// Firing Prometheus and Loki rules at critical or warning (`AlertGlance`):
/// one row per rule, red dot for critical, orange for warning, the summary
/// and its app · environment, how long it has been firing at the edge. The
/// rules' own view — manual Alertmanager silences are not applied.
struct FiringAlertsRail: View {
    let glance: AlertGlance

    static let limit = 5

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(glance.rows.prefix(Self.limit)) { row in
                let subtitle = [row.context, row.more > 0 ? "+\(row.more) more" : nil]
                    .compactMap { $0 }.joined(separator: " · ")
                RailRow(dot: .filled(row.critical ? .red : .orange),
                        title: row.title,
                        subtitle: subtitle.isEmpty ? nil : subtitle,
                        meta: row.since?.shortAge,
                        help: help(row),
                        accessibilityLabel: "\(row.critical ? "Critical" : "Warning"): \(row.title)",
                        action: { open(row) })
            }
            if glance.rows.count > Self.limit {
                RailNote("+\(glance.rows.count - Self.limit) more firing")
            }
        }
    }

    private func help(_ row: AlertGlance.Row) -> String {
        let lines = row.alerts.map { alert in
            [alert.summary ?? alert.name, alert.description].compactMap { $0 }.joined(separator: " — ")
        }
        return ([row.name] + lines).joined(separator: "\n")
    }

    /// Prometheus rules open their alerts page narrowed to the rule; Loki
    /// has no UI of its own, so its rows only carry the tooltip.
    private func open(_ row: AlertGlance.Row) {
        guard row.alerts.contains(where: { $0.source == .prometheus }),
              let url = MetricsClient.shared.alertsPage(for: row.name)
        else { return }
        NSWorkspace.shared.open(url)
    }
}

/// Reference, not attention: the rail's last line holds the saved links as
/// small titles and the notes as a count into `.notes`. Links stay findable
/// by typing in the palette and are added with `/add-link`.
struct RailFoot: View {
    let links: [SavedLink]
    let notes: Int
    let onOpenLink: (SavedLink) -> Void
    let onOpenNotes: () -> Void

    var body: some View {
        FlowRow(hSpacing: 8, vSpacing: 4) {
            ForEach(links) { link in
                Button { onOpenLink(link) } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 7, weight: .semibold))
                        Text(link.title)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: 120, alignment: .leading)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(link.url)
            }
            if notes > 0 {
                Button(action: onOpenNotes) {
                    Text("\(notes) note\(notes == 1 ? "" : "s") ›")
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Every scratch note — .notes")
            }
        }
        .font(RailRowMetrics.metaFont)
        .foregroundStyle(.tertiary)
        .padding(.horizontal, RailRowMetrics.inset + 2)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A left-aligned wrapping row: an HStack that runs out of proposed width
/// starts a new line instead of overflowing its container. Exists because a
/// fixed-width frame CENTERS an oversized child rather than clipping it —
/// overflow here used to bleed across the panel's centre column.
struct FlowRow: Layout {
    var hSpacing: CGFloat = 4
    var vSpacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews,
                      cache: inout ()) -> CGSize
    {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0
        var rowHeight: CGFloat = 0, widest: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                x = 0
                y += rowHeight + vSpacing
                rowHeight = 0
            }
            x += size.width + hSpacing
            rowHeight = max(rowHeight, size.height)
            widest = max(widest, x - hSpacing)
        }
        return CGSize(width: maxWidth.isFinite ? min(widest, maxWidth) : widest,
                      height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize,
                       subviews: Subviews, cache: inout ())
    {
        var x = bounds.minX, y = bounds.minY
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + vSpacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: .unspecified)
            x += size.width + hSpacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
