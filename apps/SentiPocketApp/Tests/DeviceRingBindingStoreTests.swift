import Foundation
import XCTest
@testable import SentiPocketApp

final class DeviceRingBindingStoreTests: XCTestCase {
    private let binding = DeviceRingBinding(
        registryVersion: 2,
        sessionId: "session-shared",
        tokenFingerprint: "fingerprint",
        installationGeneration: "7",
        bindingId: String(repeating: "i", count: 24),
        bindingRevision: String(repeating: "r", count: 32),
        leaseExpiresAtSec: 2_000
    )

    func test_binding_gate_requires_the_complete_exact_server_proof() {
        let gate = DeviceRingBindingGate(initialBinding: binding, nowEpochSec: { 1_000 })

        XCTAssertTrue(gate.permits(
            sessionId: "session-shared",
            bindingVersion: 2,
            bindingId: binding.bindingId,
            bindingRevision: binding.bindingRevision,
            installationGeneration: "7"
        ))
        XCTAssertFalse(gate.permits(
            sessionId: "session-shared",
            bindingVersion: nil,
            bindingId: nil,
            bindingRevision: nil,
            installationGeneration: nil
        ), "an unversioned V1 push never masquerades as a V2 binding")
        XCTAssertFalse(gate.permits(
            sessionId: "session-shared",
            bindingVersion: 2,
            bindingId: binding.bindingId,
            bindingRevision: "stale-revision",
            installationGeneration: "7"
        ))
        XCTAssertFalse(gate.permits(
            sessionId: "session-shared",
            bindingVersion: 2,
            bindingId: binding.bindingId,
            bindingRevision: binding.bindingRevision,
            installationGeneration: "6"
        ))
    }

    func test_replacement_and_expiry_revoke_authority_immediately() {
        let expiredGate = DeviceRingBindingGate(initialBinding: binding, nowEpochSec: { 2_000 })
        XCTAssertFalse(expiredGate.permits(
            sessionId: binding.sessionId,
            bindingVersion: 2,
            bindingId: binding.bindingId,
            bindingRevision: binding.bindingRevision,
            installationGeneration: binding.installationGeneration
        ), "lease expiry is logical and exact; equality is already expired")

        let gate = DeviceRingBindingGate(initialBinding: binding, nowEpochSec: { 1_000 })
        gate.replace(with: nil)
        XCTAssertFalse(gate.permits(
            sessionId: binding.sessionId,
            bindingVersion: 2,
            bindingId: binding.bindingId,
            bindingRevision: binding.bindingRevision,
            installationGeneration: binding.installationGeneration
        ))
    }

    func test_token_fingerprint_is_deterministic_and_never_the_raw_token() {
        let first = DeviceRingTokenFingerprint.make("aabbcc")
        XCTAssertEqual(first, DeviceRingTokenFingerprint.make("aabbcc"))
        XCTAssertNotEqual(first, DeviceRingTokenFingerprint.make("ddeeff"))
        XCTAssertFalse(first.contains("aabbcc"))
    }

    func test_registration_renewal_and_unregister_retry_survive_process_restarts() throws {
        let memory = DeviceRingPersistenceMemory()
        let first = makeController(memory)
        let attempt = try first.beginRegistration("session-shared", "token-A", false)
        XCTAssertEqual(attempt.installationGeneration, "1")
        let accepted = binding(for: attempt)
        try first.commitRegistration(attempt, accepted)
        XCTAssertEqual(first.loadCurrentBinding(), accepted)

        let afterRegistrationRestart = makeController(memory)
        XCTAssertEqual(afterRegistrationRestart.loadCurrentBinding(), accepted)
        let renewal = try afterRegistrationRestart.beginRegistration("session-shared", "token-A", false)
        XCTAssertEqual(renewal, attempt, "an identical lease renewal reuses the durable generation")
        XCTAssertNil(afterRegistrationRestart.loadCurrentBinding(), "renewal clears accepted proof before networking")

        let afterPendingRestart = makeController(memory)
        XCTAssertEqual(
            try afterPendingRestart.beginRegistration("session-shared", "token-A", false),
            renewal,
            "a killed app retries the exact persisted registration transition"
        )
        try afterPendingRestart.commitRegistration(renewal, accepted)
        let cleanup = try XCTUnwrap(afterPendingRestart.beginRevocation(accepted))
        XCTAssertEqual(cleanup.installationGeneration, "2")
        XCTAssertEqual(cleanup.previousInstallationGeneration, "1")
        XCTAssertNil(afterPendingRestart.loadCurrentBinding())

        let afterCleanupRestart = makeController(memory)
        XCTAssertEqual(
            try afterCleanupRestart.beginRevocation(nil),
            cleanup,
            "failed compare-delete proof must survive a restart even though currentBinding was already cleared"
        )
        try afterCleanupRestart.completeUnregistration(cleanup)
        let replacement = try makeController(memory).beginRegistration("session-shared", "token-B", false)
        XCTAssertEqual(replacement.installationGeneration, "3")
        XCTAssertEqual(replacement.installationId, attempt.installationId)
    }

    func test_failed_renewal_retains_non_authorizing_cleanup_proof_across_restart() throws {
        let memory = DeviceRingPersistenceMemory()
        let controller = makeController(memory)
        let attempt = try controller.beginRegistration("session-shared", "token-A", false)
        let accepted = binding(for: attempt)
        try controller.commitRegistration(attempt, accepted)

        XCTAssertEqual(
            try controller.beginRegistration("session-shared", "token-A", false),
            attempt,
            "an identical renewal reuses the accepted generation"
        )
        XCTAssertNil(controller.loadCurrentBinding(), "the retained cleanup proof must never authorize a push")

        let afterFailedRenewalRestart = makeController(memory)
        XCTAssertNil(afterFailedRenewalRestart.loadCurrentBinding())
        let cleanup = try XCTUnwrap(afterFailedRenewalRestart.beginRevocation(nil))
        XCTAssertEqual(cleanup.installationGeneration, "2")
        XCTAssertEqual(cleanup.previousInstallationGeneration, attempt.installationGeneration)
        XCTAssertEqual(cleanup.bindingId, accepted.bindingId)
        XCTAssertEqual(cleanup.bindingRevision, accepted.bindingRevision)

        XCTAssertEqual(
            try makeController(memory).beginRevocation(nil),
            cleanup,
            "the derived conditional unregister itself remains an exact restart retry"
        )
    }

    func test_new_registration_can_supersede_cleanup_without_losing_old_revocation_proof() throws {
        let memory = DeviceRingPersistenceMemory()
        let controller = makeController(memory)
        let first = try controller.beginRegistration("session-shared", "token-A", false)
        let accepted = binding(for: first)
        try controller.commitRegistration(first, accepted)

        let cleanup = try XCTUnwrap(controller.beginRevocation(accepted))
        XCTAssertEqual(cleanup.installationGeneration, "2")
        let replacement = try controller.beginRegistration("session-shared", "token-B", false)
        XCTAssertEqual(replacement.installationGeneration, "3")
        XCTAssertNil(controller.loadCurrentBinding())

        let afterRestart = makeController(memory)
        let retryCleanup = try XCTUnwrap(afterRestart.beginRevocation(nil))
        XCTAssertEqual(retryCleanup.installationGeneration, "4")
        XCTAssertEqual(retryCleanup.previousInstallationGeneration, accepted.installationGeneration)
        XCTAssertEqual(retryCleanup.bindingId, accepted.bindingId)
        XCTAssertEqual(retryCleanup.bindingRevision, accepted.bindingRevision)
    }

    func test_corrupt_or_internally_inconsistent_state_fails_closed() throws {
        let malformed = DeviceRingPersistenceMemory(Data("{".utf8))
        let malformedController = makeController(malformed)
        XCTAssertNil(malformedController.loadCurrentBinding())
        XCTAssertThrowsError(
            try malformedController.beginRegistration("session-shared", "token-A", false)
        ) { error in
            XCTAssertEqual(error as? DeviceRingBindingStoreError, .corruptState)
        }

        let installationId = String(repeating: "A", count: 43)
        let attempt = DeviceRingRegistrationAttempt(
            installationId: installationId,
            installationGeneration: "1",
            sessionId: "session-shared",
            tokenFingerprint: DeviceRingTokenFingerprint.make("token-A")
        )
        let inconsistent = DeviceRingInstallationStateStore.State(
            schemaVersion: 2,
            installationId: installationId,
            generation: "1",
            pending: nil,
            completed: nil,
            currentBinding: binding(for: attempt),
            revocableBinding: nil
        )
        let inconsistentMemory = DeviceRingPersistenceMemory(try JSONEncoder().encode(inconsistent))
        let inconsistentController = makeController(inconsistentMemory)
        XCTAssertNil(inconsistentController.loadCurrentBinding())
        XCTAssertThrowsError(
            try inconsistentController.beginRegistration("session-shared", "token-A", false)
        ) { error in
            XCTAssertEqual(error as? DeviceRingBindingStoreError, .corruptState)
        }
    }

    func test_max_generation_revocation_rotates_and_persists_cleared_identity() throws {
        let oldInstallationId = String(repeating: "Z", count: 43)
        let fingerprint = DeviceRingTokenFingerprint.make("token-max")
        let maxGeneration = String(UInt64.max)
        let maxBinding = DeviceRingBinding(
            registryVersion: 2,
            sessionId: "session-shared",
            tokenFingerprint: fingerprint,
            installationGeneration: maxGeneration,
            bindingId: String(repeating: "i", count: 24),
            bindingRevision: String(repeating: "r", count: 32),
            leaseExpiresAtSec: Int64.max
        )
        let maxState = DeviceRingInstallationStateStore.State(
            schemaVersion: 2,
            installationId: oldInstallationId,
            generation: maxGeneration,
            pending: nil,
            completed: DeviceRingInstallationStateStore.CompletedRegistration(
                installationGeneration: maxGeneration,
                sessionId: maxBinding.sessionId,
                tokenFingerprint: fingerprint
            ),
            currentBinding: maxBinding,
            revocableBinding: maxBinding
        )
        let memory = DeviceRingPersistenceMemory(try JSONEncoder().encode(maxState))
        let controller = makeController(memory)
        XCTAssertEqual(controller.loadCurrentBinding(), maxBinding)

        XCTAssertNil(
            try controller.beginRevocation(maxBinding),
            "a new installation identity cannot compare-delete the old identity's max-generation binding"
        )
        XCTAssertNil(controller.loadCurrentBinding())
        let persisted = try JSONDecoder().decode(
            DeviceRingInstallationStateStore.State.self,
            from: try XCTUnwrap(memory.snapshot())
        )
        XCTAssertNotEqual(persisted.installationId, oldInstallationId)
        XCTAssertEqual(persisted.generation, "1")
        XCTAssertNil(persisted.pending)
        XCTAssertNil(persisted.completed)
        XCTAssertNil(persisted.currentBinding)
        XCTAssertNil(persisted.revocableBinding)
        XCTAssertNil(makeController(memory).loadCurrentBinding(), "restart must never resurrect the max-generation proof")

        let replacement = try makeController(memory).beginRegistration("session-shared", "token-new", false)
        XCTAssertEqual(replacement.installationId, persisted.installationId)
        XCTAssertEqual(replacement.installationGeneration, "2")
    }

    private func makeController(_ memory: DeviceRingPersistenceMemory) -> DeviceRingInstallationController {
        DeviceRingInstallationStateStore(persistence: memory.persistence).controller
    }

    private func binding(for attempt: DeviceRingRegistrationAttempt) -> DeviceRingBinding {
        DeviceRingBinding(
            registryVersion: 2,
            sessionId: attempt.sessionId,
            tokenFingerprint: attempt.tokenFingerprint,
            installationGeneration: attempt.installationGeneration,
            bindingId: String(repeating: "i", count: 24),
            bindingRevision: String(repeating: "r", count: 32),
            leaseExpiresAtSec: Int64.max
        )
    }
}

private final class DeviceRingPersistenceMemory {
    private let lock = NSLock()
    private var data: Data?

    init(_ data: Data? = nil) {
        self.data = data
    }

    var persistence: DeviceRingInstallationPersistence {
        DeviceRingInstallationPersistence(
            load: { [self] in snapshot() },
            save: { [self] in replace(with: $0) }
        )
    }

    func snapshot() -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return data
    }

    private func replace(with data: Data) {
        lock.lock()
        self.data = data
        lock.unlock()
    }
}
