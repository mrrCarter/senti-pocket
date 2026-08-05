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

    static func makeConfiguration() -> URLSessionConfiguration {
        precondition(resourceTimeout >= requestTimeout)
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = requestTimeout
        configuration.timeoutIntervalForResource = resourceTimeout
        return configuration
    }
}
