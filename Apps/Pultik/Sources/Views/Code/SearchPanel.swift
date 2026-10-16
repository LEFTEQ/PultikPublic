import SwiftUI

/// The side column's panes beside a code canvas (PR workbench D6, Cursor's
/// sidebar model): the file tree, code search and a lookup's results.
enum SidePane: String, CaseIterable {
    case tree, search, references

    var title: String {
        switch self {
        case .tree: "Files"
        case .search: "Search"
        case .references: "References"
        }
    }
}

/// Code search over the repository at the PR's head (D3): match case, whole
/// word and regex, the whole repo or this PR's files; results by file. The
/// first search backfills the head's blobs, so it says so while it waits.
struct CodeSearchPane: View {
    let store: StatusStore
    let repo: String
    let head: String
    /// This PR's files — the narrower scope.
    let prPaths: [String]
    /// ⌘⇧F bumps it: the field takes the keys.
    let focusRequest: Int
    let open: (GrepHit) -> Void
    @State private var query = ""
    @State private var options = SearchOptions()
    @State private var wholeRepo = true
    @State private var hits: [GrepHit]?
    @State private var searching = false
    @State private var failure: String?
    @State private var took: Double?
    @FocusState private var focused: Bool

    private struct Key: Equatable {
        let query: String
        let options: SearchOptions
        let wholeRepo: Bool
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass").font(.system(size: 10)).foregroundStyle(Theme.ink3)
                TextField("Search the code", text: $query)
                    .textFieldStyle(.plain).font(Theme.Typo.meta).focused($focused)
                toggle("Aa", on: $options.caseSensitive, help: "Match case")
                toggle("ab", on: $options.wholeWord, help: "Whole word")
                toggle(".*", on: $options.regex, help: "Regular expression")
            }
            .padding(.horizontal, 8)
            .frame(height: 26)
            .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous))
            HStack(spacing: 6) {
                Picker("", selection: $wholeRepo) {
                    Text("Repo").tag(true)
                    Text("This PR").tag(false)
                }
                .pickerStyle(.segmented).controlSize(.mini).fixedSize()
                Spacer(minLength: 4)
                if searching { ProgressView().controlSize(.mini) }
                if let hits, !searching {
                    Text(verbatim: "\(hits.count) · \(Int((took ?? 0) * 1000)) ms")
                        .font(Theme.Typo.meta).monospacedDigit().foregroundStyle(Theme.ink3)
                }
            }
            if let failure {
                Text(failure).font(Theme.Typo.meta).foregroundStyle(Theme.danger).lineLimit(3)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Self.groups(hits ?? []), id: \.path) { group in
                        Text(group.path).font(Theme.Typo.figure).foregroundStyle(Theme.ink2)
                            .lineLimit(1).truncationMode(.head)
                            .padding(.top, 6)
                        ForEach(group.hits, id: \.self) { hit in
                            Button { open(hit) } label: { HitRow(hit: hit) }.buttonStyle(.plain)
                        }
                    }
                }
            }
        }
        .padding(8)
        .onChange(of: focusRequest, initial: true) { _, _ in focused = true }
        .task(id: Key(query: query, options: options, wholeRepo: wholeRepo)) {
            let text = query.trimmingCharacters(in: .whitespaces)
            guard text.count >= 2 else {
                hits = nil
                return
            }
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            searching = true
            defer { searching = false }
            let started = Date()
            do {
                let found = try await store.codeSearch(repo: repo, head: head, query: text, options: options,
                                                       paths: wholeRepo ? nil : prPaths)
                guard !Task.isCancelled else { return }
                hits = found
                took = Date().timeIntervalSince(started)
                failure = nil
            } catch is CancellationError {
            } catch {
                NSLog("pultik: code search in %@ failed: %@", repo, error.localizedDescription)
                failure = error.localizedDescription
            }
        }
    }

    private func toggle(_ label: String, on: Binding<Bool>, help: String) -> some View {
        Button { on.wrappedValue.toggle() } label: {
            Text(label).font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(on.wrappedValue ? Theme.accent : Theme.ink3)
                .frame(width: 20, height: 18)
                .background(on.wrappedValue ? Theme.accentSoft : .clear, in: RoundedRectangle(cornerRadius: Theme.Radius.kbd))
        }
        .buttonStyle(.plain)
        .help(help)
    }

    static func groups(_ hits: [GrepHit]) -> [(path: String, hits: [GrepHit])] {
        var groups: [(path: String, hits: [GrepHit])] = []
        for hit in hits {
            if groups.last?.path == hit.path { groups[groups.count - 1].hits.append(hit) } else { groups.append((hit.path, [hit])) }
        }
        return groups
    }
}

/// One matching line: its number, and the line with the match lifted.
struct HitRow: View {
    let hit: GrepHit

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(verbatim: "\(hit.line)").font(.system(size: 10, design: .monospaced)).foregroundStyle(Theme.ink3)
                .frame(minWidth: 26, alignment: .trailing)
            Text(attributed).font(.system(size: 11, design: .monospaced)).lineLimit(1)
            Spacer(minLength: 0)
        }
        .frame(height: 20)
        .contentShape(Rectangle())
    }

    /// Before, the match (lifted) and after, sliced by UTF-16 column.
    private var attributed: AttributedString {
        let units = Array(hit.text.trimmingCharacters(in: .newlines).utf16)
        let start = min(max(hit.column, 0), units.count)
        let end = min(start + max(hit.length, 0), units.count)
        let piece: (Range<Int>) -> String = { String(decoding: units[$0], as: UTF16.self) }
        var before = AttributedString(piece(0 ..< start))
        before.foregroundColor = Theme.ink2
        var match = AttributedString(piece(start ..< end))
        match.foregroundColor = Theme.ink
        match.backgroundColor = Theme.accent.opacity(0.25)
        var after = AttributedString(piece(end ..< units.count))
        after.foregroundColor = Theme.ink2
        return before + match + after
    }
}

/// A lookup's results (D2): the definitions of a name, or its references,
/// from the symbol index at the PR's head, ranked same file → imported files
/// → same directory.
struct ReferencesPane: View {
    let title: String
    /// Nil while the index builds.
    let symbols: [SymbolIndex.Symbol]?
    let failure: String?
    let open: (SymbolIndex.Symbol) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(Theme.Typo.title).foregroundStyle(Theme.ink).lineLimit(2)
            if let failure {
                Text(failure).font(Theme.Typo.meta).foregroundStyle(Theme.danger)
            } else if let symbols {
                Text(symbols.isEmpty ? "Nothing found at the head" : "\(symbols.count) found")
                    .font(Theme.Typo.meta).foregroundStyle(Theme.ink3)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(symbols.enumerated()), id: \.offset) { _, symbol in
                            Button { open(symbol) } label: {
                                HStack(spacing: 6) {
                                    Text(symbol.role == .definition ? "def" : "ref").font(Theme.Typo.micro)
                                        .foregroundStyle(symbol.role == .definition ? Theme.accent : Theme.ink3)
                                    Text(verbatim: "\(symbol.path):\(symbol.line + 1)").font(.system(size: 11, design: .monospaced))
                                        .foregroundStyle(Theme.ink2).lineLimit(1).truncationMode(.head)
                                    Spacer(minLength: 0)
                                    Text(symbol.kind).font(Theme.Typo.meta).foregroundStyle(Theme.ink3)
                                }
                                .frame(height: 20)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            } else {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text("Indexing the head — once per head").font(Theme.Typo.meta).foregroundStyle(Theme.ink3)
                }
            }
        }
        .padding(8)
    }
}
