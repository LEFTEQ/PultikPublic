import SwiftUI

/// GitHub: token via the gh CLI, liveness via ProbeGate, and the repo-pin
/// management that used to be most of the old Integrations pane.
@MainActor
@Observable
final class GitHubIntegration: Integration {
    let id = "github"
    let title = "GitHub"
    let symbol = "smallcircle.filled.circle"
    let canTest = true

    private let store: StatusStore
    private var testVerdict: IntegrationStatus?
    private var isTesting = false
    /// One field does both jobs: it filters the discovered list as you type
    /// and Pin takes it literally when what you want isn't in there.
    private var query = ""
    private var loadingSuggestions = false

    init(store: StatusStore) { self.store = store }

    var status: IntegrationStatus {
        if isTesting { return .testing }
        if let testVerdict { return testVerdict }
        if let pause = ProbeGate.shared.pauses[.github], pause.until > Date() {
            return pause.rejected
                ? .error("refused: \(pause.reason)")
                : .attention("paused — \(pause.reason)")
        }
        return .connected("via gh CLI · \(store.pinned.count) pinned")
    }

    func test() async {
        isTesting = true
        defer { isTesting = false }
        // /rate_limit is free (doesn't count against the budget) and fails
        // exactly like every real call when the token is bad.
        let verdict: IntegrationStatus = await Task.detached {
            let token: String
            do { token = try GHToken.fetch() } catch {
                return .error(error.localizedDescription)
            }
            var request = URLRequest(url: URL(string: "https://api.github.com/rate_limit")!)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            do {
                let (_, response) = try await URLSession.shared.data(for: request)
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                return code == 200
                    ? .connected("token valid")
                    : .error("GitHub answered \(code) — run `gh auth login`")
            } catch {
                return .error("unreachable: \(error.localizedDescription)")
            }
        }.value
        switch verdict {
        case .connected: ProbeGate.shared.succeeded(.github)
        case .error(let why): ProbeGate.shared.failed(.github, .rejected(why))
        default: break
        }
        testVerdict = verdict
    }

    var detail: AnyView { AnyView(GitHubDetail(integration: self, store: store)) }

    fileprivate struct GitHubDetail: View {
        @Bindable var integration: GitHubIntegration
        let store: StatusStore

        private static let visibleSuggestions = 10

        private var matches: [String] {
            let needle = integration.query
                .trimmingCharacters(in: .whitespaces)
                .lowercased()
            guard !needle.isEmpty else { return store.suggestions }
            return store.suggestions.filter { $0.lowercased().contains(needle) }
        }

        /// The suggestion rows actually on screen. Empty while discovery is
        /// loading, before it has run, and when the filter matches nothing —
        /// in all three cases every pin belongs in the list above.
        private var suggestionRows: [String] {
            guard !integration.loadingSuggestions, !store.suggestions.isEmpty else { return [] }
            return Array(matches.prefix(Self.visibleSuggestions))
        }

        /// Pins that are NOT already on screen below. Rendering the two lists
        /// disjointly is what keeps a pin click from changing any row count:
        /// toggling a visible suggestion adds nothing here and removes nothing
        /// there, so no row moves under the pointer. It also means a repo can
        /// never show up twice at once. A pin past the row cap, or filtered
        /// out by the query, is absent below and so always appears here —
        /// nothing can become unreachable.
        private var pinnedNotShownBelow: [String] {
            let onScreen = Set(suggestionRows)
            return store.pinned.filter { !onScreen.contains($0) }
        }

        var body: some View {
            VStack(alignment: .leading, spacing: 8) {
                Text("Token comes from the gh CLI (`gh auth login`). Pinned repos drive the panel's main list.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(pinnedNotShownBelow, id: \.self) { slug in
                    HStack {
                        Text(slug)
                        Spacer()
                        PinToggle(slug: slug, store: store)
                    }
                }
                HStack {
                    HStack(spacing: 4) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                        TextField("filter, or type owner/repo", text: $integration.query)
                            .textFieldStyle(.plain)
                            .onSubmit { integration.pinTyped() }
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 5))
                    Button("Pin") { integration.pinTyped() }
                        .disabled(!integration.typedIsSlug)
                }
                if integration.loadingSuggestions {
                    ProgressView().controlSize(.small)
                } else if store.suggestions.isEmpty {
                    Button("Load suggestions from GitHub") { integration.loadSuggestions() }
                } else if matches.isEmpty {
                    Text(integration.typedIsSlug
                         ? "No discovered repo matches — Pin adds it anyway."
                         : "No discovered repo matches.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    // Toggling a row here changes NO row count anywhere: the
                    // pinned list above renders only pins that are not on
                    // screen in this list, so the row keeps its exact position
                    // and the minus appears under the same pointer that just
                    // pinned it. Rows do move when the FILTER changes — that
                    // is typing, not clicking, so it cannot mis-target a click.
                    ForEach(suggestionRows, id: \.self) { slug in
                        HStack {
                            Text(slug)
                                .foregroundStyle(store.pinned.contains(slug) ? .primary : .secondary)
                            Spacer()
                            PinToggle(slug: slug, store: store)
                        }
                    }
                    if matches.count > suggestionRows.count {
                        Text("showing \(suggestionRows.count) of \(matches.count) — type to narrow.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    /// Pin/unpin for one slug, reading `store.pinned` live so the suggestion
    /// list and the pinned list above it can never disagree.
    fileprivate struct PinToggle: View {
        let slug: String
        let store: StatusStore

        var body: some View {
            let isPinned = store.pinned.contains(slug)
            Button {
                if isPinned { store.unpin(slug) } else { store.pin(slug) }
            } label: {
                Image(systemName: isPinned ? "minus.circle.fill" : "plus.circle")
                    .foregroundStyle(isPinned ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.accentColor))
            }
            .buttonStyle(.borderless)
            .help(isPinned ? "Unpin \(slug)" : "Pin \(slug)")
            .accessibilityLabel(isPinned ? "Unpin \(slug)" : "Pin \(slug)")
        }
    }

    /// A bare filter word is not a repo — only a real `owner/name` may be
    /// pinned literally, or the panel polls a URL GitHub can never resolve.
    private var typedIsSlug: Bool {
        StatusStore.isRepoSlug(query.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func pinTyped() {
        guard typedIsSlug else { return }
        store.pin(query)
        query = ""
    }

    private func loadSuggestions() {
        loadingSuggestions = true
        Task {
            await store.loadSuggestions()
            loadingSuggestions = false
        }
    }
}

/// Sentry: token in the keychain (migrated out of settings.json by
/// `StatusStore.sentryToken`), liveness via ProbeGate.
@MainActor
@Observable
final class SentryIntegration: Integration {
    let id = "sentry"
    let title = "Sentry"
    let symbol = "exclamationmark.triangle"
    let canTest = true

    private let store: StatusStore
    private var testVerdict: IntegrationStatus?
    private var isTesting = false

    init(store: StatusStore) { self.store = store }

    /// Mirror of SentryClient's fallback chain, readable synchronously (the
    /// client is an actor): keychain/settings via the store, else the
    /// SENTRY_AUTH_TOKEN line cached in ~/.claude/.env.
    private var hasToken: Bool {
        if store.sentryToken != nil { return true }
        let envFile = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: ".claude/.env")
        guard let contents = try? String(contentsOf: envFile, encoding: .utf8) else { return false }
        return contents.split(separator: "\n").contains {
            $0.hasPrefix("SENTRY_AUTH_TOKEN=") && $0.count > "SENTRY_AUTH_TOKEN=".count + 1
        }
    }

    var status: IntegrationStatus {
        if isTesting { return .testing }
        if let testVerdict { return testVerdict }
        guard hasToken else {
            return .notConfigured("no token — set one below or via SENTRY_AUTH_TOKEN")
        }
        if let pause = ProbeGate.shared.pauses[.sentry], pause.until > Date() {
            return pause.rejected
                ? .error("refused: \(pause.reason)")
                : .attention("paused — \(pause.reason)")
        }
        return .connected("watching \(store.sentryProjects.joined(separator: ", "))")
    }

    func test() async {
        isTesting = true
        defer { isTesting = false }
        guard let project = store.sentryProjects.first else {
            testVerdict = .error("no sentry projects configured")
            return
        }
        do {
            let issues = try await SentryClient.shared.unresolvedIssues(
                project: project, settingsToken: store.sentryToken)
            ProbeGate.shared.succeeded(.sentry)
            testVerdict = .connected("\(project): \(issues.count) unresolved")
        } catch {
            let failure = ProbeFailure.classify(error)
            ProbeGate.shared.failed(.sentry, failure)
            testVerdict = .error(failure.reason)
        }
    }

    var detail: AnyView { AnyView(TokenEditor(slot: tokenSlot)) }

    private var tokenSlot: TokenSlot {
        TokenSlot(
            placeholder: "API token",
            footnote: "Stored in the login keychain (pultik-sentry) — Onyx keeps the human copy. Blank falls back to SENTRY_AUTH_TOKEN in ~/.claude/.env. Projects list lives in settings.json.",
            read: { [store] in store.sentryToken },
            write: { [weak self] value in
                guard let self else { return nil }
                let failure = store.setSentryToken(value)
                // A new token invalidates whatever the last Test concluded.
                if failure == nil { testVerdict = nil }
                return failure
            }
        )
    }
}
