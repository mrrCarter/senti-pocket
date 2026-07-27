import XCTest
@testable import SentiPocketApp
import PocketVoice   // TEST-ONLY: assert the locator's pinned literals stay == WhisperModelDescriptor.baseEnglish

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

    func test_resolve_returns_nil_when_the_model_is_not_provisioned() throws {
        // HERMETIC (forge #114 nit): inject an EMPTY Application Support + a bundle with no ggml resource, so this
        // can't false-fail once a real 147MB model is side-loaded on the test host. Graceful degrade (nil) = exactly
        // the old `modelURL: nil` behavior — a missing model never crashes or blocks a dial.
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let fm = TempAppSupportFileManager(appSupport: dir)
        let noResourceBundle = Bundle(for: WhisperModelLocatorTests.self)   // test bundle: no ggml-base.en.bin
        XCTAssertNil(WhisperModelLocator.resolve(fileManager: fm, bundle: noResourceBundle))
    }

    func test_pinned_constants_match_the_whisper_descriptor() {
        // Drift-catcher (forge/warden #114 nit): the locator's literals MUST stay == PocketVoice's descriptor. If
        // baseEnglish is ever repointed, THIS fails — instead of the locator silently rejecting the new correct model
        // as wrong-size (→ brief-only degrade with green tests). The app target keeps the literals (no PocketVoice
        // import); only this test asserts the mirror.
        XCTAssertEqual(WhisperModelLocator.modelFileName, WhisperModelDescriptor.baseEnglish.fileName)
        XCTAssertEqual(WhisperModelLocator.expectedByteCount, WhisperModelDescriptor.baseEnglish.byteCount)
        // Still pinned to the known-good fetched + sha256-verified model (a03779c8…6d002, 147_964_211 bytes).
        XCTAssertEqual(WhisperModelLocator.expectedByteCount, 147_964_211)
    }
}

/// A FileManager whose Application Support directory is a caller-supplied temp dir, so `resolve()` can be tested
/// hermetically — with no dependence on the real test-host container (which could hold a side-loaded model).
private final class TempAppSupportFileManager: FileManager, @unchecked Sendable {
    private let appSupport: URL
    init(appSupport: URL) { self.appSupport = appSupport; super.init() }
    override func url(for directory: FileManager.SearchPathDirectory, in domain: FileManager.SearchPathDomainMask,
                      appropriateFor url: URL?, create shouldCreate: Bool) throws -> URL {
        if directory == .applicationSupportDirectory { return appSupport }
        return try super.url(for: directory, in: domain, appropriateFor: url, create: shouldCreate)
    }
}
