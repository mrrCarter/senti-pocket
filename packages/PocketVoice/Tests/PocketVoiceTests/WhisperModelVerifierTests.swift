import Foundation
@testable import PocketVoice
import XCTest

final class WhisperModelVerifierTests: XCTestCase {
    func testBaseEnglishDescriptorMatchesPinnedArtifact() {
        XCTAssertEqual(WhisperModelDescriptor.baseEnglish.identifier, "whisper-base.en")
        XCTAssertEqual(WhisperModelDescriptor.baseEnglish.fileName, "ggml-base.en.bin")
        XCTAssertEqual(WhisperModelDescriptor.baseEnglish.byteCount, 147_964_211)
        XCTAssertEqual(
            WhisperModelDescriptor.baseEnglish.sha256,
            "a03779c86df3323075f5e796cb2ce5029f00ec8869eee3fdfb897afe36c6d002"
        )
    }

    func testVerifierAcceptsExactDigestSizeAndName() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let model = root.appendingPathComponent("model.bin")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("hello".utf8).write(to: model)
        defer { try? FileManager.default.removeItem(at: root) }

        let descriptor = try WhisperModelDescriptor(
            identifier: "test",
            fileName: "model.bin",
            sha256: "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824",
            byteCount: 5
        )

        let verified = try WhisperModelVerifier().verify(model, against: descriptor)
        XCTAssertEqual(verified.url, model)
        XCTAssertEqual(verified.modelBytes, Data("hello".utf8))
    }

    func testVerifiedModelRejectsSameBytesAtReplacedFileIdentity() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let model = root.appendingPathComponent("model.bin")
        let replacement = root.appendingPathComponent("replacement.bin")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("hello".utf8).write(to: model)
        try Data("hello".utf8).write(to: replacement)
        defer { try? FileManager.default.removeItem(at: root) }

        let descriptor = try WhisperModelDescriptor(
            identifier: "test",
            fileName: "model.bin",
            sha256: "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824",
            byteCount: 5
        )
        let verified = try WhisperModelVerifier().verify(model, against: descriptor)

        _ = try FileManager.default.replaceItemAt(model, withItemAt: replacement)

        XCTAssertThrowsError(try verified.revalidate()) { error in
            XCTAssertEqual(error as? VoiceError, .modelVerificationFailed)
        }
    }

    func testVerifiedModelRetainsTheExactBytesAfterTheSourcePathChanges() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let model = root.appendingPathComponent("model.bin")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("hello".utf8).write(to: model)
        defer { try? FileManager.default.removeItem(at: root) }

        let descriptor = try WhisperModelDescriptor(
            identifier: "test",
            fileName: "model.bin",
            sha256: "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824",
            byteCount: 5
        )
        let verified = try WhisperModelVerifier().verify(model, against: descriptor)

        try Data("other".utf8).write(to: model)

        XCTAssertEqual(verified.modelBytes, Data("hello".utf8))
    }

    func testVerifierRejectsDigestMismatch() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let model = root.appendingPathComponent("model.bin")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("hello".utf8).write(to: model)
        defer { try? FileManager.default.removeItem(at: root) }

        let descriptor = try WhisperModelDescriptor(
            identifier: "test",
            fileName: "model.bin",
            sha256: String(repeating: "0", count: 64),
            byteCount: 5
        )

        XCTAssertThrowsError(try WhisperModelVerifier().verify(model, against: descriptor)) { error in
            XCTAssertEqual(error as? VoiceError, .modelVerificationFailed)
        }
    }
}
