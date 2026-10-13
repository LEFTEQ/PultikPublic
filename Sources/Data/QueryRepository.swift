import Foundation
import Observation

/// A backend resource the repository caches: its name, the schema its
/// snapshot is written in, and how long an answer stays current.
struct QueryResource<Value: Codable & Sendable>: Sendable {
    let name: String
    var schema = 1
    /// Past this an answer reads "as of HH:MM" (DESIGN.md §7, stale).
    var staleAfter: TimeInterval
    /// Written to disk so a cold start is never blank. Detail reads that are
    /// cheap to refetch stay in memory only.
    var persists = true
    /// Keys of this resource kept, in memory and on disk, most recently used
    /// first; nil = the repository's and the store's defaults. A detail
    /// resource keyed per object (a PR's files) sets its own.
    var keep: Int?
}

/// How current a resource's value is.
struct QueryFreshness: Equatable, Sendable {
    let fetchedAt: Date
    /// Restored from disk at launch; no live answer since.
    let restored: Bool

    func isStale(after staleAfter: TimeInterval, now: Date = Date()) -> Bool {
        restored || now.timeIntervalSince(fetchedAt) > staleAfter
    }
}

/// The one cache and state layer every module reads (copilot shell D8):
/// identity-keyed values, versioned disk snapshots for an instant cold
/// start, stale-while-revalidate, one shared flight per key, invalidation
/// after a mutation, and prefetch only on an explicit selection.
///
/// It owns no schedule: `BackendSchedule` decides when a backend polls, and
/// each poll `record`s what it learned. Detail reads (a PR's files, a job's
/// log) go through `load`, which answers from memory while fresh and
/// otherwise joins or starts the key's single flight.
@MainActor
@Observable
final class QueryRepository {
    static let shared = QueryRepository(store: .shared)

    /// By resource name, for the current identity only.
    private(set) var freshness: [String: QueryFreshness] = [:]

    @ObservationIgnored private let store: QuerySnapshotStore
    @ObservationIgnored private let memoryLimit: Int
    @ObservationIgnored private var memory: [QueryKey: (value: any Sendable, fetchedAt: Date)] = [:]
    /// Least recently used first.
    @ObservationIgnored private var recency: [QueryKey] = []
    @ObservationIgnored private var flights: [QueryKey: Task<any Sendable, Error>] = [:]

    init(store: QuerySnapshotStore, memoryLimit: Int = 64) {
        self.store = store
        self.memoryLimit = memoryLimit
    }

    /// Cold start: the last snapshot fetched under THIS identity, with its
    /// age — never another identity's.
    func restore<Value>(_ resource: QueryResource<Value>, key: QueryKey) async -> QuerySnapshot<Value>? {
        guard let snapshot = await store.load(Value.self, key: key, schema: resource.schema) else { return nil }
        // A live answer that landed while the disk read ran wins.
        guard freshness[resource.name] == nil else { return nil }
        freshness[resource.name] = QueryFreshness(fetchedAt: snapshot.fetchedAt, restored: true)
        remember(key, snapshot.value, at: snapshot.fetchedAt, keep: resource.keep)
        return snapshot
    }

    /// A live answer arrived: it is current now and becomes the next cold
    /// start's snapshot.
    func record<Value>(_ resource: QueryResource<Value>, key: QueryKey, value: Value, at date: Date = Date()) {
        freshness[resource.name] = QueryFreshness(fetchedAt: date, restored: false)
        remember(key, value, at: date, keep: resource.keep)
        guard resource.persists else { return }
        let store = store
        Task.detached(priority: .utility) {
            await store.save(value, key: key, schema: resource.schema, fetchedAt: date, keep: resource.keep)
        }
    }

    /// The identity behind a resource changed: nothing shown for it belongs
    /// to the new one.
    func forget(_ resource: String) {
        freshness[resource] = nil
        invalidate(resource: resource)
    }

    /// After a mutation: the next `load` of this resource fetches.
    func invalidate(resource: String) {
        for key in memory.keys where key.resource == resource { memory[key] = nil }
        recency.removeAll { $0.resource == resource }
    }

    func cached<Value>(_: Value.Type, key: QueryKey) -> (value: Value, fetchedAt: Date)? {
        guard let entry = memory[key], let value = entry.value as? Value else { return nil }
        return (value, entry.fetchedAt)
    }

    /// The value while younger than `maxAge`; otherwise the key's one flight
    /// — joined when it is already in the air, so two readers of the same
    /// object cost one request. A persisted resource missing from memory
    /// reads its snapshot first: a key that names immutable content (a PR's
    /// files at `base...head`) survives a relaunch without a request.
    func load<Value>(_ resource: QueryResource<Value>, key: QueryKey, maxAge: TimeInterval, now: Date = Date(),
                     fetch: @escaping @Sendable () async throws -> Value) async throws -> Value {
        if let hit = cached(Value.self, key: key), now.timeIntervalSince(hit.fetchedAt) < maxAge {
            touch(key)
            if resource.keep != nil, resource.persists {
                // A use keeps its snapshot on disk too (keep evicts the least used).
                let store = store
                Task.detached(priority: .utility) { await store.touch(key) }
            }
            return hit.value
        }
        if resource.persists, cached(Value.self, key: key) == nil {
            if let snapshot = await store.load(Value.self, key: key, schema: resource.schema),
               cached(Value.self, key: key) == nil {
                remember(key, snapshot.value, at: snapshot.fetchedAt, keep: resource.keep)
            }
            // Memory is the truth after the await: a live answer or another
            // reader's fetch may have landed while the disk read ran.
            if let hit = cached(Value.self, key: key), now.timeIntervalSince(hit.fetchedAt) < maxAge {
                touch(key)
                return hit.value
            }
        }
        let flight: Task<any Sendable, Error>
        if let existing = flights[key] {
            flight = existing
        } else {
            flight = Task { try await fetch() as any Sendable }
            flights[key] = flight
        }
        // Only this flight's own readers clear it: a reader resuming late
        // must not drop a newer flight started for the same key.
        defer { if flights[key] == flight { flights[key] = nil } }
        let value = try await flight.value
        guard let typed = value as? Value else { throw QueryError.typeMismatch(key.description) }
        record(resource, key: key, value: typed)
        return typed
    }

    /// What memory or the key's snapshot holds, at any age, without a fetch:
    /// the caller judges currency itself (a change request against its
    /// index's `updatedAt`). A snapshot read lands in memory.
    /// `remember: false` peeks without pulling the snapshot into memory (a
    /// background sync walking a hundred keys).
    func held<Value>(_ resource: QueryResource<Value>, key: QueryKey,
                     remember keeps: Bool = true) async -> (value: Value, fetchedAt: Date)? {
        if let hit = cached(Value.self, key: key) { return hit }
        guard resource.persists,
              let snapshot = await store.load(Value.self, key: key, schema: resource.schema) else { return nil }
        if let hit = cached(Value.self, key: key) { return hit }
        if keeps { remember(key, snapshot.value, at: snapshot.fetchedAt, keep: resource.keep) }
        return (snapshot.value, snapshot.fetchedAt)
    }

    /// A background sync's answer (the warm set, D9): written to disk only,
    /// so syncing a hundred objects never pushes what is on screen out of
    /// memory. A copy memory already holds is refreshed in place.
    /// The returned write can be awaited (a sync that promises "on disk").
    @discardableResult
    func persist<Value>(_ resource: QueryResource<Value>, key: QueryKey, value: Value,
                        at date: Date = Date()) -> Task<Void, Never>? {
        if memory[key] != nil { memory[key] = (value, date) }
        guard resource.persists else { return nil }
        let store = store
        let schema = resource.schema
        let keep = resource.keep
        return Task.detached(priority: .utility) {
            await store.save(value, key: key, schema: schema, fetchedAt: date, keep: keep)
        }
    }

    /// Whether the key has a snapshot on disk, without reading it.
    func isPersisted(_ key: QueryKey) async -> Bool {
        await store.exists(key)
    }

    /// Warm a key the operator just selected (D8: explicit selection only,
    /// inside the caller's budgets) without waiting for it.
    func prefetch<Value>(_ resource: QueryResource<Value>, key: QueryKey, maxAge: TimeInterval,
                         fetch: @escaping @Sendable () async throws -> Value) {
        Task { _ = try? await load(resource, key: key, maxAge: maxAge, fetch: fetch) }
    }

    private func remember(_ key: QueryKey, _ value: any Sendable, at date: Date, keep: Int? = nil) {
        memory[key] = (value, date)
        touch(key)
        if let keep {
            let siblings = recency.filter { $0.resource == key.resource }
            for oldest in siblings.dropLast(max(1, keep)) {
                memory[oldest] = nil
                recency.removeAll { $0 == oldest }
            }
        }
        while recency.count > memoryLimit {
            let oldest = recency.removeFirst()
            memory[oldest] = nil
        }
    }

    private func touch(_ key: QueryKey) {
        recency.removeAll { $0 == key }
        recency.append(key)
    }
}

enum QueryError: Error, LocalizedError {
    case typeMismatch(String)

    var errorDescription: String? {
        switch self {
        case let .typeMismatch(key): "cached \(key) has another type"
        }
    }
}
