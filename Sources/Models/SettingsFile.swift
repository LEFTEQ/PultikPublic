import Foundation

/// How a JSON settings file read came out. Foundation-only so the contract
/// harness tests the policy that keeps an AI typo from resetting — or
/// erasing — the panel's settings (decision D11, brief AC13).
enum SettingsResolution<Value> {
    /// Decoded. `issues`/`skipped` list what a `LossyArray` left out; `data`
    /// is the file's bytes, persisted as the last good copy when clean.
    case fresh(Value, issues: [String], skipped: [SkippedEntry], data: Data)
    /// The file exists but does not decode.
    case unreadable(lastGood: Value?, issue: String)
    /// No file at all: the only case where legacy fallbacks may run.
    case absent
}

/// One entry a `LossyArray` skipped: which list, which owner's list, where,
/// and — when the bad entry still names itself — its identity, so the last
/// good copy's entry can stand in for it.
struct SkippedEntry: Equatable, Sendable {
    /// The list's key: "projects", "services", "prod", "links".
    let list: String
    /// The identity of the entry owning a nested list ("exampleapp" for a
    /// project's prod pointers); nil for top-level lists.
    var owner: String?
    let index: Int
    /// The bad entry's `key` / `ref` / `url` / `name`, if it carries one.
    let identity: String?
}

/// A settings file the snapshot policy can manage.
protocol SettingsDocument: Decodable {
    /// Put back, from the last good copy, the entries a lossy decode skipped.
    mutating func restoreSkipped(_ skipped: [SkippedEntry], from lastGood: Self)
    /// Every in-place rewrite; true when anything changed.
    mutating func applyMigrations() -> Bool
}

/// What a settings read hands the app.
struct SettingsSnapshot<Value> {
    var value: Value
    /// One orange row each: skipped entries, or the whole file failing.
    var issues: [String]
    /// False while the file does not decode cleanly — undecodable or lossy.
    /// Writing then would replace a half-done edit with the in-memory copy,
    /// or erase the entries the lossy decode skipped.
    var writable: Bool
    /// A clean decode whose migrations changed something: the caller saves.
    var needsSave: Bool
}

enum SettingsFile {
    /// The policy every load runs. Nil = no file, the caller's legacy path.
    ///
    /// - clean decode → migrations may be saved; it becomes the last good
    ///   copy in memory and in `lastGoodURL`;
    /// - lossy decode → the last good copy's entries stand in for skipped
    ///   ones, migrations apply in memory only, never written;
    /// - undecodable → the last good copy (memory, else `lastGoodURL`, else
    ///   `fallback`), the file left exactly as it is.
    static func snapshot<Value: SettingsDocument>(
        at url: URL, lastGoodURL: URL, memory: SettingsMemory<Value>, fallback: () -> Value
    ) -> SettingsSnapshot<Value>? {
        let previous = memory.lastGood ?? persistedLastGood(Value.self, at: lastGoodURL, memory: memory)
        switch resolve(Value.self, at: url, lastGood: previous) {
        case .absent:
            return nil
        case let .unreadable(lastGood, issue):
            // Every load branch migrates (CLAUDE.md) — in memory only: the
            // last good copy may be one an older build persisted.
            var value = lastGood ?? fallback()
            _ = value.applyMigrations()
            return SettingsSnapshot(value: value, issues: [issue], writable: false, needsSave: false)
        case .fresh(var value, let issues, let skipped, let data):
            guard issues.isEmpty else {
                if let previous { value.restoreSkipped(skipped, from: previous) }
                _ = value.applyMigrations()
                return SettingsSnapshot(value: value, issues: issues, writable: false, needsSave: false)
            }
            let migrated = value.applyMigrations()
            memory.remember(value)
            // A migrated value is about to be saved, and the save persists it.
            if !migrated { persist(data, lastGoodURL: lastGoodURL, source: url, memory: memory) }
            return SettingsSnapshot(value: value, issues: [], writable: true, needsSave: migrated)
        }
    }

    static func resolve<Value: Decodable>(
        _ type: Value.Type, at url: URL, lastGood: Value?
    ) -> SettingsResolution<Value> {
        guard FileManager.default.fileExists(atPath: url.path) else { return .absent }
        let name = url.lastPathComponent
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            return .unreadable(lastGood: lastGood, issue: "\(name): \(error.localizedDescription)")
        }
        let sink = ConfigIssueSink()
        let decoder = JSONDecoder()
        decoder.userInfo[ConfigIssueSink.key] = sink
        do {
            let value = try decoder.decode(Value.self, from: data)
            return .fresh(value, issues: sink.issues, skipped: sink.skipped, data: data)
        } catch {
            let at = Self.path(of: error)
            return .unreadable(
                lastGood: lastGood,
                issue: "\(name)\(at.isEmpty ? "" : " \(at)"): \(ConfigIssueSink.describe(error))"
            )
        }
    }

    /// Copies a clean settings file's bytes beside it, once per change of the
    /// source — so a launch whose settings.json no longer decodes still runs
    /// on the user's estate instead of the shipped defaults.
    static func persist<Value>(_ data: Data, lastGoodURL: URL, source: URL, memory: SettingsMemory<Value>) {
        let stamp = Self.stamp(of: source)
        guard stamp == nil || stamp != memory.persistedSource else { return }
        do {
            try data.write(to: lastGoodURL, options: .atomic)
            memory.persistedSource = stamp
        } catch {
            NSLog("pultik: could not keep %@ — %@", lastGoodURL.lastPathComponent, error.localizedDescription)
        }
    }

    /// The persisted last good copy, used only when memory has none.
    private static func persistedLastGood<Value: Decodable>(
        _ type: Value.Type, at url: URL, memory: SettingsMemory<Value>
    ) -> Value? {
        guard case let .fresh(value, issues, _, _) = resolve(type, at: url, lastGood: nil), issues.isEmpty
        else { return nil }
        memory.remember(value)
        return value
    }

    /// The file's (modification date, size) — cheap identity for "did this
    /// change since I last looked / since I last wrote it".
    static func stamp(of url: URL) -> Stamp? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let modified = attributes[.modificationDate] as? Date,
              let size = attributes[.size] as? Int
        else { return nil }
        return Stamp(modified: modified, size: size)
    }

    struct Stamp: Equatable, Sendable {
        let modified: Date
        let size: Int
    }

    private static func path(of error: Error) -> String {
        guard let decoding = error as? DecodingError else { return "" }
        let context: DecodingError.Context?
        switch decoding {
        case let .keyNotFound(_, ctx), let .typeMismatch(_, ctx),
             let .valueNotFound(_, ctx), let .dataCorrupted(ctx):
            context = ctx
        @unknown default:
            context = nil
        }
        return context.map { ConfigIssueSink.path($0.codingPath) } ?? ""
    }
}

extension Array {
    /// Re-inserts, from `lastGood`, each entry of `list` (owned by `owner`)
    /// that a lossy decode skipped, at its old position — matched by `id`,
    /// so an entry that cannot name itself stays out.
    mutating func restore(_ skipped: [SkippedEntry], list: String, owner: String? = nil,
                          from lastGood: [Element], id: (Element) -> String) {
        for entry in skipped where entry.list == list && entry.owner == owner {
            guard let identity = entry.identity,
                  !contains(where: { id($0) == identity }),
                  let previous = lastGood.first(where: { id($0) == identity })
            else { continue }
            insert(previous, at: Swift.min(entry.index, count))
        }
    }
}

/// The last settings value that decoded cleanly, the stamp of the app's own
/// last write, and which source version was last persisted. Shared by every
/// `Preferences.load()` caller, so it is locked.
final class SettingsMemory<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var good: Value?
    private var written: SettingsFile.Stamp?
    private var persisted: SettingsFile.Stamp?

    var lastGood: Value? {
        lock.withLock { good }
    }

    func remember(_ value: Value) {
        lock.withLock { good = value }
    }

    /// Recorded right after the app's own atomic write, so the hot-reload
    /// watcher can tell that event from an outside edit.
    var lastWritten: SettingsFile.Stamp? {
        get { lock.withLock { written } }
        set { lock.withLock { written = newValue } }
    }

    var persistedSource: SettingsFile.Stamp? {
        get { lock.withLock { persisted } }
        set { lock.withLock { persisted = newValue } }
    }
}
