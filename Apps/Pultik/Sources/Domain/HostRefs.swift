import Foundation

/// Pultík's own domain (stay in Pultík N2): change requests, reviews, runs,
/// jobs and log tails as Pultík models them, behind `CodeHost`, `CIHost` and
/// `CIStatusSource`. Only `Sources/API/Hosts/` and the `GitHub*` API files
/// know GitHub; views and stores speak these types, so our own forge or CI
/// arrives as one more adapter (`tools/host-neutral-check.sh` holds the line).
/// Foundation-only: the contract harness builds it.
enum HostKind: String, Codable, Hashable, Sendable {
    /// github.com — the first adapter.
    case github = "gh"
}

/// One change request on one host: `gh:owner/repo#1907`.
struct ChangeRequestRef: Hashable, Codable, Sendable, CustomStringConvertible {
    var host: HostKind = .github
    let repo: String
    let number: Int

    init(host: HostKind = .github, repo: String, number: Int) {
        self.host = host
        self.repo = repo
        self.number = number
    }

    /// The host-qualified id every surface keys it by.
    var key: String { "\(host.rawValue):\(repo)#\(number)" }
    var description: String { key }

    /// `gh:owner/repo#1907` back into a ref; nil for anything else.
    init?(key: String) {
        guard let colon = key.firstIndex(of: ":"), let host = HostKind(rawValue: String(key[..<colon])),
              let hash = key.lastIndex(of: "#"), hash > colon, let number = Int(key[key.index(after: hash)...])
        else { return nil }
        let repo = String(key[key.index(after: colon) ..< hash])
        guard repo.contains("/") else { return nil }
        self.init(host: host, repo: repo, number: number)
    }
}

/// One CI run on one host: `gh:owner/repo/run/123`.
struct CIRunRef: Hashable, Codable, Sendable, CustomStringConvertible {
    var host: HostKind = .github
    let repo: String
    let runID: Int

    init(host: HostKind = .github, repo: String, runID: Int) {
        self.host = host
        self.repo = repo
        self.runID = runID
    }

    var key: String { "\(host.rawValue):\(repo)/run/\(runID)" }
    var description: String { key }

    init?(key: String) {
        guard let colon = key.firstIndex(of: ":"), let host = HostKind(rawValue: String(key[..<colon])),
              let marker = key.range(of: "/run/", options: .backwards), marker.lowerBound > colon,
              let runID = Int(key[marker.upperBound...])
        else { return nil }
        self.init(host: host, repo: String(key[key.index(after: colon) ..< marker.lowerBound]), runID: runID)
    }
}
