import CryptoKit
import Darwin
import Foundation
@testable import PocketVoice
import XCTest

final class WhisperModelStoreTests: XCTestCase {
    func testValidImportIsPrivateVerifiedAndDiscoverable() async throws {
        let fixture = try makeFixture(data: Data("hello".utf8))
        defer { fixture.remove() }
        let store = WhisperModelStore(
            rootDirectory: fixture.storeRoot,
            descriptor: fixture.descriptor
        )

        let installed = try await store.installLocalFile(at: fixture.source)

        XCTAssertEqual(installed.url, fixture.installed)
        XCTAssertEqual(try Data(contentsOf: installed.url), fixture.data)
        XCTAssertEqual(try permissions(at: fixture.storeRoot), 0o700)
        XCTAssertEqual(try permissions(at: installed.url), 0o400)
        XCTAssertEqual(
            try installed.url.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup,
            true
        )
        try installed.revalidate()
        let verified = try await store.verifyInstalledModel()
        XCTAssertEqual(verified, installed)
        try assertNoPartialFiles(in: fixture.storeRoot)
    }

    func testWrongNameUnderSizeOverSizeAndDigestAreRejectedWithoutCanonicalFile() async throws {
        let valid = Data("hello".utf8)

        do {
            let fixture = try makeFixture(data: valid, sourceName: "renamed.bin")
            defer { fixture.remove() }
            let store = WhisperModelStore(rootDirectory: fixture.storeRoot, descriptor: fixture.descriptor)
            await assertStoreError(.sourceNameMismatch) {
                _ = try await store.installLocalFile(at: fixture.source)
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.installed.path))
        }

        do {
            let fixture = try makeFixture(data: Data("hell".utf8), descriptorData: valid)
            defer { fixture.remove() }
            let store = WhisperModelStore(rootDirectory: fixture.storeRoot, descriptor: fixture.descriptor)
            await assertStoreError(.byteCountMismatch) {
                _ = try await store.installLocalFile(at: fixture.source)
            }
            try assertNoCanonicalOrPartialFiles(fixture)
        }

        do {
            let fixture = try makeFixture(data: Data("helloo".utf8), descriptorData: valid)
            defer { fixture.remove() }
            let store = WhisperModelStore(rootDirectory: fixture.storeRoot, descriptor: fixture.descriptor)
            await assertStoreError(.byteCountMismatch) {
                _ = try await store.installLocalFile(at: fixture.source)
            }
            try assertNoCanonicalOrPartialFiles(fixture)
        }

        do {
            let fixture = try makeFixture(data: Data("jello".utf8), descriptorData: valid)
            defer { fixture.remove() }
            let store = WhisperModelStore(rootDirectory: fixture.storeRoot, descriptor: fixture.descriptor)
            await assertStoreError(.digestMismatch) {
                _ = try await store.installLocalFile(at: fixture.source)
            }
            try assertNoCanonicalOrPartialFiles(fixture)
        }
    }

    func testSourceSymlinkDirectoryAndFIFOAreRejected() async throws {
        let fixture = try makeFixture(data: Data("hello".utf8))
        defer { fixture.remove() }
        try FileManager.default.removeItem(at: fixture.source)
        let target = fixture.base.appendingPathComponent("payload.bin")
        try fixture.data.write(to: target)
        try FileManager.default.createSymbolicLink(at: fixture.source, withDestinationURL: target)
        let symlinkStore = WhisperModelStore(
            rootDirectory: fixture.storeRoot,
            descriptor: fixture.descriptor
        )

        await assertStoreError(.sourceNotRegularFile) {
            _ = try await symlinkStore.installLocalFile(at: fixture.source)
        }
        try assertNoCanonicalOrPartialFiles(fixture)

        try FileManager.default.removeItem(at: fixture.source)
        try FileManager.default.createDirectory(at: fixture.source, withIntermediateDirectories: false)
        let directoryStore = WhisperModelStore(
            rootDirectory: fixture.storeRoot,
            descriptor: fixture.descriptor
        )
        await assertStoreError(.sourceNotRegularFile) {
            _ = try await directoryStore.installLocalFile(at: fixture.source)
        }
        try assertNoCanonicalOrPartialFiles(fixture)

        try FileManager.default.removeItem(at: fixture.source)
        let fifoResult = fixture.source.path.withCString { Darwin.mkfifo($0, 0o600) }
        XCTAssertEqual(fifoResult, 0)
        let fifoStore = WhisperModelStore(
            rootDirectory: fixture.storeRoot,
            descriptor: fixture.descriptor
        )
        await assertStoreError(.sourceNotRegularFile) {
            _ = try await fifoStore.installLocalFile(at: fixture.source)
        }
        try assertNoCanonicalOrPartialFiles(fixture)

        XCTAssertThrowsError(
            try WhisperModelVerifier().verify(fixture.source, against: fixture.descriptor)
        ) { error in
            XCTAssertEqual(error as? VoiceError, .modelVerificationFailed)
        }
    }

    func testSymlinkStoreRootCannotEscapePrivateDirectory() async throws {
        let fixture = try makeFixture(data: Data("hello".utf8))
        defer { fixture.remove() }
        let outside = fixture.base.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(
            at: fixture.storeRoot,
            withDestinationURL: outside
        )
        let store = WhisperModelStore(rootDirectory: fixture.storeRoot, descriptor: fixture.descriptor)

        await assertStoreError(.invalidStoreURL) {
            _ = try await store.installLocalFile(at: fixture.source)
        }

        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
    }

    func testInvalidReplacementPreservesPriorBytesAndInode() async throws {
        let fixture = try makeFixture(data: Data("hello".utf8))
        defer { fixture.remove() }
        let store = WhisperModelStore(rootDirectory: fixture.storeRoot, descriptor: fixture.descriptor)
        _ = try await store.installLocalFile(at: fixture.source)
        let inodeBefore = try inode(at: fixture.installed)

        try Data("jello".utf8).write(to: fixture.source, options: .atomic)
        await assertStoreError(.digestMismatch) {
            _ = try await store.installLocalFile(at: fixture.source)
        }

        XCTAssertEqual(try Data(contentsOf: fixture.installed), fixture.data)
        XCTAssertEqual(try inode(at: fixture.installed), inodeBefore)
        try assertNoPartialFiles(in: fixture.storeRoot)
    }

    func testValidReimportIsIdempotentAndKeepsInode() async throws {
        let fixture = try makeFixture(data: Data("hello".utf8))
        defer { fixture.remove() }
        let store = WhisperModelStore(rootDirectory: fixture.storeRoot, descriptor: fixture.descriptor)
        let first = try await store.installLocalFile(at: fixture.source)
        let inodeBefore = try inode(at: first.url)

        let second = try await store.installLocalFile(at: fixture.source)

        XCTAssertEqual(second, first)
        XCTAssertEqual(try inode(at: second.url), inodeBefore)
        try assertNoPartialFiles(in: fixture.storeRoot)
    }

    func testDestinationSymlinkIsReplacedWithoutTouchingItsTarget() async throws {
        let fixture = try makeFixture(data: Data("hello".utf8))
        defer { fixture.remove() }
        let outside = fixture.base.appendingPathComponent("outside.bin")
        try Data("outside".utf8).write(to: outside)
        try FileManager.default.createDirectory(at: fixture.storeRoot, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(
            at: fixture.installed,
            withDestinationURL: outside
        )
        let store = WhisperModelStore(rootDirectory: fixture.storeRoot, descriptor: fixture.descriptor)

        _ = try await store.installLocalFile(at: fixture.source)

        XCTAssertEqual(try Data(contentsOf: outside), Data("outside".utf8))
        XCTAssertEqual(try Data(contentsOf: fixture.installed), fixture.data)
        XCTAssertEqual(
            try fixture.installed.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink,
            false
        )
    }

    func testSourcePathMutationDuringImportIsRejectedAndCleaned() async throws {
        let fixture = try makeFixture(data: Data("hello".utf8))
        defer { fixture.remove() }
        let initialStore = WhisperModelStore(
            rootDirectory: fixture.storeRoot,
            descriptor: fixture.descriptor
        )
        _ = try await initialStore.installLocalFile(at: fixture.source)
        let inodeBefore = try inode(at: fixture.installed)
        let source = fixture.source
        let mutationErrors = LockedErrorBox()
        let store = WhisperModelStore(
            rootDirectory: fixture.storeRoot,
            descriptor: fixture.descriptor,
            hooks: .init(
                didOpenSource: {},
                didCopyChunk: { _ in },
                didFinishCopy: {
                    do {
                        try Data("jello".utf8).write(to: source, options: .atomic)
                    } catch {
                        mutationErrors.store(error)
                    }
                }
            )
        )

        await assertStoreError(.sourceChangedDuringImport) {
            _ = try await store.installLocalFile(at: fixture.source)
        }

        try mutationErrors.rethrowIfPresent()
        XCTAssertEqual(try Data(contentsOf: fixture.installed), fixture.data)
        XCTAssertEqual(try inode(at: fixture.installed), inodeBefore)
        try assertNoPartialFiles(in: fixture.storeRoot)
    }

    func testMidCopyCancellationRemovesPrivatePartial() async throws {
        let data = Data(repeating: 0x61, count: 2_200_000)
        let fixture = try makeFixture(data: data)
        defer { fixture.remove() }
        let store = WhisperModelStore(
            rootDirectory: fixture.storeRoot,
            descriptor: fixture.descriptor,
            hooks: .init(
                didOpenSource: {},
                didCopyChunk: { _ in
                    withUnsafeCurrentTask { task in task?.cancel() }
                },
                didFinishCopy: {}
            )
        )

        await assertStoreError(.cancelled) {
            _ = try await store.installLocalFile(at: fixture.source)
        }

        try assertNoCanonicalOrPartialFiles(fixture)
    }

    func testCallerCancellationPreservesPriorModelReleasesLeaseAndAllowsRetry() async throws {
        let data = Data(repeating: 0x61, count: 2_200_000)
        let fixture = try makeFixture(data: data)
        defer { fixture.remove() }
        let initialStore = WhisperModelStore(
            rootDirectory: fixture.storeRoot,
            descriptor: fixture.descriptor
        )
        _ = try await initialStore.installLocalFile(at: fixture.source)
        let inodeBefore = try inode(at: fixture.installed)
        let gate = OneShotGate()
        let store = WhisperModelStore(
            rootDirectory: fixture.storeRoot,
            descriptor: fixture.descriptor,
            hooks: .init(
                didOpenSource: { gate.blockOnce() },
                didCopyChunk: { _ in },
                didFinishCopy: {}
            )
        )
        let source = fixture.source
        let importTask = Task {
            try await store.installLocalFile(at: source)
        }
        guard await gate.waitUntilBlocked() else {
            gate.release()
            importTask.cancel()
            _ = try? await importTask.value
            XCTFail("import did not reach the deterministic cancellation gate")
            return
        }

        importTask.cancel()
        gate.release()
        do {
            _ = try await importTask.value
            XCTFail("cancelled import unexpectedly succeeded")
        } catch {
            XCTAssertEqual(error as? WhisperModelStoreError, .cancelled)
        }
        XCTAssertEqual(try Data(contentsOf: fixture.installed), fixture.data)
        XCTAssertEqual(try inode(at: fixture.installed), inodeBefore)
        try assertNoPartialFiles(in: fixture.storeRoot)

        let retried = try await store.installLocalFile(at: source)
        try retried.revalidate()
        XCTAssertEqual(try inode(at: retried.url), inodeBefore)
    }

    func testConcurrentStoreInstancesCannotOwnTheSameCommitter() async throws {
        let fixture = try makeFixture(data: Data("hello".utf8))
        defer { fixture.remove() }
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let firstStore = WhisperModelStore(
            rootDirectory: fixture.storeRoot,
            descriptor: fixture.descriptor,
            hooks: .init(
                didOpenSource: {
                    entered.signal()
                    release.wait()
                },
                didCopyChunk: { _ in },
                didFinishCopy: {}
            )
        )
        let secondStore = WhisperModelStore(
            rootDirectory: fixture.storeRoot,
            descriptor: fixture.descriptor
        )
        let first = Task {
            try await firstStore.installLocalFile(at: fixture.source)
        }
        let didEnter = await Task.detached {
            entered.wait(timeout: .now() + 5) == .success
        }.value
        guard didEnter else {
            release.signal()
            first.cancel()
            _ = try? await first.value
            XCTFail("first transaction did not reach the deterministic gate")
            return
        }

        await assertStoreError(.installationInProgress) {
            _ = try await secondStore.installLocalFile(at: fixture.source)
        }
        release.signal()
        let installed = try await first.value
        try installed.revalidate()
        try assertNoPartialFiles(in: fixture.storeRoot)
    }

    func testVerificationCannotStraddleAnotherStoreCommit() async throws {
        let fixture = try makeFixture(data: Data("hello".utf8))
        defer { fixture.remove() }
        let initialStore = WhisperModelStore(
            rootDirectory: fixture.storeRoot,
            descriptor: fixture.descriptor
        )
        _ = try await initialStore.installLocalFile(at: fixture.source)
        let gate = OneShotGate()
        let importingStore = WhisperModelStore(
            rootDirectory: fixture.storeRoot,
            descriptor: fixture.descriptor,
            hooks: .init(
                didOpenSource: { gate.blockOnce() },
                didCopyChunk: { _ in },
                didFinishCopy: {}
            )
        )
        let verifyingStore = WhisperModelStore(
            rootDirectory: fixture.storeRoot,
            descriptor: fixture.descriptor
        )
        let source = fixture.source
        let importTask = Task {
            try await importingStore.installLocalFile(at: source)
        }
        guard await gate.waitUntilBlocked() else {
            gate.release()
            importTask.cancel()
            _ = try? await importTask.value
            XCTFail("import did not reach the deterministic verification gate")
            return
        }

        await assertStoreError(.installationInProgress) {
            _ = try await verifyingStore.verifyInstalledModel()
        }
        gate.release()
        let installed = try await importTask.value
        try installed.revalidate()
    }

    func testRootReplacementDuringImportCannotEscapeOrReturnStaleURL() async throws {
        let fixture = try makeFixture(data: Data("hello".utf8))
        defer { fixture.remove() }
        let movedRoot = fixture.base.appendingPathComponent("moved-PocketModels", isDirectory: true)
        let outside = fixture.base.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
        let mutationErrors = LockedErrorBox()
        let storeRoot = fixture.storeRoot
        let store = WhisperModelStore(
            rootDirectory: storeRoot,
            descriptor: fixture.descriptor,
            hooks: .init(
                didOpenSource: {
                    do {
                        try FileManager.default.moveItem(at: storeRoot, to: movedRoot)
                        try FileManager.default.createSymbolicLink(
                            at: storeRoot,
                            withDestinationURL: outside
                        )
                    } catch {
                        mutationErrors.store(error)
                    }
                },
                didCopyChunk: { _ in },
                didFinishCopy: {}
            )
        )

        await assertStoreError(.invalidStoreURL) {
            _ = try await store.installLocalFile(at: fixture.source)
        }

        try mutationErrors.rethrowIfPresent()
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
        try assertNoPartialFiles(in: movedRoot)
        XCTAssertFalse(FileManager.default.fileExists(atPath: movedRoot.appendingPathComponent("model.bin").path))
    }

    func testInstalledTokenRejectsSameByteInodeReplacement() async throws {
        let fixture = try makeFixture(data: Data("hello".utf8))
        defer { fixture.remove() }
        let store = WhisperModelStore(rootDirectory: fixture.storeRoot, descriptor: fixture.descriptor)
        let installed = try await store.installLocalFile(at: fixture.source)
        let replacement = fixture.storeRoot.appendingPathComponent("replacement.bin")
        try fixture.data.write(to: replacement)

        _ = try FileManager.default.replaceItemAt(installed.url, withItemAt: replacement)

        XCTAssertThrowsError(try installed.revalidate()) { error in
            XCTAssertEqual(error as? VoiceError, .modelVerificationFailed)
        }
    }

    func testMissingInstalledModelAndRevalidationErrorsAreSanitized() async throws {
        let fixture = try makeFixture(data: Data("hello".utf8))
        defer { fixture.remove() }
        let store = WhisperModelStore(
            rootDirectory: fixture.storeRoot,
            descriptor: fixture.descriptor
        )

        do {
            _ = try await store.verifyInstalledModel()
            XCTFail("missing model unexpectedly verified")
        } catch {
            XCTAssertEqual(error as? WhisperModelStoreError, .notInstalled)
            XCTAssertFalse(error.localizedDescription.contains(fixture.base.path))
        }

        let installed = try await store.installLocalFile(at: fixture.source)
        try FileManager.default.removeItem(at: installed.url)
        do {
            try installed.revalidate()
            XCTFail("removed installed model unexpectedly revalidated")
        } catch {
            XCTAssertEqual(error as? VoiceError, .modelVerificationFailed)
            XCTAssertFalse(error.localizedDescription.contains(fixture.base.path))
        }
    }

    func testDescriptorRejectsUnsafeCanonicalFilenames() throws {
        let unsafeNames = [
            "../model.bin",
            "folder\\model.bin",
            ".",
            "..",
            "model\n.bin",
            String(repeating: "a", count: 129) + ".bin"
        ]
        for fileName in unsafeNames {
            XCTAssertThrowsError(
                try WhisperModelDescriptor(
                    identifier: "test",
                    fileName: fileName,
                    sha256: sha256(Data("hello".utf8)),
                    byteCount: 5
                ),
                "must reject \(String(reflecting: fileName))"
            )
        }
    }

    func testDescriptorDecodingCannotBypassValidation() throws {
        let digest = String(repeating: "a", count: 64)
        let invalid = """
        {"identifier":"test","fileName":"../model.bin","sha256":"\(digest)","byteCount":5}
        """

        XCTAssertThrowsError(
            try JSONDecoder().decode(
                WhisperModelDescriptor.self,
                from: try XCTUnwrap(invalid.data(using: .utf8))
            )
        )
    }

    func testDescriptorCodableRoundTripPreservesValidatedValue() throws {
        let descriptor = try WhisperModelDescriptor(
            identifier: "test-model",
            fileName: "model.bin",
            sha256: String(repeating: "a", count: 64),
            byteCount: 5
        )

        let encoded = try JSONEncoder().encode(descriptor)

        XCTAssertEqual(
            try JSONDecoder().decode(WhisperModelDescriptor.self, from: encoded),
            descriptor
        )
    }

    private func assertStoreError(
        _ expected: WhisperModelStoreError,
        operation: () async throws -> Void
    ) async {
        do {
            try await operation()
            XCTFail("expected \(expected)")
        } catch {
            XCTAssertEqual(error as? WhisperModelStoreError, expected)
        }
    }

    private func assertNoCanonicalOrPartialFiles(_ fixture: Fixture) throws {
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.installed.path))
        if FileManager.default.fileExists(atPath: fixture.storeRoot.path) {
            try assertNoPartialFiles(in: fixture.storeRoot)
        }
    }

    private func assertNoPartialFiles(in directory: URL) throws {
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertFalse(names.contains(where: { $0.hasSuffix(".partial") }), "\(names)")
    }

    private func permissions(at url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }

    private func inode(at url: URL) throws -> UInt64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return try XCTUnwrap(attributes[.systemFileNumber] as? NSNumber).uint64Value
    }

    private func makeFixture(
        data: Data,
        descriptorData: Data? = nil,
        sourceName: String = "model.bin"
    ) throws -> Fixture {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let sourceDirectory = base.appendingPathComponent("source", isDirectory: true)
        let storeRoot = base.appendingPathComponent(
            WhisperModelStore.defaultDirectoryName,
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: sourceDirectory,
            withIntermediateDirectories: true
        )
        let source = sourceDirectory.appendingPathComponent(sourceName, isDirectory: false)
        try data.write(to: source)
        let pinned = descriptorData ?? data
        let descriptor = try WhisperModelDescriptor(
            identifier: "test-model",
            fileName: "model.bin",
            sha256: sha256(pinned),
            byteCount: Int64(pinned.count)
        )
        return Fixture(
            base: base,
            source: source,
            storeRoot: storeRoot,
            installed: storeRoot.appendingPathComponent(descriptor.fileName),
            descriptor: descriptor,
            data: pinned
        )
    }

    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

private struct Fixture: Sendable {
    let base: URL
    let source: URL
    let storeRoot: URL
    let installed: URL
    let descriptor: WhisperModelDescriptor
    let data: Data

    func remove() {
        try? FileManager.default.removeItem(at: base)
    }
}

private final class OneShotGate: @unchecked Sendable {
    private let lock = NSLock()
    private let entered = DispatchSemaphore(value: 0)
    private let releaseSemaphore = DispatchSemaphore(value: 0)
    private var hasBlocked = false

    func blockOnce() {
        lock.lock()
        let shouldBlock = !hasBlocked
        hasBlocked = true
        lock.unlock()
        guard shouldBlock else { return }
        entered.signal()
        releaseSemaphore.wait()
    }

    func waitUntilBlocked() async -> Bool {
        await Task.detached {
            self.entered.wait(timeout: .now() + 5) == .success
        }.value
    }

    func release() {
        releaseSemaphore.signal()
    }
}

private final class LockedErrorBox: @unchecked Sendable {
    private let lock = NSLock()
    private var error: Error?

    func store(_ error: Error) {
        lock.lock()
        if self.error == nil {
            self.error = error
        }
        lock.unlock()
    }

    func rethrowIfPresent() throws {
        lock.lock()
        let captured = error
        lock.unlock()
        if let captured { throw captured }
    }
}
