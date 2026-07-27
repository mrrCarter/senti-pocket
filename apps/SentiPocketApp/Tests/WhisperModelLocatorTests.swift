import XCTest
@testable import SentiPocketApp

/// Unit tests for the DIALS capture-path model resolver (option A). Cover the graceful-degrade + selection logic
/// deterministically with small temp files; the real 147.9MB-model positive path is Mac/device-verified separately
/// (headless sims can't exercise mic capture, and a 147MB fixture in-suite is wasteful).
final class WhisperModelLocatorTests: XCTestCase {
    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("wml-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func writeFile(_ url: URL, byteCount: Int) throws {
        try Data(count: byteCount).write(to: url)
    }

    func test_firstUsable_returns_nil_when_no_candidate_exists() throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let missing = dir.appendingPathComponent("ggml-base.en.bin")
        XCTAssertNil(WhisperModelLocator.firstUsable(in: [missing], expectedByteCount: 1024))
    }

    func test_firstUsable_skips_wrong_size_and_returns_the_exact_match() throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let wrong = dir.appendingPathComponent("wrong.bin"); try writeFile(wrong, byteCount: 512)   // partial/truncated
        let right = dir.appendingPathComponent("right.bin"); try writeFile(right, byteCount: 1024)  // exact
        XCTAssertEqual(WhisperModelLocator.firstUsable(in: [wrong, right], expectedByteCount: 1024), right)
    }

    func test_firstUsable_rejects_a_symlink_even_when_its_target_size_matches() throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let real = dir.appendingPathComponent("real.bin"); try writeFile(real, byteCount: 1024)
        let link = dir.appendingPathComponent("link.bin")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        // No indirection to an unverified target — a symlink of the right size is still rejected.
        XCTAssertNil(WhisperModelLocator.firstUsable(in: [link], expectedByteCount: 1024))
    }

    func test_resolve_returns_nil_when_the_model_is_not_provisioned() {
        // Fresh test host: no side-loaded model at Application Support, no bundled resource → graceful degrade (nil),
        // i.e. exactly the old `modelURL: nil` behavior — a missing model never crashes or blocks a dial.
        XCTAssertNil(WhisperModelLocator.resolve())
    }

    func test_pinned_constants_match_the_fetched_verified_model() {
        // Byte-exact to the model fetched + sha256-verified on MacinCloud (a03779c8…6d002, 147_964_211 bytes),
        // which equals PocketVoice.WhisperModelDescriptor.baseEnglish.
        XCTAssertEqual(WhisperModelLocator.modelFileName, "ggml-base.en.bin")
        XCTAssertEqual(WhisperModelLocator.expectedByteCount, 147_964_211)
    }
}
