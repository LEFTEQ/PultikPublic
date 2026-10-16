import Foundation

/// Every change-request verb as GitHub requests it (PR workbench D4): a
/// GraphQL mutation whose single `$input` variable carries every value — a
/// node id, a body the operator typed — so nothing is ever spliced into a
/// document; or the one REST call where GraphQL has no clean form (the
/// milestone, which REST sets and clears alike by number).
/// Foundation-only: the contract harness pins each verb's request.
enum GitHubPRMutations {
    /// A JSON value, typed so a request's variables compare in a test.
    indirect enum Value: Encodable, Equatable, Sendable, ExpressibleByStringLiteral, ExpressibleByIntegerLiteral,
        ExpressibleByBooleanLiteral, ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral,
        ExpressibleByNilLiteral {
        case string(String)
        case int(Int)
        case bool(Bool)
        case list([Value])
        case object([String: Value])
        case null

        init(stringLiteral value: String) { self = .string(value) }
        init(integerLiteral value: Int) { self = .int(value) }
        init(booleanLiteral value: Bool) { self = .bool(value) }
        init(arrayLiteral elements: Value...) { self = .list(elements) }
        init(dictionaryLiteral elements: (String, Value)...) {
            self = .object(Dictionary(elements, uniquingKeysWith: { $1 }))
        }
        init(nilLiteral: ()) { self = .null }

        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case .string(let value): try container.encode(value)
            case .int(let value): try container.encode(value)
            case .bool(let value): try container.encode(value)
            case .list(let value): try container.encode(value)
            case .object(let value): try container.encode(value)
            case .null: try container.encodeNil()
            }
        }
    }

    /// One request of a verb. Merge with its branch is two; every other verb
    /// is one.
    struct Step: Equatable, Sendable {
        enum Request: Equatable, Sendable {
            /// `name` is the mutation field, its input type `<Name>Input` —
            /// GitHub's convention for every mutation used here.
            case graphQL(name: String, input: [String: Value])
            case rest(method: String, path: String, body: [String: Value])
        }

        let request: Request
        /// What the steps before this one already did, said first when this
        /// one is refused: the merge landed even if its branch survived.
        var after: String?

        /// Built from the mutation's name alone: the operator's values live in
        /// `$input`.
        var document: String? {
            guard case .graphQL(let name, _) = request, let first = name.first else { return nil }
            return "mutation($input: \(first.uppercased() + name.dropFirst())Input!) { \(name)(input: $input) { clientMutationId } }"
        }

        func body() throws -> Data {
            switch request {
            case .graphQL(_, let input):
                return try JSONEncoder().encode(GraphQLBody(query: document ?? "", variables: ["input": .object(input)]))
            case .rest(_, _, let body):
                return try JSONEncoder().encode(body)
            }
        }

        /// The host's refusal of this step, after what already happened.
        func refused(_ message: String) -> CodeHostFailure {
            .rejected(after.map { "\($0): \(message)" } ?? message)
        }
    }

    /// A 4xx answer to a mutation, with GitHub's own message.
    struct Refusal: Error, LocalizedError, Equatable {
        let status: Int
        let message: String

        var errorDescription: String? { message }
    }

    enum Failure: Error {
        case rateLimited
    }

    /// The steps of `verb` against the activity the operator saw. A verb the
    /// activity cannot carry (no branch to delete, no pending review to
    /// discard) throws before any request goes out.
    static func steps(_ verb: ChangeRequestVerb, on activity: ChangeRequestActivity,
                      ref: ChangeRequestRef) throws -> [Step] {
        let pr = Value.string(activity.nodeID)
        func mutation(_ name: String, _ input: [String: Value]) -> [Step] {
            [Step(request: .graphQL(name: name, input: input))]
        }
        switch verb {
        case .merge(let method, let expectedHead, let deleteBranch):
            let merge = Step(request: .graphQL(name: "mergePullRequest", input: [
                "pullRequestId": pr, "expectedHeadOid": .string(expectedHead), "mergeMethod": .string(method.github),
            ]))
            // The repository deletes merged branches itself.
            guard deleteBranch, !activity.merge.deleteBranchOnMerge else { return [merge] }
            guard let headRef = activity.merge.headRefID else { throw CodeHostFailure.rejected(noBranch) }
            return [merge, Step(request: .graphQL(name: "deleteRef", input: ["refId": .string(headRef)]),
                                after: "Merged, but the branch was not deleted")]
        case .enableAutoMerge(let method):
            // On the head the operator saw: a push since would merge unseen code.
            return mutation("enablePullRequestAutoMerge", [
                "pullRequestId": pr, "mergeMethod": .string(method.github), "expectedHeadOid": .string(activity.headSHA),
            ])
        case .disableAutoMerge:
            return mutation("disablePullRequestAutoMerge", ["pullRequestId": pr])
        case .updateBranch(let rebase, let expectedHead):
            return mutation("updatePullRequestBranch", [
                "pullRequestId": pr, "expectedHeadOid": .string(expectedHead),
                "updateMethod": rebase ? "REBASE" : "MERGE",
            ])
        case .close:
            return mutation("closePullRequest", ["pullRequestId": pr])
        case .reopen:
            return mutation("reopenPullRequest", ["pullRequestId": pr])
        case .markReady:
            return mutation("markPullRequestReadyForReview", ["pullRequestId": pr])
        case .convertToDraft:
            return mutation("convertPullRequestToDraft", ["pullRequestId": pr])
        case .deleteBranch:
            guard let headRef = activity.merge.headRefID else { throw CodeHostFailure.rejected(noBranch) }
            return mutation("deleteRef", ["refId": .string(headRef)])
        case .comment(let body):
            return mutation("addComment", ["subjectId": pr, "body": .string(body)])
        case .reply(let thread, let body):
            return mutation("addPullRequestReviewThreadReply", [
                "pullRequestReviewThreadId": .string(thread), "body": .string(body),
            ])
        case .resolve(let thread):
            return mutation("resolveReviewThread", ["threadId": .string(thread)])
        case .unresolve(let thread):
            return mutation("unresolveReviewThread", ["threadId": .string(thread)])
        case .edit(let title, let body):
            // An absent field stays as it is; only what changed travels.
            var input: [String: Value] = ["pullRequestId": pr]
            if let title { input["title"] = .string(title) }
            if let body { input["body"] = .string(body) }
            return mutation("updatePullRequest", input)
        case .addReviewComment(let comment):
            guard let pending = activity.pendingReview else {
                // The first one opens the pending review with it, in one
                // request: no review is ever left open without its comment.
                return mutation("addPullRequestReview", [
                    "pullRequestId": pr, "commitOID": .string(activity.headSHA), "threads": [.object(thread(comment))],
                ])
            }
            var input = thread(comment)
            input["pullRequestReviewId"] = .string(pending.id)
            return mutation("addPullRequestReviewThread", input)
        case .submitReview(let event, let body):
            if let pending = activity.pendingReview {
                return mutation("submitPullRequestReview", [
                    "pullRequestReviewId": .string(pending.id), "event": .string(event.github), "body": .string(body),
                ])
            }
            return mutation("addPullRequestReview", [
                "pullRequestId": pr, "commitOID": .string(activity.headSHA), "event": .string(event.github),
                "body": .string(body),
            ])
        case .discardPendingReview:
            guard let pending = activity.pendingReview else {
                throw CodeHostFailure.rejected("There is no pending review to discard.")
            }
            return mutation("deletePullRequestReview", ["pullRequestReviewId": .string(pending.id)])
        case .setReviewers(let users, let teams):
            // A requested bot is a person to the domain and a bot to GitHub.
            let bots = Set(activity.requestedReviewers.filter(\.isBot).map(\.id))
            return mutation("requestReviews", [
                "pullRequestId": pr, "union": false,
                "userIds": .list(users.filter { !bots.contains($0) }.map(Value.string)),
                "botIds": .list(users.filter { bots.contains($0) }.map(Value.string)),
                "teamIds": .list(teams.map(Value.string)),
            ])
        case .setAssignees(let ids):
            return mutation("updatePullRequest", ["pullRequestId": pr, "assigneeIds": .list(ids.map(Value.string))])
        case .setLabels(let ids):
            return mutation("updatePullRequest", ["pullRequestId": pr, "labelIds": .list(ids.map(Value.string))])
        case .setMilestone(let milestone):
            return [Step(request: .rest(method: "PATCH", path: "/repos/\(ref.repo)/issues/\(ref.number)",
                                        body: ["milestone": milestone.map { .int($0.number) } ?? .null]))]
        }
    }

    private static let noBranch = "The head branch is gone or lives in another repository."

    private static func thread(_ comment: DraftReviewComment) -> [String: Value] {
        var input: [String: Value] = [
            "path": .string(comment.path), "line": .int(comment.line), "side": .string(comment.side.github),
            "body": .string(comment.body),
        ]
        if let startLine = comment.startLine {
            input["startLine"] = .int(startLine)
            input["startSide"] = .string((comment.startSide ?? comment.side).github)
        }
        return input
    }

    /// A mutation's answer: GitHub's errors are the refusal, in its words;
    /// quota exhaustion inside the 200 throws `rateLimited`.
    static func decode(_ data: Data, name: String) throws {
        let answer = try JSONDecoder().decode(Answer.self, from: data)
        let errors = answer.errors ?? []
        if errors.contains(where: { $0.type == "RATE_LIMITED" }) { throw Failure.rateLimited }
        if !errors.isEmpty {
            throw CodeHostFailure.rejected(errors.map(\.message).joined(separator: "\n"))
        }
        guard case .some(.some) = answer.data?[name] else {
            throw CodeHostFailure.rejected("GitHub did not apply \(name).")
        }
    }

    /// GitHub's message from a refused REST body, with each validation
    /// detail; the status alone when the body is not GitHub's JSON.
    static func refusalMessage(_ data: Data, status: Int) -> String {
        // An HTML error page or an empty body is still a refusal: the status
        // is what is left to say.
        guard let body = try? JSONDecoder().decode(RESTRefusal.self, from: data), let message = body.message else {
            return "GitHub refused the change (HTTP \(status))."
        }
        let details = (body.errors ?? []).compactMap(\.text)
        return details.isEmpty ? message : "\(message): \(details.joined(separator: "; "))"
    }

    // MARK: - Wire

    private struct GraphQLBody: Encodable {
        let query: String
        let variables: [String: Value]
    }

    private struct Answer: Decodable {
        let data: [String: Present?]?
        let errors: [Failed]?

        struct Failed: Decodable {
            let type: String?
            let message: String
        }
    }

    /// Any payload: a mutation's answer only has to be there.
    private struct Present: Decodable {
        init(from _: Decoder) {}
    }

    private struct RESTRefusal: Decodable {
        let message: String?
        let errors: [Detail]?

        /// A validation detail: a plain string on some endpoints, an object
        /// with a message, or only the field and code on others.
        struct Detail: Decodable {
            let text: String?

            init(from decoder: Decoder) throws {
                if let text = try? decoder.singleValueContainer().decode(String.self) {
                    self.text = text
                    return
                }
                let fields = try decoder.container(keyedBy: Keys.self)
                let parts = try [Keys.field, .code].compactMap { try fields.decodeIfPresent(String.self, forKey: $0) }
                text = try fields.decodeIfPresent(String.self, forKey: .message)
                    ?? (parts.isEmpty ? nil : parts.joined(separator: " "))
            }

            enum Keys: String, CodingKey { case message, field, code }
        }
    }
}

private extension MergeMethod {
    var github: String { rawValue.uppercased() }
}

private extension ReviewEvent {
    var github: String {
        switch self {
        case .approve: "APPROVE"
        case .requestChanges: "REQUEST_CHANGES"
        case .comment: "COMMENT"
        }
    }
}

private extension DraftReviewComment.Side {
    var github: String { rawValue.uppercased() }
}
