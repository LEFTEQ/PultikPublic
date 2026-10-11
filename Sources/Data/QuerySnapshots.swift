import CryptoKit
import Foundation

/// Whose answer a cached value is (copilot shell D8): the backend resource,
/// the identity that fetched it — a credential digest, an origin, a box set —
/// and its scope (a workspace, a repo set). A snapshot written under one
/// identity is never served to another: the identity is part of the file
/// name and is checked again on load.
struct QueryKey: Hashable, Sendable, CustomStringConvertible {
    let resource: String
    let identity: String
    var scope: String = ""

    /// Never the identity: it may be derived from a credential.
    var description: String { scope.isEmpty ? resource : "\(resource)[\(scope)]" }

    /// What reaches the disk: a digest, so no identity or scope is written
    /// in clear.
    var digest: String {
        Self.digest([resource, identity, scope].joined(separator: "\u{0}"))
    }

    /// An identity derived from a credential: one-way, so a key, a log line
    /// or a file name can carry it without carrying the secret.
    static func digest(_ material: String) -> String {
        SHA256.hash(data: Data(material.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

/// A persisted answer and the moment it was fetched — the "as of" a cold
/// start shows until the first live answer.
struct QuerySnapshot<Value: Codable & Sendable>: Codable, Sendable {
    let schema: Int
    let resource: String
    let key: String
    let fetchedAt: Date
    let value: Value
}

/// Versioned, identity-keyed snapshots under `~/Library/Caches/Pultik/Query/`,
/// one directory per resource. Bounded: a snapshot over `maxBytes` is not
/// written, and each resource keeps only its `keepPerResource` most recently
/// written identities. A snapshot of another schema, another identity or one
/// that no longer decodes reads as absent — never as a guess.
actor QuerySnapshotStore {
    static let shared = QuerySnapshotStore()

    static var defaultDirectory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Pultik/Query", isDirectory: true)
    }

    let directory: URL
    let maxBytes: Int
    let keepPerResource: Int
    /// The newest fetch written per key this run: saves are detached tasks,
    /// and an older answer arriving late must not overwrite a newer one.
    private var written: [String: Date] = [:]

    init(directory: URL = QuerySnapshotStore.defaultDirectory, maxBytes: Int = 2 << 20, keepPerResource: Int = 3) {
        self.directory = directory
        self.maxBytes = maxBytes
        self.keepPerResource = keepPerResource
    }

    /// The snapshot coder: default key and date strategies both ways, so a
    /// model's own `CodingKeys` round-trip whatever its API decoder does.
    /// Non-finite floats travel as strings: Prometheus can answer `NaN`.
    private static let nonFinite = (positive: "+Infinity", negative: "-Infinity", nan: "NaN")

    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.nonConformingFloatEncodingStrategy = .convertToString(
            positiveInfinity: nonFinite.positive, negativeInfinity: nonFinite.negative, nan: nonFinite.nan)
        return encoder
    }

    private static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.nonConformingFloatDecodingStrategy = .convertFromString(
            positiveInfinity: nonFinite.positive, negativeInfinity: nonFinite.negative, nan: nonFinite.nan)
        return decoder
    }

    func load<Value: Codable & Sendable>(_: Value.Type, key: QueryKey, schema: Int) -> QuerySnapshot<Value>? {
        let url = fileURL(key)
        guard let data = try? Data(contentsOf: url) else { return nil }
        do {
            let snapshot = try Self.decoder().decode(QuerySnapshot<Value>.self, from: data)
            guard snapshot.schema == schema, snapshot.key == key.digest, snapshot.resource == key.resource else {
                return nil
            }
            touch(key) // a snapshot read is a use: eviction keeps the most recently used
            return snapshot
        } catch {
            NSLog("pultik: snapshot %@ unreadable, dropping it: %@", key.description, error.localizedDescription)
            try? FileManager.default.removeItem(at: url)
            return nil
        }
    }

    /// `keep` overrides `keepPerResource` for a resource keyed per object.
    func save<Value: Codable & Sendable>(_ value: Value, key: QueryKey, schema: Int, fetchedAt: Date, keep: Int? = nil) {
        if let newest = written[key.digest], newest > fetchedAt { return }
        let snapshot = QuerySnapshot(schema: schema, resource: key.resource, key: key.digest,
                                     fetchedAt: fetchedAt, value: value)
        do {
            let data = try Self.encoder().encode(snapshot)
            guard data.count <= maxBytes else {
                NSLog("pultik: snapshot %@ is %d bytes, over the %d cap — not written",
                      key.description, data.count, maxBytes)
                return
            }
            let folder = resourceDirectory(key.resource)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            let url = fileURL(key)
            try data.write(to: url, options: [.atomic])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            written[key.digest] = fetchedAt
            evict(in: folder, keeping: url, limit: keep ?? keepPerResource)
        } catch {
            NSLog("pultik: snapshot %@ not written: %@", key.description, error.localizedDescription)
        }
    }

    /// Marks the key's snapshot used now, when there is one.
    func touch(_ key: QueryKey) {
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: fileURL(key).path)
    }

    func remove(_ key: QueryKey) {
        try? FileManager.default.removeItem(at: fileURL(key))
    }

    private func resourceDirectory(_ resource: String) -> URL {
        directory.appendingPathComponent(resource, isDirectory: true)
    }

    private func fileURL(_ key: QueryKey) -> URL {
        resourceDirectory(key.resource).appendingPathComponent("\(key.digest).json")
    }

    /// The resource keeps its newest identities; older ones go.
    private func evict(in folder: URL, keeping current: URL, limit: Int) {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        guard files.count > limit else { return }
        let byAge = files.sorted { lhs, rhs in
            let l = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let r = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return l > r
        }
        for file in byAge.dropFirst(limit) where file.standardizedFileURL != current.standardizedFileURL {
            try? FileManager.default.removeItem(at: file)
        }
    }
}
