import Foundation

/// What a PR's first frame draws beyond its data (instant PR open): the
/// markdown of its description, comments and reviews as parsed blocks, and
/// its diff laid out as a document. Both are built off the main thread as the
/// warm set fills and moves (`StatusStore.prepareRender`), and live outside
/// the view tree, so they survive the panel's 30 s release and a move to the
/// next PR. A text nothing prepared is parsed where it is drawn, once.
///
/// Keyed by content — the source text in its repo, the diff's
/// `base...head` scope — so a held entry is never another revision's. A
/// link's target depends on what the indexes held when its text was parsed:
/// each text carries that (`known`) and is parsed again, behind what is
/// drawn, once the indexes have grown; the store drops everything when the
/// identity behind them changes (`removeAll`).
@MainActor
final class PRRenderCache {
    static let shared = PRRenderCache()

    /// One change request's part of a preparation.
    struct Part: Sendable {
        var repo: String
        var texts: [String] = []
        /// The files key's scope and the change set it names.
        var files: (scope: String, changes: ChangeSet)?
    }

    private struct Text: Hashable, Sendable {
        let repo: String
        let source: String
    }

    /// The resolver reads a copy of the indexes, never the store: it is
    /// built for exactly this hop off the main thread.
    private struct Resolver: @unchecked Sendable {
        let value: any AutolinkResolver
    }

    /// Past these the cache starts over: a guard against a week-long run,
    /// far above what the warm set holds.
    private static let textLimit = 40_000
    private static let documentLimit = 120

    /// `known`: how many change requests the index held at the parse; -1
    /// for a text parsed where it was drawn.
    private var markdown: [Text: (blocks: [GFMBlock], known: Int)] = [:]
    private var documents: [String: DiffDocument] = [:]
    /// What a preparation in flight will bring: asking again queues nothing.
    private var pendingTexts: Set<Text> = []
    private var pendingDocuments: Set<String> = []
    /// Preparations run one after another: a launch's hundred and fifty
    /// never take every core from the panel.
    private var tail: Task<Void, Never>?

    /// The blocks of `source`: prepared, or parsed here and kept.
    func blocks(_ source: String, repo: String, resolver: AutolinkResolver?) -> [GFMBlock] {
        let key = Text(repo: repo, source: source)
        if let held = markdown[key] { return held.blocks }
        let parsed = GFM.blocks(source, repo: repo, resolver: resolver)
        if markdown.count >= Self.textLimit { markdown.removeAll() }
        markdown[key] = (parsed, -1)
        return parsed
    }

    /// The default-fold document of the diff at `scope`, if one was prepared.
    func document(scope: String) -> DiffDocument? {
        documents[scope]
    }

    /// Parses and lays out, off the main thread, what of `parts` is not held
    /// yet or was parsed against other indexes than `known` counts.
    /// `resolver` must not read main-actor state.
    func prepare(_ parts: [Part], resolver: any AutolinkResolver, known: Int) {
        var texts: [Text] = []
        var files: [(scope: String, changes: ChangeSet)] = []
        for part in parts {
            for source in part.texts where !source.isEmpty {
                let key = Text(repo: part.repo, source: source)
                if markdown[key]?.known != known, pendingTexts.insert(key).inserted { texts.append(key) }
            }
            if let diff = part.files, documents[diff.scope] == nil, pendingDocuments.insert(diff.scope).inserted {
                files.append(diff)
            }
        }
        guard !texts.isEmpty || !files.isEmpty else { return }
        let previous = tail
        let resolver = Resolver(value: resolver)
        tail = Task.detached(priority: .utility) { [weak self] in
            await previous?.value
            var parsed: [Text: [GFMBlock]] = [:]
            for text in texts {
                parsed[text] = GFM.blocks(text.source, repo: text.repo, resolver: resolver.value)
            }
            let built = files.map { (scope: $0.scope, document: DiffDocument($0.changes)) }
            await self?.keep(parsed, built, known: known)
        }
    }

    private func keep(_ parsed: [Text: [GFMBlock]], _ built: [(scope: String, document: DiffDocument)], known: Int) {
        if markdown.count + parsed.count > Self.textLimit { markdown.removeAll() }
        for (text, blocks) in parsed {
            markdown[text] = (blocks, known)
            pendingTexts.remove(text)
        }
        if documents.count + built.count > Self.documentLimit { documents.removeAll() }
        for entry in built {
            documents[entry.scope] = entry.document
            pendingDocuments.remove(entry.scope)
        }
    }

    /// The identity behind the indexes changed: nothing parsed against the
    /// old one is drawn for the new.
    func removeAll() {
        markdown.removeAll()
        documents.removeAll()
        pendingTexts.removeAll()
        pendingDocuments.removeAll()
    }
}
