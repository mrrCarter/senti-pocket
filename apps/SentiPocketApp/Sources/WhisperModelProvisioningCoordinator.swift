import Combine
import Foundation
import PocketVoice

enum WhisperModelStoreResult: Equatable, Sendable {
    case success
    case failure(WhisperModelStoreError)
    case unexpectedFailure
}

/// App-facing, value-returning boundary around PocketVoice's model store. Mapping arbitrary
/// errors here keeps non-Sendable error values and source URLs out of presentation state.
protocol WhisperModelStoring: Sendable {
    func verifyInstalled() async -> WhisperModelStoreResult
    func installLocalFile(
        at sourceURL: URL,
        progress: @escaping @Sendable (WhisperModelInstallProgress) -> Void
    ) async -> WhisperModelStoreResult
    func removeInstalled() async -> WhisperModelStoreResult
}

actor LiveWhisperModelStoreClient: WhisperModelStoring {
    private var store: WhisperModelStore?

    func verifyInstalled() async -> WhisperModelStoreResult {
        do {
            let store = try resolvedStore()
            _ = try await store.verifyInstalledModel()
            return .success
        } catch {
            return Self.result(for: error)
        }
    }

    func installLocalFile(
        at sourceURL: URL,
        progress: @escaping @Sendable (WhisperModelInstallProgress) -> Void
    ) async -> WhisperModelStoreResult {
        do {
            let store = try resolvedStore()
            _ = try await store.installLocalFile(at: sourceURL, progress: progress)
            return .success
        } catch {
            return Self.result(for: error)
        }
    }

    func removeInstalled() async -> WhisperModelStoreResult {
        do {
            let store = try resolvedStore()
            try await store.removeInstalledModel()
            return .success
        } catch {
            return Self.result(for: error)
        }
    }

    /// Store construction can fail transiently while protected app storage is unavailable. Cache
    /// only a successful construction so an explicit UI refresh can recover without an app restart.
    private func resolvedStore() throws -> WhisperModelStore {
        if let store { return store }
        let resolved = try WhisperModelStore(descriptor: .baseEnglish)
        store = resolved
        return resolved
    }

    private static func result(for error: Error) -> WhisperModelStoreResult {
        if let storeError = error as? WhisperModelStoreError {
            return .failure(storeError)
        }
        if error is CancellationError {
            return .failure(.cancelled)
        }
        return .unexpectedFailure
    }
}

enum WhisperModelAvailability: Equatable, Sendable {
    case checking
    case notInstalled
    case installed
    case unusable
    case unavailable
}

enum WhisperModelProvisioningActivity: Equatable, Sendable {
    case idle
    case installing(WhisperModelInstallProgress?)
    case verifying
    case cancelling
    case removing

    var isBusy: Bool { self != .idle }
}

enum WhisperModelProvisioningNotice: Equatable, Sendable {
    case invalidSelection
    case incorrectModel
    case selectedFileIntegrityFailure
    case integrityFailure
    case storageUnavailable
    case storeBusy
    case installationFailed
    case removalFailed
    case verificationFailed
    case installationNotVerified
    case removalNotVerified

    var title: String {
        switch self {
        case .invalidSelection: return "File could not be imported"
        case .incorrectModel: return "That is not the required model"
        case .selectedFileIntegrityFailure: return "Selected file failed verification"
        case .integrityFailure: return "Model verification failed"
        case .storageUnavailable: return "Model storage unavailable"
        case .storeBusy: return "Model operation already running"
        case .installationFailed: return "Model was not installed"
        case .removalFailed: return "Model was not removed"
        case .verificationFailed: return "Model status unavailable"
        case .installationNotVerified: return "Installation could not be confirmed"
        case .removalNotVerified: return "Removal could not be confirmed"
        }
    }

    var detail: String {
        switch self {
        case .invalidSelection:
            return "Choose a downloaded local copy of the required regular model file and try again."
        case .incorrectModel:
            return "The selected file does not match Senti Pocket's pinned filename, size, and integrity policy."
        case .selectedFileIntegrityFailure:
            return "The selected copy did not match Senti Pocket's pinned SHA-256 digest. The installed model state was checked separately."
        case .integrityFailure:
            return "The private model copy is present but cannot be trusted. Replace it with the pinned model file."
        case .storageUnavailable:
            return "Senti Pocket cannot safely access its private model storage on this device right now."
        case .storeBusy:
            return "Wait for the current model operation to finish, then try again."
        case .installationFailed:
            return "Senti Pocket could not durably commit the verified model. Your prior model state was preserved when possible."
        case .removalFailed:
            return "Senti Pocket could not prove that the private model copy was durably removed."
        case .verificationFailed:
            return "Senti Pocket could not fully verify the private model copy, so on-device speech readiness is not claimed."
        case .installationNotVerified:
            return "The import operation ended, but a fresh full verification did not find an installed model."
        case .removalNotVerified:
            return "The removal operation ended, but a fresh full verification still found an installed model."
        }
    }
}

struct WhisperModelProvisioningState: Equatable, Sendable {
    var availability: WhisperModelAvailability
    var activity: WhisperModelProvisioningActivity
    var notice: WhisperModelProvisioningNotice?

    static let initial = WhisperModelProvisioningState(
        availability: .checking,
        activity: .idle,
        notice: nil
    )
}

/// App-lifetime owner of the device-local Whisper model lifecycle.
///
/// Store verification is the only readiness authority. Mutation completion, progress, and the
/// dial-time path locator never directly produce `.installed` or `.notInstalled` state.
@MainActor
final class WhisperModelProvisioningCoordinator: ObservableObject {
    @Published private(set) var state: WhisperModelProvisioningState

    static let requiredFileName = WhisperModelDescriptor.baseEnglish.fileName
    static let requiredByteCount = WhisperModelDescriptor.baseEnglish.byteCount

    private enum Mutation: Equatable, Sendable {
        case install
        case remove
    }

    private let store: any WhisperModelStoring
    private var operation: Task<Void, Never>?
    private var generation: UInt64 = 0
    private var hasStarted = false

    convenience init() {
        self.init(store: LiveWhisperModelStoreClient())
    }

    init(
        store: any WhisperModelStoring,
        initialState: WhisperModelProvisioningState = .initial
    ) {
        self.store = store
        state = initialState
    }

    deinit {
        operation?.cancel()
    }

    @discardableResult
    func start() -> Task<Void, Never>? {
        guard !hasStarted else { return operation }
        hasStarted = true
        return beginVerification()
    }

    @discardableResult
    func refresh() -> Task<Void, Never>? {
        guard state.activity == .idle else { return nil }
        return beginVerification()
    }

    /// Called only after the settings view's explicit confirmation dialog.
    @discardableResult
    func installConfirmedCopy(_ importedCopy: WhisperModelImportedCopy) -> Task<Void, Never>? {
        guard state.activity == .idle, state.availability != .checking else {
            importedCopy.discard()
            return nil
        }

        let token = advanceGeneration()
        state.activity = .installing(nil)
        state.notice = nil
        let store = store
        let task = Task { @MainActor [weak self] in
            let sourceURL = importedCopy.url
            let accessedSecurityScope = sourceURL.startAccessingSecurityScopedResource()
            defer {
                if accessedSecurityScope {
                    sourceURL.stopAccessingSecurityScopedResource()
                }
            }
            // This URL is an app-owned `asCopy` import, never a provider/open-mode URL. Unlink
            // exactly that copied directory entry after Store has finished or joined cancellation.
            defer { importedCopy.discard() }

            let mutationResult = await store.installLocalFile(at: sourceURL) { [weak self] progress in
                Task { @MainActor [weak self] in
                    self?.receiveInstallProgress(progress, token: token)
                }
            }
            guard let self, self.isCurrent(token), !Task.isCancelled else { return }
            await self.reconcile(
                token: token,
                mutation: .install,
                mutationResult: mutationResult
            )
        }
        operation = task
        return task
    }

    /// Cancelling an import never assumes rollback. The old task is invalidated first; a fresh,
    /// uncancelled task joins Store cleanup and then re-verifies canonical state.
    @discardableResult
    func cancelInstallation() -> Task<Void, Never>? {
        guard case .installing = state.activity else { return nil }
        let previous = operation
        let token = advanceGeneration()
        previous?.cancel()
        state.activity = .cancelling
        state.notice = nil
        let store = store
        let task = Task { @MainActor [weak self] in
            await previous?.value
            guard let self, self.isCurrent(token), !Task.isCancelled else { return }
            self.state.activity = .verifying
            let verification = await store.verifyInstalled()
            guard self.isCurrent(token), !Task.isCancelled else { return }
            self.applyVerification(
                verification,
                token: token,
                mutation: nil,
                mutationResult: nil
            )
        }
        operation = task
        return task
    }

    /// Called only after the settings view's destructive confirmation dialog.
    @discardableResult
    func removeConfirmedModel() -> Task<Void, Never>? {
        guard state.activity == .idle, state.availability != .checking else { return nil }

        let token = advanceGeneration()
        state.activity = .removing
        state.notice = nil
        let store = store
        let task = Task { @MainActor [weak self] in
            let mutationResult = await store.removeInstalled()
            guard let self, self.isCurrent(token), !Task.isCancelled else { return }
            await self.reconcile(
                token: token,
                mutation: .remove,
                mutationResult: mutationResult
            )
        }
        operation = task
        return task
    }

    func dismissNotice() {
        state.notice = nil
    }

    private func beginVerification() -> Task<Void, Never> {
        operation?.cancel()
        let token = advanceGeneration()
        state = WhisperModelProvisioningState(
            availability: .checking,
            activity: .idle,
            notice: nil
        )
        let store = store
        let task = Task { @MainActor [weak self] in
            let verification = await store.verifyInstalled()
            guard let self, self.isCurrent(token), !Task.isCancelled else { return }
            self.applyVerification(
                verification,
                token: token,
                mutation: nil,
                mutationResult: nil
            )
        }
        operation = task
        return task
    }

    private func reconcile(
        token: UInt64,
        mutation: Mutation,
        mutationResult: WhisperModelStoreResult
    ) async {
        guard isCurrent(token), !Task.isCancelled else { return }
        state.activity = .verifying
        let verification = await store.verifyInstalled()
        guard isCurrent(token), !Task.isCancelled else { return }
        applyVerification(
            verification,
            token: token,
            mutation: mutation,
            mutationResult: mutationResult
        )
    }

    private func applyVerification(
        _ verification: WhisperModelStoreResult,
        token: UInt64,
        mutation: Mutation?,
        mutationResult: WhisperModelStoreResult?
    ) {
        guard isCurrent(token) else { return }

        let mutationNotice = mutation.flatMap { mutation in
            mutationResult.flatMap { Self.notice(for: $0, mutation: mutation) }
        }

        switch verification {
        case .success:
            state.availability = .installed
            if mutation == .remove, mutationResult == .success {
                state.notice = .removalNotVerified
            } else {
                state.notice = mutationNotice
            }

        case .failure(.notInstalled):
            state.availability = .notInstalled
            if mutation == .install, mutationResult == .success {
                state.notice = .installationNotVerified
            } else {
                state.notice = mutationNotice
            }

        case .failure(let error):
            switch error {
            case .digestMismatch, .byteCountMismatch, .storagePolicyFailed:
                state.availability = .unusable
                state.notice = .integrityFailure
            case .storageUnavailable, .invalidStoreURL:
                state.availability = .unavailable
                state.notice = .storageUnavailable
            default:
                state.availability = .unavailable
                state.notice = .verificationFailed
            }

        case .unexpectedFailure:
            state.availability = .unavailable
            state.notice = .verificationFailed
        }

        state.activity = .idle
        operation = nil
    }

    private func receiveInstallProgress(
        _ progress: WhisperModelInstallProgress,
        token: UInt64
    ) {
        guard isCurrent(token), case .installing(let current) = state.activity else { return }
        guard Self.progress(progress, isForwardFrom: current) else { return }
        state.activity = .installing(progress)
    }

    static func progress(
        _ next: WhisperModelInstallProgress,
        isForwardFrom current: WhisperModelInstallProgress?
    ) -> Bool {
        if case .copying(let completed, let total) = next,
           total <= 0 || completed < 0 || completed > total {
            return false
        }
        guard let current else { return true }

        switch (current, next) {
        case let (.copying(oldCompleted, oldTotal), .copying(newCompleted, newTotal)):
            return oldTotal == newTotal && newCompleted >= oldCompleted
        default:
            return progressRank(next) >= progressRank(current)
        }
    }

    private static func progressRank(_ progress: WhisperModelInstallProgress) -> Int {
        switch progress {
        case .copying: return 0
        case .verifying: return 1
        case .finishing: return 2
        }
    }

    private static func notice(
        for result: WhisperModelStoreResult,
        mutation: Mutation
    ) -> WhisperModelProvisioningNotice? {
        switch result {
        case .success, .failure(.cancelled):
            return nil
        case .unexpectedFailure:
            return mutation == .install ? .installationFailed : .removalFailed
        case .failure(let error):
            switch error {
            case .invalidSourceURL, .sourceRequiresLocalCopy, .sourceNotRegularFile,
                 .sourceUnavailable, .sourceChangedDuringImport:
                return .invalidSelection
            case .sourceNameMismatch, .byteCountMismatch:
                return .incorrectModel
            case .digestMismatch:
                return .selectedFileIntegrityFailure
            case .storageUnavailable, .invalidStoreURL, .storagePolicyFailed:
                return .storageUnavailable
            case .installationInProgress:
                return .storeBusy
            case .commitFailed:
                return .installationFailed
            case .removalFailed:
                return .removalFailed
            case .notInstalled:
                return mutation == .install ? .installationFailed : nil
            case .cancelled:
                return nil
            }
        }
    }

    private func advanceGeneration() -> UInt64 {
        generation &+= 1
        return generation
    }

    private func isCurrent(_ token: UInt64) -> Bool {
        generation == token
    }
}
