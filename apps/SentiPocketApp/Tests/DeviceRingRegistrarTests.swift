import XCTest
import Security
@testable import SentiPocketApp

private final class RegistrarBearer: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: String?

    init(_ value: String?) { stored = value }

    func load() -> String? {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func set(_ value: String?) {
        lock.lock()
        stored = value
        lock.unlock()
    }
}

private final class ScriptedRegistryClient: DeviceRingRegistryClient, @unchecked Sendable {
    enum RegisterStep {
        case success(DeviceRingRegistrationReceipt)
        case successAfter(() -> Void, DeviceRingRegistrationReceipt)
        case failure(DeviceRingRegistrationError)
        case failureAfter(() -> Void, DeviceRingRegistrationError)
    }
    enum CleanupStep {
        case success
        case successAfter(() -> Void)
        case failure(DeviceRingRegistrationError)
        case failureAfter(() -> Void, DeviceRingRegistrationError)
    }
    enum UnregisterStep {
        case success
        case failure(DeviceRingRegistrationError)
    }

    private let lock = NSLock()
    private var registerSteps: [RegisterStep]
    private var cleanupSteps: [CleanupStep]
    private var unregisterSteps: [UnregisterStep]
    private let ownerHandleForBearer: (String) -> String
    private var storedOwnerContextBearers: [String] = []
    private var storedRegisters: [(DeviceRingRegistrationRequest, String)] = []
    private var storedCleanups: [(DeviceRingRegistrationCleanupRequest, String)] = []
    private var storedUnregisters: [(DeviceRingUnregistrationRequest, String)] = []

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    init(
        registerSteps: [RegisterStep],
        cleanupSteps: [CleanupStep] = [.success],
        unregisterSteps: [UnregisterStep] = [.success],
        ownerHandleForBearer: @escaping (String) -> String = { _ in DeviceRingFingerprint.digest("owner-a") }
    ) {
        self.registerSteps = registerSteps
        self.cleanupSteps = cleanupSteps
        self.unregisterSteps = unregisterSteps
        self.ownerHandleForBearer = ownerHandleForBearer
    }

    var registers: [(DeviceRingRegistrationRequest, String)] {
        withLock { storedRegisters }
    }

    var unregisters: [(DeviceRingUnregistrationRequest, String)] {
        withLock { storedUnregisters }
    }

    var cleanups: [(DeviceRingRegistrationCleanupRequest, String)] {
        withLock { storedCleanups }
    }

    var ownerContextBearers: [String] {
        withLock { storedOwnerContextBearers }
    }

    func ownerContext(bearerToken: String) async throws -> DeviceRingRegistryOwnerContext {
        let handle = withLock {
            storedOwnerContextBearers.append(bearerToken)
            return ownerHandleForBearer(bearerToken)
        }
        return DeviceRingRegistryOwnerContext(
            ownerVersion: DeviceRingRegistryOwnerContext.version,
            ownerHandle: handle,
            serverTime: Date(timeIntervalSince1970: 1_900_000_000)
        )
    }

    func register(
        _ request: DeviceRingRegistrationRequest,
        bearerToken: String
    ) async throws -> DeviceRingRegistrationReceipt {
        let step = withLock {
            storedRegisters.append((request, bearerToken))
            return registerSteps.isEmpty ? nil : registerSteps.removeFirst()
        }
        guard let step else { throw DeviceRingRegistrationError.retryable(503) }
        switch step {
        case .success(let receipt): return receipt
        case .successAfter(let beforeReturn, let receipt):
            beforeReturn()
            return receipt
        case .failure(let error): throw error
        case .failureAfter(let beforeThrow, let error):
            beforeThrow()
            throw error
        }
    }

    func cleanupRegistration(
        _ request: DeviceRingRegistrationCleanupRequest,
        bearerToken: String
    ) async throws {
        let step = withLock {
            storedCleanups.append((request, bearerToken))
            return cleanupSteps.isEmpty ? nil : cleanupSteps.removeFirst()
        }
        guard let step else { throw DeviceRingRegistrationError.retryable(503) }
        switch step {
        case .success: return
        case .successAfter(let beforeReturn): beforeReturn()
        case .failure(let error): throw error
        case .failureAfter(let beforeThrow, let error):
            beforeThrow()
            throw error
        }
    }

    func unregister(
        _ request: DeviceRingUnregistrationRequest,
        bearerToken: String
    ) async throws {
        let step = withLock {
            storedUnregisters.append((request, bearerToken))
            return unregisterSteps.isEmpty ? nil : unregisterSteps.removeFirst()
        }
        guard let step else { throw DeviceRingRegistrationError.retryable(503) }
        switch step {
        case .success: return
        case .failure(let error): throw error
        }
    }
}

private actor DelayedOwnerContextRegistryClient: DeviceRingRegistryClient {
    private var contextStarted = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var contextResponse: CheckedContinuation<DeviceRingRegistryOwnerContext, Error>?
    private(set) var registerRequests: [DeviceRingRegistrationRequest] = []

    func ownerContext(bearerToken: String) async throws -> DeviceRingRegistryOwnerContext {
        contextStarted = true
        for waiter in startWaiters { waiter.resume() }
        startWaiters.removeAll()
        return try await withCheckedThrowingContinuation { continuation in
            contextResponse = continuation
        }
    }

    func register(
        _ request: DeviceRingRegistrationRequest,
        bearerToken: String
    ) async throws -> DeviceRingRegistrationReceipt {
        registerRequests.append(request)
        throw DeviceRingRegistrationError.retryable(503)
    }

    func cleanupRegistration(
        _ request: DeviceRingRegistrationCleanupRequest,
        bearerToken: String
    ) async throws {
        throw DeviceRingRegistrationError.retryable(503)
    }

    func unregister(
        _ request: DeviceRingUnregistrationRequest,
        bearerToken: String
    ) async throws {
        throw DeviceRingRegistrationError.retryable(503)
    }

    func waitUntilContextStarted() async {
        if contextStarted { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func succeedContext(_ context: DeviceRingRegistryOwnerContext) {
        let continuation = contextResponse
        contextResponse = nil
        continuation?.resume(returning: context)
    }

    func failContext(_ error: DeviceRingRegistrationError) {
        let continuation = contextResponse
        contextResponse = nil
        continuation?.resume(throwing: error)
    }
}

private actor DelayedFirstRegistryClient: DeviceRingRegistryClient {
    private var firstStarted = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var firstResponse: CheckedContinuation<DeviceRingRegistrationReceipt, Error>?
    private(set) var requests: [DeviceRingRegistrationRequest] = []
    private(set) var cleanupRequests: [DeviceRingRegistrationCleanupRequest] = []
    private(set) var unregisterRequests: [DeviceRingUnregistrationRequest] = []
    private let laterResult: Result<DeviceRingRegistrationReceipt, DeviceRingRegistrationError>

    init(laterResult: Result<DeviceRingRegistrationReceipt, DeviceRingRegistrationError>) {
        self.laterResult = laterResult
    }

    func ownerContext(bearerToken: String) async throws -> DeviceRingRegistryOwnerContext {
        DeviceRingRegistryOwnerContext(
            ownerVersion: DeviceRingRegistryOwnerContext.version,
            ownerHandle: DeviceRingFingerprint.digest("owner-a"),
            serverTime: Date(timeIntervalSince1970: 1_900_000_000)
        )
    }

    func register(
        _ request: DeviceRingRegistrationRequest,
        bearerToken: String
    ) async throws -> DeviceRingRegistrationReceipt {
        requests.append(request)
        if requests.count > 1 {
            switch laterResult {
            case .success(let receipt): return receipt
            case .failure(let error): throw error
            }
        }
        firstStarted = true
        for waiter in startWaiters { waiter.resume() }
        startWaiters.removeAll()
        return try await withCheckedThrowingContinuation { continuation in
            firstResponse = continuation
        }
    }

    func cleanupRegistration(
        _ request: DeviceRingRegistrationCleanupRequest,
        bearerToken: String
    ) async throws {
        cleanupRequests.append(request)
    }

    func unregister(
        _ request: DeviceRingUnregistrationRequest,
        bearerToken: String
    ) async throws {
        unregisterRequests.append(request)
    }

    func waitUntilFirstStarted() async {
        if firstStarted { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func completeFirst(with result: Result<DeviceRingRegistrationReceipt, DeviceRingRegistrationError>) {
        guard let continuation = firstResponse else { return }
        firstResponse = nil
        switch result {
        case .success(let receipt): continuation.resume(returning: receipt)
        case .failure(let error): continuation.resume(throwing: error)
        }
    }
}

@MainActor
final class DeviceRingRegistrarTests: XCTestCase {
    private let bindingA = "bind_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    private let bindingB = "bind_bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
    private let claimA = "claim_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    private let claimB = "claim_bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"

    private func receipt(
        session: String,
        platform: String = "apns",
        bindingId: String,
        bindingRevision: Int,
        claimId: String,
        claimRevision: Int,
        expiresAt: Date = Date(timeIntervalSince1970: 1_900_604_800)
    ) -> DeviceRingRegistrationReceipt {
        DeviceRingRegistrationReceipt(
            ownerVersion: DeviceRingRegistryOwnerContext.version,
            ownerHandle: DeviceRingFingerprint.digest("owner-a"),
            sessionId: session,
            platform: platform,
            bindingId: bindingId,
            bindingRevision: bindingRevision,
            tokenClaimId: claimId,
            tokenClaimRevision: claimRevision,
            expiresAt: expiresAt,
            serverTime: Date(timeIntervalSince1970: 1_900_000_000),
            wallTimeAtReceipt: Date(timeIntervalSince1970: 1_900_000_000),
            continuousTimeAtReceipt: 10_000,
            authorizedLeaseDuration: expiresAt.timeIntervalSince1970 - 1_900_000_000,
            idempotent: false
        )
    }

    private func revocationReceipt(
        session: String,
        bindingId: String,
        bindingRevision: Int,
        claimId: String,
        claimRevision: Int,
        expiresAt: Date = Date(timeIntervalSince1970: 1_900_604_800)
    ) -> DeviceRingRevocationReceipt {
        DeviceRingRevocationReceipt(
            ownerVersion: DeviceRingRegistryOwnerContext.version,
            ownerHandle: DeviceRingFingerprint.digest("owner-a"),
            sessionId: session,
            platform: "apns",
            bindingId: bindingId,
            bindingRevision: bindingRevision,
            tokenClaimId: claimId,
            tokenClaimRevision: claimRevision,
            expiresAt: expiresAt,
            serverTime: Date(timeIntervalSince1970: 1_900_000_000),
            idempotent: true
        )
    }

    private func bindingRecord(leaseAuthority: DeviceRingLeaseAuthority?) -> DeviceRingBindingRecord {
        DeviceRingBindingRecord(
            sessionId: "session-a",
            platform: "apns",
            tokenDigest: DeviceRingFingerprint.digest("aabbcc"),
            credentialFingerprint: DeviceRingFingerprint.digest("bearer-a"),
            ownerVersion: DeviceRingRegistryOwnerContext.version,
            ownerHandle: DeviceRingFingerprint.digest("owner-a"),
            bindingId: bindingA,
            bindingRevision: 1,
            tokenClaimId: claimA,
            tokenClaimRevision: 1,
            expiresAt: Date(timeIntervalSince1970: 1_900_604_800),
            leaseAuthority: leaseAuthority
        )
    }

    private func makeRegistrar(
        client: any DeviceRingRegistryClient,
        bearer: RegistrarBearer = RegistrarBearer("bearer-a"),
        storage: TestDeviceRingSecureStorage = TestDeviceRingSecureStorage(),
        authorityDenyStore: TestDeviceRingAuthorityDenyStore = TestDeviceRingAuthorityDenyStore(),
        keys: [String] = [
            "11111111-1111-4111-8111-111111111111",
            "22222222-2222-4222-8222-222222222222",
            "33333333-3333-4333-8333-333333333333",
        ]
    ) -> (DeviceRingRegistrar, RegistrarBearer, DeviceRingRegistryStateStore, DeviceInstallationIdentityStore) {
        var keyIndex = 0
        let identity = DeviceInstallationIdentityStore(
            storage: storage,
            randomBytes: { count in Data(repeating: 0x51, count: count) }
        )
        let state = DeviceRingRegistryStateStore(
            storage: storage,
            authorityDenyStore: authorityDenyStore
        )
        let registrar = DeviceRingRegistrar(
            client: client,
            installationStore: identity,
            stateStore: state,
            bearerProvider: bearer.load,
            now: { Date(timeIntervalSince1970: 1_900_000_000) },
            continuousNow: { 10_000 },
            makeIdempotencyKey: {
                defer { keyIndex += 1 }
                return keys[min(keyIndex, keys.count - 1)]
            },
            retryDelay: { _ in },
            renewalWindow: 2 * 24 * 60 * 60
        )
        return (registrar, bearer, state, identity)
    }

    func test_token_before_login_registers_once_login_and_selection_are_ready() async throws {
        let client = ScriptedRegistryClient(registerSteps: [.success(receipt(
            session: "session-a",
            bindingId: bindingA,
            bindingRevision: 1,
            claimId: claimA,
            claimRevision: 1
        ))])
        let (registrar, _, state, _) = makeRegistrar(client: client)
        await registrar.selectSession("session-a")?.value
        await registrar.tokenUpdated("aabbcc")?.value
        XCTAssertTrue(client.registers.isEmpty)

        await registrar.loginCompleted()?.value

        XCTAssertEqual(client.registers.count, 1)
        XCTAssertEqual(try state.load().binding?.sessionId, "session-a")
        XCTAssertNil(try state.load().pendingRegistration)
    }

    func test_ambiguous_network_replays_same_idempotency_key_on_foreground() async throws {
        let client = ScriptedRegistryClient(registerSteps: [
            .failure(.network("lost response")),
            .success(receipt(
                session: "session-a",
                bindingId: bindingA,
                bindingRevision: 1,
                claimId: claimA,
                claimRevision: 1
            )),
        ])
        let (registrar, _, state, _) = makeRegistrar(client: client)
        await registrar.selectSession("session-a")?.value
        await registrar.tokenUpdated("aabbcc")?.value
        await registrar.loginCompleted()?.value
        XCTAssertNotNil(try state.load().pendingRegistration)

        await registrar.applicationBecameActive()?.value

        XCTAssertEqual(client.registers.count, 2)
        XCTAssertEqual(client.registers[0].0.idempotencyKey, client.registers[1].0.idempotencyKey)
        XCTAssertNil(try state.load().pendingRegistration)
    }

    func test_receipt_state_save_failure_keeps_pending_and_replays_same_operation() async throws {
        let storage = TestDeviceRingSecureStorage()
        let serverReceipt = receipt(
            session: "session-a",
            bindingId: bindingA,
            bindingRevision: 1,
            claimId: claimA,
            claimRevision: 1
        )
        let client = ScriptedRegistryClient(registerSteps: [
            .successAfter({
                storage.writeError = DeviceRingSecureStoreError.keychain(errSecNotAvailable)
            }, serverReceipt),
            .success(serverReceipt),
        ])
        let (registrar, _, state, _) = makeRegistrar(client: client, storage: storage)
        await registrar.tokenUpdated("aabbcc")?.value
        await registrar.selectSession("session-a")?.value
        await registrar.loginCompleted()?.value

        storage.writeError = nil
        let retained = try XCTUnwrap(state.load().pendingRegistration)
        XCTAssertNil(try state.load().binding)

        await registrar.applicationBecameActive()?.value

        XCTAssertEqual(client.registers.count, 2)
        XCTAssertEqual(client.registers[0].0.idempotencyKey, retained.idempotencyKey)
        XCTAssertEqual(client.registers[1].0.idempotencyKey, retained.idempotencyKey)
        XCTAssertNotNil(try state.load().binding)
        XCTAssertNil(try state.load().pendingRegistration)
    }

    func test_signout_cleans_ambiguous_post_from_durable_digest_without_register_replay_or_raw_token() async throws {
        let client = ScriptedRegistryClient(
            registerSteps: [.failure(.network("response lost"))],
            cleanupSteps: [.success]
        )
        let (registrar, _, state, identity) = makeRegistrar(client: client)
        await registrar.tokenUpdated("aabbcc")?.value
        await registrar.selectSession("session-a")?.value
        await registrar.loginCompleted()?.value
        let pending = try XCTUnwrap(state.load().pendingRegistration)

        try await registrar.revokeBeforeSignOut()

        XCTAssertEqual(client.registers.count, 1)
        XCTAssertEqual(client.cleanups.count, 1)
        let cleanup = client.cleanups[0]
        XCTAssertEqual(cleanup.0.installationId, try identity.load())
        XCTAssertEqual(cleanup.0.idempotencyKey, pending.idempotencyKey)
        XCTAssertEqual(cleanup.0.tokenDigest, pending.tokenDigest)
        XCTAssertEqual(cleanup.0.sessionId, pending.sessionId)
        XCTAssertEqual(cleanup.0.platform, pending.platform)
        XCTAssertEqual(cleanup.1, "bearer-a")
        XCTAssertTrue(client.unregisters.isEmpty)
        XCTAssertTrue(try state.load().isEmpty)
    }

    func test_direct_registration_recovery_receipt_persists_revocation_fence_then_exact_deletes() async throws {
        let client = ScriptedRegistryClient(
            registerSteps: [.failure(.registrationCommittedButUnauthorized(revocationReceipt(
                session: "session-a",
                bindingId: bindingB,
                bindingRevision: 4,
                claimId: claimB,
                claimRevision: 4
            )))],
            unregisterSteps: [.success]
        )
        let (registrar, _, state, _) = makeRegistrar(client: client)
        await registrar.tokenUpdated("aabbcc")?.value
        await registrar.selectSession("session-a")?.value
        await registrar.loginCompleted()?.value
        XCTAssertEqual(client.registers.count, 1)
        XCTAssertTrue(client.cleanups.isEmpty)
        XCTAssertEqual(client.unregisters.count, 1)
        XCTAssertEqual(client.unregisters[0].0.bindingId, bindingB)
        XCTAssertEqual(client.unregisters[0].0.bindingRevision, 4)
        XCTAssertTrue(try state.load().isEmpty)
    }

    func test_cleanup_error_during_signout_never_discards_ambiguous_pending() async throws {
        let client = ScriptedRegistryClient(
            registerSteps: [.failure(.network("response lost"))],
            cleanupSteps: [.failure(.idempotencyConflict)]
        )
        let (registrar, _, state, _) = makeRegistrar(client: client)
        await registrar.tokenUpdated("aabbcc")?.value
        await registrar.selectSession("session-a")?.value
        await registrar.loginCompleted()?.value
        let pending = try XCTUnwrap(state.load().pendingRegistration)

        do {
            try await registrar.revokeBeforeSignOut()
            XCTFail("unresolved ambiguous registration must keep the bearer")
        } catch {
            XCTAssertEqual(error as? DeviceRingSignOutError, .revocationIncomplete)
        }
        XCTAssertEqual(try state.load().pendingRegistration, pending)
        XCTAssertTrue(try state.load().revocationRequested)
        XCTAssertEqual(client.registers.count, 1)
        XCTAssertEqual(client.cleanups.count, 1)
        XCTAssertTrue(client.unregisters.isEmpty)
    }

    func test_same_owner_fresh_bearer_finishes_pending_cleanup_after_signout_401() async throws {
        let client = ScriptedRegistryClient(
            registerSteps: [.failure(.network("response lost"))],
            cleanupSteps: [.failure(.reauthenticationRequired), .success]
        )
        let (registrar, bearer, state, _) = makeRegistrar(client: client)
        await registrar.tokenUpdated("aabbcc")?.value
        await registrar.selectSession("session-a")?.value
        await registrar.loginCompleted()?.value
        let pending = try XCTUnwrap(state.load().pendingRegistration)

        try registrar.beginSignOut()
        do {
            try await registrar.finishSignOut()
            XCTFail("the rejected bearer must retain the pending operation for reauthentication")
        } catch {
            XCTAssertEqual(error as? DeviceRingSignOutError, .revocationIncomplete)
        }
        XCTAssertEqual(client.cleanups.count, 1)
        XCTAssertEqual(client.cleanups[0].1, "bearer-a")

        registrar.authenticationInvalidated()
        bearer.set("bearer-b")
        await registrar.loginCompleted()?.value
        try await registrar.finishSignOut()

        XCTAssertEqual(client.cleanups.count, 2)
        XCTAssertEqual(client.cleanups[1].1, "bearer-b")
        XCTAssertEqual(client.cleanups[1].0.ownerVersion, pending.ownerVersion)
        XCTAssertEqual(client.cleanups[1].0.ownerHandle, pending.ownerHandle)
        XCTAssertTrue(try state.load().isEmpty)
    }

    func test_authenticated_owner_context_completes_prerelease_keychain_cutover_before_new_registration() async throws {
        let storage = TestDeviceRingSecureStorage()
        storage.seed(
            Data(#"{"schema":2,"binding":{"ownerless":true}}"#.utf8),
            account: "registry-state"
        )
        let client = ScriptedRegistryClient(registerSteps: [.success(receipt(
            session: "session-a",
            bindingId: bindingA,
            bindingRevision: 1,
            claimId: claimA,
            claimRevision: 1
        ))])
        let (registrar, _, state, _) = makeRegistrar(client: client, storage: storage)

        await registrar.tokenUpdated("aabbcc")?.value
        await registrar.selectSession("session-a")?.value
        await registrar.loginCompleted()?.value

        XCTAssertEqual(client.ownerContextBearers, ["bearer-a"])
        XCTAssertNil(storage.snapshot(account: "registry-state"))
        XCTAssertEqual(try state.load().binding?.bindingId, bindingA)
        XCTAssertFalse(state.authorityIsDenied())
    }

    func test_owner_context_failure_preserves_prerelease_keychain_and_performs_no_registration() async throws {
        let storage = TestDeviceRingSecureStorage()
        let legacy = Data(#"{"schema":2,"binding":{"ownerless":true}}"#.utf8)
        storage.seed(legacy, account: "registry-state")
        let client = DelayedOwnerContextRegistryClient()
        let (registrar, _, state, _) = makeRegistrar(client: client, storage: storage)

        await registrar.tokenUpdated("aabbcc")?.value
        await registrar.selectSession("session-a")?.value
        let login = registrar.loginCompleted()
        await client.waitUntilContextStarted()
        await client.failContext(.network("owner context unavailable"))
        await login?.value

        XCTAssertEqual(storage.snapshot(account: "registry-state"), legacy)
        XCTAssertNil(storage.snapshot(account: "registry-state-v3"))
        XCTAssertTrue(try state.load().isEmpty)
        let failedContextRegisters = await client.registerRequests
        XCTAssertTrue(failedContextRegisters.isEmpty)
    }

    func test_authentication_invalidation_during_owner_context_preserves_legacy_and_performs_no_registration() async throws {
        let storage = TestDeviceRingSecureStorage()
        let legacy = Data(#"{"schema":2,"binding":{"ownerless":true}}"#.utf8)
        storage.seed(legacy, account: "registry-state")
        let client = DelayedOwnerContextRegistryClient()
        let (registrar, _, state, _) = makeRegistrar(client: client, storage: storage)

        await registrar.tokenUpdated("aabbcc")?.value
        await registrar.selectSession("session-a")?.value
        let login = registrar.loginCompleted()
        await client.waitUntilContextStarted()
        registrar.authenticationInvalidated()
        await client.succeedContext(DeviceRingRegistryOwnerContext(
            ownerVersion: DeviceRingRegistryOwnerContext.version,
            ownerHandle: DeviceRingFingerprint.digest("owner-a"),
            serverTime: Date(timeIntervalSince1970: 1_900_000_000)
        ))
        await login?.value

        XCTAssertEqual(storage.snapshot(account: "registry-state"), legacy)
        XCTAssertNil(storage.snapshot(account: "registry-state-v3"))
        XCTAssertTrue(try state.load().isEmpty)
        XCTAssertTrue(state.authorityIsDenied())
        let invalidatedContextRegisters = await client.registerRequests
        XCTAssertTrue(invalidatedContextRegisters.isEmpty)
    }

    func test_different_owner_fresh_bearer_cannot_cleanup_stolen_pending_state() async throws {
        let client = ScriptedRegistryClient(
            registerSteps: [.failure(.network("response lost"))],
            cleanupSteps: [.success],
            ownerHandleForBearer: { bearer in
                DeviceRingFingerprint.digest(bearer == "bearer-a" ? "owner-a" : "owner-b")
            }
        )
        let (registrar, bearer, state, _) = makeRegistrar(client: client)
        await registrar.tokenUpdated("aabbcc")?.value
        await registrar.selectSession("session-a")?.value
        await registrar.loginCompleted()?.value
        let pending = try XCTUnwrap(state.load().pendingRegistration)

        try registrar.beginSignOut()
        registrar.authenticationInvalidated()
        bearer.set("bearer-b")
        await registrar.loginCompleted()?.value

        do {
            try await registrar.finishSignOut()
            XCTFail("a different authenticated owner must not clear another owner's pending operation")
        } catch {
            XCTAssertEqual(error as? DeviceRingSignOutError, .revocationIncomplete)
        }
        XCTAssertTrue(client.cleanups.isEmpty)
        XCTAssertEqual(try state.load().pendingRegistration, pending)
        XCTAssertTrue(try state.load().revocationRequested)
    }

    func test_token_loss_still_cleans_ambiguous_operation_from_persisted_digest() async throws {
        let client = ScriptedRegistryClient(
            registerSteps: [.failure(.network("response lost"))],
            cleanupSteps: [.success]
        )
        let (registrar, _, state, _) = makeRegistrar(client: client)
        await registrar.tokenUpdated("aabbcc")?.value
        await registrar.selectSession("session-a")?.value
        await registrar.loginCompleted()?.value
        let pending = try XCTUnwrap(state.load().pendingRegistration)

        await registrar.tokenInvalidated()?.value

        XCTAssertNil(registrar.currentVoipToken)
        XCTAssertEqual(client.registers.count, 1)
        XCTAssertEqual(client.cleanups.count, 1)
        XCTAssertEqual(client.cleanups[0].0.tokenDigest, pending.tokenDigest)
        XCTAssertTrue(client.unregisters.isEmpty)
        XCTAssertTrue(try state.load().isEmpty)
    }

    func test_cleanup_success_local_clear_failure_retries_the_identical_pending_operation() async throws {
        let storage = TestDeviceRingSecureStorage()
        let client = ScriptedRegistryClient(
            registerSteps: [.failure(.network("response lost"))],
            cleanupSteps: [.success, .success]
        )
        let (registrar, _, state, _) = makeRegistrar(client: client, storage: storage)
        await registrar.tokenUpdated("aabbcc")?.value
        await registrar.selectSession("session-a")?.value
        await registrar.loginCompleted()?.value
        let pending = try XCTUnwrap(state.load().pendingRegistration)

        storage.deleteError = DeviceRingSecureStoreError.keychain(errSecNotAvailable)
        do {
            try await registrar.revokeBeforeSignOut()
            XCTFail("failed local clear must retain sign-out authority for retry")
        } catch {
            XCTAssertEqual(error as? DeviceRingSignOutError, .revocationIncomplete)
        }
        XCTAssertEqual(try state.load().pendingRegistration, pending)

        storage.deleteError = nil
        try await registrar.revokeBeforeSignOut()

        XCTAssertEqual(client.registers.count, 1)
        XCTAssertEqual(client.cleanups.count, 2)
        XCTAssertEqual(client.cleanups[0].0, client.cleanups[1].0)
        XCTAssertEqual(client.cleanups[0].0.idempotencyKey, pending.idempotencyKey)
        XCTAssertTrue(try state.load().isEmpty)
    }

    func test_late_cleanup_success_cannot_clear_a_different_pending_operation() async throws {
        let storage = TestDeviceRingSecureStorage()
        let authority = TestDeviceRingAuthorityDenyStore(denied: true)
        let pendingA = DeviceRingPendingRegistration(
            sessionId: "session-a",
            platform: "apns",
            tokenDigest: DeviceRingFingerprint.digest("token-a"),
            credentialFingerprint: DeviceRingFingerprint.digest("bearer-a"),
            ownerVersion: DeviceRingRegistryOwnerContext.version,
            ownerHandle: DeviceRingFingerprint.digest("owner-a"),
            idempotencyKey: "11111111-1111-4111-8111-111111111111",
            expectedBindingId: nil,
            expectedBindingRevision: nil,
            expectedTokenClaimId: nil,
            expectedTokenClaimRevision: nil
        )
        let pendingB = DeviceRingPendingRegistration(
            sessionId: "session-b",
            platform: "apns",
            tokenDigest: DeviceRingFingerprint.digest("token-b"),
            credentialFingerprint: DeviceRingFingerprint.digest("bearer-a"),
            ownerVersion: DeviceRingRegistryOwnerContext.version,
            ownerHandle: DeviceRingFingerprint.digest("owner-a"),
            idempotencyKey: "22222222-2222-4222-8222-222222222222",
            expectedBindingId: nil,
            expectedBindingRevision: nil,
            expectedTokenClaimId: nil,
            expectedTokenClaimRevision: nil
        )
        var stateStore: DeviceRingRegistryStateStore!
        let client = ScriptedRegistryClient(
            registerSteps: [],
            cleanupSteps: [.successAfter {
                try! stateStore.save(DeviceRingRegistryState(
                    pendingRegistration: pendingB,
                    revocationRequested: true
                ))
            }]
        )
        let (registrar, _, state, identity) = makeRegistrar(
            client: client,
            storage: storage,
            authorityDenyStore: authority
        )
        stateStore = state
        _ = try identity.loadOrCreate()
        try state.save(DeviceRingRegistryState(
            pendingRegistration: pendingA,
            revocationRequested: true
        ))

        await registrar.loginCompleted()?.value

        XCTAssertEqual(client.cleanups.count, 1)
        XCTAssertEqual(client.cleanups[0].0.idempotencyKey, pendingA.idempotencyKey)
        XCTAssertEqual(try state.load().pendingRegistration, pendingB)
        XCTAssertTrue(try state.load().revocationRequested)
        XCTAssertTrue(client.registers.isEmpty)
        XCTAssertTrue(client.unregisters.isEmpty)
    }

    func test_denied_before_commit_retires_only_that_UUID_then_mints_a_fresh_current_operation() async throws {
        let client = ScriptedRegistryClient(registerSteps: [
            .failure(.registrationDeniedBeforeCommit),
            .success(receipt(
                session: "session-a",
                bindingId: bindingA,
                bindingRevision: 1,
                claimId: claimA,
                claimRevision: 1
            )),
        ])
        let (registrar, _, state, _) = makeRegistrar(client: client)

        await registrar.tokenUpdated("aabbcc")?.value
        await registrar.selectSession("session-a")?.value
        await registrar.loginCompleted()?.value

        XCTAssertEqual(client.registers.count, 2)
        XCTAssertNotEqual(client.registers[0].0.idempotencyKey, client.registers[1].0.idempotencyKey)
        XCTAssertEqual(client.registers[0].0.voipToken, client.registers[1].0.voipToken)
        XCTAssertNil(try state.load().pendingRegistration)
        XCTAssertEqual(try state.load().binding?.bindingId, bindingA)
        XCTAssertTrue(client.cleanups.isEmpty)
    }

    func test_legacy_binding_without_monotonic_authority_renews_before_authorizing() async throws {
        let client = ScriptedRegistryClient(registerSteps: [.success(receipt(
            session: "session-a",
            bindingId: bindingA,
            bindingRevision: 2,
            claimId: claimA,
            claimRevision: 2
        ))])
        let (registrar, _, state, identity) = makeRegistrar(client: client)
        _ = try identity.loadOrCreate()
        try state.save(DeviceRingRegistryState(binding: bindingRecord(leaseAuthority: nil)))

        await registrar.tokenUpdated("aabbcc")?.value
        await registrar.selectSession("session-a")?.value
        await registrar.loginCompleted()?.value

        XCTAssertEqual(client.registers.count, 1)
        XCTAssertEqual(client.registers[0].0.expectedBindingId, bindingA)
        XCTAssertEqual(client.registers[0].0.expectedBindingRevision, 1)
        XCTAssertNotNil(try state.load().binding?.leaseAuthority)
        XCTAssertNil(try state.load().pendingRegistration)
    }

    func test_existing_binding_renewal_invalidates_live_authority_before_replacement() async throws {
        let expiresSoon = Date(timeIntervalSince1970: 1_900_000_400)
        let client = ScriptedRegistryClient(registerSteps: [
            .success(receipt(
                session: "session-a",
                bindingId: bindingA,
                bindingRevision: 1,
                claimId: claimA,
                claimRevision: 1,
                expiresAt: expiresSoon
            )),
            .success(receipt(
                session: "session-a",
                bindingId: bindingA,
                bindingRevision: 2,
                claimId: claimA,
                claimRevision: 2
            )),
        ])
        let (registrar, _, state, _) = makeRegistrar(client: client)
        await registrar.tokenUpdated("aabbcc")?.value
        await registrar.selectSession("session-a")?.value
        await registrar.loginCompleted()?.value
        XCTAssertEqual(try state.load().binding?.bindingRevision, 1)
        let oldFence = try XCTUnwrap(state.load().binding?.fence)
        let gate = DeviceRingBindingGate(
            stateStore: state,
            credentialProvider: { "bearer-a" },
            voipTokenProvider: { registrar.currentVoipToken },
            isSessionSelected: { $0 == "session-a" },
            now: { Date(timeIntervalSince1970: 1_900_000_000) },
            continuousNow: { 10_000 }
        )
        XCTAssertTrue(gate.permits(sessionId: "session-a", fence: oldFence))

        var invalidationCount = 0
        registrar.onBindingAuthorityInvalidated = {
            invalidationCount += 1
            XCTAssertFalse(
                gate.permits(sessionId: "session-a", fence: oldFence),
                "the pending renewal must close the old gate before external teardown re-enters"
            )
        }
        await registrar.applicationBecameActive()?.value

        XCTAssertEqual(invalidationCount, 1)
        XCTAssertEqual(client.registers.count, 2)
        XCTAssertEqual(try state.load().binding?.bindingRevision, 2)
        XCTAssertNil(try state.load().pendingRegistration)
    }

    func test_session_move_posts_with_old_binding_fence_and_new_operation_key() async throws {
        let client = ScriptedRegistryClient(registerSteps: [
            .success(receipt(
                session: "session-a",
                bindingId: bindingA,
                bindingRevision: 1,
                claimId: claimA,
                claimRevision: 1
            )),
            .success(receipt(
                session: "session-b",
                bindingId: bindingB,
                bindingRevision: 2,
                claimId: claimB,
                claimRevision: 2
            )),
        ])
        let (registrar, _, state, _) = makeRegistrar(client: client)
        await registrar.tokenUpdated("aabbcc")?.value
        await registrar.selectSession("session-a")?.value
        await registrar.loginCompleted()?.value

        await registrar.selectSession("session-b")?.value

        XCTAssertEqual(client.registers.count, 2)
        XCTAssertNotEqual(client.registers[0].0.idempotencyKey, client.registers[1].0.idempotencyKey)
        XCTAssertEqual(client.registers[1].0.expectedBindingId, bindingA)
        XCTAssertEqual(client.registers[1].0.expectedBindingRevision, 1)
        XCTAssertEqual(try state.load().binding?.sessionId, "session-b")
    }

    func test_fresh_token_after_invalidation_atomically_transfers_old_binding() async throws {
        let client = ScriptedRegistryClient(registerSteps: [
            .success(receipt(
                session: "session-a",
                bindingId: bindingA,
                bindingRevision: 1,
                claimId: claimA,
                claimRevision: 1
            )),
            .success(receipt(
                session: "session-a",
                bindingId: bindingB,
                bindingRevision: 2,
                claimId: claimB,
                claimRevision: 2
            )),
        ])
        let (registrar, _, state, _) = makeRegistrar(client: client)
        await registrar.tokenUpdated("aabbcc")?.value
        await registrar.selectSession("session-a")?.value
        await registrar.loginCompleted()?.value

        let invalidation = registrar.tokenInvalidated()
        let replacement = registrar.tokenUpdated("ddeeff")
        await invalidation?.value
        await replacement?.value

        XCTAssertEqual(client.registers.count, 2)
        XCTAssertEqual(client.registers[1].0.expectedBindingId, bindingA)
        XCTAssertEqual(client.registers[1].0.expectedBindingRevision, 1)
        XCTAssertTrue(client.unregisters.isEmpty)
        XCTAssertEqual(try state.load().binding?.bindingId, bindingB)
        XCTAssertEqual(try state.load().binding?.tokenDigest, DeviceRingFingerprint.digest("ddeeff"))
        XCTAssertFalse(try state.load().revocationRequested)
    }

    func test_binding_conflict_retries_same_operation_key_with_returned_fence() async {
        let serverFence = DeviceRingServerBindingFence(
            bindingId: bindingA,
            bindingRevision: 8,
            expiresAt: Date(timeIntervalSince1970: 2_000_000_000)
        )
        let client = ScriptedRegistryClient(registerSteps: [
            .failure(.bindingConflict(serverFence)),
            .success(receipt(
                session: "session-a",
                bindingId: bindingA,
                bindingRevision: 9,
                claimId: claimA,
                claimRevision: 9
            )),
        ])
        let (registrar, _, _, _) = makeRegistrar(client: client)
        await registrar.tokenUpdated("aabbcc")?.value
        await registrar.selectSession("session-a")?.value
        await registrar.loginCompleted()?.value

        XCTAssertEqual(client.registers.count, 2)
        XCTAssertEqual(client.registers[0].0.idempotencyKey, client.registers[1].0.idempotencyKey)
        XCTAssertEqual(client.registers[1].0.expectedBindingId, bindingA)
        XCTAssertEqual(client.registers[1].0.expectedBindingRevision, 8)
    }

    func test_token_claim_conflict_retries_same_operation_key_with_returned_fence() async {
        let serverFence = DeviceRingServerTokenClaimFence(
            tokenClaimId: claimA,
            tokenClaimRevision: 8,
            expiresAt: Date(timeIntervalSince1970: 1_900_000_100)
        )
        let client = ScriptedRegistryClient(registerSteps: [
            .failure(.tokenClaimConflict(serverFence)),
            .success(receipt(
                session: "session-a",
                bindingId: bindingA,
                bindingRevision: 1,
                claimId: claimA,
                claimRevision: 9
            )),
        ])
        let (registrar, _, _, _) = makeRegistrar(client: client)
        await registrar.tokenUpdated("aabbcc")?.value
        await registrar.selectSession("session-a")?.value
        await registrar.loginCompleted()?.value

        XCTAssertEqual(client.registers.count, 2)
        XCTAssertEqual(client.registers[0].0.idempotencyKey, client.registers[1].0.idempotencyKey)
        XCTAssertEqual(client.registers[1].0.expectedTokenClaimId, claimA)
        XCTAssertEqual(client.registers[1].0.expectedTokenClaimRevision, 8)
    }

    func test_signout_uses_old_bearer_exact_delete_then_preserves_installation_identity() async throws {
        let client = ScriptedRegistryClient(registerSteps: [.success(receipt(
            session: "session-a",
            bindingId: bindingA,
            bindingRevision: 1,
            claimId: claimA,
            claimRevision: 1
        ))])
        let (registrar, bearer, state, identity) = makeRegistrar(client: client)
        await registrar.tokenUpdated("aabbcc")?.value
        await registrar.selectSession("session-a")?.value
        await registrar.loginCompleted()?.value
        let installationBefore = try identity.load()

        try await registrar.revokeBeforeSignOut()
        bearer.set(nil)

        XCTAssertEqual(client.unregisters.count, 1)
        XCTAssertEqual(client.unregisters[0].1, "bearer-a")
        XCTAssertEqual(client.unregisters[0].0.bindingId, bindingA)
        XCTAssertTrue(try state.load().isEmpty)
        XCTAssertEqual(try identity.load(), installationBefore)
    }

    func test_same_owner_fresh_bearer_exact_deletes_binding_after_signout_401() async throws {
        let client = ScriptedRegistryClient(
            registerSteps: [.success(receipt(
                session: "session-a",
                bindingId: bindingA,
                bindingRevision: 1,
                claimId: claimA,
                claimRevision: 1
            ))],
            unregisterSteps: [.failure(.reauthenticationRequired), .success]
        )
        let (registrar, bearer, state, _) = makeRegistrar(client: client)
        await registrar.tokenUpdated("aabbcc")?.value
        await registrar.selectSession("session-a")?.value
        await registrar.loginCompleted()?.value
        let binding = try XCTUnwrap(state.load().binding)

        try registrar.beginSignOut()
        do {
            try await registrar.finishSignOut()
            XCTFail("the rejected bearer must retain the binding for reauthentication")
        } catch {
            XCTAssertEqual(error as? DeviceRingSignOutError, .revocationIncomplete)
        }
        XCTAssertEqual(client.unregisters.count, 1)
        XCTAssertEqual(client.unregisters[0].1, "bearer-a")

        registrar.authenticationInvalidated()
        bearer.set("bearer-b")
        await registrar.loginCompleted()?.value
        try await registrar.finishSignOut()

        XCTAssertEqual(client.unregisters.count, 2)
        XCTAssertEqual(client.unregisters[1].1, "bearer-b")
        XCTAssertEqual(client.unregisters[1].0.ownerVersion, binding.ownerVersion)
        XCTAssertEqual(client.unregisters[1].0.ownerHandle, binding.ownerHandle)
        XCTAssertTrue(try state.load().isEmpty)
    }

    func test_different_owner_fresh_bearer_cannot_delete_stolen_binding_fence() async throws {
        let client = ScriptedRegistryClient(
            registerSteps: [.success(receipt(
                session: "session-a",
                bindingId: bindingA,
                bindingRevision: 1,
                claimId: claimA,
                claimRevision: 1
            ))],
            unregisterSteps: [.success],
            ownerHandleForBearer: { bearer in
                DeviceRingFingerprint.digest(bearer == "bearer-a" ? "owner-a" : "owner-b")
            }
        )
        let (registrar, bearer, state, _) = makeRegistrar(client: client)
        await registrar.tokenUpdated("aabbcc")?.value
        await registrar.selectSession("session-a")?.value
        await registrar.loginCompleted()?.value
        let binding = try XCTUnwrap(state.load().binding)

        try registrar.beginSignOut()
        registrar.authenticationInvalidated()
        bearer.set("bearer-b")
        await registrar.loginCompleted()?.value

        do {
            try await registrar.finishSignOut()
            XCTFail("a different authenticated owner must not clear another owner's binding")
        } catch {
            XCTAssertEqual(error as? DeviceRingSignOutError, .revocationIncomplete)
        }
        XCTAssertTrue(client.unregisters.isEmpty)
        XCTAssertEqual(try state.load().binding, binding)
        XCTAssertTrue(try state.load().revocationRequested)
    }

    func test_failed_signout_delete_retains_durable_revocation_and_binding() async throws {
        let client = ScriptedRegistryClient(
            registerSteps: [.success(receipt(
                session: "session-a",
                bindingId: bindingA,
                bindingRevision: 1,
                claimId: claimA,
                claimRevision: 1
            ))],
            unregisterSteps: [.failure(.retryable(503)), .success]
        )
        let (registrar, _, state, _) = makeRegistrar(client: client)
        await registrar.tokenUpdated("aabbcc")?.value
        await registrar.selectSession("session-a")?.value
        await registrar.loginCompleted()?.value

        do {
            try await registrar.revokeBeforeSignOut()
            XCTFail("a failed exact DELETE must retain the bearer and retry state")
        } catch {
            XCTAssertEqual(error as? DeviceRingSignOutError, .revocationIncomplete)
        }

        let retained = try state.load()
        XCTAssertTrue(retained.revocationRequested)
        XCTAssertEqual(retained.binding?.bindingId, bindingA)

        try await registrar.revokeBeforeSignOut()
        XCTAssertEqual(client.unregisters.count, 2)
        XCTAssertEqual(client.unregisters.map { $0.1 }, ["bearer-a", "bearer-a"])
        XCTAssertEqual(client.unregisters[0].0, client.unregisters[1].0)
        XCTAssertTrue(try state.load().isEmpty)
    }

    func test_signout_marker_write_failure_retains_bearer_then_retry_succeeds() async throws {
        let storage = TestDeviceRingSecureStorage()
        let client = ScriptedRegistryClient(
            registerSteps: [.success(receipt(
                session: "session-a",
                bindingId: bindingA,
                bindingRevision: 1,
                claimId: claimA,
                claimRevision: 1
            ))],
            unregisterSteps: [.success]
        )
        let (registrar, _, state, _) = makeRegistrar(client: client, storage: storage)
        await registrar.tokenUpdated("aabbcc")?.value
        await registrar.selectSession("session-a")?.value
        await registrar.loginCompleted()?.value

        storage.writeError = DeviceRingSecureStoreError.keychain(errSecNotAvailable)
        XCTAssertThrowsError(try registrar.beginSignOut()) {
            XCTAssertEqual($0 as? DeviceRingSignOutError, .secureState)
        }
        XCTAssertTrue(client.unregisters.isEmpty)
        XCTAssertNotNil(try state.load().binding)
        XCTAssertTrue(state.authorityIsDenied())
        XCTAssertNil(
            state.restorableSelectedSessionId(credential: "bearer-a"),
            "a killed launch must not restore the last clean selection after the Keychain marker write failed"
        )

        storage.writeError = nil
        try await registrar.revokeBeforeSignOut()
        XCTAssertEqual(client.unregisters.count, 1)
        XCTAssertEqual(client.unregisters[0].1, "bearer-a")
        XCTAssertTrue(try state.load().isEmpty)
        XCTAssertFalse(state.authorityIsDenied())
    }

    func test_successful_server_delete_with_local_clear_failure_retries_exact_delete() async throws {
        let storage = TestDeviceRingSecureStorage()
        let client = ScriptedRegistryClient(
            registerSteps: [.success(receipt(
                session: "session-a",
                bindingId: bindingA,
                bindingRevision: 1,
                claimId: claimA,
                claimRevision: 1
            ))],
            unregisterSteps: [.success, .success]
        )
        let (registrar, _, state, _) = makeRegistrar(client: client, storage: storage)
        await registrar.tokenUpdated("aabbcc")?.value
        await registrar.selectSession("session-a")?.value
        await registrar.loginCompleted()?.value

        storage.deleteError = DeviceRingSecureStoreError.keychain(errSecNotAvailable)
        do {
            try await registrar.revokeBeforeSignOut()
            XCTFail("local clear failure must retain retry authority")
        } catch {
            XCTAssertEqual(error as? DeviceRingSignOutError, .revocationIncomplete)
        }
        XCTAssertTrue(try state.load().revocationRequested)

        storage.deleteError = nil
        try await registrar.revokeBeforeSignOut()
        XCTAssertEqual(client.unregisters.count, 2)
        XCTAssertEqual(client.unregisters[0].0, client.unregisters[1].0)
        XCTAssertTrue(try state.load().isEmpty)
    }

    func test_renewal_403_uses_digest_cleanup_then_exact_deletes_independent_older_binding() async throws {
        let expiresSoon = Date(timeIntervalSince1970: 1_900_000_400)
        let client = ScriptedRegistryClient(
            registerSteps: [
                .success(receipt(
                    session: "session-a",
                    bindingId: bindingA,
                    bindingRevision: 1,
                    claimId: claimA,
                    claimRevision: 1,
                    expiresAt: expiresSoon
                )),
                .failure(.notAuthorized),
            ],
            cleanupSteps: [.success],
            unregisterSteps: [.success]
        )
        let (registrar, _, state, _) = makeRegistrar(client: client)
        var selected = true
        registrar.onSessionAuthorizationRevoked = { sessionId in
            XCTAssertEqual(sessionId, "session-a")
            selected = false
        }
        await registrar.tokenUpdated("aabbcc")?.value
        await registrar.selectSession("session-a")?.value
        await registrar.loginCompleted()?.value
        let fence = try XCTUnwrap(state.load().binding?.fence)
        let gate = DeviceRingBindingGate(
            stateStore: state,
            credentialProvider: { "bearer-a" },
            voipTokenProvider: { registrar.currentVoipToken },
            isSessionSelected: { _ in selected },
            now: { Date(timeIntervalSince1970: 1_900_000_000) },
            continuousNow: { 10_000 }
        )
        XCTAssertTrue(gate.permits(sessionId: "session-a", fence: fence))

        await registrar.applicationBecameActive()?.value

        XCTAssertFalse(selected)
        XCTAssertFalse(gate.permits(sessionId: "session-a", fence: fence))
        XCTAssertTrue(client.unregisters.isEmpty)
        let retained = try state.load()
        let pending = try XCTUnwrap(retained.pendingRegistration)
        XCTAssertEqual(retained.binding?.bindingId, bindingA)
        XCTAssertTrue(retained.revocationRequested)
        XCTAssertEqual(client.registers[1].0.expectedBindingId, bindingA)
        XCTAssertEqual(client.registers[1].0.expectedBindingRevision, 1)

        await registrar.applicationBecameActive()?.value

        XCTAssertEqual(client.registers.count, 2)
        XCTAssertEqual(client.cleanups.count, 1)
        XCTAssertEqual(client.cleanups[0].0.idempotencyKey, pending.idempotencyKey)
        XCTAssertEqual(client.cleanups[0].0.tokenDigest, pending.tokenDigest)
        XCTAssertEqual(client.unregisters.count, 1)
        XCTAssertEqual(client.unregisters[0].0.bindingId, bindingA)
        XCTAssertEqual(client.unregisters[0].0.bindingRevision, 1)
        XCTAssertTrue(try state.load().isEmpty)
    }

    func test_renewal_403_state_write_failure_leaves_pending_and_gate_closed() async throws {
        let storage = TestDeviceRingSecureStorage()
        let expiresSoon = Date(timeIntervalSince1970: 1_900_000_400)
        let client = ScriptedRegistryClient(registerSteps: [
            .success(receipt(
                session: "session-a",
                bindingId: bindingA,
                bindingRevision: 1,
                claimId: claimA,
                claimRevision: 1,
                expiresAt: expiresSoon
            )),
            .failureAfter({
                storage.writeError = DeviceRingSecureStoreError.keychain(errSecNotAvailable)
            }, .notAuthorized),
        ])
        let (registrar, _, state, _) = makeRegistrar(client: client, storage: storage)
        var selected = true
        registrar.onSessionAuthorizationRevoked = { _ in selected = false }
        await registrar.tokenUpdated("aabbcc")?.value
        await registrar.selectSession("session-a")?.value
        await registrar.loginCompleted()?.value
        let fence = try XCTUnwrap(state.load().binding?.fence)
        let gate = DeviceRingBindingGate(
            stateStore: state,
            credentialProvider: { "bearer-a" },
            voipTokenProvider: { registrar.currentVoipToken },
            isSessionSelected: { _ in selected },
            now: { Date(timeIntervalSince1970: 1_900_000_000) },
            continuousNow: { 10_000 }
        )
        XCTAssertTrue(gate.permits(sessionId: "session-a", fence: fence))

        await registrar.applicationBecameActive()?.value
        storage.writeError = nil

        XCTAssertFalse(selected)
        XCTAssertNotNil(try state.load().pendingRegistration)
        XCTAssertFalse(gate.permits(sessionId: "session-a", fence: fence))
        XCTAssertTrue(client.unregisters.isEmpty)
    }

    func test_non_signout_closures_fall_back_to_keychain_marker_when_file_deny_fails() async throws {
        for closesByInvalidatingToken in [true, false] {
            let storage = TestDeviceRingSecureStorage()
            let authority = TestDeviceRingAuthorityDenyStore()
            let initialClient = ScriptedRegistryClient(registerSteps: [.success(receipt(
                session: "session-a",
                bindingId: bindingA,
                bindingRevision: 1,
                claimId: claimA,
                claimRevision: 1
            ))])
            let (initial, bearer, state, _) = makeRegistrar(
                client: initialClient,
                storage: storage,
                authorityDenyStore: authority
            )
            await initial.tokenUpdated("aabbcc")?.value
            await initial.selectSession("session-a")?.value
            await initial.loginCompleted()?.value
            XCTAssertFalse(try state.load().revocationRequested)

            let relaunchClient = ScriptedRegistryClient(registerSteps: [])
            let (relaunch, _, _, _) = makeRegistrar(
                client: relaunchClient,
                bearer: bearer,
                storage: storage,
                authorityDenyStore: authority
            )
            await relaunch.selectSession("session-a")?.value
            await relaunch.tokenUpdated("aabbcc")?.value
            authority.writeError = DeviceRingSecureStoreError.keychain(errSecNotAvailable)

            if closesByInvalidatingToken {
                await relaunch.tokenInvalidated()?.value
            } else {
                await relaunch.selectSession(nil)?.value
            }

            let event = closesByInvalidatingToken ? "token invalidation" : "session deselection"
            XCTAssertFalse(state.authorityIsDenied(), "the injected file-denial write must fail for \(event)")
            XCTAssertTrue(try state.load().revocationRequested, "Keychain must independently close \(event)")
            XCTAssertNil(
                state.restorableSelectedSessionId(credential: "bearer-a"),
                "a killed launch must not restore authority after \(event)"
            )
            XCTAssertTrue(relaunchClient.registers.isEmpty)
            XCTAssertTrue(relaunchClient.unregisters.isEmpty)
        }
    }

    func test_token_invalidation_before_login_persists_marker_then_login_exact_deletes() async throws {
        let storage = TestDeviceRingSecureStorage()
        let initialClient = ScriptedRegistryClient(registerSteps: [.success(receipt(
            session: "session-a",
            bindingId: bindingA,
            bindingRevision: 1,
            claimId: claimA,
            claimRevision: 1
        ))])
        let (initial, bearer, state, _) = makeRegistrar(client: initialClient, storage: storage)
        await initial.tokenUpdated("aabbcc")?.value
        await initial.selectSession("session-a")?.value
        await initial.loginCompleted()?.value

        let revokeClient = ScriptedRegistryClient(registerSteps: [], unregisterSteps: [.success])
        let (relaunch, _, _, _) = makeRegistrar(
            client: revokeClient,
            bearer: bearer,
            storage: storage
        )
        await relaunch.selectSession("session-a")?.value
        await relaunch.tokenUpdated("aabbcc")?.value
        await relaunch.tokenInvalidated()?.value

        XCTAssertNil(relaunch.currentVoipToken)
        XCTAssertTrue(try state.load().revocationRequested)
        XCTAssertTrue(revokeClient.unregisters.isEmpty)

        await relaunch.loginCompleted()?.value
        XCTAssertEqual(revokeClient.unregisters.count, 1)
        XCTAssertEqual(revokeClient.unregisters[0].0.bindingId, bindingA)
        XCTAssertTrue(try state.load().isEmpty)
    }

    func test_deselection_before_login_persists_marker_then_login_exact_deletes() async throws {
        let storage = TestDeviceRingSecureStorage()
        let initialClient = ScriptedRegistryClient(registerSteps: [.success(receipt(
            session: "session-a",
            bindingId: bindingA,
            bindingRevision: 1,
            claimId: claimA,
            claimRevision: 1
        ))])
        let (initial, bearer, state, _) = makeRegistrar(client: initialClient, storage: storage)
        await initial.tokenUpdated("aabbcc")?.value
        await initial.selectSession("session-a")?.value
        await initial.loginCompleted()?.value

        let revokeClient = ScriptedRegistryClient(registerSteps: [], unregisterSteps: [.success])
        let (relaunch, _, _, _) = makeRegistrar(
            client: revokeClient,
            bearer: bearer,
            storage: storage
        )
        await relaunch.tokenUpdated("aabbcc")?.value
        await relaunch.selectSession("session-a")?.value
        await relaunch.selectSession(nil)?.value

        XCTAssertTrue(try state.load().revocationRequested)
        XCTAssertTrue(revokeClient.unregisters.isEmpty)

        await relaunch.loginCompleted()?.value
        XCTAssertEqual(revokeClient.unregisters.count, 1)
        XCTAssertEqual(revokeClient.unregisters[0].0.bindingId, bindingA)
        XCTAssertTrue(try state.load().isEmpty)
    }

    func test_late_response_after_session_generation_change_cannot_publish_old_binding() async throws {
        let receiptB = receipt(
            session: "session-b",
            bindingId: bindingB,
            bindingRevision: 2,
            claimId: claimB,
            claimRevision: 2
        )
        let client = DelayedFirstRegistryClient(laterResult: .success(receiptB))
        let (registrar, _, state, _) = makeRegistrar(client: client)
        await registrar.tokenUpdated("aabbcc")?.value
        await registrar.selectSession("session-a")?.value
        let task = registrar.loginCompleted()
        await client.waitUntilFirstStarted()

        _ = registrar.selectSession("session-b")
        await client.completeFirst(with: .success(receipt(
            session: "session-a",
            bindingId: bindingA,
            bindingRevision: 1,
            claimId: claimA,
            claimRevision: 1
        )))
        await task?.value

        XCTAssertEqual(try state.load().binding?.bindingId, bindingB)
        XCTAssertEqual(try state.load().binding?.sessionId, "session-b")
        let requestCount = await client.requests.count
        XCTAssertEqual(requestCount, 2)
        let cleanupCount = await client.cleanupRequests.count
        XCTAssertEqual(cleanupCount, 1, "operation A must be cleanup-barriered before operation B is persisted")
    }

    func test_bearer_change_during_owner_context_fetch_starts_no_registration() async throws {
        let bearer = RegistrarBearer("bearer-a")
        let client = ScriptedRegistryClient(
            registerSteps: [.success(receipt(
                session: "session-a",
                bindingId: bindingA,
                bindingRevision: 1,
                claimId: claimA,
                claimRevision: 1
            ))],
            ownerHandleForBearer: { _ in
                bearer.set("bearer-b")
                return DeviceRingFingerprint.digest("owner-a")
            }
        )
        let (registrar, _, state, _) = makeRegistrar(client: client, bearer: bearer)
        await registrar.tokenUpdated("aabbcc")?.value
        await registrar.selectSession("session-a")?.value
        await registrar.loginCompleted()?.value

        XCTAssertEqual(client.ownerContextBearers, ["bearer-a"])
        XCTAssertTrue(client.registers.isEmpty)
        XCTAssertTrue(try state.load().isEmpty)
    }

    func test_bearer_change_during_registration_success_cannot_publish_old_binding() async throws {
        let bearer = RegistrarBearer("bearer-a")
        let serverReceipt = receipt(
            session: "session-a",
            bindingId: bindingA,
            bindingRevision: 1,
            claimId: claimA,
            claimRevision: 1
        )
        let client = ScriptedRegistryClient(registerSteps: [
            .successAfter({ bearer.set("bearer-b") }, serverReceipt),
        ])
        let (registrar, _, state, _) = makeRegistrar(client: client, bearer: bearer)
        await registrar.tokenUpdated("aabbcc")?.value
        await registrar.selectSession("session-a")?.value
        await registrar.loginCompleted()?.value

        XCTAssertEqual(client.registers.count, 1)
        XCTAssertNil(try state.load().binding)
        XCTAssertNotNil(try state.load().pendingRegistration)
    }

    func test_protocol_receipt_identity_mismatch_cannot_splice_fences_into_pending_intent() async throws {
        let mismatchedReceipts = [
            receipt(
                session: "session-b",
                bindingId: bindingA,
                bindingRevision: 1,
                claimId: claimA,
                claimRevision: 1
            ),
            receipt(
                session: "session-a",
                platform: "fcm",
                bindingId: bindingA,
                bindingRevision: 1,
                claimId: claimA,
                claimRevision: 1
            ),
        ]

        for mismatchedReceipt in mismatchedReceipts {
            let client = ScriptedRegistryClient(registerSteps: [.success(mismatchedReceipt)])
            let (registrar, _, state, _) = makeRegistrar(client: client)
            await registrar.tokenUpdated("aabbcc")?.value
            await registrar.selectSession("session-a")?.value
            await registrar.loginCompleted()?.value

            XCTAssertNil(try state.load().binding)
            XCTAssertEqual(try state.load().pendingRegistration?.sessionId, "session-a")
            XCTAssertEqual(try state.load().pendingRegistration?.platform, "apns")
        }
    }

    func test_superseded_ambiguous_A_is_cleaned_before_B_and_signout_cannot_leave_A_zombie() async throws {
        let client = DelayedFirstRegistryClient(laterResult: .failure(.network("B response lost")))
        let (registrar, _, state, identity) = makeRegistrar(client: client)
        _ = try identity.loadOrCreate()
        try state.save(DeviceRingRegistryState(binding: bindingRecord(
            leaseAuthority: DeviceRingLeaseAuthority(
                serverTime: Date(timeIntervalSince1970: 1_900_000_000),
                wallTimeAtReceipt: Date(timeIntervalSince1970: 1_900_000_000),
                continuousTimeAtReceipt: 10_000,
                authorizedLifetime: 400
            )
        )))

        await registrar.tokenUpdated("aabbcc")?.value
        await registrar.selectSession("session-a")?.value
        let task = registrar.loginCompleted()
        await client.waitUntilFirstStarted()

        _ = registrar.selectSession("session-b")
        await client.completeFirst(with: .success(receipt(
            session: "session-a",
            bindingId: bindingB,
            bindingRevision: 2,
            claimId: claimB,
            claimRevision: 2
        )))
        await task?.value

        let pendingB = try XCTUnwrap(state.load().pendingRegistration)
        XCTAssertEqual(try state.load().binding?.bindingId, bindingA)
        let registerRequests = await client.requests
        XCTAssertEqual(registerRequests.count, 2)
        XCTAssertNotEqual(registerRequests[0].idempotencyKey, registerRequests[1].idempotencyKey)
        XCTAssertEqual(registerRequests[1].idempotencyKey, pendingB.idempotencyKey)
        XCTAssertEqual(registerRequests[1].expectedBindingId, bindingA)
        let firstCleanup = await client.cleanupRequests
        XCTAssertEqual(firstCleanup.map(\.idempotencyKey), [registerRequests[0].idempotencyKey])

        try await registrar.revokeBeforeSignOut()

        let allCleanups = await client.cleanupRequests
        XCTAssertEqual(
            allCleanups.map(\.idempotencyKey),
            [registerRequests[0].idempotencyKey, pendingB.idempotencyKey]
        )
        let unregisters = await client.unregisterRequests
        XCTAssertEqual(unregisters.count, 1)
        XCTAssertEqual(unregisters[0].bindingId, bindingA)
        XCTAssertEqual(unregisters[0].bindingRevision, 1)
        XCTAssertTrue(try state.load().isEmpty)
    }
}
