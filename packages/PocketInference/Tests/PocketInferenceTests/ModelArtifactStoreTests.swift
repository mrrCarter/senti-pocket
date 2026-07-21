import Foundation
@testable import PocketInference
import XCTest

final class ModelArtifactStoreTests: XCTestCase {
    func testInstallsOnlyDigestAndSizeMatchedArtifact() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let source = root.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("hello".utf8).write(to: source)
        defer { try? FileManager.default.removeItem(at: root) }

        let descriptor = try ModelDescriptor(
            identifier: "test-model",
            fileName: "test.litertlm",
            sha256: "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824",
            byteCount: 5
        )
        let store = ModelArtifactStore(rootDirectory: root.appendingPathComponent("models"))

        let installed = try await store.installLocalFile(at: source, descriptor: descriptor)

        XCTAssertEqual(try Data(contentsOf: installed.url), Data("hello".utf8))
        XCTAssertEqual(
            try installed.url.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup,
            true
        )
        let verifiedAgain = try await store.verifyInstalledModel(descriptor)
        XCTAssertEqual(verifiedAgain, installed)
    }

    func testRejectsDigestMismatch() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let source = root.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("hello".utf8).write(to: source)
        defer { try? FileManager.default.removeItem(at: root) }

        let descriptor = try ModelDescriptor(
            identifier: "test-model",
            fileName: "test.litertlm",
            sha256: String(repeating: "0", count: 64),
            byteCount: 5
        )
        let store = ModelArtifactStore(rootDirectory: root.appendingPathComponent("models"))

        do {
            _ = try await store.installLocalFile(at: source, descriptor: descriptor)
            XCTFail("Expected digest rejection")
        } catch {
            XCTAssertEqual(error as? ModelArtifactError, .digestMismatch)
        }
    }

    func testVerifiedArtifactRejectsSameBytesAtReplacedFileIdentity() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let source = root.appendingPathComponent("source")
        let replacement = root.appendingPathComponent("replacement")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("hello".utf8).write(to: source)
        try Data("hello".utf8).write(to: replacement)
        defer { try? FileManager.default.removeItem(at: root) }

        let descriptor = try ModelDescriptor(
            identifier: "test-model",
            fileName: "test.litertlm",
            sha256: "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824",
            byteCount: 5
        )
        let store = ModelArtifactStore(rootDirectory: root.appendingPathComponent("models"))
        let installed = try await store.installLocalFile(at: source, descriptor: descriptor)

        _ = try FileManager.default.replaceItemAt(installed.url, withItemAt: replacement)

        XCTAssertThrowsError(try installed.revalidate()) { error in
            XCTAssertEqual(error as? ModelArtifactError, .fileChangedAfterVerification)
        }
    }

    func testRuntimeSnapshotRetainsTheExactVerifiedBytesAfterInstalledPathChanges() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let source = root.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("hello".utf8).write(to: source)
        defer { try? FileManager.default.removeItem(at: root) }

        let descriptor = try ModelDescriptor(
            identifier: "test-model",
            fileName: "test.litertlm",
            sha256: "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824",
            byteCount: 5
        )
        let store = ModelArtifactStore(rootDirectory: root.appendingPathComponent("models"))
        let installed = try await store.installLocalFile(at: source, descriptor: descriptor)
        var snapshot: RuntimeModelSnapshot? = try installed.makeRuntimeSnapshot(
            in: root.appendingPathComponent("runtime")
        )
        let snapshotURL = try XCTUnwrap(snapshot?.url)
        let snapshotDirectory = snapshotURL.deletingLastPathComponent()

        try Data("other".utf8).write(to: installed.url)

        XCTAssertEqual(try Data(contentsOf: snapshotURL), Data("hello".utf8))
        XCTAssertEqual(snapshotURL.pathExtension, "litertlm")
        snapshot = nil
        XCTAssertFalse(FileManager.default.fileExists(atPath: snapshotDirectory.path))
    }

    func testDescriptorRejectsTraversalAndWrongExtension() {
        XCTAssertThrowsError(
            try ModelDescriptor(
                identifier: "model",
                fileName: "../model.litertlm",
                sha256: String(repeating: "0", count: 64),
                byteCount: 1
            )
        )
        XCTAssertThrowsError(
            try ModelDescriptor(
                identifier: "model",
                fileName: "model.bin",
                sha256: String(repeating: "0", count: 64),
                byteCount: 1
            )
        )
    }

    func testDownloadRequiresExplicitHostAllowlist() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let descriptor = try ModelDescriptor(
            identifier: "test-model",
            fileName: "test.litertlm",
            sha256: String(repeating: "0", count: 64),
            byteCount: 1
        )
        let store = ModelArtifactStore(rootDirectory: root)
        let sourceURL = try XCTUnwrap(URL(string: "https://models.example.com/test.litertlm"))

        do {
            _ = try await store.downloadAndInstall(
                from: sourceURL,
                descriptor: descriptor
            )
            XCTFail("Expected host allowlist rejection")
        } catch {
            XCTAssertEqual(error as? ModelArtifactError, .insecureTransport)
        }
    }
}
