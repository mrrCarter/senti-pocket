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
        let didEnter = await waitForSemaphore(entered, timeout: 5)
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

        let renameResult = replacement.path.withCString { replacementPath in
            installed.url.path.withCString { installedPath in
                Darwin.rename(replacementPath, installedPath)
            }
        }
        let renameError = errno
        guard renameResult == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(renameError))
        }

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

    func testInstallProgressIsMonotonicAndOrdered() async throws {
        let fixture = try makeFixture(data: Data("hello".utf8))
        defer { fixture.remove() }
        let events = LockedArrayBox<WhisperModelInstallProgress>()
        let store = WhisperModelStore(rootDirectory: fixture.storeRoot, descriptor: fixture.descriptor)

        let installed = try await store.installLocalFile(at: fixture.source) { event in
            events.append(event)
        }

        try installed.revalidate()
        let observed = events.snapshot()
        XCTAssertEqual(
            observed.first,
            .copying(completed: 0, total: Int64(fixture.data.count))
        )
        XCTAssertEqual(Array(observed.suffix(2)), [.verifying, .finishing])
        let copiedBytes = observed.compactMap { event -> Int64? in
            guard case let .copying(completed, total) = event else { return nil }
            XCTAssertEqual(total, Int64(fixture.data.count))
            return completed
        }
        XCTAssertEqual(copiedBytes, copiedBytes.sorted())
        XCTAssertEqual(copiedBytes.last, Int64(fixture.data.count))
    }

    func testFailedInstallDoesNotEmitFinishingProgress() async throws {
        let fixture = try makeFixture(
            data: Data("jello".utf8),
            descriptorData: Data("hello".utf8)
        )
        defer { fixture.remove() }
        let events = LockedArrayBox<WhisperModelInstallProgress>()
        let store = WhisperModelStore(rootDirectory: fixture.storeRoot, descriptor: fixture.descriptor)

        await assertStoreError(.digestMismatch) {
            _ = try await store.installLocalFile(at: fixture.source) { event in
                events.append(event)
            }
        }

        let observed = events.snapshot()
        XCTAssertEqual(observed.last, .verifying)
        XCTAssertFalse(observed.contains(.finishing))
        try assertNoCanonicalOrPartialFiles(fixture)
    }

    func testRemoveIsDurableIdempotentAndInvalidatesInstalledToken() async throws {
        let fixture = try makeFixture(data: Data("hello".utf8))
        defer { fixture.remove() }
        let syncCount = LockedCounter()
        let store = WhisperModelStore(
            rootDirectory: fixture.storeRoot,
            descriptor: fixture.descriptor,
            hooks: .init(
                didOpenSource: {},
                didCopyChunk: { _ in },
                didFinishCopy: {},
                didSynchronizeRemovalDirectory: { syncCount.increment() }
            )
        )
        let installed = try await store.installLocalFile(at: fixture.source)

        try await store.removeInstalledModel()

        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.installed.path))
        XCTAssertThrowsError(try installed.revalidate()) { error in
            XCTAssertEqual(error as? VoiceError, .modelVerificationFailed)
        }
        await assertStoreError(.notInstalled) {
            _ = try await store.verifyInstalledModel()
        }
        try await store.removeInstalledModel()
        XCTAssertEqual(syncCount.value(), 2)
        try assertNoPartialFiles(in: fixture.storeRoot)
    }

    func testMissingRemoveCreatesOnlyPrivateStoreAndSynchronizes() async throws {
        let fixture = try makeFixture(data: Data("hello".utf8))
        defer { fixture.remove() }
        let syncCount = LockedCounter()
        let store = WhisperModelStore(
            rootDirectory: fixture.storeRoot,
            descriptor: fixture.descriptor,
            hooks: .init(
                didOpenSource: {},
                didCopyChunk: { _ in },
                didFinishCopy: {},
                didSynchronizeRemovalDirectory: { syncCount.increment() }
            )
        )

        try await store.removeInstalledModel()
        try await store.removeInstalledModel()

        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.storeRoot.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.installed.path))
        XCTAssertEqual(try permissions(at: fixture.storeRoot), 0o700)
        XCTAssertEqual(
            try fixture.storeRoot.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup,
            true
        )
        XCTAssertEqual(syncCount.value(), 2)
        let names = try FileManager.default.contentsOfDirectory(atPath: fixture.storeRoot.path)
        XCTAssertEqual(names, [".whisper-model-store.lock"])
    }

    func testRemoveRecoversCorruptOwnedRegularCanonical() async throws {
        let fixture = try makeFixture(data: Data("hello".utf8))
        defer { fixture.remove() }
        let store = WhisperModelStore(rootDirectory: fixture.storeRoot, descriptor: fixture.descriptor)
        _ = try await store.installLocalFile(at: fixture.source)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: fixture.installed.path
        )
        try Data("jello".utf8).write(to: fixture.installed, options: [])
        var mutableInstalled = fixture.installed
        var values = URLResourceValues()
        values.isExcludedFromBackup = false
        try? mutableInstalled.setResourceValues(values)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o000],
            ofItemAtPath: fixture.installed.path
        )

        try await store.removeInstalledModel()

        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.installed.path))
    }

    func testRemoveRejectsSymlinkDirectoryFIFOAndHardLinkWithoutTouchingTargets() async throws {
        do {
            let fixture = try makeFixture(data: Data("hello".utf8))
            defer { fixture.remove() }
            try FileManager.default.createDirectory(at: fixture.storeRoot, withIntermediateDirectories: false)
            let outside = fixture.base.appendingPathComponent("outside.bin")
            try Data("outside".utf8).write(to: outside)
            try FileManager.default.createSymbolicLink(
                at: fixture.installed,
                withDestinationURL: outside
            )
            let store = WhisperModelStore(rootDirectory: fixture.storeRoot, descriptor: fixture.descriptor)

            await assertStoreError(.removalFailed) {
                try await store.removeInstalledModel()
            }
            XCTAssertEqual(try Data(contentsOf: outside), Data("outside".utf8))
            XCTAssertEqual(
                try fixture.installed.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink,
                true
            )
        }

        do {
            let fixture = try makeFixture(data: Data("hello".utf8))
            defer { fixture.remove() }
            try FileManager.default.createDirectory(at: fixture.storeRoot, withIntermediateDirectories: false)
            try FileManager.default.createDirectory(at: fixture.installed, withIntermediateDirectories: false)
            let store = WhisperModelStore(rootDirectory: fixture.storeRoot, descriptor: fixture.descriptor)

            await assertStoreError(.removalFailed) {
                try await store.removeInstalledModel()
            }
            var isDirectory: ObjCBool = false
            XCTAssertTrue(
                FileManager.default.fileExists(
                    atPath: fixture.installed.path,
                    isDirectory: &isDirectory
                )
            )
            XCTAssertTrue(isDirectory.boolValue)
        }

        do {
            let fixture = try makeFixture(data: Data("hello".utf8))
            defer { fixture.remove() }
            try FileManager.default.createDirectory(at: fixture.storeRoot, withIntermediateDirectories: false)
            XCTAssertEqual(fixture.installed.path.withCString { Darwin.mkfifo($0, 0o600) }, 0)
            let store = WhisperModelStore(rootDirectory: fixture.storeRoot, descriptor: fixture.descriptor)

            await assertStoreError(.removalFailed) {
                try await store.removeInstalledModel()
            }
            XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.installed.path))
        }

        do {
            let fixture = try makeFixture(data: Data("hello".utf8))
            defer { fixture.remove() }
            try FileManager.default.createDirectory(at: fixture.storeRoot, withIntermediateDirectories: false)
            let outside = fixture.base.appendingPathComponent("outside.bin")
            try Data("outside".utf8).write(to: outside)
            let linkResult = outside.path.withCString { outsidePath in
                fixture.installed.path.withCString { installedPath in
                    Darwin.link(outsidePath, installedPath)
                }
            }
            XCTAssertEqual(linkResult, 0)
            let store = WhisperModelStore(rootDirectory: fixture.storeRoot, descriptor: fixture.descriptor)

            await assertStoreError(.removalFailed) {
                try await store.removeInstalledModel()
            }
            XCTAssertEqual(try Data(contentsOf: outside), Data("outside".utf8))
            XCTAssertEqual(try inode(at: outside), try inode(at: fixture.installed))
        }
    }

    func testCanonicalRegularFileSwapBeforeUnlinkIsRejected() async throws {
        let fixture = try makeFixture(data: Data("hello".utf8))
        defer { fixture.remove() }
        let moved = fixture.storeRoot.appendingPathComponent("preserved.bin")
        let replacement = Data("replacement".utf8)
        let mutationErrors = LockedErrorBox()
        let store = WhisperModelStore(
            rootDirectory: fixture.storeRoot,
            descriptor: fixture.descriptor,
            hooks: .init(
                didOpenSource: {},
                didCopyChunk: { _ in },
                didFinishCopy: {},
                willRemoveCanonical: {
                    do {
                        try FileManager.default.moveItem(at: fixture.installed, to: moved)
                        try replacement.write(to: fixture.installed)
                    } catch {
                        mutationErrors.store(error)
                    }
                }
            )
        )
        _ = try await store.installLocalFile(at: fixture.source)

        await assertStoreError(.removalFailed) {
            try await store.removeInstalledModel()
        }

        try mutationErrors.rethrowIfPresent()
        XCTAssertEqual(try Data(contentsOf: moved), fixture.data)
        XCTAssertEqual(try Data(contentsOf: fixture.installed), replacement)
    }

    func testRootReplacementBeforeUnlinkCannotEscape() async throws {
        let fixture = try makeFixture(data: Data("hello".utf8))
        defer { fixture.remove() }
        let movedRoot = fixture.base.appendingPathComponent("moved-PocketModels", isDirectory: true)
        let outside = fixture.base.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
        let outsideModel = outside.appendingPathComponent(fixture.descriptor.fileName)
        try Data("outside".utf8).write(to: outsideModel)
        let mutationErrors = LockedErrorBox()
        let storeRoot = fixture.storeRoot
        let store = WhisperModelStore(
            rootDirectory: storeRoot,
            descriptor: fixture.descriptor,
            hooks: .init(
                didOpenSource: {},
                didCopyChunk: { _ in },
                didFinishCopy: {},
                willRemoveCanonical: {
                    do {
                        try FileManager.default.moveItem(at: storeRoot, to: movedRoot)
                        try FileManager.default.createSymbolicLink(
                            at: storeRoot,
                            withDestinationURL: outside
                        )
                    } catch {
                        mutationErrors.store(error)
                    }
                }
            )
        )
        _ = try await store.installLocalFile(at: fixture.source)

        await assertStoreError(.invalidStoreURL) {
            try await store.removeInstalledModel()
        }

        try mutationErrors.rethrowIfPresent()
        XCTAssertEqual(
            try Data(contentsOf: movedRoot.appendingPathComponent(fixture.descriptor.fileName)),
            fixture.data
        )
        XCTAssertEqual(try Data(contentsOf: outsideModel), Data("outside".utf8))
    }

    func testRemoveSerializesInstallVerifyAndAnotherRemove() async throws {
        let fixture = try makeFixture(data: Data("hello".utf8))
        defer { fixture.remove() }
        let gate = OneShotGate()
        let removingStore = WhisperModelStore(
            rootDirectory: fixture.storeRoot,
            descriptor: fixture.descriptor,
            hooks: .init(
                didOpenSource: {},
                didCopyChunk: { _ in },
                didFinishCopy: {},
                willRemoveCanonical: { gate.blockOnce() }
            )
        )
        let competingStore = WhisperModelStore(
            rootDirectory: fixture.storeRoot,
            descriptor: fixture.descriptor
        )
        _ = try await removingStore.installLocalFile(at: fixture.source)
        let removal = Task { try await removingStore.removeInstalledModel() }
        guard await gate.waitUntilBlocked() else {
            gate.release()
            removal.cancel()
            _ = try? await removal.value
            XCTFail("removal did not reach the deterministic lease gate")
            return
        }

        await assertStoreError(.installationInProgress) {
            try await competingStore.removeInstalledModel()
        }
        await assertStoreError(.installationInProgress) {
            _ = try await competingStore.verifyInstalledModel()
        }
        await assertStoreError(.installationInProgress) {
            _ = try await removingStore.installLocalFile(at: fixture.source)
        }

        gate.release()
        try await removal.value
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.installed.path))
    }

    func testCallerCancellationBeforeUnlinkPreservesModelAndReleasesLease() async throws {
        let fixture = try makeFixture(data: Data("hello".utf8))
        defer { fixture.remove() }
        let gate = OneShotGate()
        let store = WhisperModelStore(
            rootDirectory: fixture.storeRoot,
            descriptor: fixture.descriptor,
            hooks: .init(
                didOpenSource: {},
                didCopyChunk: { _ in },
                didFinishCopy: {},
                willRemoveCanonical: { gate.blockOnce() }
            )
        )
        _ = try await store.installLocalFile(at: fixture.source)
        let inodeBefore = try inode(at: fixture.installed)
        let removal = Task { try await store.removeInstalledModel() }
        guard await gate.waitUntilBlocked() else {
            gate.release()
            removal.cancel()
            _ = try? await removal.value
            XCTFail("removal did not reach the deterministic cancellation gate")
            return
        }

        removal.cancel()
        gate.release()
        do {
            try await removal.value
            XCTFail("cancelled removal unexpectedly succeeded")
        } catch {
            XCTAssertEqual(error as? WhisperModelStoreError, .cancelled)
        }
        XCTAssertEqual(try Data(contentsOf: fixture.installed), fixture.data)
        XCTAssertEqual(try inode(at: fixture.installed), inodeBefore)

        try await store.removeInstalledModel()
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.installed.path))
    }

    func testMissingRemoveSerializesWithFirstInstall() async throws {
        let fixture = try makeFixture(data: Data("hello".utf8))
        defer { fixture.remove() }
        let gate = OneShotGate()
        let removingStore = WhisperModelStore(
            rootDirectory: fixture.storeRoot,
            descriptor: fixture.descriptor,
            hooks: .init(
                didOpenSource: {},
                didCopyChunk: { _ in },
                didFinishCopy: {},
                didAcquireRemovalLease: { gate.blockOnce() }
            )
        )
        let competingStore = WhisperModelStore(
            rootDirectory: fixture.storeRoot,
            descriptor: fixture.descriptor
        )
        let removal = Task { try await removingStore.removeInstalledModel() }
        guard await gate.waitUntilBlocked() else {
            gate.release()
            removal.cancel()
            _ = try? await removal.value
            XCTFail("missing removal did not acquire the deterministic lease")
            return
        }

        await assertStoreError(.installationInProgress) {
            _ = try await competingStore.installLocalFile(at: fixture.source)
        }
        await assertStoreError(.installationInProgress) {
            try await competingStore.removeInstalledModel()
        }

        gate.release()
        try await removal.value
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.installed.path))
    }

    func testCancellationAfterUnlinkStillCommitsDurableRemoval() async throws {
        let fixture = try makeFixture(data: Data("hello".utf8))
        defer { fixture.remove() }
        let syncCount = LockedCounter()
        let store = WhisperModelStore(
            rootDirectory: fixture.storeRoot,
            descriptor: fixture.descriptor,
            hooks: .init(
                didOpenSource: {},
                didCopyChunk: { _ in },
                didFinishCopy: {},
                didUnlinkCanonical: {
                    withUnsafeCurrentTask { task in task?.cancel() }
                },
                didSynchronizeRemovalDirectory: { syncCount.increment() }
            )
        )
        _ = try await store.installLocalFile(at: fixture.source)

        try await store.removeInstalledModel()

        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.installed.path))
        XCTAssertEqual(syncCount.value(), 1)
    }

    func testFinalUnlinkENOENTStillSynchronizesAndSucceeds() async throws {
        let fixture = try makeFixture(data: Data("hello".utf8))
        defer { fixture.remove() }
        let mutationErrors = LockedErrorBox()
        let syncCount = LockedCounter()
        let store = WhisperModelStore(
            rootDirectory: fixture.storeRoot,
            descriptor: fixture.descriptor,
            hooks: .init(
                didOpenSource: {},
                didCopyChunk: { _ in },
                didFinishCopy: {},
                willUnlinkCanonical: {
                    do {
                        try FileManager.default.removeItem(at: fixture.installed)
                    } catch {
                        mutationErrors.store(error)
                    }
                },
                didSynchronizeRemovalDirectory: { syncCount.increment() }
            )
        )
        _ = try await store.installLocalFile(at: fixture.source)

        try await store.removeInstalledModel()

        try mutationErrors.rethrowIfPresent()
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.installed.path))
        XCTAssertEqual(syncCount.value(), 1)
    }

    func testLeafRecreatedAfterDirectorySyncCannotProduceFalseSuccess() async throws {
        let fixture = try makeFixture(data: Data("hello".utf8))
        defer { fixture.remove() }
        let mutationErrors = LockedErrorBox()
        let replacement = Data("replacement".utf8)
        let store = WhisperModelStore(
            rootDirectory: fixture.storeRoot,
            descriptor: fixture.descriptor,
            hooks: .init(
                didOpenSource: {},
                didCopyChunk: { _ in },
                didFinishCopy: {},
                didSynchronizeRemovalDirectory: {
                    do {
                        try replacement.write(to: fixture.installed)
                    } catch {
                        mutationErrors.store(error)
                    }
                }
            )
        )
        _ = try await store.installLocalFile(at: fixture.source)

        await assertStoreError(.removalFailed) {
            try await store.removeInstalledModel()
        }

        try mutationErrors.rethrowIfPresent()
        XCTAssertEqual(try Data(contentsOf: fixture.installed), replacement)
    }

    func testRootReplacementAfterDirectorySyncCannotEscapeOrSucceed() async throws {
        let fixture = try makeFixture(data: Data("hello".utf8))
        defer { fixture.remove() }
        let movedRoot = fixture.base.appendingPathComponent("moved-PocketModels", isDirectory: true)
        let outside = fixture.base.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
        let outsideModel = outside.appendingPathComponent(fixture.descriptor.fileName)
        try Data("outside".utf8).write(to: outsideModel)
        let mutationErrors = LockedErrorBox()
        let storeRoot = fixture.storeRoot
        let store = WhisperModelStore(
            rootDirectory: storeRoot,
            descriptor: fixture.descriptor,
            hooks: .init(
                didOpenSource: {},
                didCopyChunk: { _ in },
                didFinishCopy: {},
                didSynchronizeRemovalDirectory: {
                    do {
                        try FileManager.default.moveItem(at: storeRoot, to: movedRoot)
                        try FileManager.default.createSymbolicLink(
                            at: storeRoot,
                            withDestinationURL: outside
                        )
                    } catch {
                        mutationErrors.store(error)
                    }
                }
            )
        )
        _ = try await store.installLocalFile(at: fixture.source)

        await assertStoreError(.invalidStoreURL) {
            try await store.removeInstalledModel()
        }

        try mutationErrors.rethrowIfPresent()
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: movedRoot.appendingPathComponent(fixture.descriptor.fileName).path
            )
        )
        XCTAssertEqual(try Data(contentsOf: outsideModel), Data("outside".utf8))
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
        await waitForSemaphore(entered, timeout: 5)
    }

    func release() {
        releaseSemaphore.signal()
    }
}

private func waitForSemaphore(
    _ semaphore: DispatchSemaphore,
    timeout: TimeInterval
) async -> Bool {
    let deadline = DispatchTime.now() + timeout
    return await withCheckedContinuation { continuation in
        DispatchQueue.global(qos: .userInitiated).async {
            continuation.resume(returning: semaphore.wait(timeout: deadline) == .success)
        }
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

private final class LockedArrayBox<Element: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var elements: [Element] = []

    func append(_ element: Element) {
        lock.lock()
        elements.append(element)
        lock.unlock()
    }

    func snapshot() -> [Element] {
        lock.lock()
        let snapshot = elements
        lock.unlock()
        return snapshot
    }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }

    func value() -> Int {
        lock.lock()
        let snapshot = count
        lock.unlock()
        return snapshot
    }
}
