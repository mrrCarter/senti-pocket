import Foundation

/// Bounded deadlines for interactive Senti HTTP calls.
///
/// `URLSession.shared` inherits Foundation's multi-day resource timeout, which can leave a phone-facing operation
/// suspended long after the UI can use its result. Production clients use this policy while tests remain free to
/// inject purpose-built sessions and URL protocols.
enum SentiHTTPTransportPolicy {
    static let requestTimeout: TimeInterval = 15
    static let resourceTimeout: TimeInterval = 60
    static let liveSession = URLSession(configuration: makeConfiguration())
    static let checkpointSession = URLSession(configuration: makeCheckpointConfiguration())

    static func makeConfiguration() -> URLSessionConfiguration {
        precondition(resourceTimeout >= requestTimeout)
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = requestTimeout
        configuration.timeoutIntervalForResource = resourceTimeout
        return configuration
    }

    /// Exact signed checkpoints are streamed under their own 45-second request deadline inside this 60-second wall.
    /// The session carries no URL cache, cookies, or credential store; authorization always comes from the current
    /// Keychain bearer explicitly attached by `HTTPCheckpointTransport`.
    static func makeCheckpointConfiguration() -> URLSessionConfiguration {
        precondition(resourceTimeout >= requestTimeout)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = requestTimeout
        configuration.timeoutIntervalForResource = resourceTimeout
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        return configuration
    }
}
