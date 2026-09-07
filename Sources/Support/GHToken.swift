import Foundation

enum GHTokenError: LocalizedError {
    case ghNotFound
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case .ghNotFound:
            return "gh CLI not found — install it and run `gh auth login`."
        case .commandFailed(let detail):
            return "`gh auth token` failed: \(detail)"
        }
    }
}

enum GHToken {
    /// Reads the GitHub token from the gh CLI. Blocking — call off the main thread.
    static func fetch() throws -> String {
        let candidates = ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/usr/bin/gh"]
        guard let ghPath = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw GHTokenError.ghNotFound
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: ghPath)
        process.arguments = ["auth", "token"]
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let err = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw GHTokenError.commandFailed(err.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        let token = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !token.isEmpty else {
            throw GHTokenError.commandFailed("empty token — run `gh auth login`")
        }
        return token
    }
}
