import Combine
import Foundation
import PocketVoice
import XCTest
@testable import SentiPocketApp

private enum WhisperModelProvisioningTestError: Error {
    case requestTimeout
}

private actor ControlledWhisperModelStore: WhisperModelStoring {
    enum RequestKind: Equatable, Sendable {
        case verify
        case install
        case remove
    }

    struct Request: Equatable, Sendable {
        let id: Int
        let kind: RequestKind
        let sourceURL: URL?
    }

    private struct PendingRequest {
        let request: Request
        let continuation: CheckedContinuation<WhisperModelStoreResult, Never>
    }

    private struct RequestWaiter {
        let id: UUID
        let count: Int
        let continuation: CheckedContinuation<Bool, Never>
    }

    private var nextID = 1
    private var requests: [Request] = []
    private var pending: [PendingRequest] = []
    private var progressCallbacks: [Int: (@Sendable (WhisperModelInstallProgress) -> Void)] = [:]
    private var requestWaiters: [RequestWaiter] = []

    func verifyInstalled() async -> WhisperModelStoreResult {
        await suspend(kind: .verify, sourceURL: nil, progress: nil)
    }

    func installLocalFile(
        at sourceURL: URL,
        progress: @escaping @Sendable (WhisperModelInstallProgress) -> Void
    ) async -> WhisperModelStoreResult {
        await suspend(kind: .install, sourceURL: sourceURL, progress: progress)
    }

    func removeInstalled() async -> WhisperModelStoreResult {
        await suspend(kind: .remove, sourceURL: nil, progress: nil)
    }

    func waitForRequestCount(_ count: Int) async -> Bool {
        if requests.count >= count { return true }
        let waiterID = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if requests.count >= count {
                    continuation.resume(returning: true)
                } else {
                    requestWaiters.append(RequestWaiter(
                        id: waiterID,
                        count: count,
                        continuation: continuation
                    ))
                }
            }
        } onCancel: {
            Task { await self.cancelWaiter(waiterID) }
        }
    }

    func requestSnapshot() -> [Request] { requests }

    func resume(requestID: Int, returning result: WhisperModelStoreResult) {
        guard let index = pending.firstIndex(where: { $0.request.id == requestID }) else {
            preconditionFailure("No pending Whisper model request with that ID")
        }
        let request = pending.remove(at: index)
        request.continuation.resume(returning: result)
    }

    func emitProgress(requestID: Int, _ progress: WhisperModelInstallProgress) {
        guard let callback = progressCallbacks[requestID] else {
            preconditionFailure("No pending Whisper install request with that ID")
        }
        callback(progress)
    }

    private func suspend(
        kind: RequestKind,
        sourceURL: URL?,
        progress: (@Sendable (WhisperModelInstallProgress) -> Void)?
    ) async -> WhisperModelStoreResult {
        let request = Request(id: nextID, kind: kind, sourceURL: sourceURL)
        nextID += 1
        return await withCheckedContinuation { continuation in
            pending.append(PendingRequest(
                request: request,
                continuation: continuation
            ))
            if let progress {
                progressCallbacks[request.id] = progress
            }
            requests.append(request)
            resumeSatisfiedWaiters()
        }
    }

    private func resumeSatisfiedWaiters() {
        var remaining: [RequestWaiter] = []
        for waiter in requestWaiters {
            if requests.count >= waiter.count {
                waiter.continuation.resume(returning: true)
            } else {
                remaining.append(waiter)
            }
        }
        requestWaiters = remaining
    }

    private func cancelWaiter(_ id: UUID) {
        guard let index = requestWaiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = requestWaiters.remove(at: index)
        waiter.continuation.resume(returning: false)
    }
}

@MainActor
final class WhisperModelProvisioningCoordinatorTests: XCTestCase {
    func test_start_fullyVerifiesInstalledModelOnlyOnce() async throws {
        let store = ControlledWhisperModelStore()
        let coordinator = WhisperModelProvisioningCoordinator(store: store)

        let operation = try XCTUnwrap(coordinator.start())
        _ = coordinator.start()
        let request = try await nextRequest(store, count: 1)
        XCTAssertEqual(request.kind, .verify)

        await store.resume(requestID: request.id, returning: .success)
        await operation.value

        XCTAssertEqual(coordinator.state, state(.installed))
        let finalRequests = await store.requestSnapshot()
        XCTAssertEqual(finalRequests.count, 1)
    }

    func test_start_mapsMissingModelToNormalNotInstalledState() async throws {
        let store = ControlledWhisperModelStore()
        let coordinator = WhisperModelProvisioningCoordinator(store: store)

        let operation = try XCTUnwrap(coordinator.start())
        let request = try await nextRequest(store, count: 1)
        await store.resume(requestID: request.id, returning: .failure(.notInstalled))
        await operation.value

        XCTAssertEqual(coordinator.state, state(.notInstalled))
    }

    func test_start_mapsIntegrityFailureToUnusableWithoutClaimingReadiness() async throws {
        let store = ControlledWhisperModelStore()
        let coordinator = WhisperModelProvisioningCoordinator(store: store)

        let operation = try XCTUnwrap(coordinator.start())
        let request = try await nextRequest(store, count: 1)
        await store.resume(requestID: request.id, returning: .failure(.digestMismatch))
        await operation.value

        XCTAssertEqual(
            coordinator.state,
            state(.unusable, notice: .integrityFailure)
        )
    }

    func test_installProjectsMonotonicProgressThenUsesFreshVerificationAsTruth() async throws {
        let store = ControlledWhisperModelStore()
        let coordinator = WhisperModelProvisioningCoordinator(
            store: store,
            initialState: state(.notInstalled)
        )
        let selectedURL = URL(fileURLWithPath: "/selected/ggml-base.en.bin")

        let operation = try XCTUnwrap(coordinator.installConfirmedCopy(copy(selectedURL)))
        let install = try await nextRequest(store, count: 1)
        XCTAssertEqual(install.kind, .install)
        XCTAssertEqual(install.sourceURL, selectedURL)

        let copyPublished = expectation(description: "copy progress published")
        let copyObservation = coordinator.$state
            .filter { $0.activity == .installing(.copying(completed: 32, total: 100)) }
            .prefix(1)
            .sink { _ in copyPublished.fulfill() }

        await store.emitProgress(
            requestID: install.id,
            .copying(completed: 32, total: 100)
        )
        await fulfillment(of: [copyPublished], timeout: 1)
        XCTAssertEqual(
            coordinator.state.activity,
            .installing(.copying(completed: 32, total: 100))
        )
        withExtendedLifetime(copyObservation) {}

        let regressionPublished = expectation(description: "regressive progress rejected")
        regressionPublished.isInverted = true
        let regressionObservation = coordinator.$state
            .filter { $0.activity == .installing(.copying(completed: 16, total: 100)) }
            .sink { _ in regressionPublished.fulfill() }
        await store.emitProgress(
            requestID: install.id,
            .copying(completed: 16, total: 100)
        )
        await fulfillment(of: [regressionPublished], timeout: 0.1)
        XCTAssertEqual(
            coordinator.state.activity,
            .installing(.copying(completed: 32, total: 100))
        )
        withExtendedLifetime(regressionObservation) {}

        let finishingPublished = expectation(description: "finishing progress published")
        let finishingObservation = coordinator.$state
            .filter { $0.activity == .installing(.finishing) }
            .prefix(1)
            .sink { _ in finishingPublished.fulfill() }
        await store.emitProgress(requestID: install.id, .verifying)
        await store.emitProgress(requestID: install.id, .finishing)
        await fulfillment(of: [finishingPublished], timeout: 1)
        XCTAssertEqual(coordinator.state.activity, .installing(.finishing))
        withExtendedLifetime(finishingObservation) {}

        XCTAssertFalse(WhisperModelProvisioningCoordinator.progress(
            .copying(completed: 16, total: 100),
            isForwardFrom: .copying(completed: 32, total: 100)
        ))
        XCTAssertFalse(WhisperModelProvisioningCoordinator.progress(
            .copying(completed: 101, total: 100),
            isForwardFrom: nil
        ))
        XCTAssertFalse(WhisperModelProvisioningCoordinator.progress(
            .copying(completed: 40, total: 101),
            isForwardFrom: .copying(completed: 32, total: 100)
        ))
        XCTAssertFalse(WhisperModelProvisioningCoordinator.progress(
            .verifying,
            isForwardFrom: .finishing
        ))

        await store.resume(requestID: install.id, returning: .success)
        let verification = try await nextRequest(store, count: 2)
        XCTAssertEqual(verification.kind, .verify)
        XCTAssertEqual(coordinator.state.activity, .verifying)
        await store.resume(requestID: verification.id, returning: .success)
        await operation.value

        XCTAssertEqual(coordinator.state, state(.installed))
    }

    func test_successfulInstallNeverClaimsInstalledWhenCanonicalReverificationIsMissing() async throws {
        let store = ControlledWhisperModelStore()
        let coordinator = WhisperModelProvisioningCoordinator(
            store: store,
            initialState: state(.notInstalled)
        )

        let operation = try XCTUnwrap(coordinator.installConfirmedCopy(copy(
            URL(fileURLWithPath: "/selected/ggml-base.en.bin")
        )))
        let install = try await nextRequest(store, count: 1)
        await store.resume(requestID: install.id, returning: .success)
        let verification = try await nextRequest(store, count: 2)
        await store.resume(requestID: verification.id, returning: .failure(.notInstalled))
        await operation.value

        XCTAssertEqual(
            coordinator.state,
            state(.notInstalled, notice: .installationNotVerified)
        )
    }

    func test_installFailurePreservesVerifiedPriorModelAndUsesSanitizedNotice() async throws {
        let store = ControlledWhisperModelStore()
        let coordinator = WhisperModelProvisioningCoordinator(
            store: store,
            initialState: state(.installed)
        )

        let operation = try XCTUnwrap(coordinator.installConfirmedCopy(copy(
            URL(fileURLWithPath: "/private/provider/path/incorrect.bin")
        )))
        let install = try await nextRequest(store, count: 1)
        await store.resume(requestID: install.id, returning: .failure(.sourceNameMismatch))
        let verification = try await nextRequest(store, count: 2)
        await store.resume(requestID: verification.id, returning: .success)
        await operation.value

        XCTAssertEqual(coordinator.state, state(.installed, notice: .incorrectModel))
        XCTAssertFalse(coordinator.state.notice?.detail.contains("/private/provider") ?? true)
    }

    func test_selectedDigestFailureDoesNotMislabelTheVerifiedInstalledCopy() async throws {
        let store = ControlledWhisperModelStore()
        let coordinator = WhisperModelProvisioningCoordinator(
            store: store,
            initialState: state(.installed)
        )

        let operation = try XCTUnwrap(coordinator.installConfirmedCopy(copy(
            URL(fileURLWithPath: "/selected/ggml-base.en.bin")
        )))
        let install = try await nextRequest(store, count: 1)
        await store.resume(requestID: install.id, returning: .failure(.digestMismatch))
        let verification = try await nextRequest(store, count: 2)
        await store.resume(requestID: verification.id, returning: .success)
        await operation.value

        XCTAssertEqual(
            coordinator.state,
            state(.installed, notice: .selectedFileIntegrityFailure)
        )
    }

    func test_removeSuccessNeverClaimsMissingWhenCanonicalReverificationStillSucceeds() async throws {
        let store = ControlledWhisperModelStore()
        let coordinator = WhisperModelProvisioningCoordinator(
            store: store,
            initialState: state(.installed)
        )

        let operation = try XCTUnwrap(coordinator.removeConfirmedModel())
        let removal = try await nextRequest(store, count: 1)
        XCTAssertEqual(removal.kind, .remove)
        await store.resume(requestID: removal.id, returning: .success)
        let verification = try await nextRequest(store, count: 2)
        await store.resume(requestID: verification.id, returning: .success)
        await operation.value

        XCTAssertEqual(
            coordinator.state,
            state(.installed, notice: .removalNotVerified)
        )
    }

    func test_confirmedRemovalPublishesMissingOnlyAfterFreshVerification() async throws {
        let store = ControlledWhisperModelStore()
        let coordinator = WhisperModelProvisioningCoordinator(
            store: store,
            initialState: state(.installed)
        )

        let operation = try XCTUnwrap(coordinator.removeConfirmedModel())
        let removal = try await nextRequest(store, count: 1)
        await store.resume(requestID: removal.id, returning: .success)
        let verification = try await nextRequest(store, count: 2)
        await store.resume(requestID: verification.id, returning: .failure(.notInstalled))
        await operation.value

        XCTAssertEqual(coordinator.state, state(.notInstalled))
    }

    func test_cancelJoinsIgnoringCancellationStoreThenReconcilesActualMissingState() async throws {
        let store = ControlledWhisperModelStore()
        let coordinator = WhisperModelProvisioningCoordinator(
            store: store,
            initialState: state(.installed)
        )
        let sourceURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: false)
        try Data([0x01]).write(to: sourceURL, options: .atomic)

        let oldOperation = try XCTUnwrap(coordinator.installConfirmedCopy(copy(
            sourceURL
        )))
        let install = try await nextRequest(store, count: 1)
        let reconciliation = try XCTUnwrap(coordinator.cancelInstallation())
        XCTAssertEqual(coordinator.state.activity, .cancelling)
        let requestsBeforeCleanup = await store.requestSnapshot()
        XCTAssertEqual(requestsBeforeCleanup.map(\.kind), [.install])

        // The controlled store intentionally ignores Task cancellation and reports a late success.
        await store.emitProgress(requestID: install.id, .finishing)
        await store.resume(requestID: install.id, returning: .success)
        await oldOperation.value
        XCTAssertFalse(FileManager.default.fileExists(atPath: sourceURL.path))

        let verification = try await nextRequest(store, count: 2)
        XCTAssertEqual(verification.kind, .verify)
        await store.resume(requestID: verification.id, returning: .failure(.notInstalled))
        await reconciliation.value

        XCTAssertEqual(coordinator.state, state(.notInstalled))
    }

    func test_cancelReconcilesToPreservedInstalledModelWhenReplacementNeverCommits() async throws {
        let store = ControlledWhisperModelStore()
        let coordinator = WhisperModelProvisioningCoordinator(
            store: store,
            initialState: state(.installed)
        )

        _ = try XCTUnwrap(coordinator.installConfirmedCopy(copy(
            URL(fileURLWithPath: "/selected/ggml-base.en.bin")
        )))
        let install = try await nextRequest(store, count: 1)
        let reconciliation = try XCTUnwrap(coordinator.cancelInstallation())
        await store.resume(requestID: install.id, returning: .failure(.cancelled))
        let verification = try await nextRequest(store, count: 2)
        await store.resume(requestID: verification.id, returning: .success)
        await reconciliation.value

        XCTAssertEqual(coordinator.state, state(.installed))
    }

    func test_oldGenerationProgressCannotOverwriteANewerInstall() async throws {
        let store = ControlledWhisperModelStore()
        let coordinator = WhisperModelProvisioningCoordinator(
            store: store,
            initialState: state(.installed)
        )
        let selectedURL = URL(fileURLWithPath: "/selected/ggml-base.en.bin")

        _ = try XCTUnwrap(coordinator.installConfirmedCopy(copy(selectedURL)))
        let oldInstall = try await nextRequest(store, count: 1)
        let firstReconciliation = try XCTUnwrap(coordinator.cancelInstallation())
        await store.resume(requestID: oldInstall.id, returning: .failure(.cancelled))
        let firstVerification = try await nextRequest(store, count: 2)
        await store.resume(requestID: firstVerification.id, returning: .success)
        await firstReconciliation.value

        let newOperation = try XCTUnwrap(coordinator.installConfirmedCopy(copy(selectedURL)))
        let newInstall = try await nextRequest(store, count: 3)
        let stalePublished = expectation(description: "stale finishing progress rejected")
        stalePublished.isInverted = true
        let staleObservation = coordinator.$state
            .filter { $0.activity == .installing(.finishing) }
            .sink { _ in stalePublished.fulfill() }

        await store.emitProgress(requestID: oldInstall.id, .finishing)
        await fulfillment(of: [stalePublished], timeout: 0.1)
        XCTAssertEqual(coordinator.state.activity, .installing(nil))
        withExtendedLifetime(staleObservation) {}

        let currentPublished = expectation(description: "current progress published")
        let currentObservation = coordinator.$state
            .filter { $0.activity == .installing(.copying(completed: 1, total: 10)) }
            .prefix(1)
            .sink { _ in currentPublished.fulfill() }
        await store.emitProgress(
            requestID: newInstall.id,
            .copying(completed: 1, total: 10)
        )
        await fulfillment(of: [currentPublished], timeout: 1)
        XCTAssertEqual(
            coordinator.state.activity,
            .installing(.copying(completed: 1, total: 10))
        )
        withExtendedLifetime(currentObservation) {}

        let secondReconciliation = try XCTUnwrap(coordinator.cancelInstallation())
        await store.resume(requestID: newInstall.id, returning: .failure(.cancelled))
        await newOperation.value
        let secondVerification = try await nextRequest(store, count: 4)
        await store.resume(requestID: secondVerification.id, returning: .success)
        await secondReconciliation.value
        XCTAssertEqual(coordinator.state, state(.installed))
    }

    func test_repeatedMutationRequestsCannotCreateCompetingStoreOperations() async throws {
        let store = ControlledWhisperModelStore()
        let coordinator = WhisperModelProvisioningCoordinator(
            store: store,
            initialState: state(.notInstalled)
        )
        let selectedURL = URL(fileURLWithPath: "/selected/ggml-base.en.bin")

        _ = try XCTUnwrap(coordinator.installConfirmedCopy(copy(selectedURL)))
        let install = try await nextRequest(store, count: 1)
        let refusedURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: false)
        try Data([0x01]).write(to: refusedURL, options: .atomic)
        XCTAssertNil(coordinator.installConfirmedCopy(copy(refusedURL)))
        XCTAssertFalse(FileManager.default.fileExists(atPath: refusedURL.path))
        XCTAssertNil(coordinator.removeConfirmedModel())
        XCTAssertNil(coordinator.refresh())
        let requests = await store.requestSnapshot()
        XCTAssertEqual(requests.count, 1)

        let reconciliation = try XCTUnwrap(coordinator.cancelInstallation())
        await store.resume(requestID: install.id, returning: .failure(.cancelled))
        let verification = try await nextRequest(store, count: 2)
        await store.resume(requestID: verification.id, returning: .failure(.notInstalled))
        await reconciliation.value
    }

    func test_refreshFencesLateInitialVerificationCompletion() async throws {
        let store = ControlledWhisperModelStore()
        let coordinator = WhisperModelProvisioningCoordinator(store: store)

        let first = try XCTUnwrap(coordinator.start())
        let firstVerification = try await nextRequest(store, count: 1)
        let second = try XCTUnwrap(coordinator.refresh())
        let secondVerification = try await nextRequest(store, count: 2)

        await store.resume(requestID: firstVerification.id, returning: .success)
        await first.value
        XCTAssertEqual(coordinator.state.availability, .checking)

        await store.resume(
            requestID: secondVerification.id,
            returning: .failure(.notInstalled)
        )
        await second.value
        XCTAssertEqual(coordinator.state, state(.notInstalled))
    }

    func test_refreshRecoversAfterTransientStorageFailure() async throws {
        let store = ControlledWhisperModelStore()
        let coordinator = WhisperModelProvisioningCoordinator(store: store)

        let first = try XCTUnwrap(coordinator.start())
        let failedVerification = try await nextRequest(store, count: 1)
        await store.resume(
            requestID: failedVerification.id,
            returning: .failure(.storageUnavailable)
        )
        await first.value
        XCTAssertEqual(coordinator.state, state(.unavailable, notice: .storageUnavailable))

        let retry = try XCTUnwrap(coordinator.refresh())
        let successfulVerification = try await nextRequest(store, count: 2)
        await store.resume(requestID: successfulVerification.id, returning: .success)
        await retry.value

        XCTAssertEqual(coordinator.state, state(.installed))
    }

    func test_installAlwaysDiscardsThePickerOwnedCopyAfterStoreAndVerificationFinish() async throws {
        let store = ControlledWhisperModelStore()
        let coordinator = WhisperModelProvisioningCoordinator(
            store: store,
            initialState: state(.notInstalled)
        )
        let sourceURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: false)
        try Data([0x01]).write(to: sourceURL, options: .atomic)
        XCTAssertTrue(FileManager.default.fileExists(atPath: sourceURL.path))

        let operation = try XCTUnwrap(coordinator.installConfirmedCopy(copy(sourceURL)))
        let install = try await nextRequest(store, count: 1)
        await store.resume(requestID: install.id, returning: .success)
        let verification = try await nextRequest(store, count: 2)
        await store.resume(requestID: verification.id, returning: .success)
        await operation.value

        XCTAssertFalse(FileManager.default.fileExists(atPath: sourceURL.path))
    }

    private func nextRequest(
        _ store: ControlledWhisperModelStore,
        count: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws -> ControlledWhisperModelStore.Request {
        let reachedCount = await withTaskGroup(of: Bool.self, returning: Bool.self) { group in
            group.addTask {
                await store.waitForRequestCount(count)
            }
            group.addTask {
                do {
                    try await Task.sleep(nanoseconds: 2_000_000_000)
                    return false
                } catch {
                    return false
                }
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
        guard reachedCount else {
            XCTFail("Whisper model requests did not reach \(count)", file: file, line: line)
            throw WhisperModelProvisioningTestError.requestTimeout
        }
        let requests = await store.requestSnapshot()
        guard requests.count >= count else {
            XCTFail("Whisper model request snapshot regressed", file: file, line: line)
            throw WhisperModelProvisioningTestError.requestTimeout
        }
        return requests[count - 1]
    }

    private func state(
        _ availability: WhisperModelAvailability,
        activity: WhisperModelProvisioningActivity = .idle,
        notice: WhisperModelProvisioningNotice? = nil
    ) -> WhisperModelProvisioningState {
        WhisperModelProvisioningState(
            availability: availability,
            activity: activity,
            notice: notice
        )
    }

    private func copy(_ url: URL) -> WhisperModelImportedCopy {
        WhisperModelImportedCopy(url: url)
    }
}
