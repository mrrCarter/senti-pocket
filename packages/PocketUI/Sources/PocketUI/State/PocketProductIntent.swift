import Foundation

/// User gestures emitted by the account and Sessions surfaces.
///
/// These are presentation intents only. They carry no credential, URL, MCP tool name, or server authority. The app
/// coordinator maps them to Atlas/Relay-owned deterministic auth and repository operations.
public enum PocketProductIntent: Equatable, Sendable {
    case beginSignIn
    case cancelSignIn
    case retryAuthentication
    case signOut

    case selectSession(sessionId: String)
    case refreshSessions
    case loadMoreSessions
    case refreshActivity(sessionId: String)
    case openEvent(sessionId: String, sequenceId: Int64)
    case openAction(sessionId: String, actionId: String)
    case refreshCheckpoints(sessionId: String)
    case openCheckpoint(sessionId: String, checkpointId: String)
}

/// A deliberately credential-free projection of the native authorization coordinator.
public enum PocketSignInPhase: Equatable, Sendable {
    case signedOut
    case authorizing
    case signedIn
    case reauthenticationRequired
    case signingOut
    case unavailable(PocketSignInUnavailableReason)
}

public enum PocketSignInUnavailableReason: Equatable, Sendable {
    case configuration
    case network
    case secureStorage
    case service

    public var userMessage: String {
        switch self {
        case .configuration:
            return "This build is not registered for secure sign-in."
        case .network:
            return "Sign-in could not reach Senti. Check your connection and try again."
        case .secureStorage:
            return "Senti could not securely store your session on this device."
        case .service:
            return "Secure sign-in is temporarily unavailable."
        }
    }
}
