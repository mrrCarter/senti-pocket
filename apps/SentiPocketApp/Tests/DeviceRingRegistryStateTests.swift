import XCTest
import Security
@testable import SentiPocketApp

final class TestDeviceRingSecureStorage: DeviceRingSecureStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]
    var readError: Error?
    var writeError: Error?
    var insertError: Error?
    var deleteError: Error?

    func read(account: String) throws -> Data? {
        lock.lock()
        defer { lock.unlock() }
        if let readError { throw readError }
        return values[account]
    }

    func insertIfAbsent(_ data: Data, account: String) throws -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if let insertError { throw insertError }
        guard values[account] == nil else { return false }
        values[account] = data
        return true
    }

    func write(_ data: Data, account: String) throws {
        lock.lock()
        defer { lock.unlock() }
        if let writeError { throw writeError }
        values[account] = data
    }

    func delete(account: String) throws {
        lock.lock()
        defer { lock.unlock() }
        if let deleteError { throw deleteError }
        values.removeValue(forKey: account)
    }

    func seed(_ data: Data, account: String) {
        lock.lock()
        values[account] = data
        lock.unlock()
    }

    func snapshot(account: String) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return values[account]
    }
}

final class TestDeviceRingAuthorityDenyStore: DeviceRingAuthorityDenyStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var denied: Bool
    var readError: Error?
    var writeError: Error?

    init(denied: Bool = false) {
        self.denied = denied
    }

    func isDenied() throws -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if let readError { throw readError }
        return denied
    }

    func deny() throws {
        lock.lock()
        defer { lock.unlock() }
        if let writeError { throw writeError }
        denied = true
    }

    func clear() throws {
        lock.lock()
        defer { lock.unlock() }
        if let writeError { throw writeError }
        denied = false
    }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func increment() {
        lock.lock()
        stored += 1
        lock.unlock()
    }
}

private final class InstallationRaceStorage: DeviceRingSecureStoring, @unchecked Sendable {
    private let lock = NSLock()
    private let winner: Data
    private var insertLost = false

    init(winner: Data) { self.winner = winner }

    func read(account: String) throws -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return insertLost ? winner : nil
    }

    func insertIfAbsent(_ data: Data, account: String) throws -> Bool {
        lock.lock()
        defer { lock.unlock() }
        insertLost = true
        return false
    }

    func write(_ data: Data, account: String) throws {}
    func delete(account: String) throws {}
}

final class DeviceRingRegistryStateTests: XCTestCase {
    private let bindingId = "bind_0123456789abcdef0123456789abcdef"
    private let claimId = "claim_0123456789abcdef0123456789abcdef"

    private func binding(
        credential: String = "bearer-a",
        token: String = "aabbcc",
        expiresAt: Date = Date(timeIntervalSince1970: 2_000_000_000),
        wallTimeAtReceipt: Date = Date(timeIntervalSince1970: 1_900_000_000),
        continuousTimeAtReceipt: TimeInterval = 10_000,
        authorizedLifetime: TimeInterval? = 7 * 24 * 60 * 60
    ) -> DeviceRingBindingRecord {
        DeviceRingBindingRecord(
            sessionId: "session-a",
            platform: "apns",
            tokenDigest: DeviceRingFingerprint.digest(token),
            credentialFingerprint: DeviceRingFingerprint.digest(credential),
            ownerVersion: DeviceRingRegistryOwnerContext.version,
            ownerHandle: DeviceRingFingerprint.digest("owner-a"),
            bindingId: bindingId,
            bindingRevision: 7,
            tokenClaimId: claimId,
            tokenClaimRevision: 9,
            expiresAt: expiresAt,
            leaseAuthority: authorizedLifetime.map {
                DeviceRingLeaseAuthority(
                    serverTime: expiresAt.addingTimeInterval(-$0),
                    wallTimeAtReceipt: wallTimeAtReceipt,
                    continuousTimeAtReceipt: continuousTimeAtReceipt,
                    authorizedLifetime: $0
                )
            }
        )
    }

    func test_installation_identity_is_exactly_32_bytes_stable_and_unpadded() throws {
        let storage = TestDeviceRingSecureStorage()
        let calls = LockedCounter()
        let store = DeviceInstallationIdentityStore(
            storage: storage,
            randomBytes: { count in
                calls.increment()
                return Data(repeating: 0x51, count: count)
            }
        )

        let first = try store.loadOrCreate()
        let second = try DeviceInstallationIdentityStore(
            storage: storage,
            randomBytes: { _ in XCTFail("stable identity must not regenerate"); return Data() }
        ).loadOrCreate()

        XCTAssertEqual(first, second)
        XCTAssertEqual(first.count, 43)
        XCTAssertFalse(first.contains("="))
        XCTAssertEqual(calls.value, 1)
    }

    func test_installation_identity_insert_race_returns_keychain_winner() throws {
        let winner = Data(repeating: 0x52, count: 32)
        let storage = InstallationRaceStorage(winner: winner)
        let store = DeviceInstallationIdentityStore(
            storage: storage,
            randomBytes: { count in Data(repeating: 0x51, count: count) }
        )

        XCTAssertEqual(try store.loadOrCreate(), DeviceRingFingerprint.base64URL(winner))
    }

    func test_corrupt_or_unavailable_installation_identity_fails_closed() {
        let corrupt = TestDeviceRingSecureStorage()
        corrupt.seed(Data(repeating: 0, count: 31), account: "installation-id")
        XCTAssertThrowsError(try DeviceInstallationIdentityStore(storage: corrupt).loadOrCreate())

        let unavailable = TestDeviceRingSecureStorage()
        unavailable.readError = DeviceRingSecureStoreError.keychain(errSecInteractionNotAllowed)
        XCTAssertThrowsError(try DeviceInstallationIdentityStore(storage: unavailable).loadOrCreate())
    }

    func test_registry_state_roundtrips_without_raw_token_or_bearer() throws {
        let storage = TestDeviceRingSecureStorage()
        let store = DeviceRingRegistryStateStore(
            storage: storage,
            authorityDenyStore: TestDeviceRingAuthorityDenyStore()
        )
        let state = DeviceRingRegistryState(binding: binding())

        try store.save(state)
        XCTAssertEqual(try store.load(), state)

        let bytes = try XCTUnwrap(storage.snapshot(account: "registry-state-v3"))
        let text = try XCTUnwrap(String(data: bytes, encoding: .utf8))
        XCTAssertFalse(text.contains("bearer-a"))
        XCTAssertFalse(text.contains("aabbcc"))
        XCTAssertTrue(text.contains(DeviceRingFingerprint.digest("bearer-a")))
        XCTAssertTrue(text.contains(DeviceRingFingerprint.digest("aabbcc")))
    }

    func test_unknown_schema_and_unknown_fields_fail_closed() {
        let storage = TestDeviceRingSecureStorage()
        let store = DeviceRingRegistryStateStore(
            storage: storage,
            authorityDenyStore: TestDeviceRingAuthorityDenyStore()
        )
        storage.seed(Data(#"{"schema":99,"binding":null,"pendingRegistration":null,"revocationRequested":false}"#.utf8),
                     account: "registry-state-v3")
        XCTAssertThrowsError(try store.load())

        storage.seed(Data(#"{"schema":2,"binding":null,"pendingRegistration":null,"revocationRequested":false}"#.utf8),
                     account: "registry-state-v3")
        XCTAssertThrowsError(try store.load(), "ownerless prerelease schema must not be silently upgraded")

        storage.seed(Data(#"{"schema":3,"binding":null,"pendingRegistration":null,"revocationRequested":false,"future":1}"#.utf8),
                     account: "registry-state-v3")
        XCTAssertThrowsError(try store.load())
    }

    func test_authenticated_owner_context_cutover_denies_then_removes_ownerless_legacy_envelope() throws {
        let storage = TestDeviceRingSecureStorage()
        let denial = TestDeviceRingAuthorityDenyStore()
        let store = DeviceRingRegistryStateStore(storage: storage, authorityDenyStore: denial)
        storage.seed(
            Data(#"{"schema":2,"binding":{"ownerless":true}}"#.utf8),
            account: "registry-state"
        )

        try store.completeOwnerContinuityCutover()

        XCTAssertNil(storage.snapshot(account: "registry-state"))
        XCTAssertTrue(store.authorityIsDenied())
        XCTAssertTrue(try store.load().isEmpty)
        try store.completeOwnerContinuityCutover()
    }

    func test_owner_context_cutover_never_deletes_legacy_bytes_before_durable_denial() {
        let storage = TestDeviceRingSecureStorage()
        let denial = TestDeviceRingAuthorityDenyStore()
        let store = DeviceRingRegistryStateStore(storage: storage, authorityDenyStore: denial)
        let legacy = Data(#"{"schema":2}"#.utf8)
        storage.seed(legacy, account: "registry-state")
        denial.writeError = DeviceRingSecureStoreError.keychain(errSecNotAvailable)

        XCTAssertThrowsError(try store.completeOwnerContinuityCutover())
        XCTAssertEqual(storage.snapshot(account: "registry-state"), legacy)

        denial.writeError = nil
        storage.deleteError = DeviceRingSecureStoreError.keychain(errSecNotAvailable)
        XCTAssertThrowsError(try store.completeOwnerContinuityCutover())
        XCTAssertEqual(storage.snapshot(account: "registry-state"), legacy)
        XCTAssertTrue(store.authorityIsDenied())
    }

    func test_binding_and_pending_owner_mismatch_is_corrupt() throws {
        let storage = TestDeviceRingSecureStorage()
        let store = DeviceRingRegistryStateStore(
            storage: storage,
            authorityDenyStore: TestDeviceRingAuthorityDenyStore()
        )
        let record = binding()
        let pending = DeviceRingPendingRegistration(
            sessionId: record.sessionId,
            platform: record.platform,
            tokenDigest: record.tokenDigest,
            credentialFingerprint: record.credentialFingerprint,
            ownerVersion: DeviceRingRegistryOwnerContext.version,
            ownerHandle: DeviceRingFingerprint.digest("owner-b"),
            idempotencyKey: UUID().uuidString.lowercased(),
            expectedBindingId: record.bindingId,
            expectedBindingRevision: record.bindingRevision,
            expectedTokenClaimId: nil,
            expectedTokenClaimRevision: nil
        )
        XCTAssertThrowsError(try store.save(DeviceRingRegistryState(
            binding: record,
            pendingRegistration: pending
        )))
    }

    func test_failed_atomic_state_write_preserves_previous_fence() throws {
        let storage = TestDeviceRingSecureStorage()
        let store = DeviceRingRegistryStateStore(
            storage: storage,
            authorityDenyStore: TestDeviceRingAuthorityDenyStore()
        )
        let original = DeviceRingRegistryState(binding: binding())
        try store.save(original)
        storage.writeError = DeviceRingSecureStoreError.keychain(errSecNotAvailable)

        var replacement = original
        replacement.binding = binding(token: "different")
        XCTAssertThrowsError(try store.save(replacement))

        storage.writeError = nil
        XCTAssertEqual(try store.load(), original)
    }

    func test_killed_launch_restores_only_clean_selection_for_exact_credential() throws {
        let storage = TestDeviceRingSecureStorage()
        let store = DeviceRingRegistryStateStore(
            storage: storage,
            authorityDenyStore: TestDeviceRingAuthorityDenyStore()
        )
        let record = binding()
        try store.save(DeviceRingRegistryState(binding: record))

        XCTAssertEqual(
            store.restorableSelectedSessionId(credential: "bearer-a"),
            "session-a"
        )
        XCTAssertNil(store.restorableSelectedSessionId(credential: nil))
        XCTAssertNil(store.restorableSelectedSessionId(credential: "bearer-b"))

        try store.save(DeviceRingRegistryState(
            binding: record,
            pendingRegistration: DeviceRingPendingRegistration(
                sessionId: record.sessionId,
                platform: record.platform,
                tokenDigest: record.tokenDigest,
                credentialFingerprint: record.credentialFingerprint,
                ownerVersion: record.ownerVersion,
                ownerHandle: record.ownerHandle,
                idempotencyKey: UUID().uuidString.lowercased(),
                expectedBindingId: record.bindingId,
                expectedBindingRevision: record.bindingRevision,
                expectedTokenClaimId: nil,
                expectedTokenClaimRevision: nil
            )
        ))
        XCTAssertNil(store.restorableSelectedSessionId(credential: "bearer-a"))

        try store.save(DeviceRingRegistryState(binding: record, revocationRequested: true))
        XCTAssertNil(store.restorableSelectedSessionId(credential: "bearer-a"))

        storage.seed(Data("{".utf8), account: "registry-state-v3")
        XCTAssertNil(store.restorableSelectedSessionId(credential: "bearer-a"))
    }

    @MainActor
    func test_independent_authority_denial_blocks_restore_and_gate_even_when_keychain_state_is_clean() throws {
        let storage = TestDeviceRingSecureStorage()
        let denial = TestDeviceRingAuthorityDenyStore()
        let store = DeviceRingRegistryStateStore(
            storage: storage,
            authorityDenyStore: denial
        )
        let record = binding()
        try store.save(DeviceRingRegistryState(binding: record))
        let gate = DeviceRingBindingGate(
            stateStore: store,
            credentialProvider: { "bearer-a" },
            voipTokenProvider: { "aabbcc" },
            isSessionSelected: { $0 == "session-a" },
            now: { Date(timeIntervalSince1970: 1_900_000_000) },
            continuousNow: { 10_000 }
        )

        XCTAssertEqual(store.restorableSelectedSessionId(credential: "bearer-a"), "session-a")
        XCTAssertTrue(gate.permits(sessionId: "session-a", fence: record.fence))

        try store.denyAuthority()
        XCTAssertNil(store.restorableSelectedSessionId(credential: "bearer-a"))
        XCTAssertFalse(gate.permits(sessionId: "session-a", fence: record.fence))

        denial.readError = DeviceRingSecureStoreError.corrupt("marker unreadable")
        XCTAssertTrue(store.authorityIsDenied(), "marker read failures must deny, never permit")
        XCTAssertNil(store.restorableSelectedSessionId(credential: "bearer-a"))

        let continuityMissing = DeviceRingRegistryStateStore(
            storage: storage,
            authorityDenyStore: TestDeviceRingAuthorityDenyStore(denied: true)
        )
        XCTAssertNil(
            continuityMissing.restorableSelectedSessionId(credential: "bearer-a"),
            "Keychain state surviving independently of App Support must not restore authority"
        )
        let continuityGate = DeviceRingBindingGate(
            stateStore: continuityMissing,
            credentialProvider: { "bearer-a" },
            voipTokenProvider: { "aabbcc" },
            isSessionSelected: { $0 == "session-a" },
            now: { Date(timeIntervalSince1970: 1_900_000_000) },
            continuousNow: { 10_000 }
        )
        XCTAssertFalse(continuityGate.permits(sessionId: "session-a", fence: record.fence))
    }

    @MainActor
    func test_binding_gate_requires_exact_current_fence_session_token_credential_and_lease() throws {
        let storage = TestDeviceRingSecureStorage()
        let store = DeviceRingRegistryStateStore(
            storage: storage,
            authorityDenyStore: TestDeviceRingAuthorityDenyStore()
        )
        let record = binding()
        try store.save(DeviceRingRegistryState(binding: record))
        var selected = "session-a"
        var token = "aabbcc"
        var credential = "bearer-a"
        let gate = DeviceRingBindingGate(
            stateStore: store,
            credentialProvider: { credential },
            voipTokenProvider: { token },
            isSessionSelected: { $0 == selected },
            now: { Date(timeIntervalSince1970: 1_900_000_000) },
            continuousNow: { 10_000 }
        )

        XCTAssertTrue(gate.permits(sessionId: "session-a", fence: record.fence))
        credential = "bearer-b"
        XCTAssertFalse(gate.permits(sessionId: "session-a", fence: record.fence))
        credential = "bearer-a"
        token = "rotated"
        XCTAssertFalse(gate.permits(sessionId: "session-a", fence: record.fence))
        token = "aabbcc"
        selected = "session-b"
        XCTAssertFalse(gate.permits(sessionId: "session-a", fence: record.fence))
    }

    @MainActor
    func test_pending_registration_or_revocation_marker_closes_binding_gate() throws {
        let storage = TestDeviceRingSecureStorage()
        let store = DeviceRingRegistryStateStore(
            storage: storage,
            authorityDenyStore: TestDeviceRingAuthorityDenyStore()
        )
        let record = binding()
        let pending = DeviceRingPendingRegistration(
            sessionId: record.sessionId,
            platform: "apns",
            tokenDigest: record.tokenDigest,
            credentialFingerprint: record.credentialFingerprint,
            ownerVersion: record.ownerVersion,
            ownerHandle: record.ownerHandle,
            idempotencyKey: UUID().uuidString.lowercased(),
            expectedBindingId: record.bindingId,
            expectedBindingRevision: record.bindingRevision,
            expectedTokenClaimId: nil,
            expectedTokenClaimRevision: nil
        )
        let gate = DeviceRingBindingGate(
            stateStore: store,
            credentialProvider: { "bearer-a" },
            voipTokenProvider: { "aabbcc" },
            isSessionSelected: { $0 == "session-a" },
            now: { Date(timeIntervalSince1970: 1_900_000_000) },
            continuousNow: { 10_000 }
        )

        try store.save(DeviceRingRegistryState(binding: record, pendingRegistration: pending))
        XCTAssertFalse(gate.permits(sessionId: "session-a", fence: record.fence))
        try store.save(DeviceRingRegistryState(binding: record, revocationRequested: true))
        XCTAssertFalse(gate.permits(sessionId: "session-a", fence: record.fence))
    }

    @MainActor
    func test_monotonic_lease_exact_boundary_wall_rollback_and_reboot_fail_closed() throws {
        let storage = TestDeviceRingSecureStorage()
        let store = DeviceRingRegistryStateStore(
            storage: storage,
            authorityDenyStore: TestDeviceRingAuthorityDenyStore()
        )
        let record = binding(
            expiresAt: Date(timeIntervalSince1970: 1_900_001_000),
            authorizedLifetime: 1_000
        )
        try store.save(DeviceRingRegistryState(binding: record))
        var wall = Date(timeIntervalSince1970: 1_900_000_000)
        var continuous: TimeInterval? = 10_000
        let gate = DeviceRingBindingGate(
            stateStore: store,
            credentialProvider: { "bearer-a" },
            voipTokenProvider: { "aabbcc" },
            isSessionSelected: { $0 == "session-a" },
            now: { wall },
            continuousNow: { continuous }
        )

        XCTAssertTrue(gate.permits(sessionId: "session-a", fence: record.fence))
        wall = wall.addingTimeInterval(699)
        continuous = 10_699
        XCTAssertTrue(gate.permits(sessionId: "session-a", fence: record.fence))

        wall = wall.addingTimeInterval(1)
        continuous = 10_700
        XCTAssertFalse(
            gate.permits(sessionId: "session-a", fence: record.fence),
            "exactly 300 seconds remaining is outside the strict safety margin"
        )

        wall = Date(timeIntervalSince1970: 1_899_999_000)
        continuous = 10_100
        XCTAssertFalse(
            gate.permits(sessionId: "session-a", fence: record.fence),
            "wall rollback cannot extend a monotonic lease"
        )

        wall = Date(timeIntervalSince1970: 1_900_086_400)
        continuous = 100
        XCTAssertFalse(
            gate.permits(sessionId: "session-a", fence: record.fence),
            "a monotonic reset/reboot requires server renewal"
        )
    }

    @MainActor
    func test_missing_legacy_lease_authority_is_recoverable_but_never_authorized() throws {
        let storage = TestDeviceRingSecureStorage()
        let store = DeviceRingRegistryStateStore(
            storage: storage,
            authorityDenyStore: TestDeviceRingAuthorityDenyStore()
        )
        let record = binding(authorizedLifetime: nil)
        try store.save(DeviceRingRegistryState(binding: record))
        XCTAssertEqual(store.restorableSelectedSessionId(credential: "bearer-a"), "session-a")
        let gate = DeviceRingBindingGate(
            stateStore: store,
            credentialProvider: { "bearer-a" },
            voipTokenProvider: { "aabbcc" },
            isSessionSelected: { _ in true },
            now: { Date(timeIntervalSince1970: 1_900_000_000) },
            continuousNow: { 10_000 }
        )
        XCTAssertFalse(gate.permits(sessionId: "session-a", fence: record.fence))
    }

    func test_raw_push_fence_parser_rejects_v1_extra_fields_boolean_and_unsafe_revision() {
        let valid: [AnyHashable: Any] = [
            "v": 2,
            "sessionId": "session-a",
            "binding": ["v": 2, "id": bindingId, "revision": 7],
        ]
        XCTAssertEqual(DeviceRingPushFenceParser.parse(valid)?.fence.revision, 7)

        var v1 = valid
        v1["v"] = 1
        XCTAssertNil(DeviceRingPushFenceParser.parse(v1))
        var extra = valid
        extra["binding"] = ["v": 2, "id": bindingId, "revision": 7, "extra": true]
        XCTAssertNil(DeviceRingPushFenceParser.parse(extra))
        var boolRevision = valid
        boolRevision["binding"] = ["v": 2, "id": bindingId, "revision": true]
        XCTAssertNil(DeviceRingPushFenceParser.parse(boolRevision))
        var unsafe = valid
        unsafe["binding"] = ["v": 2, "id": bindingId, "revision": 9_007_199_254_740_992]
        XCTAssertNil(DeviceRingPushFenceParser.parse(unsafe))
    }
}
