import Foundation

/// Thin client for eve's `/eve/v1` HTTP API on the WireGuard mesh.
///
/// Mesh-gated, plus an optional `Authorization: Bearer evk_…` for eve's RBAC
/// gate — see `EveAuth`; without a token the requests are exactly what they
/// were before. Off-mesh every call fails fast and the panel degrades to
/// GitHub-only (see `probeHealth`'s short timeout).
actor EveClient {
    static let shared = EveClient()

    private let base = URL(string: "https://eve.ops.example.invalid")!
    private let session: URLSession

    init() {
        session = PollingSession.make(timeout: 300) // stream stays open while eve works
    }

    /// Fast reachability probe — 3s budget so an off-mesh panel opens
    /// instantly. Returns the classified failure (nil = healthy) so a 401/403
    /// on a half-open trial re-arms the breaker as `.rejected`, not
    /// `.unreachable` — the same contract as the GitHub and Sentry probes.
    func probeHealth(settingsToken: String?) async -> ProbeFailure? {
        var request = URLRequest(url: base.appending(path: "eve/v1/health"))
        request.timeoutInterval = 3
        EveAuth.apply(await EveAuth.shared.token(preferred: settingsToken), to: &request)
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return .unreachable("no response")
            }
            guard http.statusCode == 200 else {
                return .classify(HTTPStatusError(status: http.statusCode))
            }
            guard let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  body["ok"] as? Bool == true else {
                return .unreachable("health endpoint not ok")
            }
            return nil
        } catch {
            return .classify(error)
        }
    }

    /// Recent PR-subagent runs — matched to open PRs by repo#number.
    /// Fails fast off-mesh (10s budget) so refresh never hangs on it.
    ///
    /// Reports its failures rather than flattening them to `[]`: with the
    /// alerts rail hidden this is the ONLY eve call a refresh makes, and a
    /// breaker can't back off from a failure nobody told it about.
    func prSessions(settingsToken: String?) async -> ProbeResult<[EveSession]> {
        var request = URLRequest(url: base.appending(path: "eve/v1/sessions")
            .appending(queryItems: [
                URLQueryItem(name: "flow", value: "pr_review"),
                URLQueryItem(name: "limit", value: "50"),
            ]))
        request.timeoutInterval = 10
        EveAuth.apply(await EveAuth.shared.token(preferred: settingsToken), to: &request)
        let data: Data
        do {
            let (body, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return .failed(.unreachable("no response"))
            }
            guard (200..<300).contains(http.statusCode) else {
                return .failed(.classify(HTTPStatusError(status: http.statusCode)))
            }
            data = body
        } catch {
            return .failed(.classify(error))
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601Flexible
        do {
            return .value(try decoder.decode(EveSessionsResponse.self, from: data).sessions)
        } catch {
            // A 2xx we can't read is not a valid answer — report it like the
            // notifications client does instead of flattening to [] and
            // letting the gate record a success it didn't earn.
            return .failed(.unreachable("unreadable sessions payload"))
        }
    }

    struct AskEvent {
        let text: String
        let done: Bool
        let sessionId: String
    }

    /// POST /eve/v1/session responds 202 {sessionId, continuationToken, ok} —
    /// decode only what we use (`ok` is a Bool, so [String: String] won't do).
    private struct SessionCreated: Decodable {
        let sessionId: String
    }

    /// Ask eve and stream the growing answer. Yields the cumulative text after
    /// each stream event; the final element has `done == true`.
    func ask(_ message: String, settingsToken: String?) -> AsyncThrowingStream<AskEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    // Resolved once for the whole exchange — create + stream.
                    let token = await EveAuth.shared.token(preferred: settingsToken)
                    var create = URLRequest(url: base.appending(path: "eve/v1/session"))
                    create.httpMethod = "POST"
                    create.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    create.httpBody = try JSONEncoder().encode(["message": message])
                    create.timeoutInterval = 15
                    EveAuth.apply(token, to: &create)
                    let (data, response) = try await session.data(for: create)
                    guard (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) == true,
                          let created = try? JSONDecoder().decode(SessionCreated.self, from: data)
                    else {
                        throw URLError(.badServerResponse)
                    }
                    let sessionId = created.sessionId

                    // NDJSON event stream; the answer text arrives cumulatively
                    // (text ?? message ?? messageSoFar ?? cumulativeText).
                    let streamURL = base.appending(path: "eve/v1/session/\(sessionId)/stream")
                    var streamRequest = URLRequest(url: streamURL)
                    EveAuth.apply(token, to: &streamRequest)
                    let (bytes, _) = try await session.bytes(for: streamRequest)
                    var latest = ""
                    for try await line in bytes.lines {
                        guard let lineData = line.data(using: .utf8),
                              let event = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                              let type = event["type"] as? String
                        else { continue }
                        // The stream replays our own inbound turn — never echo it.
                        if type == "message.received" { continue }
                        let payload = event["data"] as? [String: Any]
                        let text = (payload?["text"] ?? payload?["message"]
                            ?? payload?["messageSoFar"] ?? payload?["cumulativeText"]) as? String
                        if let text, type.hasPrefix("message.") || type == "session.completed" {
                            latest = text
                            continuation.yield(AskEvent(text: latest, done: false, sessionId: sessionId))
                        }
                        // The turn ends on session.waiting (eve parks for the next
                        // user message) — the stream itself never closes.
                        if type == "session.waiting" || type == "session.completed" || type == "session.failed" { break }
                    }
                    continuation.yield(AskEvent(text: latest, done: true, sessionId: sessionId))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
