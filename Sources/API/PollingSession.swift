import Foundation

/// Polling stores retain the latest decoded snapshot. HTTP response caches
/// would keep a second copy in every backend's long-lived session.
enum PollingSession {
    static func make(timeout: TimeInterval = 60) -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.timeoutIntervalForRequest = timeout
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }
}
