import XCTest
@testable import SentiPocketApp
import PocketContracts

/// Locks the durable-outbox crash-safety of the governed write (Atlas #22). A Carter-confirmed write must be
/// persisted BEFORE the send, so a crash / app-kill during the `.sending` window can't silently drop it — the exact
/// "in-memory only → lost on kill" gap OutboxStore exists to close, previously left open for the in-flight window
/// (OutboxStore.save fired only in the offline catches). Pairs with the gateway's (principal, proposal.id)
/// crash-recovery (relay-verified handlers.mjs L266/270/283): the SAME persisted proposal id is resent on restore, so
/// a restart-retry dedups server-side (idempotent replay / 409 reconcile) — never a double-post.
///
/// These do NOT re-assert the consent/honesty invariants (unchanged by this fix): never-auto-confirm, render-gate
/// (.sent only on a pin-verified signature), offline→pending. Only the persist TIMING moved.
@MainActor
final class PhoneWriteOutboxDurabilityTests: XCTestCase {

    private enum FileSystemFailure: Error {
        case metadataUnavailable
        case readUnavailable
        case installUnavailable
        case writeUnavailable
    }

    override func setUp() { super.setUp(); OutboxStore.clear() }
    override func tearDown() { OutboxStore.clear(); super.tearDown() }

    /// A client pointed at an unroutable host — the send Task never lands (no token in test → execute() fails fast),
    /// which is all these tests need: they assert the SYNCHRONOUS persist, not the network outcome.
    private func makeClient() -> PocketWriteClient {
        PocketWriteClient(apiBaseURL: URL(string: "https://unit.invalid")!)
    }

    private func makeIntent(
        sessionId: String = "session-A",
        message: String = "Durable local-only write"
    ) -> PersistedWriteIntent {
        let proposal = PocketWriteClient.makeHumanMessageProposal(
            sessionId: sessionId,
            message: message,
            at: Date(timeIntervalSince1970: 1_784_000_000)
        )
        return PersistedWriteIntent(
            proposal: proposal,
            confirmation: GovernedWriteConfirmation(
                proposalId: proposal.id,
                confirmedProposalHash: proposal.proposalHash,
                confirmedAt: Date(timeIntervalSince1970: 1_784_000_001)
            )
        )
    }

    private func makeTemporaryOutboxFileSystem() throws -> (root: URL, fileSystem: OutboxStore.FileSystem) {
        let root = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = root.appendingPathComponent(
            "OutboxStoreTests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return (directory, OutboxStore.FileSystem.live(in: directory))
    }

    private func setBackupExcluded(_ excluded: Bool, at url: URL) throws {
        var values = URLResourceValues()
        values.isExcludedFromBackup = excluded
        var uncachedURL = URL(fileURLWithPath: url.path, isDirectory: url.hasDirectoryPath)
        try uncachedURL.setResourceValues(values)
    }

    private func isBackupExcluded(at url: URL) throws -> Bool {
        let uncachedURL = URL(fileURLWithPath: url.path, isDirectory: url.hasDirectoryPath)
        return try uncachedURL.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true
    }

    private func prepareExcludedStagingDirectory(_ fileSystem: OutboxStore.FileSystem) throws -> URL {
        let directory = try XCTUnwrap(fileSystem.stagingDirectoryURL)
        try fileSystem.createDirectory(directory)
        try setBackupExcluded(true, at: directory)
        XCTAssertTrue(try isBackupExcluded(at: directory))
        return directory
    }

    func test_successful_claim_is_excluded_from_backup_and_round_trips_exactly() throws {
        let location = try makeTemporaryOutboxFileSystem()
        defer { try? FileManager.default.removeItem(at: location.root) }
        let canonicalURL = try XCTUnwrap(location.fileSystem.canonicalURL)
        let stagingDirectoryURL = try XCTUnwrap(location.fileSystem.stagingDirectoryURL)
        let intent = makeIntent()

        XCTAssertEqual(OutboxStore.claimForTesting(intent, using: location.fileSystem), .claimed)
        XCTAssertTrue(try isBackupExcluded(at: stagingDirectoryURL))
        XCTAssertTrue(try isBackupExcluded(at: canonicalURL))
        XCTAssertEqual(OutboxStore.loadForTesting(using: location.fileSystem), intent)
    }

    func test_legacy_unexcluded_outbox_is_upgraded_before_exact_restore() throws {
        let location = try makeTemporaryOutboxFileSystem()
        defer { try? FileManager.default.removeItem(at: location.root) }
        let canonicalURL = try XCTUnwrap(location.fileSystem.canonicalURL)
        let intent = makeIntent(message: "Restore only after metadata upgrade")
        XCTAssertEqual(OutboxStore.claimForTesting(intent, using: location.fileSystem), .claimed)

        try setBackupExcluded(false, at: canonicalURL)
        XCTAssertFalse(try isBackupExcluded(at: canonicalURL), "precondition: emulate a legacy unexcluded outbox")

        XCTAssertEqual(OutboxStore.loadForTesting(using: location.fileSystem), intent)
        XCTAssertTrue(try isBackupExcluded(at: canonicalURL),
                      "a legacy file must be upgraded and verified before its intent is exposed")
    }

    func test_backup_metadata_failure_returns_storage_unavailable_and_removes_partial_outbox() throws {
        let location = try makeTemporaryOutboxFileSystem()
        defer { try? FileManager.default.removeItem(at: location.root) }
        let stagingDirectoryURL = try prepareExcludedStagingDirectory(location.fileSystem)
        let stagingURL = try XCTUnwrap(location.fileSystem.stagingURL)
        let canonicalURL = try XCTUnwrap(location.fileSystem.canonicalURL)
        var fileSystem = location.fileSystem
        fileSystem.isExcludedFromBackup = { $0 == stagingDirectoryURL }
        fileSystem.excludeFromBackup = { _ in throw FileSystemFailure.metadataUnavailable }

        XCTAssertEqual(OutboxStore.claimForTesting(makeIntent(), using: fileSystem), .storageUnavailable)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stagingURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: canonicalURL.path))
        XCTAssertNil(OutboxStore.loadForTesting(using: location.fileSystem))
    }

    func test_read_back_mismatch_returns_storage_unavailable_and_removes_partial_outbox() throws {
        let location = try makeTemporaryOutboxFileSystem()
        defer { try? FileManager.default.removeItem(at: location.root) }
        let stagingURL = try XCTUnwrap(location.fileSystem.stagingURL)
        let canonicalURL = try XCTUnwrap(location.fileSystem.canonicalURL)
        var fileSystem = location.fileSystem
        let read = fileSystem.read
        fileSystem.read = { url in
            var data = try read(url)
            data.append(0)
            return data
        }

        XCTAssertEqual(OutboxStore.claimForTesting(makeIntent(), using: fileSystem), .storageUnavailable)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stagingURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: canonicalURL.path))
    }

    func test_unprotectable_legacy_outbox_is_unavailable_without_deleting_its_owner() throws {
        let location = try makeTemporaryOutboxFileSystem()
        defer { try? FileManager.default.removeItem(at: location.root) }
        let canonicalURL = try XCTUnwrap(location.fileSystem.canonicalURL)
        let stagingDirectoryURL = try XCTUnwrap(location.fileSystem.stagingDirectoryURL)
        let stagingURL = try XCTUnwrap(location.fileSystem.stagingURL)
        let intent = makeIntent()
        XCTAssertEqual(OutboxStore.claimForTesting(intent, using: location.fileSystem), .claimed)
        try setBackupExcluded(false, at: canonicalURL)
        let originalBytes = try Data(contentsOf: canonicalURL)

        var failingFileSystem = location.fileSystem
        let liveIsExcluded = failingFileSystem.isExcludedFromBackup
        failingFileSystem.isExcludedFromBackup = { url in
            if url == canonicalURL || url == stagingURL { return false }
            return try liveIsExcluded(url)
        }
        failingFileSystem.excludeFromBackup = { _ in throw FileSystemFailure.metadataUnavailable }

        XCTAssertNil(OutboxStore.loadForTesting(using: failingFileSystem))
        XCTAssertEqual(try Data(contentsOf: canonicalURL), originalBytes)
        XCTAssertTrue(try isBackupExcluded(at: stagingDirectoryURL))
        XCTAssertEqual(OutboxStore.loadForTesting(using: location.fileSystem), intent,
                       "a later healthy load may upgrade the same owner; the failed load may not erase it")
    }

    func test_read_failure_during_B_claim_cannot_overwrite_existing_A() throws {
        let location = try makeTemporaryOutboxFileSystem()
        defer { try? FileManager.default.removeItem(at: location.root) }
        let canonicalURL = try XCTUnwrap(location.fileSystem.canonicalURL)
        let intentA = makeIntent(sessionId: "session-A", message: "A owns the slot")
        let intentB = makeIntent(sessionId: "session-B", message: "B must wait")
        XCTAssertEqual(OutboxStore.claimForTesting(intentA, using: location.fileSystem), .claimed)
        let originalBytes = try Data(contentsOf: canonicalURL)

        var failingFileSystem = location.fileSystem
        failingFileSystem.read = { _ in throw FileSystemFailure.readUnavailable }

        XCTAssertEqual(OutboxStore.claimForTesting(intentB, using: failingFileSystem), .storageUnavailable)
        XCTAssertEqual(try Data(contentsOf: canonicalURL), originalBytes)
        XCTAssertEqual(OutboxStore.loadForTesting(using: location.fileSystem), intentA)
    }

    func test_metadata_failure_during_late_A_clear_cannot_delete_newer_B() throws {
        let location = try makeTemporaryOutboxFileSystem()
        defer { try? FileManager.default.removeItem(at: location.root) }
        let canonicalURL = try XCTUnwrap(location.fileSystem.canonicalURL)
        let stagingURL = try XCTUnwrap(location.fileSystem.stagingURL)
        let intentA = makeIntent(sessionId: "session-A", message: "Stale A")
        let intentB = makeIntent(sessionId: "session-B", message: "Current B")
        XCTAssertEqual(OutboxStore.claimForTesting(intentB, using: location.fileSystem), .claimed)
        try setBackupExcluded(false, at: canonicalURL)
        let originalBytes = try Data(contentsOf: canonicalURL)

        var failingFileSystem = location.fileSystem
        let liveIsExcluded = failingFileSystem.isExcludedFromBackup
        failingFileSystem.isExcludedFromBackup = { url in
            if url == canonicalURL || url == stagingURL { return false }
            return try liveIsExcluded(url)
        }
        failingFileSystem.excludeFromBackup = { _ in throw FileSystemFailure.metadataUnavailable }

        OutboxStore.clearForTesting(matching: intentA, using: failingFileSystem)

        XCTAssertEqual(try Data(contentsOf: canonicalURL), originalBytes)
        XCTAssertEqual(OutboxStore.loadForTesting(using: location.fileSystem), intentB)
    }

    func test_interruption_before_staging_file_exclusion_strands_bytes_only_in_excluded_directory() throws {
        let location = try makeTemporaryOutboxFileSystem()
        defer { try? FileManager.default.removeItem(at: location.root) }
        let stagingDirectoryURL = try prepareExcludedStagingDirectory(location.fileSystem)
        let stagingURL = try XCTUnwrap(location.fileSystem.stagingURL)
        let canonicalURL = try XCTUnwrap(location.fileSystem.canonicalURL)
        var fileSystem = location.fileSystem
        fileSystem.isExcludedFromBackup = { $0 == stagingDirectoryURL }
        fileSystem.excludeFromBackup = { _ in throw FileSystemFailure.metadataUnavailable }
        fileSystem.remove = { _ in } // emulate cleanup reporting success without removing anything

        let intent = makeIntent()
        XCTAssertEqual(OutboxStore.claimForTesting(intent, using: fileSystem), .storageUnavailable)
        XCTAssertTrue(FileManager.default.fileExists(atPath: stagingURL.path))
        XCTAssertTrue(try isBackupExcluded(at: stagingDirectoryURL),
                      "the directory must be excluded before any confirmed staging bytes are written")
        XCTAssertFalse(FileManager.default.fileExists(atPath: canonicalURL.path))
        XCTAssertEqual(OutboxStore.loadForTesting(using: location.fileSystem), intent,
                       "a later launch must recover a complete excluded candidate rather than lose confirmation")
    }

    func test_install_failure_with_noop_cleanup_leaves_only_an_excluded_staging_file() throws {
        let location = try makeTemporaryOutboxFileSystem()
        defer { try? FileManager.default.removeItem(at: location.root) }
        let stagingDirectoryURL = try XCTUnwrap(location.fileSystem.stagingDirectoryURL)
        let stagingURL = try XCTUnwrap(location.fileSystem.stagingURL)
        let canonicalURL = try XCTUnwrap(location.fileSystem.canonicalURL)
        var fileSystem = location.fileSystem
        fileSystem.install = { _, _ in throw FileSystemFailure.installUnavailable }
        fileSystem.remove = { _ in }

        let intent = makeIntent()
        XCTAssertEqual(OutboxStore.claimForTesting(intent, using: fileSystem), .storageUnavailable)
        XCTAssertTrue(FileManager.default.fileExists(atPath: stagingURL.path))
        XCTAssertTrue(try isBackupExcluded(at: stagingDirectoryURL))
        XCTAssertTrue(try isBackupExcluded(at: stagingURL))
        XCTAssertFalse(FileManager.default.fileExists(atPath: canonicalURL.path))
        XCTAssertEqual(OutboxStore.loadForTesting(using: location.fileSystem), intent)
    }

    func test_principal_boundary_clear_tombstones_stranded_candidate_when_removal_is_noop() throws {
        let location = try makeTemporaryOutboxFileSystem()
        defer { try? FileManager.default.removeItem(at: location.root) }
        let stagingURL = try XCTUnwrap(location.fileSystem.stagingURL)
        let canonicalURL = try XCTUnwrap(location.fileSystem.canonicalURL)
        var interruptedFileSystem = location.fileSystem
        interruptedFileSystem.install = { _, _ in throw FileSystemFailure.installUnavailable }
        interruptedFileSystem.remove = { _ in }

        let priorPrincipalIntent = makeIntent(message: "Must not survive the account boundary")
        XCTAssertEqual(
            OutboxStore.claimForTesting(priorPrincipalIntent, using: interruptedFileSystem),
            .storageUnavailable
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: stagingURL.path),
                      "precondition: a complete excluded recovery candidate was stranded")

        var clearingFileSystem = location.fileSystem
        clearingFileSystem.remove = { _ in } // deletion reports success without deleting the stranded candidate
        OutboxStore.clearForTesting(using: clearingFileSystem)

        XCTAssertTrue(FileManager.default.fileExists(atPath: canonicalURL.path),
                      "clear must leave a durable canonical tombstone rather than depend on deletion")
        XCTAssertTrue(try isBackupExcluded(at: canonicalURL))
        XCTAssertTrue(try Data(contentsOf: canonicalURL).isEmpty)
        XCTAssertNil(OutboxStore.loadForTesting(using: location.fileSystem),
                     "a later healthy launch must not recover the prior principal's confirmed intent")
    }

    func test_principal_boundary_clear_truncates_prior_bytes_when_tombstone_write_cannot_allocate() throws {
        let location = try makeTemporaryOutboxFileSystem()
        defer { try? FileManager.default.removeItem(at: location.root) }
        let canonicalURL = try XCTUnwrap(location.fileSystem.canonicalURL)
        let priorPrincipalIntent = makeIntent(message: "Erase even when the volume is full")
        XCTAssertEqual(OutboxStore.claimForTesting(priorPrincipalIntent, using: location.fileSystem), .claimed)
        XCTAssertFalse(try Data(contentsOf: canonicalURL).isEmpty)

        var fullVolumeFileSystem = location.fileSystem
        fullVolumeFileSystem.write = { _, _ in throw FileSystemFailure.writeUnavailable }
        fullVolumeFileSystem.remove = { _ in } // force the allocation-free truncation fallback

        OutboxStore.clearForTesting(using: fullVolumeFileSystem)

        XCTAssertTrue(FileManager.default.fileExists(atPath: canonicalURL.path))
        XCTAssertTrue(try Data(contentsOf: canonicalURL).isEmpty,
                      "tombstone ENOSPC must fall back to verified in-place erasure")
        XCTAssertNil(OutboxStore.loadForTesting(using: location.fileSystem),
                     "prior-principal bytes may not remain loadable after the auth boundary")
    }

    func test_staged_recovery_cannot_overwrite_a_canonical_owner_created_during_recovery() throws {
        let location = try makeTemporaryOutboxFileSystem()
        defer { try? FileManager.default.removeItem(at: location.root) }
        let stagingURL = try XCTUnwrap(location.fileSystem.stagingURL)
        let canonicalURL = try XCTUnwrap(location.fileSystem.canonicalURL)
        let intentA = makeIntent(sessionId: "session-A", message: "Interrupted candidate A")
        let intentB = makeIntent(sessionId: "session-B", message: "Concurrent canonical owner B")

        XCTAssertEqual(OutboxStore.claimForTesting(intentB, using: location.fileSystem), .claimed)
        let bytesB = try Data(contentsOf: canonicalURL)
        try FileManager.default.removeItem(at: canonicalURL)

        var interruptedFileSystem = location.fileSystem
        interruptedFileSystem.install = { _, _ in throw FileSystemFailure.installUnavailable }
        interruptedFileSystem.remove = { _ in }
        XCTAssertEqual(OutboxStore.claimForTesting(intentA, using: interruptedFileSystem), .storageUnavailable)
        XCTAssertTrue(FileManager.default.fileExists(atPath: stagingURL.path))

        var racingFileSystem = location.fileSystem
        let noReplaceRecovery = racingFileSystem.recover
        racingFileSystem.recover = { source, destination in
            try bytesB.write(to: destination, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var mutableDestination = destination
            try mutableDestination.setResourceValues(values)
            try noReplaceRecovery(source, destination)
        }

        XCTAssertNil(OutboxStore.loadForTesting(using: racingFileSystem),
                     "the colliding recovery attempt must fail closed instead of returning either owner")
        XCTAssertEqual(try Data(contentsOf: canonicalURL), bytesB)
        XCTAssertEqual(OutboxStore.loadForTesting(using: location.fileSystem), intentB,
                       "canonical B must win; staged A may never replace it")
    }

    /// THE FIX: confirm() persists the intent synchronously (top of post(), before `state = .sending` and before the
    /// network Task can run — MainActor serialization guarantees the Task has NOT run before this synchronous read).
    /// So an app-kill in the `.sending` window finds the confirmed write in the durable outbox. Before the fix nothing
    /// was persisted until an offline error, leaving the in-flight window unprotected.
    func test_confirm_persists_the_intent_before_the_send() async {
        let vm = PhoneWriteViewModel(sessionId: "6cf7e861", client: makeClient())

        vm.draft("Merge now")
        XCTAssertNil(OutboxStore.load(), "draft() alone must not persist — nothing is confirmed yet")

        vm.confirm()
        let persisted = OutboxStore.load()
        XCTAssertNotNil(persisted, "confirm() must persist BEFORE the send — else a kill in .sending loses the write")
        XCTAssertEqual(persisted?.proposal.renderedPreview, "Merge now")
        XCTAssertEqual(persisted?.confirmation.proposalId, persisted?.proposal.id,
                       "the persisted confirmation must bind the persisted proposal's id")

        // Drain the in-flight send Task so it can't leak into another test; the synchronous assertions above already
        // captured the in-flight-window persistence (the Task holds `self` weakly and no-ops once vm deallocates).
        for _ in 0..<5 { await Task.yield() }
    }

    /// The RESTORE half of the guarantee: a persisted intent reloads as `.pending` on init with the SAME proposal id,
    /// so a restart-retry hits the gateway's (principal, proposal.id) crash-recovery instead of authoring a duplicate.
    /// Fully hermetic — init() does no network.
    func test_persisted_intent_restores_as_pending_with_the_same_proposal_id() {
        let proposal = PocketWriteClient.makeHumanMessageProposal(sessionId: "6cf7e861", message: "Wait for forge")
        let confirmation = GovernedWriteConfirmation(
            proposalId: proposal.id,
            confirmedProposalHash: proposal.proposalHash,
            confirmedAt: Date(timeIntervalSince1970: 1_784_000_000))
        OutboxStore.save(PersistedWriteIntent(proposal: proposal, confirmation: confirmation))

        let vm = PhoneWriteViewModel(sessionId: "6cf7e861", client: makeClient())
        guard case .pending(let message) = vm.state else {
            return XCTFail("a restored confirmed intent must surface as .pending")
        }
        XCTAssertTrue(message.contains("6cf7e861"), "pending UI must name the exact target session")
        XCTAssertEqual(OutboxStore.load()?.proposal.id, proposal.id,
                       "restore must preserve the proposal id — it is the key the gateway crash-recovery dedups on")
    }

    /// Hostile cross-session regression: selecting B must never make a persisted A intent retryable, overwritable,
    /// or clearable. This closes the global-outbox confused-deputy path found by independent review.
    func test_foreign_session_intent_is_blocked_and_preserved() {
        let proposal = PocketWriteClient.makeHumanMessageProposal(
            sessionId: "session-A",
            message: "Only session A may retry this",
            at: Date(timeIntervalSince1970: 1_784_000_000)
        )
        let confirmation = GovernedWriteConfirmation(
            proposalId: proposal.id,
            confirmedProposalHash: proposal.proposalHash,
            confirmedAt: Date(timeIntervalSince1970: 1_784_000_000)
        )
        let persisted = PersistedWriteIntent(proposal: proposal, confirmation: confirmation)
        OutboxStore.save(persisted)

        let sessionB = PhoneWriteViewModel(sessionId: "session-B", client: makeClient())
        XCTAssertEqual(sessionB.state, .blockedByPendingSession("session-A"))

        sessionB.retryPending()
        sessionB.draft("Attempt to overwrite A")
        sessionB.cancel()

        XCTAssertEqual(sessionB.state, .blockedByPendingSession("session-A"))
        XCTAssertEqual(OutboxStore.load(), persisted, "session B must not mutate session A's confirmed outbox")
    }

    func test_canonically_equal_but_byte_distinct_session_cannot_claim_persisted_intent() {
        let composedSessionId = "session-caf\u{00E9}"
        let decomposedSessionId = "session-cafe\u{0301}"
        XCTAssertEqual(composedSessionId, decomposedSessionId, "precondition: Swift String equality is canonical")
        XCTAssertFalse(UTF8ExactIdentity.matches(composedSessionId, decomposedSessionId))

        let persisted = makeIntent(
            sessionId: composedSessionId,
            message: "Only the byte-exact selected session may retry this"
        )
        OutboxStore.save(persisted)

        guard case .foreignSession(let boundSessionId) = persisted.binding(to: decomposedSessionId) else {
            return XCTFail("a canonical Unicode variant must remain a foreign session")
        }
        XCTAssertTrue(UTF8ExactIdentity.matches(boundSessionId, composedSessionId))
        XCTAssertFalse(UTF8ExactIdentity.matches(boundSessionId, decomposedSessionId))

        let variantSelection = PhoneWriteViewModel(sessionId: decomposedSessionId, client: makeClient())
        guard case .blockedByPendingSession(let blockedSessionId) = variantSelection.state else {
            return XCTFail("the byte-distinct selection must be blocked by the persisted owner")
        }
        XCTAssertTrue(UTF8ExactIdentity.matches(blockedSessionId, composedSessionId))
        XCTAssertFalse(UTF8ExactIdentity.matches(blockedSessionId, decomposedSessionId))

        variantSelection.retryPending()
        variantSelection.draft("Attempt to overwrite the exact owner")
        variantSelection.cancel()

        guard let restored = OutboxStore.load() else {
            return XCTFail("retry, draft, and cancel from a byte-distinct session must preserve the outbox")
        }
        XCTAssertTrue(UTF8ExactIdentity.matches(restored.proposal.targetSessionId, composedSessionId))
        XCTAssertFalse(UTF8ExactIdentity.matches(restored.proposal.targetSessionId, decomposedSessionId))
        XCTAssertTrue(UTF8ExactIdentity.matches(restored.proposal.id, persisted.proposal.id))
    }

    func test_confirm_compare_and_set_cannot_overwrite_an_intent_claimed_after_view_model_init() {
        let sessionB = PhoneWriteViewModel(sessionId: "session-B", client: makeClient())
        let proposalA = PocketWriteClient.makeHumanMessageProposal(
            sessionId: "session-A",
            message: "A claimed the slot after B was composed",
            at: Date(timeIntervalSince1970: 1_784_000_000)
        )
        let confirmationA = GovernedWriteConfirmation(
            proposalId: proposalA.id,
            confirmedProposalHash: proposalA.proposalHash,
            confirmedAt: Date(timeIntervalSince1970: 1_784_000_001)
        )
        let intentA = PersistedWriteIntent(proposal: proposalA, confirmation: confirmationA)
        XCTAssertEqual(OutboxStore.claim(intentA), .claimed)

        sessionB.draft("B must not overwrite A")
        sessionB.confirm()

        XCTAssertEqual(sessionB.state, .blockedByPendingSession("session-A"))
        XCTAssertEqual(OutboxStore.load(), intentA)
    }

    func test_late_compare_and_clear_for_A_does_not_delete_B() {
        let proposalA = PocketWriteClient.makeHumanMessageProposal(
            sessionId: "session-A",
            message: "A",
            at: Date(timeIntervalSince1970: 1_784_000_000)
        )
        let intentA = PersistedWriteIntent(
            proposal: proposalA,
            confirmation: GovernedWriteConfirmation(
                proposalId: proposalA.id,
                confirmedProposalHash: proposalA.proposalHash,
                confirmedAt: Date(timeIntervalSince1970: 1_784_000_001)
            )
        )
        let proposalB = PocketWriteClient.makeHumanMessageProposal(
            sessionId: "session-B",
            message: "B",
            at: Date(timeIntervalSince1970: 1_784_000_002)
        )
        let intentB = PersistedWriteIntent(
            proposal: proposalB,
            confirmation: GovernedWriteConfirmation(
                proposalId: proposalB.id,
                confirmedProposalHash: proposalB.proposalHash,
                confirmedAt: Date(timeIntervalSince1970: 1_784_000_003)
            )
        )
        OutboxStore.save(intentB)

        OutboxStore.clear(matching: intentA)

        XCTAssertEqual(OutboxStore.load(), intentB)
    }

    func test_submillisecond_live_intent_owns_its_millisecond_roundtrip() {
        let proposal = PocketWriteClient.makeHumanMessageProposal(
            sessionId: "session-A",
            message: "Canonical durable identity",
            at: Date(timeIntervalSince1970: 1_784_000_000.000456)
        )
        let intent = PersistedWriteIntent(
            proposal: proposal,
            confirmation: GovernedWriteConfirmation(
                proposalId: proposal.id,
                confirmedProposalHash: proposal.proposalHash,
                confirmedAt: Date(timeIntervalSince1970: 1_784_000_001.000789)
            )
        )
        OutboxStore.save(intent)

        XCTAssertNotEqual(OutboxStore.load(), intent,
                          "precondition: disk normalization intentionally drops sub-millisecond Date precision")
        XCTAssertEqual(OutboxStore.claim(intent), .claimed,
                       "canonical durable equality must recognize the live intent as the existing owner")

        OutboxStore.clear(matching: intent)

        XCTAssertNil(OutboxStore.load(), "the live intent must be able to clear its own normalized durable slot")
    }

    func test_tampered_persisted_confirmation_is_never_restored() {
        let proposal = PocketWriteClient.makeHumanMessageProposal(
            sessionId: "session-A",
            message: "Original content"
        )
        let mismatched = GovernedWriteConfirmation(
            proposalId: "different-proposal",
            confirmedProposalHash: proposal.proposalHash,
            confirmedAt: Date(timeIntervalSince1970: 1_784_000_000)
        )
        OutboxStore.save(PersistedWriteIntent(proposal: proposal, confirmation: mismatched))

        let vm = PhoneWriteViewModel(sessionId: "session-A", client: makeClient())

        guard case .refused(let message) = vm.state else {
            return XCTFail("a tampered outbox must fail closed")
        }
        XCTAssertTrue(message.contains("integrity"))
        XCTAssertNil(OutboxStore.load(), "a structurally invalid local intent must never remain retryable")
    }

    func test_canonically_equal_but_byte_distinct_confirmation_proposal_id_is_invalidated() {
        let composedProposalId = "proposal-caf\u{00E9}"
        let decomposedProposalId = "proposal-cafe\u{0301}"
        XCTAssertEqual(composedProposalId, decomposedProposalId, "precondition: Swift String equality is canonical")
        XCTAssertFalse(UTF8ExactIdentity.matches(composedProposalId, decomposedProposalId))

        let createdAt = Date(timeIntervalSince1970: 1_784_000_000)
        let proposal = ActionProposal(
            id: composedProposalId,
            kind: .humanMessage,
            targetSessionId: "session-A",
            targetSequence: 0,
            renderedPreview: "The confirmation must bind the original proposal-id bytes",
            createdAt: createdAt,
            sourceQuestionId: nil
        )
        let persisted = PersistedWriteIntent(
            proposal: proposal,
            confirmation: GovernedWriteConfirmation(
                proposalId: decomposedProposalId,
                confirmedProposalHash: proposal.proposalHash,
                confirmedAt: Date(timeIntervalSince1970: 1_784_000_001)
            )
        )

        XCTAssertEqual(persisted.binding(to: "session-A"), .invalid)
        OutboxStore.save(persisted)

        let restored = PhoneWriteViewModel(sessionId: "session-A", client: makeClient())
        guard case .refused(let message) = restored.state else {
            return XCTFail("a byte-distinct confirmation proposal id must be refused")
        }
        XCTAssertTrue(message.contains("integrity"))
        XCTAssertNil(OutboxStore.load(), "the invalid confirmation must be cleared and never become retryable")
    }

    /// Regression for the moved persist: a cancelled decision must still leave NOTHING queued. cancel() after the
    /// confirm-time persist must clear the durable outbox.
    func test_cancel_after_confirm_clears_the_durable_outbox() async {
        let vm = PhoneWriteViewModel(sessionId: "6cf7e861", client: makeClient())
        vm.draft("Split the PR")
        vm.confirm()
        XCTAssertNotNil(OutboxStore.load(), "precondition: confirm() persisted the intent")

        vm.cancel()
        XCTAssertNil(OutboxStore.load(), "cancel() must clear the durable outbox — a cancelled decision queues nothing")

        for _ in 0..<5 { await Task.yield() }
    }

    func test_later_dial_cancel_cannot_erase_an_earlier_confirmed_intent() async {
        let proposal = PocketWriteClient.makeHumanMessageProposal(
            sessionId: "session-A",
            message: "Already confirmed before the new call",
            at: Date(timeIntervalSince1970: 1_784_000_000)
        )
        let persisted = PersistedWriteIntent(
            proposal: proposal,
            confirmation: GovernedWriteConfirmation(
                proposalId: proposal.id,
                confirmedProposalHash: proposal.proposalHash,
                confirmedAt: Date(timeIntervalSince1970: 1_784_000_000)
            )
        )
        OutboxStore.save(persisted)
        let restored = PhoneWriteViewModel(sessionId: "session-A", client: makeClient())
        let laterDial = PhoneWriteAdapter(restored)
        guard case .pending = restored.state else {
            return XCTFail("precondition: the earlier committed operation must restore as pending")
        }

        await laterDial.draft("A later call cannot arm while the earlier operation is pending")
        await laterDial.cancel()

        guard case .pending = restored.state else {
            return XCTFail("a pre-confirm hangup in the later call must leave the earlier operation pending")
        }
        XCTAssertEqual(OutboxStore.load(), persisted,
                       "the later adapter owns no draft and must not delete an earlier confirmation")
    }
}
