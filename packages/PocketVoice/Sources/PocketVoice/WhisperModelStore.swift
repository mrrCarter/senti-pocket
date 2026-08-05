import Darwin
import Foundation

/// A lightweight, revalidatable handle to a model installed by WhisperModelStore.
///
/// Unlike VerifiedWhisperModel, this value never retains the model's 148 MB byte snapshot.
/// Loading remains fail-closed: the recognizer performs its own full verification before handing
/// bytes to whisper.cpp.
public struct InstalledWhisperModel: Equatable, Sendable {
    public let url: URL
    public let descriptor: WhisperModelDescriptor
    private let fileIdentity: WhisperFileIdentity

    init(url: URL, descriptor: WhisperModelDescriptor, fileIdentity: WhisperFileIdentity) {
        self.url = url
        self.descriptor = descriptor
        self.fileIdentity = fileIdentity
    }

    /// Re-hash the installed file and require the same filesystem object observed at installation.
    func revalidate() throws {
        let current = try WhisperModelVerifier.verifyFile(url, against: descriptor)
        guard current == fileIdentity else {
            throw VoiceError.modelVerificationFailed
        }
    }
}

/// Sanitized import failures. Cases deliberately carry no selected-file or container paths.
public enum WhisperModelStoreError: Error, Equatable, Sendable {
    case invalidStoreURL
    case invalidSourceURL
    case sourceNameMismatch
    case sourceRequiresLocalCopy
    case sourceNotRegularFile
    case sourceUnavailable
    case byteCountMismatch
    case digestMismatch
    case sourceChangedDuringImport
    case notInstalled
    case storageUnavailable
    case storagePolicyFailed
    case commitFailed
    case installationInProgress
    case cancelled
}

extension WhisperModelStoreError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidStoreURL:
            return "The private speech-model store is unavailable"
        case .invalidSourceURL:
            return "Choose a local speech-model file"
        case .sourceNameMismatch:
            return "The selected speech-model filename is not the pinned filename"
        case .sourceRequiresLocalCopy:
            return "Import a downloaded local copy of the speech model"
        case .sourceNotRegularFile:
            return "The selected speech model must be a regular file"
        case .sourceUnavailable:
            return "The selected speech-model file could not be read"
        case .byteCountMismatch:
            return "The selected speech model has the wrong size"
        case .digestMismatch:
            return "The selected speech model failed integrity verification"
        case .sourceChangedDuringImport:
            return "The selected speech model changed during import"
        case .notInstalled:
            return "The speech model is not installed"
        case .storageUnavailable:
            return "Private speech-model storage is unavailable"
        case .storagePolicyFailed:
            return "The speech model could not be protected on this device"
        case .commitFailed:
            return "The verified speech model could not be installed"
        case .installationInProgress:
            return "A speech-model import is already in progress"
        case .cancelled:
            return "Speech-model import was cancelled"
        }
    }
}

/// Serializes one user-initiated, local-only model import for one pinned descriptor.
///
/// The store owns no downloader or network client and never logs source or destination paths.
/// Its caller must provide an already-materialized local copy. The store copies through a
/// same-directory private staging inode, verifies the staged bytes, and exposes them with one
/// atomic rename. Readers therefore see either the prior canonical file or the complete new file.
public actor WhisperModelStore {
    public static let defaultDirectoryName = "PocketModels"

    public nonisolated let rootDirectory: URL
    public nonisolated let descriptor: WhisperModelDescriptor

    private let hooks: Hooks
    private var activeTransactionID: UUID?

    /// Creates the production store at the app-private Application Support location.
    public init(descriptor: WhisperModelDescriptor = .baseEnglish) throws {
        rootDirectory = try Self.applicationSupportRoot().standardizedFileURL
        self.descriptor = descriptor
        hooks = .production
    }

    /// Root injection is intentionally internal so production callers cannot redirect durable
    /// model bytes outside the app-private container. Tests use it for isolated fixtures.
    init(
        rootDirectory: URL,
        descriptor: WhisperModelDescriptor
    ) {
        self.rootDirectory = rootDirectory.standardizedFileURL
        self.descriptor = descriptor
        hooks = .production
    }

    init(
        rootDirectory: URL,
        descriptor: WhisperModelDescriptor,
        hooks: Hooks
    ) {
        self.rootDirectory = rootDirectory.standardizedFileURL
        self.descriptor = descriptor
        self.hooks = hooks
    }

    /// Canonical directory matching SentiPocketApp's existing WhisperModelLocator.
    public static func applicationSupportRoot() throws -> URL {
        do {
            return try FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            ).appendingPathComponent(defaultDirectoryName, isDirectory: true)
        } catch {
            throw WhisperModelStoreError.storageUnavailable
        }
    }

    public nonisolated func installedURL() -> URL {
        rootDirectory.appendingPathComponent(descriptor.fileName, isDirectory: false)
    }

    /// Fully verifies the current canonical file without retaining its contents in memory.
    public func verifyInstalledModel() async throws -> InstalledWhisperModel {
        let root = rootDirectory
        let pinned = descriptor
        let worker = Task.detached(priority: .userInitiated) {
            try Transaction.verifyInstalled(rootDirectory: root, descriptor: pinned)
        }
        return try await withTaskCancellationHandler(
            operation: {
                do {
                    return try await worker.value
                } catch is CancellationError {
                    throw WhisperModelStoreError.cancelled
                }
            },
            onCancel: {
                worker.cancel()
            }
        )
    }

    /// Imports a user-selected local file. A second import is refused while the detached bounded
    /// copy is active; actor reentrancy cannot create two committers for the same canonical leaf.
    public func installLocalFile(at sourceURL: URL) async throws -> InstalledWhisperModel {
        guard activeTransactionID == nil else {
            throw WhisperModelStoreError.installationInProgress
        }
        let transactionID = UUID()
        activeTransactionID = transactionID
        defer {
            if activeTransactionID == transactionID {
                activeTransactionID = nil
            }
        }

        let root = rootDirectory
        let pinned = descriptor
        let transactionHooks = hooks
        let worker = Task.detached(priority: .userInitiated) {
            try await Transaction.install(
                sourceURL: sourceURL,
                rootDirectory: root,
                descriptor: pinned,
                hooks: transactionHooks
            )
        }

        return try await withTaskCancellationHandler(
            operation: {
                do {
                    return try await worker.value
                } catch is CancellationError {
                    throw WhisperModelStoreError.cancelled
                }
            },
            onCancel: {
                worker.cancel()
            }
        )
    }
}

extension WhisperModelStore {
    struct Hooks: Sendable {
        let didOpenSource: @Sendable () -> Void
        let didCopyChunk: @Sendable (Int64) -> Void
        let didFinishCopy: @Sendable () -> Void

        static let production = Hooks(
            didOpenSource: {},
            didCopyChunk: { _ in },
            didFinishCopy: {}
        )
    }

    private enum Transaction {
        private static let chunkByteCount = 1_048_576
        private static let directoryMode: mode_t = 0o700
        private static let stagingMode: mode_t = 0o600
        private static let installedMode: mode_t = 0o400

        static func install(
            sourceURL: URL,
            rootDirectory: URL,
            descriptor: WhisperModelDescriptor,
            hooks: Hooks
        ) async throws -> InstalledWhisperModel {
            try checkCancellation()
            guard sourceURL.isFileURL else {
                throw WhisperModelStoreError.invalidSourceURL
            }
            guard sourceURL.lastPathComponent == descriptor.fileName else {
                throw WhisperModelStoreError.sourceNameMismatch
            }
            let directory = try openPrivateDirectory(rootDirectory, create: true)
            defer {
                _ = Darwin.close(directory.root)
                _ = Darwin.close(directory.parent)
            }
            try applyDirectoryPolicy(to: rootDirectory, directory: directory)
            let transactionLease = try acquireTransactionLock(in: directory.root)
            defer { releaseTransactionLock(transactionLease) }

            let canonicalURL = rootDirectory.appendingPathComponent(
                descriptor.fileName,
                isDirectory: false
            )
            let stagingLeaf = ".whisper-import-\(UUID().uuidString).partial"
            let stagingURL = rootDirectory.appendingPathComponent(stagingLeaf, isDirectory: false)

            var stagingFD: Int32 = -1
            var stagingExists = false
            defer {
                if stagingFD >= 0 {
                    _ = Darwin.close(stagingFD)
                }
                if stagingExists {
                    _ = stagingLeaf.withCString { leaf in
                        Darwin.unlinkat(directory.root, leaf, 0)
                    }
                }
            }

            stagingFD = try createStagingFile(in: directory.root, named: stagingLeaf)
            stagingExists = true

            let didAccessSecurityScope = sourceURL.startAccessingSecurityScopedResource()
            defer {
                if didAccessSecurityScope {
                    sourceURL.stopAccessingSecurityScopedResource()
                }
            }
            try requireLocallyMaterializedSource(sourceURL)

            try await coordinatedCopy(
                sourceURL: sourceURL,
                stagingFD: stagingFD,
                descriptor: descriptor,
                hooks: hooks
            )
            try synchronize(stagingFD)

            let stagedIdentity: WhisperFileIdentity
            do {
                stagedIdentity = try WhisperModelVerifier.verifyFileDescriptor(
                    stagingFD,
                    against: descriptor
                )
            } catch VoiceError.cancelled {
                throw WhisperModelStoreError.cancelled
            } catch {
                throw WhisperModelStoreError.digestMismatch
            }
            try applyInstalledPolicy(
                to: stagingURL,
                named: stagingLeaf,
                fileDescriptor: stagingFD,
                rootDirectory: rootDirectory,
                directory: directory
            )
            try synchronize(stagingFD)
            try checkCancellation()

            if let existing = try? verifiedInstalledModel(
                at: canonicalURL,
                named: descriptor.fileName,
                rootDirectory: rootDirectory,
                directory: directory,
                descriptor: descriptor,
                requirePolicy: true
            ) {
                return existing
            }

            try checkCancellation()
            try requireAnchoredFile(
                stagingFD,
                at: stagingURL,
                named: stagingLeaf,
                rootDirectory: rootDirectory,
                directory: directory
            )
            guard atomicRename(
                in: directory.root,
                source: stagingLeaf,
                destination: descriptor.fileName
            ) else {
                throw WhisperModelStoreError.commitFailed
            }
            stagingExists = false
            return InstalledWhisperModel(
                url: canonicalURL,
                descriptor: descriptor,
                fileIdentity: stagedIdentity
            )
        }

        static func verifyInstalled(
            rootDirectory: URL,
            descriptor: WhisperModelDescriptor
        ) throws -> InstalledWhisperModel {
            let directory = try openPrivateDirectory(rootDirectory, create: false)
            defer {
                _ = Darwin.close(directory.root)
                _ = Darwin.close(directory.parent)
            }
            try requireDirectoryPolicy(at: rootDirectory, directory: directory)
            let transactionLease = try acquireTransactionLock(in: directory.root)
            defer { releaseTransactionLock(transactionLease) }
            let canonicalURL = rootDirectory.appendingPathComponent(
                descriptor.fileName,
                isDirectory: false
            )
            return try verifiedInstalledModel(
                at: canonicalURL,
                named: descriptor.fileName,
                rootDirectory: rootDirectory,
                directory: directory,
                descriptor: descriptor,
                requirePolicy: true
            )
        }

        private static func verifiedInstalledModel(
            at url: URL,
            named leaf: String,
            rootDirectory: URL,
            directory: DirectoryDescriptors,
            descriptor: WhisperModelDescriptor,
            requirePolicy: Bool
        ) throws -> InstalledWhisperModel {
            let fileDescriptor = leaf.withCString { name in
                Darwin.openat(
                    directory.root,
                    name,
                    O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
                )
            }
            guard fileDescriptor >= 0 else {
                if errno == ENOENT {
                    throw WhisperModelStoreError.notInstalled
                }
                throw WhisperModelStoreError.digestMismatch
            }
            defer { _ = Darwin.close(fileDescriptor) }
            let identity: WhisperFileIdentity
            do {
                identity = try WhisperModelVerifier.verifyFileDescriptor(
                    fileDescriptor,
                    against: descriptor
                )
            } catch VoiceError.cancelled {
                throw WhisperModelStoreError.cancelled
            } catch {
                throw WhisperModelStoreError.digestMismatch
            }
            if requirePolicy {
                try requireInstalledPolicy(
                    at: url,
                    named: leaf,
                    fileDescriptor: fileDescriptor,
                    rootDirectory: rootDirectory,
                    directory: directory
                )
            }
            return InstalledWhisperModel(
                url: url,
                descriptor: descriptor,
                fileIdentity: identity
            )
        }

        private static func validateStoreURL(_ rootDirectory: URL) throws {
            guard rootDirectory.isFileURL,
                  !rootDirectory.path.isEmpty,
                  rootDirectory.path != "/",
                  rootDirectory.lastPathComponent == WhisperModelStore.defaultDirectoryName else {
                throw WhisperModelStoreError.invalidStoreURL
            }
        }

        private static func openPrivateDirectory(
            _ rootDirectory: URL,
            create: Bool
        ) throws -> DirectoryDescriptors {
            try validateStoreURL(rootDirectory)
            let parentURL = rootDirectory.deletingLastPathComponent()
            let parent = try withFileSystemPath(parentURL) { path in
                Darwin.open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            }
            guard parent >= 0 else {
                throw WhisperModelStoreError.invalidStoreURL
            }
            var shouldCloseParent = true
            defer {
                if shouldCloseParent { _ = Darwin.close(parent) }
            }
            let parentStatus = try descriptorIdentity(parent)
            guard parentStatus.isDirectory, parentStatus.isOwnedByProcess else {
                throw WhisperModelStoreError.invalidStoreURL
            }

            let rootLeaf = rootDirectory.lastPathComponent
            if create {
                let result = rootLeaf.withCString { leaf in
                    Darwin.mkdirat(parent, leaf, directoryMode)
                }
                guard result == 0 || errno == EEXIST else {
                    throw WhisperModelStoreError.storageUnavailable
                }
            }
            let root = rootLeaf.withCString { leaf in
                Darwin.openat(
                    parent,
                    leaf,
                    O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
                )
            }
            guard root >= 0 else {
                if !create, errno == ENOENT {
                    throw WhisperModelStoreError.notInstalled
                }
                throw WhisperModelStoreError.invalidStoreURL
            }
            var shouldCloseRoot = true
            defer {
                if shouldCloseRoot { _ = Darwin.close(root) }
            }
            let directory = DirectoryDescriptors(parent: parent, root: root)
            let rootStatus = try descriptorIdentity(root)
            guard rootStatus.isDirectory, rootStatus.isOwnedByProcess else {
                throw WhisperModelStoreError.invalidStoreURL
            }
            try requireDirectoryAnchor(rootDirectory, directory: directory)
            shouldCloseRoot = false
            shouldCloseParent = false
            return directory
        }

        private static func applyDirectoryPolicy(
            to rootDirectory: URL,
            directory: DirectoryDescriptors
        ) throws {
            try requireDirectoryAnchor(rootDirectory, directory: directory)
            guard Darwin.fchmod(directory.root, directoryMode) == 0 else {
                throw WhisperModelStoreError.storagePolicyFailed
            }
            try requireDirectoryAnchor(rootDirectory, directory: directory)
            #if os(iOS)
            do {
                try FileManager.default.setAttributes(
                    [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                    ofItemAtPath: rootDirectory.path
                )
            } catch {
                throw WhisperModelStoreError.storagePolicyFailed
            }
            try requireDirectoryAnchor(rootDirectory, directory: directory)
            #endif
            try excludeFromBackup(rootDirectory)
            try requireDirectoryPolicy(at: rootDirectory, directory: directory)
        }

        private static func requireDirectoryPolicy(
            at rootDirectory: URL,
            directory: DirectoryDescriptors
        ) throws {
            try requireDirectoryAnchor(rootDirectory, directory: directory)
            let status = try descriptorIdentity(directory.root)
            guard status.isDirectory,
                  status.isOwnedByProcess,
                  permissions(status.mode) == directoryMode else {
                throw WhisperModelStoreError.storagePolicyFailed
            }
            do {
                let values = try rootDirectory.resourceValues(forKeys: [.isExcludedFromBackupKey])
                guard values.isExcludedFromBackup == true else {
                    throw WhisperModelStoreError.storagePolicyFailed
                }
            } catch let error as WhisperModelStoreError {
                throw error
            } catch {
                throw WhisperModelStoreError.storagePolicyFailed
            }
            try requireDirectoryAnchor(rootDirectory, directory: directory)
            #if os(iOS)
            do {
                let attributes = try FileManager.default.attributesOfItem(atPath: rootDirectory.path)
                guard let protection = attributes[.protectionKey] as? FileProtectionType,
                      protection == .completeUntilFirstUserAuthentication else {
                    throw WhisperModelStoreError.storagePolicyFailed
                }
            } catch let error as WhisperModelStoreError {
                throw error
            } catch {
                throw WhisperModelStoreError.storagePolicyFailed
            }
            try requireDirectoryAnchor(rootDirectory, directory: directory)
            #endif
        }

        private static func createStagingFile(in root: Int32, named leaf: String) throws -> Int32 {
            let descriptor = leaf.withCString { name in
                Darwin.openat(
                    root,
                    name,
                    O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                    stagingMode
                )
            }
            guard descriptor >= 0 else {
                throw WhisperModelStoreError.storageUnavailable
            }
            var shouldUnlink = true
            defer {
                if shouldUnlink {
                    _ = Darwin.close(descriptor)
                    _ = leaf.withCString { Darwin.unlinkat(root, $0, 0) }
                }
            }
            guard Darwin.fchmod(descriptor, stagingMode) == 0,
                  try requireOwnedRegularFile(descriptor, in: root, named: leaf) else {
                throw WhisperModelStoreError.storagePolicyFailed
            }
            shouldUnlink = false
            return descriptor
        }

        /// POSIX record locks are process-associated, so the in-memory registry serializes actors
        /// in this process while F_SETLK serializes other processes and is released after a crash.
        private static func acquireTransactionLock(in root: Int32) throws -> TransactionLease {
            let rootIdentity = try descriptorIdentity(root, failure: .storageUnavailable)
            let key = DirectoryIdentityKey(
                deviceNumber: rootIdentity.deviceNumber,
                fileNumber: rootIdentity.fileNumber
            )
            guard ProcessTransactionRegistry.shared.acquire(key) else {
                throw WhisperModelStoreError.installationInProgress
            }
            var descriptor: Int32 = -1
            var hasAdvisoryLock = false
            var shouldCleanUp = true
            defer {
                if shouldCleanUp {
                    if hasAdvisoryLock {
                        _ = configureAdvisoryLock(descriptor, type: Int16(F_UNLCK))
                    }
                    if descriptor >= 0 { _ = Darwin.close(descriptor) }
                    ProcessTransactionRegistry.shared.release(key)
                }
            }

            let lockLeaf = ".whisper-model-store.lock"
            descriptor = lockLeaf.withCString { name in
                Darwin.openat(
                    root,
                    name,
                    O_RDWR | O_CREAT | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC,
                    stagingMode
                )
            }
            guard descriptor >= 0 else {
                throw WhisperModelStoreError.storageUnavailable
            }
            guard try requireOwnedRegularFile(descriptor, in: root, named: lockLeaf) else {
                throw WhisperModelStoreError.storageUnavailable
            }
            guard Darwin.fchmod(descriptor, stagingMode) == 0 else {
                throw WhisperModelStoreError.storagePolicyFailed
            }
            guard try requireOwnedRegularFile(descriptor, in: root, named: lockLeaf) else {
                throw WhisperModelStoreError.storageUnavailable
            }
            guard configureAdvisoryLock(descriptor, type: Int16(F_WRLCK)) == 0 else {
                let lockError = errno
                if lockError == EACCES || lockError == EAGAIN {
                    throw WhisperModelStoreError.installationInProgress
                }
                throw WhisperModelStoreError.storageUnavailable
            }
            hasAdvisoryLock = true
            guard try requireOwnedRegularFile(descriptor, in: root, named: lockLeaf) else {
                throw WhisperModelStoreError.storageUnavailable
            }
            shouldCleanUp = false
            return TransactionLease(descriptor: descriptor, key: key)
        }

        private static func releaseTransactionLock(_ lease: TransactionLease) {
            _ = configureAdvisoryLock(lease.descriptor, type: Int16(F_UNLCK))
            _ = Darwin.close(lease.descriptor)
            ProcessTransactionRegistry.shared.release(lease.key)
        }

        private static func configureAdvisoryLock(_ descriptor: Int32, type: Int16) -> Int32 {
            var request = flock()
            request.l_start = 0
            request.l_len = 0
            request.l_pid = 0
            request.l_type = type
            request.l_whence = Int16(SEEK_SET)
            while true {
                let result = withUnsafeMutablePointer(to: &request) { pointer in
                    Darwin.fcntl(descriptor, F_SETLK, pointer)
                }
                if result == 0 || errno != EINTR { return result }
            }
        }

        private static func coordinatedCopy(
            sourceURL: URL,
            stagingFD: Int32,
            descriptor: WhisperModelDescriptor,
            hooks: Hooks
        ) async throws {
            let state = CoordinationState()
            try await withTaskCancellationHandler(
                operation: {
                    var coordinationError: NSError?
                    state.coordinator.coordinate(
                        readingItemAt: sourceURL,
                        options: [.withoutChanges],
                        error: &coordinationError
                    ) { coordinatedURL in
                        state.store(Result {
                            try copy(
                                coordinatedSourceURL: coordinatedURL,
                                stagingFD: stagingFD,
                                descriptor: descriptor,
                                hooks: hooks
                            )
                        })
                    }
                    if let copyResult = state.load() {
                        try copyResult.get()
                        return
                    }
                    if Task.isCancelled || isUserCancellation(coordinationError) {
                        throw WhisperModelStoreError.cancelled
                    }
                    throw WhisperModelStoreError.sourceUnavailable
                },
                onCancel: {
                    state.coordinator.cancel()
                }
            )
        }

        private static func isUserCancellation(_ error: NSError?) -> Bool {
            guard let error else { return false }
            return error.domain == NSCocoaErrorDomain
                && error.code == CocoaError.Code.userCancelled.rawValue
        }

        private static func requireLocallyMaterializedSource(_ sourceURL: URL) throws {
            do {
                let values = try sourceURL.resourceValues(forKeys: [.isUbiquitousItemKey])
                guard values.isUbiquitousItem != true else {
                    throw WhisperModelStoreError.sourceRequiresLocalCopy
                }
            } catch let error as WhisperModelStoreError {
                throw error
            } catch {
                throw WhisperModelStoreError.sourceUnavailable
            }
        }

        private static func copy(
            coordinatedSourceURL: URL,
            stagingFD: Int32,
            descriptor: WhisperModelDescriptor,
            hooks: Hooks
        ) throws {
            let pathIdentityBefore: POSIXFileIdentity
            do {
                guard let identity = try pathIdentity(coordinatedSourceURL) else {
                    throw WhisperModelStoreError.sourceUnavailable
                }
                pathIdentityBefore = identity
            } catch let error as WhisperModelStoreError {
                throw error
            } catch {
                throw WhisperModelStoreError.sourceUnavailable
            }
            guard pathIdentityBefore.isRegularFile else {
                throw WhisperModelStoreError.sourceNotRegularFile
            }
            guard pathIdentityBefore.byteCount == descriptor.byteCount else {
                throw WhisperModelStoreError.byteCountMismatch
            }

            let sourceFD = try withFileSystemPath(coordinatedSourceURL) { path in
                Darwin.open(path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
            }
            guard sourceFD >= 0 else {
                if errno == ELOOP {
                    throw WhisperModelStoreError.sourceNotRegularFile
                }
                throw WhisperModelStoreError.sourceUnavailable
            }
            defer { _ = Darwin.close(sourceFD) }

            let descriptorIdentityBefore = try descriptorIdentity(sourceFD)
            guard descriptorIdentityBefore == pathIdentityBefore else {
                throw WhisperModelStoreError.sourceChangedDuringImport
            }
            hooks.didOpenSource()
            try checkCancellation()

            var buffer = [UInt8](repeating: 0, count: chunkByteCount)
            var observedByteCount: Int64 = 0
            while true {
                try checkCancellation()
                let count = try readChunk(sourceFD, into: &buffer)
                if count == 0 { break }
                observedByteCount += Int64(count)
                guard observedByteCount <= descriptor.byteCount else {
                    throw WhisperModelStoreError.byteCountMismatch
                }
                try writeAll(stagingFD, bytes: buffer, count: count)
                hooks.didCopyChunk(observedByteCount)
                try checkCancellation()
            }
            guard observedByteCount == descriptor.byteCount else {
                throw WhisperModelStoreError.byteCountMismatch
            }

            hooks.didFinishCopy()
            let descriptorIdentityAfter = try descriptorIdentity(sourceFD)
            let pathIdentityAfter = try pathIdentity(coordinatedSourceURL)
            guard descriptorIdentityAfter == descriptorIdentityBefore,
                  pathIdentityAfter == pathIdentityBefore else {
                throw WhisperModelStoreError.sourceChangedDuringImport
            }
        }

        private static func applyInstalledPolicy(
            to url: URL,
            named leaf: String,
            fileDescriptor: Int32,
            rootDirectory: URL,
            directory: DirectoryDescriptors
        ) throws {
            guard try requireOwnedRegularFile(fileDescriptor, in: directory.root, named: leaf) else {
                throw WhisperModelStoreError.storagePolicyFailed
            }
            try requireDirectoryAnchor(rootDirectory, directory: directory)
            #if os(iOS)
            do {
                try FileManager.default.setAttributes(
                    [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                    ofItemAtPath: url.path
                )
            } catch {
                throw WhisperModelStoreError.storagePolicyFailed
            }
            try requireAnchoredFile(
                fileDescriptor,
                at: url,
                named: leaf,
                rootDirectory: rootDirectory,
                directory: directory
            )
            #endif
            try excludeFromBackup(url)
            try requireAnchoredFile(
                fileDescriptor,
                at: url,
                named: leaf,
                rootDirectory: rootDirectory,
                directory: directory
            )
            guard Darwin.fchmod(fileDescriptor, installedMode) == 0 else {
                throw WhisperModelStoreError.storagePolicyFailed
            }
            try requireInstalledPolicy(
                at: url,
                named: leaf,
                fileDescriptor: fileDescriptor,
                rootDirectory: rootDirectory,
                directory: directory
            )
        }

        private static func requireInstalledPolicy(
            at url: URL,
            named leaf: String,
            fileDescriptor: Int32,
            rootDirectory: URL,
            directory: DirectoryDescriptors
        ) throws {
            try requireAnchoredFile(
                fileDescriptor,
                at: url,
                named: leaf,
                rootDirectory: rootDirectory,
                directory: directory
            )
            let status = try descriptorIdentity(fileDescriptor)
            guard status.isOwnedRegularFile,
                  permissions(status.mode) == installedMode else {
                throw WhisperModelStoreError.storagePolicyFailed
            }
            do {
                let values = try url.resourceValues(forKeys: [.isExcludedFromBackupKey])
                guard values.isExcludedFromBackup == true else {
                    throw WhisperModelStoreError.storagePolicyFailed
                }
            } catch let error as WhisperModelStoreError {
                throw error
            } catch {
                throw WhisperModelStoreError.storagePolicyFailed
            }
            try requireAnchoredFile(
                fileDescriptor,
                at: url,
                named: leaf,
                rootDirectory: rootDirectory,
                directory: directory
            )
            #if os(iOS)
            do {
                let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
                guard let protection = attributes[.protectionKey] as? FileProtectionType,
                      protection == .completeUntilFirstUserAuthentication else {
                    throw WhisperModelStoreError.storagePolicyFailed
                }
            } catch let error as WhisperModelStoreError {
                throw error
            } catch {
                throw WhisperModelStoreError.storagePolicyFailed
            }
            try requireAnchoredFile(
                fileDescriptor,
                at: url,
                named: leaf,
                rootDirectory: rootDirectory,
                directory: directory
            )
            #endif
        }

        private static func excludeFromBackup(_ url: URL) throws {
            var mutableURL = url
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            do {
                try mutableURL.setResourceValues(values)
            } catch {
                throw WhisperModelStoreError.storagePolicyFailed
            }
        }

        private static func atomicRename(
            in root: Int32,
            source: String,
            destination: String
        ) -> Bool {
            source.withCString { sourceLeaf in
                destination.withCString { destinationLeaf in
                    Darwin.renameat(root, sourceLeaf, root, destinationLeaf) == 0
                }
            }
        }

        private static func synchronize(_ descriptor: Int32) throws {
            while Darwin.fsync(descriptor) != 0 {
                if errno == EINTR { continue }
                throw WhisperModelStoreError.storageUnavailable
            }
        }

        private static func readChunk(_ descriptor: Int32, into buffer: inout [UInt8]) throws -> Int {
            while true {
                let count = buffer.withUnsafeMutableBytes {
                    Darwin.read(descriptor, $0.baseAddress, $0.count)
                }
                if count >= 0 { return count }
                if errno == EINTR { continue }
                throw WhisperModelStoreError.sourceUnavailable
            }
        }

        private static func writeAll(
            _ descriptor: Int32,
            bytes: [UInt8],
            count: Int
        ) throws {
            try bytes.withUnsafeBytes { rawBuffer in
                guard let baseAddress = rawBuffer.baseAddress else {
                    throw WhisperModelStoreError.storageUnavailable
                }
                var offset = 0
                while offset < count {
                    let written = Darwin.write(
                        descriptor,
                        baseAddress.advanced(by: offset),
                        count - offset
                    )
                    if written > 0 {
                        offset += written
                    } else if written < 0, errno == EINTR {
                        continue
                    } else {
                        throw WhisperModelStoreError.storageUnavailable
                    }
                }
            }
        }

        private static func descriptorIdentity(
            _ descriptor: Int32,
            failure: WhisperModelStoreError = .sourceUnavailable
        ) throws -> POSIXFileIdentity {
            var status = stat()
            guard Darwin.fstat(descriptor, &status) == 0 else {
                throw failure
            }
            return POSIXFileIdentity(status)
        }

        private static func relativeIdentity(
            in directory: Int32,
            named leaf: String
        ) throws -> POSIXFileIdentity? {
            var status = stat()
            let result = leaf.withCString { name in
                Darwin.fstatat(directory, name, &status, AT_SYMLINK_NOFOLLOW)
            }
            if result == 0 { return POSIXFileIdentity(status) }
            if errno == ENOENT { return nil }
            throw WhisperModelStoreError.storageUnavailable
        }

        private static func requireDirectoryAnchor(
            _ rootDirectory: URL,
            directory: DirectoryDescriptors
        ) throws {
            let parentURL = rootDirectory.deletingLastPathComponent()
            let parentDescriptor = try descriptorIdentity(
                directory.parent,
                failure: .storageUnavailable
            )
            let rootDescriptor = try descriptorIdentity(
                directory.root,
                failure: .storageUnavailable
            )
            let parentPath = try pathIdentity(parentURL)
            let rootPath = try pathIdentity(rootDirectory)
            let rootEntry = try relativeIdentity(
                in: directory.parent,
                named: rootDirectory.lastPathComponent
            )
            guard parentPath == parentDescriptor,
                  rootPath == rootDescriptor,
                  rootEntry == rootDescriptor,
                  parentDescriptor.isDirectory,
                  rootDescriptor.isDirectory else {
                throw WhisperModelStoreError.invalidStoreURL
            }
        }

        @discardableResult
        private static func requireOwnedRegularFile(
            _ fileDescriptor: Int32,
            in directory: Int32,
            named leaf: String
        ) throws -> Bool {
            let descriptor = try descriptorIdentity(
                fileDescriptor,
                failure: .storageUnavailable
            )
            let entry = try relativeIdentity(in: directory, named: leaf)
            return descriptor == entry && descriptor.isOwnedRegularFile
        }

        private static func requireAnchoredFile(
            _ fileDescriptor: Int32,
            at url: URL,
            named leaf: String,
            rootDirectory: URL,
            directory: DirectoryDescriptors
        ) throws {
            try requireDirectoryAnchor(rootDirectory, directory: directory)
            let descriptor = try descriptorIdentity(
                fileDescriptor,
                failure: .storageUnavailable
            )
            let entry = try relativeIdentity(in: directory.root, named: leaf)
            let path = try pathIdentity(url)
            guard descriptor == entry,
                  descriptor == path,
                  descriptor.isOwnedRegularFile else {
                throw WhisperModelStoreError.storagePolicyFailed
            }
            try requireDirectoryAnchor(rootDirectory, directory: directory)
        }

        private static func pathIdentity(_ url: URL) throws -> POSIXFileIdentity? {
            guard let status = try pathStatus(url) else { return nil }
            return POSIXFileIdentity(status)
        }

        private static func pathStatus(_ url: URL) throws -> stat? {
            var status = stat()
            let result = try withFileSystemPath(url) { Darwin.lstat($0, &status) }
            if result == 0 { return status }
            if errno == ENOENT { return nil }
            throw WhisperModelStoreError.storageUnavailable
        }

        private static func permissions(_ mode: mode_t) -> mode_t {
            mode & mode_t(0o777)
        }

        private static func checkCancellation() throws {
            do {
                try Task.checkCancellation()
            } catch {
                throw WhisperModelStoreError.cancelled
            }
        }

        private static func withFileSystemPath<T>(
            _ url: URL,
            _ body: (UnsafePointer<CChar>) throws -> T
        ) throws -> T {
            let result = try url.withUnsafeFileSystemRepresentation { path -> T? in
                guard let path else { return nil }
                return try body(path)
            }
            guard let result else { throw WhisperModelStoreError.invalidSourceURL }
            return result
        }
    }

    private struct DirectoryDescriptors: Sendable {
        let parent: Int32
        let root: Int32
    }

    private struct DirectoryIdentityKey: Hashable, Sendable {
        let deviceNumber: UInt64
        let fileNumber: UInt64
    }

    private struct TransactionLease: Sendable {
        let descriptor: Int32
        let key: DirectoryIdentityKey
    }

    private final class ProcessTransactionRegistry: @unchecked Sendable {
        static let shared = ProcessTransactionRegistry()

        private let lock = NSLock()
        private var activeDirectories: Set<DirectoryIdentityKey> = []

        func acquire(_ key: DirectoryIdentityKey) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            return activeDirectories.insert(key).inserted
        }

        func release(_ key: DirectoryIdentityKey) {
            lock.lock()
            activeDirectories.remove(key)
            lock.unlock()
        }
    }

    private final class CoordinationState: @unchecked Sendable {
        let coordinator = NSFileCoordinator(filePresenter: nil)
        private let lock = NSLock()
        private var result: Result<Void, Error>?

        func store(_ result: Result<Void, Error>) {
            lock.lock()
            self.result = result
            lock.unlock()
        }

        func load() -> Result<Void, Error>? {
            lock.lock()
            defer { lock.unlock() }
            return result
        }
    }

    private struct POSIXFileIdentity: Equatable, Sendable {
        let deviceNumber: UInt64
        let fileNumber: UInt64
        let byteCount: Int64
        let modifiedSeconds: Int64
        let modifiedNanoseconds: Int64
        let changedSeconds: Int64
        let changedNanoseconds: Int64
        let mode: mode_t
        let owner: uid_t
        let linkCount: UInt64

        init(_ status: stat) {
            deviceNumber = UInt64(status.st_dev)
            fileNumber = UInt64(status.st_ino)
            byteCount = Int64(status.st_size)
            modifiedSeconds = Int64(status.st_mtimespec.tv_sec)
            modifiedNanoseconds = Int64(status.st_mtimespec.tv_nsec)
            changedSeconds = Int64(status.st_ctimespec.tv_sec)
            changedNanoseconds = Int64(status.st_ctimespec.tv_nsec)
            mode = status.st_mode
            owner = status.st_uid
            linkCount = UInt64(status.st_nlink)
        }

        var isRegularFile: Bool {
            (mode & mode_t(S_IFMT)) == mode_t(S_IFREG)
        }

        var isDirectory: Bool {
            (mode & mode_t(S_IFMT)) == mode_t(S_IFDIR)
        }

        var isOwnedByProcess: Bool {
            owner == Darwin.geteuid()
        }

        var isOwnedRegularFile: Bool {
            isRegularFile && isOwnedByProcess && linkCount == 1
        }
    }
}
