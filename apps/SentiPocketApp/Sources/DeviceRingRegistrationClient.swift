import Foundation

struct DeviceRingRegistrationRequest: Encodable, Equatable, Sendable {
    let registrationVersion: Int
    let ownerVersion: Int
    let ownerHandle: String
    let installationId: String
    let idempotencyKey: String
    let voipToken: String
    let sessionId: String
    let platform: String
    let expectedBindingId: String?
    let expectedBindingRevision: Int?
    let expectedTokenClaimId: String?
    let expectedTokenClaimRevision: Int?

    init(
        ownerHandle: String,
        installationId: String,
        idempotencyKey: String,
        voipToken: String,
        sessionId: String,
        platform: String = "apns",
        expectedBindingId: String? = nil,
        expectedBindingRevision: Int? = nil,
        expectedTokenClaimId: String? = nil,
        expectedTokenClaimRevision: Int? = nil
    ) {
        self.registrationVersion = 2
        self.ownerVersion = DeviceRingRegistryOwnerContext.version
        self.ownerHandle = ownerHandle
        self.installationId = installationId
        self.idempotencyKey = idempotencyKey
        self.voipToken = voipToken
        self.sessionId = sessionId
        self.platform = platform
        self.expectedBindingId = expectedBindingId
        self.expectedBindingRevision = expectedBindingRevision
        self.expectedTokenClaimId = expectedTokenClaimId
        self.expectedTokenClaimRevision = expectedTokenClaimRevision
    }
}

struct DeviceRingRegistrationCleanupRequest: Encodable, Equatable, Sendable {
    let registrationVersion: Int
    let ownerVersion: Int
    let ownerHandle: String
    let installationId: String
    let idempotencyKey: String
    let tokenDigest: String
    let sessionId: String
    let platform: String

    init(
        ownerHandle: String,
        installationId: String,
        idempotencyKey: String,
        tokenDigest: String,
        sessionId: String,
        platform: String = "apns"
    ) {
        self.registrationVersion = 2
        self.ownerVersion = DeviceRingRegistryOwnerContext.version
        self.ownerHandle = ownerHandle
        self.installationId = installationId
        self.idempotencyKey = idempotencyKey
        self.tokenDigest = tokenDigest
        self.sessionId = sessionId
        self.platform = platform
    }
}

struct DeviceRingUnregistrationRequest: Encodable, Equatable, Sendable {
    let registrationVersion: Int
    let ownerVersion: Int
    let ownerHandle: String
    let installationId: String
    let sessionId: String
    let bindingId: String
    let bindingRevision: Int

    init(
        ownerHandle: String,
        installationId: String,
        sessionId: String,
        bindingId: String,
        bindingRevision: Int
    ) {
        self.registrationVersion = 2
        self.ownerVersion = DeviceRingRegistryOwnerContext.version
        self.ownerHandle = ownerHandle
        self.installationId = installationId
        self.sessionId = sessionId
        self.bindingId = bindingId
        self.bindingRevision = bindingRevision
    }
}

/// Opaque, server-derived continuity for the verified registry principal. It is neither a bearer nor authority: every
/// mutating request is still authenticated, and the gateway recomputes this value from that exact bearer before use.
struct DeviceRingRegistryOwnerContext: Equatable, Sendable {
    static let version = 1

    let ownerVersion: Int
    let ownerHandle: String
    let serverTime: Date
}

struct DeviceRingRegistrationReceipt: Equatable, Sendable {
    let ownerVersion: Int
    let ownerHandle: String
    let sessionId: String
    let platform: String
    let bindingId: String
    let bindingRevision: Int
    let tokenClaimId: String
    let tokenClaimRevision: Int
    let expiresAt: Date
    let serverTime: Date
    let wallTimeAtReceipt: Date
    let continuousTimeAtReceipt: TimeInterval
    let authorizedLeaseDuration: TimeInterval
    let idempotent: Bool
}

/// A committed registration that must only be used for exact revocation. Unlike a successful registration receipt,
/// this value carries no local lease authority: the gateway has explicitly said the route is unauthorized or expired.
struct DeviceRingRevocationReceipt: Equatable, Sendable {
    let ownerVersion: Int
    let ownerHandle: String
    let sessionId: String
    let platform: String
    let bindingId: String
    let bindingRevision: Int
    let tokenClaimId: String
    let tokenClaimRevision: Int
    let expiresAt: Date
    let serverTime: Date
    let idempotent: Bool
}

struct DeviceRingServerBindingFence: Equatable, Sendable {
    let bindingId: String
    let bindingRevision: Int
    let expiresAt: Date
}

struct DeviceRingServerTokenClaimFence: Equatable, Sendable {
    let tokenClaimId: String
    let tokenClaimRevision: Int
    let expiresAt: Date
}

enum DeviceRingRegistrationError: LocalizedError, Equatable, Sendable {
    case notLoggedIn
    case reauthenticationRequired
    case supersededAuthentication
    case notAuthorized
    case registrationDeniedBeforeCommit
    case registrationCommittedButUnauthorized(DeviceRingRevocationReceipt)
    case registrationExpired(DeviceRingRevocationReceipt)
    case bindingConflict(DeviceRingServerBindingFence?)
    case tokenClaimConflict(DeviceRingServerTokenClaimFence?)
    case registrationConflict
    case idempotencyConflict
    case ownerConflict
    case targetCapacity
    case revisionExhausted
    case clientUpgradeRequired
    case notConfigured
    case retryable(Int)
    case rejected(Int)
    case malformedResponse
    case network(String)

    var errorDescription: String? {
        switch self {
        case .notLoggedIn:
            return "Sign in first — registering this device for rings needs your Senti session."
        case .reauthenticationRequired:
            return "Your Senti authorization expired while registering this device."
        case .supersededAuthentication:
            return "The registry response belonged to an earlier sign-in and was ignored."
        case .notAuthorized:
            return "Not authorized to update this device's ring registration."
        case .registrationDeniedBeforeCommit:
            return "The registration operation was durably denied before it could commit."
        case .registrationCommittedButUnauthorized:
            return "The registration committed after authorization was lost and must be revoked."
        case .registrationExpired:
            return "The committed registration expired and must be cleaned up."
        case .bindingConflict:
            return "The installation binding changed and must be reconciled."
        case .tokenClaimConflict:
            return "The APNs token ownership changed and must be reconciled."
        case .registrationConflict:
            return "The registry could not serialize this registration yet."
        case .idempotencyConflict:
            return "The registry rejected a reused operation identifier."
        case .ownerConflict:
            return "This registry state belongs to a different authenticated account."
        case .targetCapacity:
            return "This target already has the maximum number of active devices."
        case .revisionExhausted:
            return "The registry fence revision is exhausted."
        case .clientUpgradeRequired:
            return "Registry V2 is required for device registration."
        case .notConfigured:
            return "Registry V2 is not configured on the gateway."
        case .retryable(let status):
            return "The gateway could not update the device registry (HTTP \(status)) — retry later."
        case .rejected(let status):
            return "The gateway rejected the device registry request (HTTP \(status))."
        case .malformedResponse:
            return "The gateway returned an invalid Registry V2 response."
        case .network(let reason):
            return "Device-registry network error: \(reason)"
        }
    }
}

protocol DeviceRingRegistryClient: Sendable {
    func ownerContext(bearerToken: String) async throws -> DeviceRingRegistryOwnerContext

    func register(
        _ request: DeviceRingRegistrationRequest,
        bearerToken: String
    ) async throws -> DeviceRingRegistrationReceipt

    func cleanupRegistration(
        _ request: DeviceRingRegistrationCleanupRequest,
        bearerToken: String
    ) async throws

    func unregister(
        _ request: DeviceRingUnregistrationRequest,
        bearerToken: String
    ) async throws
}

/// Strict Registry V2 transport. The registrar captures the bearer before beginning an operation and passes that
/// exact value here, so sign-out can issue DELETE before credential deletion and stale responses remain attributable.
struct DeviceRingRegistrationClient: DeviceRingRegistryClient, @unchecked Sendable {
    private let apiBaseURL: URL
    private let urlSession: URLSession
    private let currentBearerProvider: @Sendable () -> String?
    private let onReauthenticationRequired: @Sendable (String?) -> Void
    private let wallNow: @Sendable () -> Date
    private let continuousNow: @Sendable () -> TimeInterval?
    private let requestTimeout: TimeInterval
    private let maximumLeaseDuration: TimeInterval

    init(
        apiBaseURL: URL,
        urlSession: URLSession = SentiHTTPTransportPolicy.liveSession,
        currentBearerProvider: @escaping @Sendable () -> String? = { SessionTokenStore.load() },
        onReauthenticationRequired: @escaping @Sendable (String?) -> Void = { _ in },
        wallNow: @escaping @Sendable () -> Date = Date.init,
        continuousNow: @escaping @Sendable () -> TimeInterval? = DeviceRingContinuousClock.now,
        requestTimeout: TimeInterval = 8,
        maximumLeaseDuration: TimeInterval = 7 * 24 * 60 * 60
    ) {
        self.apiBaseURL = apiBaseURL
        self.urlSession = urlSession
        self.currentBearerProvider = currentBearerProvider
        self.onReauthenticationRequired = onReauthenticationRequired
        self.wallNow = wallNow
        self.continuousNow = continuousNow
        self.requestTimeout = requestTimeout
        self.maximumLeaseDuration = maximumLeaseDuration
    }

    func ownerContext(bearerToken: String) async throws -> DeviceRingRegistryOwnerContext {
        guard !bearerToken.isEmpty else { throw DeviceRingRegistrationError.notLoggedIn }
        let (data, response) = try await send(
            method: "GET",
            path: "/dial/register/context",
            bearerToken: bearerToken
        )
        guard response.statusCode == 200 else {
            throw try error(
                for: response.statusCode,
                data: data,
                requestBearer: bearerToken,
                retryAfter: response.value(forHTTPHeaderField: "Retry-After")
            )
        }
        struct Response: Decodable {
            let registrationVersion: Int
            let ownerVersion: Int
            let ownerHandle: String
            let serverTime: String
        }
        guard Self.hasExactKeys(in: data, expected: [
                "registrationVersion", "ownerVersion", "ownerHandle", "serverTime",
              ]),
              let decoded = try? JSONDecoder().decode(Response.self, from: data),
              decoded.registrationVersion == 2,
              decoded.ownerVersion == DeviceRingRegistryOwnerContext.version,
              Self.validDigest(decoded.ownerHandle),
              let serverTime = Self.parseDate(decoded.serverTime),
              serverTime.timeIntervalSince1970.isFinite,
              serverTime.timeIntervalSince1970 > 0 else {
            throw DeviceRingRegistrationError.malformedResponse
        }
        return DeviceRingRegistryOwnerContext(
            ownerVersion: decoded.ownerVersion,
            ownerHandle: decoded.ownerHandle,
            serverTime: serverTime
        )
    }

    func register(
        _ request: DeviceRingRegistrationRequest,
        bearerToken: String
    ) async throws -> DeviceRingRegistrationReceipt {
        guard !bearerToken.isEmpty else { throw DeviceRingRegistrationError.notLoggedIn }
        guard Self.valid(request) else { throw DeviceRingRegistrationError.rejected(400) }
        guard let continuousStart = continuousNow(), continuousStart.isFinite, continuousStart >= 0 else {
            throw DeviceRingRegistrationError.malformedResponse
        }
        let (data, response) = try await send(
            method: "POST",
            path: "/dial/register",
            body: request,
            bearerToken: bearerToken
        )
        guard response.statusCode == 200 else {
            let mapped = try error(
                for: response.statusCode,
                data: data,
                registrationRequest: request,
                requestBearer: bearerToken,
                retryAfter: response.value(forHTTPHeaderField: "Retry-After")
            )
            throw mapped
        }
        guard let continuousEnd = continuousNow(),
              continuousEnd.isFinite,
              continuousEnd >= continuousStart else {
            throw DeviceRingRegistrationError.malformedResponse
        }
        let wallTimeAtReceipt = wallNow()

        struct Response: Decodable {
            let registered: Bool
            let registrationVersion: Int
            let ownerVersion: Int
            let ownerHandle: String
            let sessionId: String
            let platform: String
            let bindingId: String
            let bindingRevision: Int
            let tokenClaimId: String
            let tokenClaimRevision: Int
            let expiresAt: String
            let serverTime: String
            let idempotent: Bool
        }
        guard Self.hasExactKeys(in: data, expected: [
            "registered", "registrationVersion", "sessionId", "platform",
                "ownerVersion", "ownerHandle",
                "bindingId", "bindingRevision", "tokenClaimId", "tokenClaimRevision",
                "expiresAt", "serverTime", "idempotent",
              ]),
              let decoded = try? JSONDecoder().decode(Response.self, from: data),
              decoded.registered,
              decoded.registrationVersion == 2,
              decoded.ownerVersion == request.ownerVersion,
              decoded.ownerHandle == request.ownerHandle,
              decoded.sessionId == request.sessionId,
              decoded.platform == request.platform,
              DeviceRingBindingFence(
                id: decoded.bindingId,
                revision: decoded.bindingRevision
              ).isValid,
              decoded.tokenClaimId.range(
                of: #"^claim_[0-9a-f]{32}$"#,
                options: .regularExpression
              ) != nil,
              DeviceRingRegistryValidation.isSafeRevision(decoded.tokenClaimRevision),
              let expiresAt = Self.parseDate(decoded.expiresAt),
              let serverTime = Self.parseDate(decoded.serverTime),
              expiresAt > serverTime else {
            throw DeviceRingRegistrationError.malformedResponse
        }
        let serverLeaseDuration = expiresAt.timeIntervalSince(serverTime)
        let authorizedLeaseDuration = serverLeaseDuration - (continuousEnd - continuousStart)
        guard serverLeaseDuration.isFinite,
              serverLeaseDuration <= maximumLeaseDuration,
              authorizedLeaseDuration.isFinite,
              authorizedLeaseDuration > 0,
              authorizedLeaseDuration <= serverLeaseDuration else {
            throw DeviceRingRegistrationError.malformedResponse
        }
        return DeviceRingRegistrationReceipt(
            ownerVersion: decoded.ownerVersion,
            ownerHandle: decoded.ownerHandle,
            sessionId: decoded.sessionId,
            platform: decoded.platform,
            bindingId: decoded.bindingId,
            bindingRevision: decoded.bindingRevision,
            tokenClaimId: decoded.tokenClaimId,
            tokenClaimRevision: decoded.tokenClaimRevision,
            expiresAt: expiresAt,
            serverTime: serverTime,
            wallTimeAtReceipt: wallTimeAtReceipt,
            continuousTimeAtReceipt: continuousEnd,
            authorizedLeaseDuration: authorizedLeaseDuration,
            idempotent: decoded.idempotent
        )
    }

    func cleanupRegistration(
        _ request: DeviceRingRegistrationCleanupRequest,
        bearerToken: String
    ) async throws {
        guard !bearerToken.isEmpty else { throw DeviceRingRegistrationError.notLoggedIn }
        guard Self.valid(request) else { throw DeviceRingRegistrationError.rejected(400) }
        let (data, response) = try await send(
            method: "POST",
            path: "/dial/register/reconcile",
            body: request,
            bearerToken: bearerToken
        )
        guard response.statusCode == 200 else {
            let mapped = try error(
                for: response.statusCode,
                data: data,
                requestBearer: bearerToken,
                retryAfter: response.value(forHTTPHeaderField: "Retry-After")
            )
            throw mapped
        }

        struct Response: Decodable {
            let registrationVersion: Int
            let ownerVersion: Int
            let ownerHandle: String
            let idempotencyKey: String
            let sessionId: String
            let platform: String
            let registered: Bool
            let authorized: Bool
            let cleanupComplete: Bool
            let serverTime: String
        }
        guard Self.hasExactKeys(in: data, expected: [
                "registrationVersion", "idempotencyKey", "sessionId", "platform",
                "ownerVersion", "ownerHandle", "registered", "authorized", "cleanupComplete", "serverTime",
              ]),
              let decoded = try? JSONDecoder().decode(Response.self, from: data),
              decoded.registrationVersion == 2,
              decoded.ownerVersion == request.ownerVersion,
              decoded.ownerHandle == request.ownerHandle,
              decoded.idempotencyKey == request.idempotencyKey,
              decoded.sessionId == request.sessionId,
              decoded.platform == request.platform,
              decoded.registered == false,
              decoded.authorized == false,
              decoded.cleanupComplete,
              let serverTime = Self.parseDate(decoded.serverTime),
              serverTime.timeIntervalSince1970.isFinite,
              serverTime.timeIntervalSince1970 > 0 else {
            throw DeviceRingRegistrationError.malformedResponse
        }
    }

    func unregister(
        _ request: DeviceRingUnregistrationRequest,
        bearerToken: String
    ) async throws {
        guard !bearerToken.isEmpty else { throw DeviceRingRegistrationError.notLoggedIn }
        guard Self.valid(request) else { throw DeviceRingRegistrationError.rejected(400) }
        let (data, response) = try await send(
            method: "DELETE",
            path: "/dial/register",
            body: request,
            bearerToken: bearerToken
        )
        guard response.statusCode == 200 else {
            let mapped = try error(
                for: response.statusCode,
                data: data,
                requestBearer: bearerToken,
                retryAfter: response.value(forHTTPHeaderField: "Retry-After")
            )
            throw mapped
        }
        struct Response: Decodable {
            let unregistered: Bool
            let registrationVersion: Int
            let ownerVersion: Int
            let ownerHandle: String
            let sessionId: String
        }
        guard Self.hasExactKeys(in: data, expected: [
                "unregistered", "registrationVersion", "ownerVersion", "ownerHandle", "sessionId",
              ]),
              let decoded = try? JSONDecoder().decode(Response.self, from: data),
              decoded.unregistered,
              decoded.registrationVersion == 2,
              decoded.ownerVersion == request.ownerVersion,
              decoded.ownerHandle == request.ownerHandle,
              decoded.sessionId == request.sessionId else {
            throw DeviceRingRegistrationError.malformedResponse
        }
    }

    private func send<Body: Encodable>(
        method: String,
        path: String,
        body: Body,
        bearerToken: String
    ) async throws -> (Data, HTTPURLResponse) {
        try await send(
            method: method,
            path: path,
            encodedBody: try JSONEncoder().encode(body),
            bearerToken: bearerToken
        )
    }

    private func send(
        method: String,
        path: String,
        bearerToken: String
    ) async throws -> (Data, HTTPURLResponse) {
        try await send(method: method, path: path, encodedBody: nil, bearerToken: bearerToken)
    }

    private func send(
        method: String,
        path: String,
        encodedBody: Data?,
        bearerToken: String
    ) async throws -> (Data, HTTPURLResponse) {
        guard let url = URL(string: path, relativeTo: apiBaseURL) else {
            throw DeviceRingRegistrationError.network("bad registry url")
        }
        var request = URLRequest(
            url: url,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: requestTimeout
        )
        request.httpMethod = method
        if encodedBody != nil {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        // The authenticated owner-context GET must never be satisfied from a shared or cross-bearer URL cache.
        // Applying the same policy to mutations keeps this transport uniformly fail-closed.
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        request.setValue("no-cache", forHTTPHeaderField: "Pragma")
        request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        request.httpBody = encodedBody

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await urlSession.data(for: request)
        } catch {
            if error is CancellationError ||
                (error as? URLError)?.code == .cancelled ||
                Task.isCancelled {
                throw CancellationError()
            }
            // Any transport failure is ambiguous: the registrar preserves this operation's idempotency key.
            throw DeviceRingRegistrationError.network(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw DeviceRingRegistrationError.malformedResponse
        }
        return (data, http)
    }

    private func error(
        for status: Int,
        data: Data,
        registrationRequest: DeviceRingRegistrationRequest? = nil,
        requestBearer: String,
        retryAfter: String?
    ) throws -> DeviceRingRegistrationError {
        if status == 401 {
            guard currentBearerProvider() == requestBearer else {
                return .supersededAuthentication
            }
            onReauthenticationRequired(requestBearer)
            return .reauthenticationRequired
        }
        if status == 429 {
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  Set(object.keys) == Set(["error", "reason"]),
                  object["error"] as? String == "registration operation rate limited",
                  object["reason"] as? String == "operation-rate-limited",
                  let retryAfter,
                  retryAfter.range(of: #"^[1-9][0-9]{0,8}$"#, options: .regularExpression) != nil else {
                throw DeviceRingRegistrationError.malformedResponse
            }
            return .retryable(429)
        }
        if status == 403 { return .notAuthorized }
        if status == 426 { return .clientUpgradeRequired }
        if status == 501 { return .notConfigured }
        if status == 409 {
            if let registrationRequest,
               Self.reason(in: data) == "registration-committed-but-unauthorized" {
                return .registrationCommittedButUnauthorized(try Self.revocationReceipt(
                    from: data,
                    request: registrationRequest,
                    reason: "registration-committed-but-unauthorized",
                    isExpired: false
                ))
            }
            return try Self.conflict(from: data, request: registrationRequest)
        }
        if status == 410, let registrationRequest {
            return .registrationExpired(try Self.revocationReceipt(
                from: data,
                request: registrationRequest,
                reason: "registration-expired",
                isExpired: true
            ))
        }
        if (500..<600).contains(status) { return .retryable(status) }
        return .rejected(status)
    }

    private static func reason(in data: Data) -> String? {
        (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["reason"] as? String
    }

    private static func revocationReceipt(
        from data: Data,
        request: DeviceRingRegistrationRequest,
        reason: String,
        isExpired: Bool
    ) throws -> DeviceRingRevocationReceipt {
        let expectedError = isExpired
            ? "registration lease expired"
            : "registration committed but current authorization is missing"
        let expectedKeys: Set<String> = [
            "registered", "committed", "authorized", "revocationRequired", "reason", "error",
            "registrationVersion", "ownerVersion", "ownerHandle", "sessionId", "platform", "bindingId", "bindingRevision",
            "tokenClaimId", "tokenClaimRevision", "expiresAt", "serverTime", "idempotent",
        ]
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == expectedKeys,
              strictBool(object["registered"]) == false,
              strictBool(object["committed"]) == true,
              strictBool(object["authorized"]) == false,
              strictBool(object["revocationRequired"]) == true,
              object["reason"] as? String == reason,
              object["error"] as? String == expectedError,
              strictPositiveInteger(object["registrationVersion"]) == 2,
              strictPositiveInteger(object["ownerVersion"]) == request.ownerVersion,
              object["ownerHandle"] as? String == request.ownerHandle,
              object["sessionId"] as? String == request.sessionId,
              object["platform"] as? String == request.platform,
              let bindingId = object["bindingId"] as? String,
              let bindingRevision = strictPositiveInteger(object["bindingRevision"]),
              DeviceRingBindingFence(id: bindingId, revision: bindingRevision).isValid,
              let tokenClaimId = object["tokenClaimId"] as? String,
              tokenClaimId.range(of: #"^claim_[0-9a-f]{32}$"#, options: .regularExpression) != nil,
              let tokenClaimRevision = strictPositiveInteger(object["tokenClaimRevision"]),
              let rawExpiry = object["expiresAt"] as? String,
              let expiresAt = parseDate(rawExpiry),
              let rawServerTime = object["serverTime"] as? String,
              let serverTime = parseDate(rawServerTime),
              expiresAt.timeIntervalSince1970.isFinite,
              expiresAt.timeIntervalSince1970 > 0,
              serverTime.timeIntervalSince1970.isFinite,
              serverTime.timeIntervalSince1970 > 0,
              (isExpired ? expiresAt <= serverTime : expiresAt > serverTime),
              strictBool(object["idempotent"]) == true else {
            throw DeviceRingRegistrationError.malformedResponse
        }
        return DeviceRingRevocationReceipt(
            ownerVersion: request.ownerVersion,
            ownerHandle: request.ownerHandle,
            sessionId: request.sessionId,
            platform: request.platform,
            bindingId: bindingId,
            bindingRevision: bindingRevision,
            tokenClaimId: tokenClaimId,
            tokenClaimRevision: tokenClaimRevision,
            expiresAt: expiresAt,
            serverTime: serverTime,
            idempotent: true
        )
    }

    private static func conflict(
        from data: Data,
        request: DeviceRingRegistrationRequest?
    ) throws -> DeviceRingRegistrationError {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let reason = object["reason"] as? String,
              object["error"] == nil || object["error"] is String else {
            throw DeviceRingRegistrationError.malformedResponse
        }
        switch reason {
        case "registration-denied-before-commit":
            guard let request,
                  Set(object.keys) == Set([
                    "registered", "committed", "authorized", "revocationRequired", "reason", "error",
                    "registrationVersion", "ownerVersion", "ownerHandle", "sessionId", "platform", "idempotent",
                  ]),
                  strictBool(object["registered"]) == false,
                  strictBool(object["committed"]) == false,
                  strictBool(object["authorized"]) == false,
                  strictBool(object["revocationRequired"]) == false,
                  object["error"] as? String == "registration operation was denied before commit",
                  strictPositiveInteger(object["registrationVersion"]) == 2,
                  strictPositiveInteger(object["ownerVersion"]) == request.ownerVersion,
                  object["ownerHandle"] as? String == request.ownerHandle,
                  object["sessionId"] as? String == request.sessionId,
                  object["platform"] as? String == request.platform,
                  strictBool(object["idempotent"]) == true else {
                throw DeviceRingRegistrationError.malformedResponse
            }
            return .registrationDeniedBeforeCommit
        case "binding-conflict":
            guard let request,
                  hasAllowedKeys(
                object,
                required: ["reason", "ownerVersion", "ownerHandle", "currentBinding"],
                optional: ["error"]
                  ),
                  strictPositiveInteger(object["ownerVersion"]) == request.ownerVersion,
                  object["ownerHandle"] as? String == request.ownerHandle else {
                throw DeviceRingRegistrationError.malformedResponse
            }
            if object["currentBinding"] is NSNull { return .bindingConflict(nil) }
            guard let current = object["currentBinding"] as? [String: Any],
                  let fence = parseBindingFence(current) else {
                throw DeviceRingRegistrationError.malformedResponse
            }
            return .bindingConflict(fence)
        case "token-claim-conflict":
            guard let request,
                  hasAllowedKeys(
                object,
                required: ["reason", "ownerVersion", "ownerHandle", "currentTokenClaim"],
                optional: ["error"]
                  ),
                  strictPositiveInteger(object["ownerVersion"]) == request.ownerVersion,
                  object["ownerHandle"] as? String == request.ownerHandle else {
                throw DeviceRingRegistrationError.malformedResponse
            }
            if object["currentTokenClaim"] is NSNull { return .tokenClaimConflict(nil) }
            guard let current = object["currentTokenClaim"] as? [String: Any],
                  let fence = parseTokenClaimFence(current) else {
                throw DeviceRingRegistrationError.malformedResponse
            }
            return .tokenClaimConflict(fence)
        case "registration-conflict":
            guard hasAllowedKeys(object, required: ["reason"], optional: ["error"]) else {
                throw DeviceRingRegistrationError.malformedResponse
            }
            return .registrationConflict
        case "idempotency-conflict":
            guard hasAllowedKeys(object, required: ["reason"], optional: ["error"]) else {
                throw DeviceRingRegistrationError.malformedResponse
            }
            return .idempotencyConflict
        case "registry-owner-conflict":
            guard Set(object.keys) == Set(["error", "reason"]),
                  object["error"] as? String == "registry owner does not match authenticated principal" else {
                throw DeviceRingRegistrationError.malformedResponse
            }
            return .ownerConflict
        case "target-capacity":
            guard hasAllowedKeys(object, required: ["reason"], optional: ["error"]) else {
                throw DeviceRingRegistrationError.malformedResponse
            }
            return .targetCapacity
        case "revision-exhausted":
            guard hasAllowedKeys(object, required: ["reason"], optional: ["error"]) else {
                throw DeviceRingRegistrationError.malformedResponse
            }
            return .revisionExhausted
        default:
            throw DeviceRingRegistrationError.malformedResponse
        }
    }

    private static func parseBindingFence(_ object: [String: Any]) -> DeviceRingServerBindingFence? {
        guard Set(object.keys) == Set(["bindingId", "bindingRevision", "expiresAt"]),
              let id = object["bindingId"] as? String,
              let revision = strictPositiveInteger(object["bindingRevision"]),
              DeviceRingBindingFence(id: id, revision: revision).isValid,
              let rawExpiry = object["expiresAt"] as? String,
              let expiresAt = parseDate(rawExpiry) else { return nil }
        return DeviceRingServerBindingFence(
            bindingId: id,
            bindingRevision: revision,
            expiresAt: expiresAt
        )
    }

    private static func parseTokenClaimFence(_ object: [String: Any]) -> DeviceRingServerTokenClaimFence? {
        guard Set(object.keys) == Set(["tokenClaimId", "tokenClaimRevision", "expiresAt"]),
              let id = object["tokenClaimId"] as? String,
              id.range(of: #"^claim_[0-9a-f]{32}$"#, options: .regularExpression) != nil,
              let revision = strictPositiveInteger(object["tokenClaimRevision"]),
              let rawExpiry = object["expiresAt"] as? String,
              let expiresAt = parseDate(rawExpiry) else { return nil }
        return DeviceRingServerTokenClaimFence(
            tokenClaimId: id,
            tokenClaimRevision: revision,
            expiresAt: expiresAt
        )
    }

    private static func parseDate(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) { return date }
        let whole = ISO8601DateFormatter()
        whole.formatOptions = [.withInternetDateTime]
        return whole.date(from: value)
    }

    private static func hasExactKeys(in data: Data, expected: Set<String>) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return false
        }
        return Set(object.keys) == expected
    }

    private static func hasAllowedKeys(
        _ object: [String: Any],
        required: Set<String>,
        optional: Set<String>
    ) -> Bool {
        let keys = Set(object.keys)
        return required.isSubset(of: keys) && keys.isSubset(of: required.union(optional))
    }

    private static func strictPositiveInteger(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let double = number.doubleValue
        guard double.isFinite,
              double.rounded(.towardZero) == double,
              double > 0,
              double <= Double(DeviceRingRegistryValidation.maximumSafeInteger) else { return nil }
        return Int(double)
    }

    private static func strictBool(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }

    private static func valid(_ request: DeviceRingRegistrationRequest) -> Bool {
        let bindingPair = (request.expectedBindingId == nil) == (request.expectedBindingRevision == nil)
        let claimPair = (request.expectedTokenClaimId == nil) == (request.expectedTokenClaimRevision == nil)
        guard request.registrationVersion == 2,
              request.ownerVersion == DeviceRingRegistryOwnerContext.version,
              validDigest(request.ownerHandle),
              validInstallationId(request.installationId),
              UUID(uuidString: request.idempotencyKey) != nil,
              DeviceRingRegistryValidation.isCanonicalOpaque(request.voipToken, maximumUTF8Bytes: 512),
              DeviceRingRegistryValidation.isCanonicalOpaque(request.sessionId, maximumUTF8Bytes: 128),
              request.platform == "apns",
              bindingPair,
              claimPair else { return false }
        if let id = request.expectedBindingId,
           let revision = request.expectedBindingRevision,
           !DeviceRingBindingFence(id: id, revision: revision).isValid {
            return false
        }
        if let id = request.expectedTokenClaimId,
           let revision = request.expectedTokenClaimRevision,
           (id.range(of: #"^claim_[0-9a-f]{32}$"#, options: .regularExpression) == nil ||
            !DeviceRingRegistryValidation.isSafeRevision(revision)) {
            return false
        }
        return true
    }

    private static func valid(_ request: DeviceRingUnregistrationRequest) -> Bool {
        request.registrationVersion == 2 &&
        request.ownerVersion == DeviceRingRegistryOwnerContext.version &&
        validDigest(request.ownerHandle) &&
        validInstallationId(request.installationId) &&
        DeviceRingRegistryValidation.isCanonicalOpaque(request.sessionId, maximumUTF8Bytes: 128) &&
        DeviceRingBindingFence(
            id: request.bindingId,
            revision: request.bindingRevision
        ).isValid
    }

    private static func valid(_ request: DeviceRingRegistrationCleanupRequest) -> Bool {
        request.registrationVersion == 2 &&
        request.ownerVersion == DeviceRingRegistryOwnerContext.version &&
        validDigest(request.ownerHandle) &&
        validInstallationId(request.installationId) &&
        UUID(uuidString: request.idempotencyKey) != nil &&
        validDigest(request.tokenDigest) &&
        DeviceRingRegistryValidation.isCanonicalOpaque(request.sessionId, maximumUTF8Bytes: 128) &&
        request.platform == "apns"
    }

    private static func validDigest(_ value: String) -> Bool {
        guard DeviceRingFingerprint.isDigest(value) else { return false }
        var base64 = value
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        base64.append(String(repeating: "=", count: (4 - base64.count % 4) % 4))
        guard let bytes = Data(base64Encoded: base64), bytes.count == 32 else { return false }
        return DeviceRingFingerprint.base64URL(bytes) == value
    }

    private static func validInstallationId(_ value: String) -> Bool {
        guard value.count == DeviceInstallationIdentityStore.encodedCharacterCount,
              value.range(
                of: #"^[A-Za-z0-9_-]{43}$"#,
                options: .regularExpression
              ) != nil else { return false }
        var base64 = value
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        base64.append(String(repeating: "=", count: (4 - base64.count % 4) % 4))
        guard let bytes = Data(base64Encoded: base64), bytes.count == 32 else { return false }
        return DeviceRingFingerprint.base64URL(bytes) == value
    }
}
