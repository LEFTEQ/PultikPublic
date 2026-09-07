import SwiftUI

/// The status strip across the panel's bottom edge.
///
/// It is supporting chrome rather than the panel's primary hierarchy: search
/// and the grouped inbox own the top edge, while CI, alerts, Eve, freshness and
/// window actions close the panel as one stable full-width footer.
///
/// One line by contract, same as the footer was: every child is lineLimit(1)
/// and fixed-shape, because an overflowing cell in a fixed frame makes SwiftUI
/// wrap character-by-character and balloons the strip into a column of glyphs.
struct PanelFooter: View {
    @Environment(\.panelIsPresented) private var panelIsPresented
    let store: StatusStore
    let eveOnline: Bool?
    var todoCount: Int = 0
    var onTodos: () -> Void = {}

    var body: some View {
        HStack(spacing: 12) {
            if store.isSectionVisible("ci") {
                CIFooterSummary(repos: store.repos)
            }
            if store.isSectionVisible("alerts"), let latest = store.visibleAlerts.first {
                AlertPulse(latest: latest, unread: store.unreadAlertCount)
            }
            if todoCount > 0 {
                Button(action: onTodos) {
                    HStack(spacing: 4) {
                        Image(systemName: "checklist")
                            .font(.system(size: 9))
                        Text("\(todoCount)")
                            .font(.system(size: 9.5, design: .monospaced))
                            .monospacedDigit()
                    }
                    .foregroundStyle(.secondary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .help("\(todoCount) open todo\(todoCount == 1 ? "" : "s") — pultik-memory")
            }
            Spacer(minLength: 8)
            EveSummary(sessions: store.eveSessions, online: eveOnline)
            refreshState
            actions
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .lineLimit(1)
    }

    @ViewBuilder
    private var refreshState: some View {
        if store.isRefreshing {
            if panelIsPresented {
                ProgressView().controlSize(.small).scaleEffect(0.8)
            } else {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
        } else if let last = store.lastRefresh {
            Text(last.shortAge == "now" ? "just now" : last.shortAge)
                .font(.system(size: 9.5, design: .monospaced))
                .foregroundStyle(.tertiary)
        }
        // Icon only — error PROSE never renders in the strip (lean and fixed-
        // shape); the text lives in the hover popover.
        if let error = store.globalError {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 9))
                .foregroundStyle(.red)
                .help(error)
        }
        // A paused breaker is why a rail is missing. Without this the sections
        // just vanish and the app looks broken instead of deliberately quiet.
        if ProbeGate.shared.isPaused {
            Image(systemName: "pause.circle")
                .font(.system(size: 9))
                .foregroundStyle(.orange)
                .help("Probes paused — refresh to retry now\n\n" + ProbeGate.shared.summary)
        }
    }

    private var actions: some View {
        HStack(spacing: 2) {
            ChromeButton(symbol: "arrow.clockwise", help: "Refresh now") {
                // The one path that may knock on a host that just refused us:
                // a person clicked. Opening the panel deliberately does NOT
                // clear the breakers — that would poll on every summon.
                ProbeGate.shared.resumeAll()
                Task { await store.refresh() }
            }
            .disabled(store.isRefreshing)
            ChromeButton(symbol: "gearshape", help: "Settings") {
                AppDelegate.shared?.openSettings()
            }
            ChromeButton(symbol: "power", help: "Quit Pultík") {
                AppDelegate.shared?.quit()
            }
        }
    }
}

private struct ChromeButton: View {
    let symbol: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11))
                .frame(width: 20, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(help)
    }
}

// MARK: - eve alerts pulse

/// The latest visible-lane alert as a compact badge — bell plus unread count,
/// red when the latest is critical. Deliberately NO title text: the bar stays
/// lean and fixed-shape, the prose lives in the hover popover, and the alerts
/// rail is the list. A click opens the eve console for the deep dive.
struct AlertPulse: View {
    let latest: EveAlert
    let unread: Int

    private var tone: Color {
        latest.severity == .critical ? .red : .secondary
    }

    var body: some View {
        Button {
            if let url = URL(string: "https://eve.ops.example.invalid") {
                NSWorkspace.shared.open(url)
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: latest.severity == .critical
                      ? "bell.badge.fill" : "bell")
                    .font(.system(size: 9))
                if unread > 0 {
                    Text("\(unread)")
                        .font(.system(size: 9.5, design: .monospaced))
                        .monospacedDigit()
                }
            }
            .foregroundStyle(tone)
            .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help("\(latest.title)\n\(latest.category) · \(latest.ts.shortAge) ago — \(unread) unread\n\(latest.body)")
    }
}

// MARK: - eve

/// eve's corner: reachability plus what it is actually doing. The palette only
/// ever showed a green dot, which said "the service answers" and nothing about
/// the work in flight.
struct EveSummary: View {
    let sessions: [EveSession]
    let online: Bool?

    private var running: Int { sessions.filter(\.isRunning).count }
    private var waiting: Int { sessions.filter { $0.status == "waiting" }.count }

    var body: some View {
        HStack(spacing: 5) {
            Text("✦")
                .font(.system(size: 10))
                .foregroundStyle(online == false ? Color.secondary : Theme.eve)
            Text(label)
                .font(.system(size: 9.5, design: .monospaced))
                .foregroundStyle(online == false ? .tertiary : .secondary)
                .lineLimit(1)
        }
        .help(help)
    }

    private var label: String {
        guard online != false else { return "eve offline" }
        if running == 0 && waiting == 0 { return "eve idle" }
        var parts: [String] = []
        if running > 0 { parts.append("\(running) running") }
        if waiting > 0 { parts.append("\(waiting) waiting") }
        return parts.joined(separator: " · ")
    }

    private var help: String {
        guard online != false else { return "eve is not reachable — check the mesh" }
        guard !sessions.isEmpty else { return "eve is reachable, no PR sessions running" }
        return sessions.prefix(8).map { session in
            let state = session.status ?? "?"
            return "\(state) — \(session.prompt?.prefix(60) ?? "session \(session.id)")"
        }.joined(separator: "\n")
    }
}
