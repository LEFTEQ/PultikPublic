import SwiftUI

private struct PanelPresentedEnvironmentKey: EnvironmentKey {
    static let defaultValue = false
}

private struct BodyShownEnvironmentKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    /// The warm panel remains mounted while ordered out. Indefinite effects
    /// must respect this value or they keep the whole hidden tree rendering.
    var panelIsPresented: Bool {
        get { self[PanelPresentedEnvironmentKey.self] }
        set { self[PanelPresentedEnvironmentKey.self] = newValue }
    }

    /// A warm module body mounted but not displayed (D4) draws at opacity 0,
    /// and SwiftUI still renders whatever animates in it — every frame.
    var bodyShown: Bool {
        get { self[BodyShownEnvironmentKey.self] }
        set { self[BodyShownEnvironmentKey.self] = newValue }
    }

    /// Whether an indefinite effect (a pulse, a spinner) may run here: the
    /// panel up and the body displayed (vt-7781 AC 8: a hidden body's pulse
    /// re-rendered the panel every frame).
    var animates: Bool {
        #if DEBUG
        if Self.debugStill { return false }
        #endif
        return panelIsPresented && bodyShown
    }

    #if DEBUG
    /// `PULTIK_DEBUG_STILL=1`: no indefinite effect anywhere, to measure what the visible ones cost.
    static let debugStill = ProcessInfo.processInfo.environment["PULTIK_DEBUG_STILL"] != nil
    #endif

    /// A row's click (stay in Pultík S1): the panel opens the object's detail
    /// (or the row's own ↵ in the global results). Nil outside the panel.
    var openRow: ((String) -> Void)? {
        get { self[OpenRowEnvironmentKey.self] }
        set { self[OpenRowEnvironmentKey.self] = newValue }
    }
}

private struct OpenRowEnvironmentKey: EnvironmentKey {
    static let defaultValue: ((String) -> Void)? = nil
}

// MARK: - Shared row chrome

/// A list row's chrome (stay in Pultík S1): a click selects the row and opens
/// its object inside Pultík through the panel's `openRow`; the page in the
/// browser is the hover ↗ on the trailing edge, or ⌘↵.
private struct RowChrome: ViewModifier {
    /// The row's object id (`pr:…`, `archive:…`, `sentry:…`).
    let id: String
    let url: String?
    /// Keyboard selection — the row ↵ would open. Outranks hover so arrowing
    /// through the list stays legible while the mouse sits somewhere else;
    /// drawn as the Kit's neutral lift, never a red fill.
    var selected = false
    @State private var hovering = false
    @Environment(\.openRow) private var openRow

    func body(content: Content) -> some View {
        content
            .padding(.vertical, 4)
            .padding(.horizontal, 8)
            .padding(.trailing, hovering ? 18 : 0)
            .background { RowBackground(selected: selected, hovering: hovering, mark: id) }
            .overlay(alignment: .trailing) {
                if hovering { LinkGlyph(url: url.flatMap(URL.init(string:)), label: "Open the page").padding(.trailing, 4) }
            }
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .onTapGesture { openRow?(id) }
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
    /// Off inside a repo-grouped list (Home's PR tile), where the group
    /// heading already names the repo.
    var showsRepo = true
    @Environment(\.animates) private var animates
    /// Shows the mark's check in a list with bulk verbs (bulk D1).
    @State private var hovering = false

    private var info: PRInfo { entry.info }

    var body: some View {
        HStack(spacing: 7) {
            MarkSlot(id: "pr:\(entry.id)", hovering: hovering) { stateGlyph }
                .frame(width: 14)
            if showsRepo {
                Text(entry.repoName)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            // verbatim: interpolated Ints in a plain Text go through the
            // locale formatter, which groups thousands — "#1 069" on cs-CZ.
            Text(verbatim: "#\(info.pr.number)")
                .font(.system(size: 11))
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
        .modifier(RowChrome(id: "pr:\(entry.id)", url: info.pr.htmlUrl, selected: selected))
        .onHover { hovering = $0 }
    }

    @ViewBuilder
    private var stateGlyph: some View {
        switch (info.state, info.review) {
        case (.failure, _):
            Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.danger).font(.system(size: 11))
        case (_, .changesRequested):
            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(Theme.warn).font(.system(size: 11))
        case (.running, _):
            Image(systemName: "circle.dotted.circle").foregroundStyle(Theme.ok)
                .font(.system(size: 11))
                .symbolEffect(.pulse, isActive: animates)
        case (.success, .approved):
            Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.ok).font(.system(size: 11))
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
            StateChip(label: "checks …", tone: Theme.ok)
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

extension PROutcome {
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
        .modifier(RowChrome(id: "archive:\(pr.id)", url: pr.url, selected: selected))
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
        .modifier(RowChrome(id: "issue:\(issue.id)", url: issue.url, selected: selected))
    }
}

// MARK: - Prod strip row

/// One Sentry production issue — red, dense, click → Sentry.
struct ProdIssueRow: View {
    let prodIssue: ProdIssue
    var selected = false
    /// The palette row's id: `prod:` in `.p`, `sentry:` among results.
    var rowID: String?

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
        .modifier(RowChrome(id: rowID ?? "prod:\(prodIssue.id)", url: prodIssue.issue.permalink, selected: selected))
    }
}
