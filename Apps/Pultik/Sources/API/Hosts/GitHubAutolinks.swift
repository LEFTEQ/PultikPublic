import Foundation
import Links

/// Where GitHub's references open (stay in Pultík D8): a change request
/// Pultík's indexes hold opens its own detail (`pultik://pr/…`, the
/// `PultikLink` scheme), anything else its page on github.com — an issue
/// number GitHub forwards to the PR when it is one.
struct GitHubAutolinks: AutolinkResolver {
    /// Pultík's indexes (the PR index, the inbox) hold this change request.
    let knows: (ChangeRequestRef) -> Bool

    func url(for reference: AutolinkReference) -> URL? {
        switch reference {
        case let .changeRequest(ref):
            if knows(ref) { return PultikLink.pr(repo: ref.repo, number: ref.number).url }
            return URL(string: "https://github.com/\(ref.repo)/issues/\(ref.number)")
        case let .user(login):
            return URL(string: "https://github.com/\(login)")
        case let .commit(repo, sha):
            return URL(string: "https://github.com/\(repo)/commit/\(sha)")
        }
    }
}
