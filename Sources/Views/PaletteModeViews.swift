import SwiftUI

// MARK: - Glass

/// Liquid Glass where the OS has it (macOS 26+), regular material below —
/// the floating completion card's background.
struct GlassCard: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        } else {
            content
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(.white.opacity(0.12), lineWidth: 0.5)
                )
        }
    }
}

/// One row of the floating completion card (slash verbs, palette modes).
struct FloatingCompletionRow: View {
    let systemImage: String
    let primary: String
    var primaryMono = false
    let blurb: String
    var selected = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: systemImage)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 18)
                Text(primary)
                    .font(primaryMono
                        ? .system(size: 12, design: .monospaced)
                        : .system(size: 12.5, weight: .medium))
                Text(blurb)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                if selected { KeyCue("↵") }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(selected ? Theme.accentSoft.opacity(0.6) : .clear,
                    in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct KeyCue: View {
    let label: String
    init(_ label: String) { self.label = label }

    var body: some View {
        Text(label)
            .font(.system(size: 10, weight: .medium, design: .monospaced))
            .foregroundStyle(.tertiary)
    }
}

// MARK: - .prod mode — the error archive

/// ALL unresolved prod errors, 12 days deep, staggered 4-day windows. The
/// header narrates the load state; rows are the same ProdIssueRow the strip
/// uses, so triage reads identically everywhere.
struct ProdArchiveView: View {
    let archive: ProdArchive
    /// Pre-filtered (query + resolved-hiding) by the panel — keyboard-sync'd.
    let issues: [ProdIssue]
    var selectedID: String?
    let isSelected: (String) -> Bool
    let onBack: () -> Void

    var body: some View {
        ScrollViewReader { scroller in
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Button(action: onBack) {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 10, weight: .bold))
                        }
                        .buttonStyle(.borderless)
                        .help("Back (Esc)")
                        Text("Prod errors")
                            .font(.system(size: 14, weight: .semibold))
                        Text("last \(archive.loadedDays)d · \(issues.count)")
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(.secondary)
                        if archive.isLoading {
                            ProgressView().controlSize(.mini).scaleEffect(0.7)
                        }
                        Spacer()
                        Text("⇥ resolve")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 8)
                    .padding(.top, 10)
                    .padding(.bottom, 4)

                    if let error = archive.error {
                        Text(error)
                            .font(.system(size: 11))
                            .foregroundStyle(.orange)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 6)
                    }
                    if issues.isEmpty && !archive.isLoading && archive.error == nil {
                        Text("quiet — no unresolved errors in the loaded window")
                            .font(.system(size: 12))
                            .foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 24)
                    }
                    ForEach(issues) { prodIssue in
                        ProdIssueRow(prodIssue: prodIssue,
                                     selected: isSelected("prod:\(prodIssue.id)"))
                            .opacity(ResolvedStore.shared.isResolved("prod:\(prodIssue.id)") ? 0.35 : 1)
                            .id("prod:\(prodIssue.id)")
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
            }
            .onChange(of: selectedID) { _, id in
                guard let id else { return }
                withAnimation(.easeOut(duration: 0.12)) { scroller.scrollTo(id, anchor: .bottom) }
            }
        }
        .onAppear { archive.load() }
    }
}

// MARK: - .issues mode — GitHub issue search

/// Issues live nowhere else in pultik: they never enter the main list, only
/// this mode. Resting state is the prefetched recent sweep; typing searches
/// GitHub across the same repos the PR archive uses.
struct IssueSearchView: View {
    let store: StatusStore
    /// Pre-filtered by the panel so the rows and ↑/↓ stay in step.
    let issues: [ArchivedIssue]
    var selectedID: String?
    let isSelected: (String) -> Bool
    let onBack: () -> Void

    private var isLoading: Bool { store.isSearchingIssues || store.isPrefetchingIssues }

    var body: some View {
        ScrollViewReader { scroller in
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Button(action: onBack) {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 10, weight: .bold))
                        }
                        .buttonStyle(.borderless)
                        .help("Back (Esc)")
                        Text("GitHub issues")
                            .font(.system(size: 14, weight: .semibold))
                        Text(store.showingRecentIssues
                             ? "recently updated · \(issues.count)"
                             : "\(issues.count) found")
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(.secondary)
                        if isLoading {
                            ProgressView().controlSize(.mini).scaleEffect(0.7)
                        }
                        Spacer()
                        Text("⇥ resolve")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 8)
                    .padding(.top, 10)
                    .padding(.bottom, 4)

                    if let error = store.issueSearchError {
                        Text(error)
                            .font(.system(size: 11))
                            .foregroundStyle(.orange)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 6)
                    }
                    if issues.isEmpty && !isLoading && store.issueSearchError == nil {
                        Text(store.showingRecentIssues
                             ? "nothing open or recently touched across your repos"
                             : "no match — try fewer words, or #812 for an exact number")
                            .font(.system(size: 12))
                            .foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 24)
                    }
                    ForEach(issues) { issue in
                        IssueRow(issue: issue, selected: isSelected("issue:\(issue.id)"))
                            .opacity(ResolvedStore.shared.isResolved("issue:\(issue.id)") ? 0.35 : 1)
                            .id("issue:\(issue.id)")
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
            }
            .onChange(of: selectedID) { _, id in
                guard let id else { return }
                withAnimation(.easeOut(duration: 0.12)) { scroller.scrollTo(id, anchor: .bottom) }
            }
        }
        .onAppear { store.warmIssuesIfNeeded() }
    }
}

// MARK: - .vit mode — all listeners

struct VitrinkaAllView: View {
    let entries: [VitrinkaListening]
    let isSelected: (String) -> Bool
    let onBack: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Button(action: onBack) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 10, weight: .bold))
                    }
                    .buttonStyle(.borderless)
                    .help("Back (Esc)")
                    Text("Vitrinka listeners")
                        .font(.system(size: 14, weight: .semibold))
                    Spacer()
                }
                .padding(.horizontal, 8)
                .padding(.top, 10)
                .padding(.bottom, 4)

                if entries.isEmpty {
                    Text("no session is listening to any board")
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 24)
                }
                ForEach(entries) { entry in
                    VitrinkaListRow(entry: entry, selected: isSelected("vit:\(entry.id)"))
                        .opacity(ResolvedStore.shared.isResolved("vit:\(entry.id)") ? 0.35 : 1)
                        .id("vit:\(entry.id)")
                }
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 8)
        }
    }
}

// MARK: - .b mode — recent boards

struct BoardsAllView: View {
    let boards: [VitrinkaBoard]
    let isSelected: (String) -> Bool
    let onBack: () -> Void

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Button(action: onBack) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 10, weight: .bold))
                    }
                    .buttonStyle(.borderless)
                    .help("Back (Esc)")
                    Text("Boards")
                        .font(.system(size: 14, weight: .semibold))
                    Text("most recently updated first")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                    Spacer()
                }
                .padding(.horizontal, 8)
                .padding(.top, 10)
                .padding(.bottom, 4)

                if boards.isEmpty {
                    Text("no board matches")
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 24)
                }
                ForEach(boards) { board in
                    VitrinkaBoardRow(board: board, selected: isSelected("board:\(board.slug)"))
                        .id("board:\(board.slug)")
                }
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 8)
        }
    }
}

// MARK: - .organize mode — workspace layouts

struct OrganizePageView: View {
    let layouts: [String]
    let isSelected: (String) -> Bool
    let onRun: (String) -> Void
    let onBack: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Button(action: onBack) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 10, weight: .bold))
                    }
                    .buttonStyle(.borderless)
                    .help("Back (Esc)")
                    Text("Organize workspaces")
                        .font(.system(size: 14, weight: .semibold))
                    Spacer()
                    Text("route + tile + spawn")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 8)
                .padding(.top, 10)
                .padding(.bottom, 4)

                if layouts.isEmpty {
                    Text("no layout matches — ↵ runs the typed name anyway")
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 24)
                }
                ForEach(layouts, id: \.self) { name in
                    FloatingCompletionRow(
                        systemImage: "rectangle.3.group",
                        primary: name, primaryMono: true,
                        blurb: name == "default" ? "bare ↵ runs this one" : "",
                        selected: isSelected("organize:\(name)")
                    ) { onRun(name) }
                        .id("organize:\(name)")
                }
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 8)
        }
    }
}

// MARK: - Path card (a pasted path, repaired, with its verbs)

/// The floating card for a path pasted into the palette. One row: what was
/// found (or the nearest directory when it was not), then the verb chips
/// with the keyboard highlight, then the key legend. Everything the keyboard
/// does here is routed by `StatusPanelView.handleKey`; the chips only add a
/// mouse path to the same verbs.
struct PathCard: View {
    let target: PathTarget
    let highlighted: Int
    let onVerb: (PathVerb) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: target.isDirectory ? "folder.fill" : "doc.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(target.isNearest ? Color.orange : Theme.accent)
                    .frame(width: 16)
                if target.isNearest {
                    Text("not found · nearest")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(Color.orange)
                }
                Text(target.name)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                if let line = target.line {
                    Text(":\(line)\(target.column.map { ":\($0)" } ?? "")")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                Text(target.abbreviatedDirectory)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
                Spacer(minLength: 0)
            }
            if let missing = target.missing {
                Text((missing as NSString).abbreviatingWithTildeInPath)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.leading, 24)
            }
            HStack(spacing: 6) {
                ForEach(Array(target.verbs.enumerated()), id: \.element) { index, verb in
                    Button { onVerb(verb) } label: {
                        HStack(spacing: 5) {
                            Text(verb.title(for: target))
                                .font(.system(size: 11.5, weight: index == highlighted ? .semibold : .medium))
                            if let chord = verb.chord {
                                Text(chord)
                                    .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .background(
                            index == highlighted ? Theme.accentSoft : Color.white.opacity(0.05),
                            in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .strokeBorder(index == highlighted ? Theme.accent.opacity(0.6) : .clear, lineWidth: 1)
                        )
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text(verb.title(for: target)))
                    .accessibilityAddTraits(index == highlighted ? .isSelected : [])
                }
                Spacer(minLength: 0)
                Text("↵ run · ⇥ next")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
            .padding(.leading, 24)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .modifier(GlassCard())
        .shadow(color: .black.opacity(0.35), radius: 14, y: 5)
    }
}
