import Foundation

/// Highlight runs by key (PR workbench WP2): a blob SHA where the mirror
/// names one, so a blob is parsed once across every change request, else a
/// digest of the reconstructed side of a patch. Parses run off the main
/// thread at user-initiated priority, two at a time; an identical request
/// in flight shares the one parse. LRU-bounded by run count, and emptied
/// when the panel releases its tree (the hidden footprint budget, P10).
actor HighlightCache {
    static let shared = HighlightCache()

    /// About 7 MB of runs: a few dozen large files.
    static let budget = 600_000
    private static let parallel = 2

    private var entries: [String: (tokens: LineTokens, used: UInt64)] = [:]
    private var flights: [String: Task<LineTokens?, Never>] = [:]
    private var weight = 0
    private var clock: UInt64 = 0
    private var running = 0
    private var waiting: [CheckedContinuation<Void, Never>] = []

    /// The runs for `key`, parsing `text()` on a miss. Nil when the text
    /// could not be read or parsed — the canvas keeps drawing it plain.
    func tokens(key: String, language: SyntaxLanguage,
                text: @escaping @Sendable () async throws -> String) async -> LineTokens? {
        clock &+= 1
        if let entry = entries[key] {
            entries[key]?.used = clock
            return entry.tokens
        }
        if let flight = flights[key] { return await flight.value }
        let flight = Task<LineTokens?, Never> { [weak self] in
            guard let self else { return nil }
            await self.acquire()
            defer { Task { await self.release() } }
            do {
                let source = try await text()
                try Task.checkCancellation()
                return try await Task.detached(priority: .userInitiated) {
                    try SyntaxEngine.highlight(source, language: language)
                }.value
            } catch is CancellationError {
                return nil
            } catch {
                NSLog("pultik: highlighting %@ (%@) failed: %@", key, language.rawValue, error.localizedDescription)
                return nil
            }
        }
        flights[key] = flight
        let tokens = await flight.value
        flights[key] = nil
        if let tokens { store(tokens, key: key) }
        return tokens
    }

    /// The panel released its tree: nothing on screen reads these.
    func purge() {
        entries = [:]
        weight = 0
    }

    private func store(_ tokens: LineTokens, key: String) {
        clock &+= 1
        entries[key] = (tokens, clock)
        weight += tokens.weight
        while weight > Self.budget, entries.count > 1,
              let oldest = entries.min(by: { $0.value.used < $1.value.used }) {
            weight -= oldest.value.tokens.weight
            entries[oldest.key] = nil
        }
    }

    private func acquire() async {
        if running < Self.parallel {
            running += 1
            return
        }
        await withCheckedContinuation { waiting.append($0) }
    }

    private func release() {
        if waiting.isEmpty {
            running -= 1
        } else {
            waiting.removeFirst().resume()
        }
    }
}
