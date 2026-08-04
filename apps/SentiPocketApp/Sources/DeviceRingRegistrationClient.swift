// DeviceRingRegistrationClient — authenticated Registry V2 register + conditional unregister transport.
//
// The gateway derives humanId from the captured session bearer. The body carries only the selected session, APNs token,
// and Keychain-owned installation generation. A successful register is not trusted until its server-generated binding
// proof is decoded, bound to the exact request, and the captured bearer is still current. Cleanup snapshots its bearer
// synchronously before sign-out and is compare-delete only; it never invalidates a later principal.

import Foundation

enum DeviceRingRegistrationError: LocalizedError, Equatable {
    case notLoggedIn
    case reauthenticationRequired
    case supersededAuthentication
    case notAuthorized
    case bindingConflict
    case deviceCapacityReached
    case malformedResponse
    case cancelled
    case retryable(Int)
    case rejected(Int)
    case network(String)

    var errorDescription: String? {
        switch self {
        case .notLoggedIn:
            return "Sign in first — registering this device for rings needs your Senti session."
        case .reauthenticationRequired:
            return "Your Senti authorization expired while registering this device."
        case .supersededAuthentication:
            return "The registration response belonged to an earlier sign-in and was ignored."
        case .notAuthorized:
            return "Not authorized to register this device for that session."
        case .bindingConflict:
            return "A newer installation binding superseded this registration."
        case .deviceCapacityReached:
            return "This Senti session already has the maximum number of registered devices."
        case .malformedResponse:
            return "The gateway returned an invalid device binding."
        case .cancelled:
            return "Device registration was cancelled."
        case .retryable(let code):
            return "The gateway couldn't register the device (HTTP \(code)) — will retry."
        case .rejected(let code):
            return "The gateway rejected the device registration (HTTP \(code))."
        case .network(let message):
            return "Device-registration network error: \(message)"
        }
    }
}

struct DeviceRingRegistrationClient {
    private let apiBaseURL: URL
    private let urlSession: URLSession
    private let tokenProvider: @Sendable () -> String?
    private let onReauthenticationRequired: @Sendable (String?) -> Void
    private let nowEpochSec: @Sendable () -> Int64

    init(
        apiBaseURL: URL,
        urlSession: URLSession = .shared,
        tokenProvider: @escaping @Sendable () -> String? = { SessionTokenStore.load() },
        onReauthenticationRequired: @escaping @Sendable (String?) -> Void = { _ in },
        nowEpochSec: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970) }
    ) {
        self.apiBaseURL = apiBaseURL
        self.urlSession = urlSession
        self.tokenProvider = tokenProvider
        self.onReauthenticationRequired = onReauthenticationRequired
        self.nowEpochSec = nowEpochSec
    }

    private struct RegisterRequest: Encodable {
        let registryVersion: Int
        let installationId: String
        let installationGeneration: String
        let voipToken: String
        let sessionId: String
        let platform: String
    }

    private struct RegisterResponse: Decodable {
        let registered: Bool
        let registryVersion: Int
        let sessionId: String
        let platform: String
        let installationGeneration: String
        let bindingId: String
        let bindingRevision: String
        let leaseExpiresAtSec: Int64
    }

    private struct UnregisterRequest: Encodable {
        let registryVersion: Int
        let installationId: String
        let installationGeneration: String
        let previousInstallationGeneration: String
        let bindingId: String
        let bindingRevision: String
        let sessionId: String
    }

    private struct ErrorResponse: Decodable {
        let reason: String?
    }

    /// Returns the exact proof the app must persist and compare with future pushes. A legacy `{}` 2xx is malformed,
    /// never treated as a V2 success.
    func register(
        voipToken: String,
        sessionId: String,
        attempt: DeviceRingRegistrationAttempt,
        platform: String = "apns"
    ) async throws -> DeviceRingBinding {
        guard let token = tokenProvider(), !token.isEmpty else {
            onReauthenticationRequired(nil)
            throw DeviceRingRegistrationError.notLoggedIn
        }
        guard !voipToken.isEmpty,
              !sessionId.isEmpty,
              sessionId == attempt.sessionId,
              Self.isOpaque(attempt.installationId),
              Self.isGeneration(attempt.installationGeneration) else {
            throw DeviceRingRegistrationError.rejected(400)
        }
        guard let url = URL(string: "/dial/register", relativeTo: apiBaseURL) else {
            throw DeviceRingRegistrationError.network("bad register url")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(RegisterRequest(
            registryVersion: DeviceRingBinding.registryVersion,
            installationId: attempt.installationId,
            installationGeneration: attempt.installationGeneration,
            voipToken: voipToken,
            sessionId: sessionId,
            platform: platform
        ))

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await urlSession.data(for: request)
        } catch is CancellationError {
            throw DeviceRingRegistrationError.cancelled
        } catch let error as URLError where error.code == .cancelled {
            throw DeviceRingRegistrationError.cancelled
        } catch {
            throw DeviceRingRegistrationError.network(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw DeviceRingRegistrationError.network("no HTTP response")
        }

        // Every terminal response is interpreted under the bearer that initiated it. A cannot publish a binding or
        // sign out B after an account switch, including a late 2xx.
        guard tokenProvider() == token else {
            throw DeviceRingRegistrationError.supersededAuthentication
        }

        switch http.statusCode {
        case 200..<300:
            guard let decoded = try? JSONDecoder().decode(RegisterResponse.self, from: data),
                  decoded.registered,
                  decoded.registryVersion == DeviceRingBinding.registryVersion,
                  decoded.sessionId == sessionId,
                  decoded.platform == platform,
                  decoded.installationGeneration == attempt.installationGeneration,
                  Self.isOpaque(decoded.bindingId),
                  Self.isOpaque(decoded.bindingRevision),
                  decoded.leaseExpiresAtSec > nowEpochSec() else {
                throw DeviceRingRegistrationError.malformedResponse
            }
            return DeviceRingBinding(
                registryVersion: decoded.registryVersion,
                sessionId: decoded.sessionId,
                tokenFingerprint: attempt.tokenFingerprint,
                installationGeneration: decoded.installationGeneration,
                bindingId: decoded.bindingId,
                bindingRevision: decoded.bindingRevision,
                leaseExpiresAtSec: decoded.leaseExpiresAtSec
            )
        case 401:
            onReauthenticationRequired(token)
            throw DeviceRingRegistrationError.reauthenticationRequired
        case 403:
            throw DeviceRingRegistrationError.notAuthorized
        case 409:
            switch (try? JSONDecoder().decode(ErrorResponse.self, from: data))?.reason {
            case "binding-generation-conflict", "binding-superseded":
                throw DeviceRingRegistrationError.bindingConflict
            case "device-cap-reached":
                throw DeviceRingRegistrationError.deviceCapacityReached
            default:
                throw DeviceRingRegistrationError.rejected(http.statusCode)
            }
        case 500..<600:
            throw DeviceRingRegistrationError.retryable(http.statusCode)
        default:
            throw DeviceRingRegistrationError.rejected(http.statusCode)
        }
    }

    /// Snapshot a best-effort compare-delete before SessionTokenStore is cleared. The returned task owns only this
    /// prepared request; a 401 or late response never calls the shared reauthentication handler.
    func beginUnregister(_ attempt: DeviceRingUnregistrationAttempt) -> Task<Bool, Never>? {
        guard let token = tokenProvider(), !token.isEmpty,
              Self.isOpaque(attempt.installationId),
              Self.isGeneration(attempt.installationGeneration),
              Self.isGeneration(attempt.previousInstallationGeneration),
              Self.isOpaque(attempt.bindingId),
              Self.isOpaque(attempt.bindingRevision),
              !attempt.sessionId.isEmpty,
              let url = URL(string: "/dial/unregister", relativeTo: apiBaseURL) else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        guard let body = try? JSONEncoder().encode(UnregisterRequest(
            registryVersion: DeviceRingBinding.registryVersion,
            installationId: attempt.installationId,
            installationGeneration: attempt.installationGeneration,
            previousInstallationGeneration: attempt.previousInstallationGeneration,
            bindingId: attempt.bindingId,
            bindingRevision: attempt.bindingRevision,
            sessionId: attempt.sessionId
        )) else { return nil }
        request.httpBody = body
        let session = urlSession
        return Task {
            do {
                let (_, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse else { return false }
                return (200..<300).contains(http.statusCode)
            } catch {
                return false
            }
        }
    }

    private static func isGeneration(_ value: String) -> Bool {
        guard !value.isEmpty,
              value.first != "0",
              value.allSatisfy(\.isNumber) else { return false }
        return UInt64(value) != nil
    }

    private static func isOpaque(_ value: String) -> Bool {
        let bytes = value.utf8
        return (22...128).contains(bytes.count) &&
        bytes.allSatisfy {
            (48...57).contains($0) ||
            (65...90).contains($0) ||
            (97...122).contains($0) ||
            $0 == 95 ||
            $0 == 45
        }
    }
}
