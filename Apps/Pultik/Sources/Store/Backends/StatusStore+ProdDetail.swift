import Foundation

/// Prod's detail reads (copilot shell WP7), through the query repository:
/// a deployment's release line and its Hlídač detail on explicit selection,
/// the apps shelf on entering Prod (D8) — none of them polled, none of them
/// a second prod poller. The release line is keyed by the GitHub credential
/// digest that read it, Hlídač's detail by its base.
extension StatusStore {
    enum ProdDetailResources {
        /// Persisted, so a cold start draws the last line, marked, while it
        /// revalidates.
        static let release = QueryResource<ReleaseLine>(name: "github.release", staleAfter: 60, keep: 12)
        /// `/api/v1/prod/{key}`: the deployment with 25 Sentry issues. Memory
        /// only — prod is never judged from disk.
        static let deployment = QueryResource<HlidacDigest.Deployment>(
            name: "hlidac.deployment", staleAfter: 15, persists: false, keep: 8)
        static let shelf = QueryResource<[ShelfRelease]>(name: "shelf.releases", staleAfter: ShelfRelease.staleAfter)
    }

    private func releaseKey(_ source: ReleaseSource, identity: String) -> QueryKey {
        QueryKey(resource: ProdDetailResources.release.name, identity: identity,
                 scope: "\(source.repo)@\(source.environment):\(source.branch ?? "")")
    }

    /// What memory holds for `source` under the current identity, any age.
    func cachedReleaseLine(_ source: ReleaseSource) -> (line: ReleaseLine, fetchedAt: Date)? {
        guard let identity = prIndexIdentity else { return nil }
        return QueryRepository.shared.cached(ReleaseLine.self, key: releaseKey(source, identity: identity))
            .map { ($0.value, $0.fetchedAt) }
    }

    /// `maxAge: .infinity` answers from memory or the snapshot at once; the
    /// default revalidates.
    func releaseLine(_ source: ReleaseSource,
                     maxAge: TimeInterval = ProdDetailResources.release.staleAfter) async throws
        -> (line: ReleaseLine, fetchedAt: Date) {
        let identity = try await client.cacheIdentity()
        let key = releaseKey(source, identity: identity)
        let line = try await QueryRepository.shared.load(ProdDetailResources.release, key: key, maxAge: maxAge) { [client] in
            try await client.releaseLine(source, identity: identity)
        }
        return (line, QueryRepository.shared.cached(ReleaseLine.self, key: key)?.fetchedAt ?? Date())
    }

    /// Only while Hlídač answers live: a blind or restored board keeps the
    /// digest's card, never a detail from before it went blind. Every
    /// selection reads anew (a concurrent reader still shares the flight):
    /// an answer from memory could predate the digest generation on screen.
    func hlidacDeployment(_ key: String) async throws -> HlidacDigest.Deployment? {
        guard hlidacConfigured, prodUnconfirmedSince == nil else { return nil }
        let base = hlidacBase
        return try await QueryRepository.shared.load(
            ProdDetailResources.deployment,
            key: QueryKey(resource: ProdDetailResources.deployment.name, identity: base.absoluteString, scope: key),
            maxAge: 0) {
            try await HlidacClient.shared.deployment(base: base, key: key)
        }
    }

    /// Entering Prod: the shelf's last answer at once (memory or snapshot),
    /// then a revalidation when it is older than its schedule. A failure
    /// keeps what is drawn, "as of"; with nothing drawn the section hides.
    func refreshShelf() async {
        let resource = ProdDetailResources.shelf
        let key = QueryKey(resource: resource.name, identity: AppsShelfClient.origin.absoluteString)
        let fetch: @Sendable () async throws -> [ShelfRelease] = { try await AppsShelfClient.shared.releases() }
        do {
            for maxAge in [TimeInterval.infinity, resource.staleAfter] {
                let releases = try await QueryRepository.shared.load(resource, key: key, maxAge: maxAge, fetch: fetch)
                if releases != shelfReleases { shelfReleases = releases }
                shelfFetchedAt = QueryRepository.shared.cached([ShelfRelease].self, key: key)?.fetchedAt
            }
        } catch {
            NSLog("pultik: apps shelf read failed: %@", String(describing: error))
        }
    }
}
