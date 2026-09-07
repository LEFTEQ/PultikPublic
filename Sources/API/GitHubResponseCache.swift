import Foundation

/// Raw conditional-response bodies; GitHubClient serializes all access.
struct GitHubResponseCache {
    struct Entry {
        let etag: String
        let data: Data
    }

    private var entries: [String: Entry] = [:]
    private var order: [String] = []
    private let maxBytes: Int
    private let maxEntries: Int
    private(set) var byteCount = 0
    var count: Int { entries.count }

    init(maxBytes: Int = 4 * 1024 * 1024, maxEntries: Int = 256) {
        self.maxBytes = max(0, maxBytes)
        self.maxEntries = max(0, maxEntries)
    }

    mutating func value(for path: String) -> Entry? {
        guard let entry = entries[path] else { return nil }
        order.removeAll { $0 == path }
        order.append(path)
        return entry
    }

    mutating func insert(_ entry: Entry, for path: String) {
        remove(path)
        // Never retain a stale validator when the replacement is too large.
        guard maxEntries > 0, entry.data.count <= maxBytes else { return }
        while entries.count >= maxEntries || byteCount > maxBytes - entry.data.count {
            guard let oldest = order.first else { break }
            remove(oldest)
        }
        entries[path] = entry
        order.append(path)
        byteCount += entry.data.count
    }

    private mutating func remove(_ path: String) {
        byteCount -= entries.removeValue(forKey: path)?.data.count ?? 0
        order.removeAll { $0 == path }
    }
}
