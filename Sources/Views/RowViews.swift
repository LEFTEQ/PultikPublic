import SwiftUI

private struct PanelPresentedEnvironmentKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// The warm panel remains mounted while ordered out. Indefinite effects
    /// must respect this value or they keep the whole hidden tree rendering.
    var panelIsPresented: Bool {
        get { self[PanelPresentedEnvironmentKey.self] }
        set { self[PanelPresentedEnvironmentKey.self] = newValue }
    }
}

// MARK: - Shared row chrome

private struct RowChrome: ViewModifier {
    let url: String?
    /// Keyboard selection — the row ↵ would open. Outranks hover so arrowing
    /// through the list stays legible while the mouse sits somewhere else.
    var selected = false
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .padding(.vertical, 4)
            .padding(.horizontal, 8)
            .background(background, in: RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(selected ? Theme.accent.opacity(0.35) : .clear, lineWidth: 1)
            )
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .onTapGesture {
                if let url, let parsed = URL(string: url) {
                    NSWorkspace.shared.open(parsed)
                }
            }
    }

    private var background: Color {
        if selected { return Theme.accent.opacity(0.16) }
        return hovering ? Color.primary.opacity(0.06) : .clear
    }
}

/// Small mono state chip — the inbox row's vocabulary for checks/review/eve.
struct StateChip: View {
    let label: String
    let tone: Color
    var filled = true

    var body: some View {
        Text(label)
            .font(.system(size: 9.5, weight: .medium, design: .monospaced))
            .foregroundStyle(tone)
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .background(filled ? tone.opacity(0.11) : .clear, in: RoundedRectangle(cornerRadius: 4))
    }
}

// MARK: - Inbox PR row

/// One dense line: state glyph · repo · #num · title ······ chips.
struct InboxPRRow: View {
    let entry: StatusStore.InboxPR
    var selected = false
    @Environment(\.panelIsPresented) private var panelIsPresented

    private var info: PRInfo { entry.info }

    var body: some View {
        HStack(spacing: 7) {
            stateGlyph
                .frame(width: 14)
            Text(entry.repoName)
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(.secondary)
            // verbatim: interpolated Ints in a plain Text go through the
            // locale formatter, which groups thousands — "#1 069" on cs-CZ.
            Text(verbatim: "#\(info.pr.number)")
                .font(.system(size: 10.5, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(.tertiary)
            Text(info.pr.title)
                .font(.system(size: 12, weight: info.attentionRank == 0 ? .medium : .regular))
                .foregroundStyle(info.attentionRank <= 1 ? .primary : .secondary)
                .lineLimit(1)
            if info.isDraft {
                StateChip(label: "draft", tone: .secondary)
            }

            Spacer(minLength: 8)

            statusChip
            if let session = entry.eveSession {
                EveSessionChip(session: session)
            }
        }
        .opacity(info.isDraft ? 0.55 : 1)
        .modifier(RowChrome(url: info.pr.htmlUrl, selected: selected))
    }

    @ViewBuilder
    private var stateGlyph: some View {
        switch (info.state, info.review) {
        case (.failure, _):
            Image(systemName: "xmark.circle.fill").foregroundStyle(.red).font(.system(size: 11))
        case (_, .changesRequested):
            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange).font(.system(size: 11))
        case (.running, _):
            Image(systemName: "circle.dotted.circle").foregroundStyle(.blue)
                .font(.system(size: 11))
                .symbolEffect(.pulse, isActive: panelIsPresented)
        case (.success, .approved):
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).font(.system(size: 11))
        default:
            Image(systemName: "circle").foregroundStyle(.tertiary).font(.system(size: 10))
        }
    }

    /// The one chip that matters most for this PR right now.
    @ViewBuilder
    private var statusChip: some View {
        if info.state == .failure {
            StateChip(label: "checks ✕", tone: .red)
        } else if info.review == .changesRequested {
            StateChip(label: "changes req.", tone: .orange)
        } else if info.state == .running {
            StateChip(label: "checks …", tone: .blue)
        } else if info.review == .approved {
            StateChip(label: info.state == .success ? "ready" : "approved", tone: .green)
        } else if !info.isDraft {
            StateChip(label: "review awaited", tone: .secondary, filled: false)
        }
    }
}

/// ✦ purple chip linking a PR to its eve PR-subagent run session.
struct EveSessionChip: View {
    let session: EveSession
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 3) {
            Text("✦")
                .font(.system(size: 9))
            Text(label)
                .font(.system(size: 9.5, weight: .medium, design: .monospaced))
        }
        .foregroundStyle(Theme.eve)
        .padding(.horizontal, 5)
        .padding(.vertical, 1.5)
        .background(Theme.eveSoft.opacity(hovering ? 1.6 : 1), in: RoundedRectangle(cornerRadius: 4))
        .onHover { hovering = $0 }
        .onTapGesture {
            if let url = URL(string: session.consoleUrl) {
                NSWorkspace.shared.open(url)
            }
        }
        .help("Open eve session")
    }

    private var label: String {
        if session.isRunning { return "eve · running" }
        if let age = session.updatedAt?.shortAge { return "eve · \(age)" }
        return "eve"
    }
}

// MARK: - Search result row

private extension PROutcome {
    var symbol: String {
        switch self {
        case .merged: "arrow.triangle.merge"
        case .closed: "xmark.circle.fill"
        case .open: "circle"
        case .draft: "circle.dotted"
        }
    }

    var tone: Color {
        switch self {
        case .merged: Theme.eve      // GitHub's merged purple
        case .closed: .red
        case .open: .green
        case .draft: .secondary
        }
    }

    var label: String {
        switch self {
        case .merged: "merged"
        case .closed: "closed"
        case .open: "open"
        case .draft: "draft"
        }
    }
}

/// One PR found by searching GitHub — merged, closed or open, from any active
/// repo. Quieter than an inbox row on purpose: this is history, not work.
struct ArchivedPRRow: View {
    let pr: ArchivedPR
    var selected = false

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: pr.outcome.symbol)
                .font(.system(size: 11))
                .foregroundStyle(pr.outcome.tone)
                .frame(width: 14)
            Text(pr.repoName)
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(.secondary)
            Text(verbatim: "#\(pr.number)")
                .font(.system(size: 10.5, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(.tertiary)
            Text(pr.title)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Spacer(minLength: 8)

            StateChip(label: pr.outcome.label, tone: pr.outcome.tone)
            Text(pr.updatedAt.shortAge)
                .font(.system(size: 9.5, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(.tertiary)
        }
        .modifier(RowChrome(url: pr.url, selected: selected))
    }
}

// MARK: - Issue row (the .issues mode)

private extension IssueOutcome {
    var symbol: String {
        switch self {
        case .open: "smallcircle.filled.circle"
        case .closed: "checkmark.circle.fill"
        case .notPlanned: "slash.circle.fill"
        }
    }

    var tone: Color {
        switch self {
        case .open: .green
        case .closed: Theme.eve      // GitHub's completed purple
        case .notPlanned: .secondary
        }
    }

    var label: String {
        switch self {
        case .open: "open"
        case .closed: "closed"
        case .notPlanned: "not planned"
        }
    }
}

/// One issue found by searching GitHub. Two lines where a PR row needs one:
/// labels and the comment count are what tell two similarly-titled issues
/// apart, and this mode is the only place issues appear at all.
struct IssueRow: View {
    let issue: ArchivedIssue
    var selected = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 7) {
                Image(systemName: issue.outcome.symbol)
                    .font(.system(size: 11))
                    .foregroundStyle(issue.outcome.tone)
                    .frame(width: 14)
                Text(issue.repoName)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.secondary)
                Text(verbatim: "#\(issue.number)")
                    .font(.system(size: 10.5, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
                Text(issue.title)
                    .font(.system(size: 12))
                    .lineLimit(1)

                Spacer(minLength: 8)

                StateChip(label: issue.outcome.label, tone: issue.outcome.tone)
                Text(issue.updatedAt.shortAge)
                    .font(.system(size: 9.5, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
            }
            if !issue.labels.isEmpty || issue.comments > 0 {
                HStack(spacing: 5) {
                    ForEach(issue.labels.prefix(2), id: \.self) { label in
                        Text(label)
                            .font(.system(size: 9.5))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.primary.opacity(0.07), in: Capsule())
                    }
                    Spacer(minLength: 8)
                    if issue.comments > 0 {
                        Label("\(issue.comments)", systemImage: "bubble.left")
                            .font(.system(size: 9.5, design: .monospaced))
                            .monospacedDigit()
                            .foregroundStyle(.tertiary)
                    }
                }
                // Aligned under the title: the glyph frame plus the row spacing.
                .padding(.leading, 21)
            }
        }
        .modifier(RowChrome(url: issue.url, selected: selected))
    }
}

// MARK: - Prod strip row

/// One Sentry production issue — red, dense, click → Sentry.
struct ProdIssueRow: View {
    let prodIssue: ProdIssue
    var selected = false

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 10))
                .foregroundStyle(.red)
                .frame(width: 14)
            Text(prodIssue.productLabel)
                .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                .foregroundStyle(.red)
            Text(prodIssue.issue.title)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
            Spacer(minLength: 8)
            Text(verbatim: "\(prodIssue.issue.eventCount)× · \(prodIssue.issue.userCount) users · \(prodIssue.issue.lastSeen.shortAge)")
                .font(.system(size: 9.5, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .modifier(RowChrome(url: prodIssue.issue.permalink, selected: selected))
    }
}

// MARK: - CI footer

/// The demoted runner layer, demoted further (2026-08-08): aggregate totals
/// only — "CI ✕3 ●2" or a lone ✓ — because per-repo entries multiplied by
/// eight repos overflowed the cell into truncated one-letter noise. The
/// per-repo breakdown lives in the hover popover; a click opens the Actions
/// page of the first repo that needs eyes.
struct CIFooterSummary: View {
    let repos: [RepoStatus]

    private var failed: Int {
        repos.reduce(0) { $0 + $1.runs.filter(\.failed).count + $1.deploys.filter(\.failed).count }
    }
    private var running: Int {
        repos.reduce(0) { $0 + $1.runs.filter(\.isRunning).count + $1.deploys.filter(\.isRunning).count }
    }
    private var unreachable: Bool { repos.allSatisfy { $0.error != nil } && !repos.isEmpty }

    /// Failed beats running beats first — where the click should land.
    private var targetRepo: RepoStatus? {
        repos.first { !$0.runs.filter(\.failed).isEmpty || !$0.deploys.filter(\.failed).isEmpty }
            ?? repos.first { !$0.runs.filter(\.isRunning).isEmpty || !$0.deploys.filter(\.isRunning).isEmpty }
            ?? repos.first
    }

    var body: some View {
        HStack(spacing: 6) {
            Kicker(text: "CI", tone: Color.secondary.opacity(0.7))
            if unreachable {
                Image(systemName: "wifi.slash").font(.system(size: 9)).foregroundStyle(.tertiary)
            } else {
                if failed > 0 {
                    Text(verbatim: "✕\(failed)")
                        .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                        .monospacedDigit()
                        .foregroundStyle(.red)
                }
                if running > 0 {
                    Text(verbatim: "●\(running)")
                        .font(.system(size: 10.5, design: .monospaced))
                        .monospacedDigit()
                        .foregroundStyle(.blue)
                }
                if failed == 0 && running == 0 {
                    Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.green)
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            guard let repo = targetRepo,
                  let url = URL(string: "https://github.com/\(repo.slug)/actions") else { return }
            NSWorkspace.shared.open(url)
        }
        .help(breakdown)
    }

    /// One line per repo — the detail the bar no longer carries.
    private var breakdown: String {
        repos.map { repo in
            let name = repo.slug.split(separator: "/").last.map(String.init) ?? repo.slug
            if let error = repo.error { return "\(name) — \(error)" }
            let failed = repo.runs.filter(\.failed).count + repo.deploys.filter(\.failed).count
            let running = repo.runs.filter(\.isRunning).count + repo.deploys.filter(\.isRunning).count
            let state = failed > 0 ? "✕\(failed)" : running > 0 ? "●\(running)" : "✓"
            return "\(name) \(state)"
        }.joined(separator: "\n")
    }
}
