import Foundation

/// Resolves the on-device Whisper STT model (`ggml-base.en.bin`) URL for the DIALS capture path (`listen()`).
///
/// WHY THIS EXISTS (option A, durable Whisper — Carter's call for the 8hr demo): `LiveDialVoice` takes a
/// `modelURL: URL?` and, when it's nil, `ensureModel()` returns false → `listen()` returns "" → the phone can
/// BRIEF but can't CAPTURE the dictated reply → nothing writes back. There was no provisioner in-tree
/// (`ModelArtifactStore` is the `.litertlm` reasoning-model store, NOT Whisper), so `DialHost.run` passed nil.
/// This locator supplies the URL: the app resolves a side-loaded / bundled `ggml-base.en.bin`, and
/// `WhisperCPPRecognizer.prepareModel(at:)` does the AUTHORITATIVE SHA-256 verify downstream.
///
/// GRACEFUL DEGRADE PRESERVED: when the model isn't provisioned yet, `resolve()` returns nil — identical to the
/// old `modelURL: nil` behavior (brief-only, no capture), so a missing model never crashes or blocks a dial.
///
/// The filename + byteCount are LITERALS mirroring `PocketVoice.WhisperModelDescriptor.baseEnglish` on purpose:
/// the app target links PocketVoice only transitively (via PocketDialVoice), so we avoid a direct `import
/// PocketVoice` here. The values are pinned + asserted byte-exact against a fetched model (sha256
/// a03779c8…6d002, 147_964_211 bytes) — the downstream verifier is the source of truth for integrity.
enum WhisperModelLocator {
    /// == `WhisperModelDescriptor.baseEnglish.fileName`.
    static let modelFileName = "ggml-base.en.bin"
    /// == `WhisperModelDescriptor.baseEnglish.byteCount` (verified byte-exact against the fetched model).
    static let expectedByteCount: Int64 = 147_964_211

    /// Canonical side-load location: `<Application Support>/PocketModels/ggml-base.en.bin`. A provisioner (or a
    /// one-time manual side-load for the demo) drops the verified `.bin` here; this is where `resolve()` looks first.
    static func installDirectory(_ fileManager: FileManager = .default) -> URL? {
        try? fileManager.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
            .appendingPathComponent("PocketModels", isDirectory: true)
    }

    /// The full install path for the model (side-load target). Nil only if Application Support can't be located.
    static func installedModelURL(_ fileManager: FileManager = .default) -> URL? {
        installDirectory(fileManager)?.appendingPathComponent(modelFileName, isDirectory: false)
    }

    /// Resolve a usable model URL, or nil if not provisioned. Searches the App Support install dir first, then the
    /// app bundle (if shipped as a resource). Returns the FIRST candidate that passes the cheap size/type gate;
    /// `prepareModel(at:)` then does the full SHA-256 verify.
    static func resolve(fileManager: FileManager = .default, bundle: Bundle = .main) -> URL? {
        var candidates: [URL] = []
        if let installed = installedModelURL(fileManager) { candidates.append(installed) }
        if let bundled = bundle.url(forResource: "ggml-base.en", withExtension: "bin") { candidates.append(bundled) }
        return firstUsable(in: candidates, expectedByteCount: expectedByteCount, fileManager: fileManager)
    }

    /// Testable core: the first candidate that is a REGULAR (non-symlink) file of EXACTLY `expectedByteCount` bytes.
    /// A wrong-size or partial download is skipped (the full download is atomic elsewhere; this just won't hand a
    /// truncated file to the recognizer). Symlinks are rejected (no indirection to an unverified target).
    static func firstUsable(in candidates: [URL], expectedByteCount: Int64, fileManager: FileManager = .default) -> URL? {
        for url in candidates {
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
                  values.isRegularFile == true,
                  values.isSymbolicLink != true,
                  let size = values.fileSize,
                  Int64(size) == expectedByteCount
            else { continue }
            return url
        }
        return nil
    }
}
