// OutboxStore — DURABLE offline write outbox (closes the B2 gap: the pending intent was in-memory only, so an
// offline write was LOST if the app was killed before reconnect). Persists the ONE pending {proposal, confirmation}
// to Application Support and reloads it on launch, so a governed write dictated + confirmed offline survives a kill
// and retries after reconnect. It stores an ALREADY-CONFIRMED intent only — the human already tapped Send; a retry
// resends the identical confirmed bytes (the gateway is idempotent by proposal id), so no re-consent is needed.
//
// Dates are epoch-millis (via safeEpochMillis) so the persisted proposal round-trips MILLISECOND-exact — the
// proposalHash stays valid when the gateway recomputes it on resend (same discipline as PocketWriteClient's wire).

import Darwin
import Foundation
import PocketContracts

/// A confirmed-but-unsent write, persisted for retry-after-reconnect.
struct PersistedWriteIntent: Codable, Sendable, Equatable {
    let proposal: ActionProposal
    let confirmation: GovernedWriteConfirmation

    enum SelectionBinding: Equatable {
        case matching
        case foreignSession(String)
        case invalid
    }

    /// A decoded file is not trusted merely because it came from Application Support. Re-verify the complete
    /// proposal hash/shape and the explicit confirmation binding before any selected session may expose a retry.
    func binding(to selectedSessionId: String) -> SelectionBinding {
        guard proposal.kind == .humanMessage,
              proposal.isValidForConfirmation(),
              confirmation.proposalId == proposal.id,
              confirmation.confirmedProposalHash == proposal.proposalHash,
              ActionReceipt.safeEpochMillis(confirmation.confirmedAt) != nil else {
            return .invalid
        }
        guard proposal.targetSessionId == selectedSessionId else {
            return .foreignSession(proposal.targetSessionId)
        }
        return .matching
    }
}

enum OutboxStore {
    enum ClaimResult: Equatable {
        case claimed
        case occupied(targetSessionId: String)
        case storageUnavailable
    }

    private enum LoadResult {
        case missing
        case loaded(PersistedWriteIntent)
        case unavailable
    }

    private enum ProtectionError: Error {
        case storageUnavailable
        case backupExclusionNotDurable
        case readBackMismatch
    }

    private static let lock = NSLock()

    /// File-system boundary shared by production and adversarial tests. Sensitive bytes are first written inside an
    /// already-excluded staging directory. Only an excluded, byte-verified staging inode can be atomically renamed to
    /// the canonical one-slot path, so termination between write and file-metadata verification cannot expose bytes
    /// to backup. POSIX rename preserves the staging inode's protection metadata while replacing the destination.
    struct FileSystem {
        let canonicalURL: URL?
        let stagingDirectoryURL: URL?
        let stagingURL: URL?
        var createDirectory: (URL) throws -> Void
        var exists: (URL) -> Bool
        var write: (Data, URL) throws -> Void
        var read: (URL) throws -> Data
        var excludeFromBackup: (URL) throws -> Void
        var isExcludedFromBackup: (URL) throws -> Bool
        var install: (URL, URL) throws -> Void
        var recover: (URL, URL) throws -> Void
        var remove: (URL) throws -> Void
        var truncate: (URL) throws -> Void

        static func live(in applicationSupportRoot: URL?) -> Self {
            let canonicalURL = applicationSupportRoot?.appendingPathComponent(
                "senti-pocket-outbox.json",
                isDirectory: false
            )
            let stagingDirectoryURL = applicationSupportRoot?.appendingPathComponent(
                ".senti-pocket-outbox-staging",
                isDirectory: true
            )
            let stagingURL = stagingDirectoryURL?.appendingPathComponent("candidate", isDirectory: false)
            return Self(
                canonicalURL: canonicalURL,
                stagingDirectoryURL: stagingDirectoryURL,
                stagingURL: stagingURL,
                createDirectory: { url in
                    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                },
                exists: { FileManager.default.fileExists(atPath: $0.path) },
                write: { data, url in
                    try data.write(
                        to: url,
                        options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
                    )
                },
                read: { try Data(contentsOf: $0) },
                excludeFromBackup: { url in
                    var values = URLResourceValues()
                    values.isExcludedFromBackup = true
                    var mutableURL = url
                    try mutableURL.setResourceValues(values)
                },
                isExcludedFromBackup: { url in
                    try url.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true
                },
                install: { source, destination in
                    let status = source.path.withCString { sourcePath in
                        destination.path.withCString { destinationPath in
                            Darwin.rename(sourcePath, destinationPath)
                        }
                    }
                    guard status == 0 else {
                        let errorCode = errno
                        throw NSError(domain: NSPOSIXErrorDomain, code: Int(errorCode))
                    }
                },
                recover: { source, destination in
                    // Unlike rename, link fails with EEXIST. Recovery may therefore publish the protected inode only
                    // while the canonical slot is still absent; it can never overwrite an owner installed by a
                    // concurrent process between the existence check and this operation.
                    let status = source.path.withCString { sourcePath in
                        destination.path.withCString { destinationPath in
                            Darwin.link(sourcePath, destinationPath)
                        }
                    }
                    guard status == 0 else {
                        let errorCode = errno
                        throw NSError(domain: NSPOSIXErrorDomain, code: Int(errorCode))
                    }
                    try? FileManager.default.removeItem(at: source)
                },
                remove: { try FileManager.default.removeItem(at: $0) },
                truncate: { url in
                    // ftruncate does not allocate blocks, so this remains a viable last-resort erasure path when an
                    // ENOSPC condition prevents the preferred atomic tombstone write.
                    let handle = try FileHandle(forWritingTo: url)
                    do {
                        try handle.truncate(atOffset: 0)
                        try handle.synchronize()
                        try handle.close()
                    } catch {
                        try? handle.close()
                        throw error
                    }
                }
            )
        }
    }

    private static var applicationSupportRoot: URL? {
        try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
    }

    static func save(_ intent: PersistedWriteIntent) {
        lock.lock()
        defer { lock.unlock() }
        _ = saveUnlocked(intent, using: .live(in: applicationSupportRoot))
    }

    /// Compare-and-set the one durable slot. Missing, loaded, and unavailable are deliberately distinct: a read or
    /// metadata failure can never be mistaken for vacancy and therefore can neither overwrite nor clear another
    /// composition's confirmed intent.
    static func claim(_ intent: PersistedWriteIntent) -> ClaimResult {
        lock.lock()
        defer { lock.unlock() }
        return claimUnlocked(intent, using: .live(in: applicationSupportRoot))
    }

    private static func claimUnlocked(_ intent: PersistedWriteIntent, using fileSystem: FileSystem) -> ClaimResult {
        switch loadResult(using: fileSystem) {
        case .missing:
            return saveUnlocked(intent, using: fileSystem) ? .claimed : .storageUnavailable
        case .loaded(let existing):
            guard durablyMatches(existing, intent) else {
                return .occupied(targetSessionId: existing.proposal.targetSessionId)
            }
            return .claimed
        case .unavailable:
            return .storageUnavailable
        }
    }

    private static func saveUnlocked(_ intent: PersistedWriteIntent, using fileSystem: FileSystem) -> Bool {
        guard let data = try? encoder.encode(intent) else { return false }
        return installProtectedData(data, using: fileSystem, eraseInstalledOnFailure: true)
    }

    /// Installs only from the excluded staging directory. Before atomic rename, the staging file itself is also
    /// excluded and byte-verified. Cleanup failure can therefore strand data only inside an excluded directory; it
    /// can never strand newly confirmed bytes at a backup-eligible canonical path.
    private static func installProtectedData(
        _ data: Data,
        using fileSystem: FileSystem,
        eraseInstalledOnFailure: Bool
    ) -> Bool {
        guard let stagingURL = fileSystem.stagingURL,
              let canonicalURL = fileSystem.canonicalURL else { return false }
        var installed = false
        do {
            try prepareStagingDirectory(using: fileSystem)
            discard(stagingURL, using: fileSystem)
            try fileSystem.write(data, stagingURL)
            try ensureBackupExcluded(at: stagingURL, using: fileSystem)
            guard try fileSystem.read(stagingURL) == data else {
                throw ProtectionError.readBackMismatch
            }
            try fileSystem.install(stagingURL, canonicalURL)
            installed = true
            guard try fileSystem.isExcludedFromBackup(canonicalURL) else {
                throw ProtectionError.backupExclusionNotDurable
            }
            guard try fileSystem.read(canonicalURL) == data else {
                throw ProtectionError.readBackMismatch
            }
            return true
        } catch {
            // A migration installs the same owner's bytes; never delete them on an unavailable verification result.
            // A new claim owns its just-installed bytes and may erase them when the durability proof fails.
            if installed && eraseInstalledOnFailure {
                eraseCanonical(using: fileSystem)
            }
            discard(stagingURL, using: fileSystem)
            return false
        }
    }

    static func load() -> PersistedWriteIntent? {
        lock.lock()
        defer { lock.unlock() }
        guard case .loaded(let intent) = loadResult(using: .live(in: applicationSupportRoot)) else { return nil }
        return intent
    }

    private static func loadResult(using fileSystem: FileSystem) -> LoadResult {
        guard let canonicalURL = fileSystem.canonicalURL else { return .unavailable }
        guard fileSystem.exists(canonicalURL) else {
            return recoverStagedResult(using: fileSystem)
        }
        do {
            // Upgrade a legacy unexcluded canonical file by copying its exact bytes through the protected staging
            // boundary. Until that succeeds, no decode or retryable intent is exposed and no caller may treat the
            // occupied slot as missing.
            if try !fileSystem.isExcludedFromBackup(canonicalURL) {
                let legacyData = try fileSystem.read(canonicalURL)
                guard installProtectedData(
                    legacyData,
                    using: fileSystem,
                    eraseInstalledOnFailure: false
                ) else {
                    return .unavailable
                }
            }
            guard try fileSystem.isExcludedFromBackup(canonicalURL) else { return .unavailable }
            let data = try fileSystem.read(canonicalURL)
            if data.isEmpty { return .missing } // verified erasure marker left only when physical removal was unavailable
            guard let intent = try? decoder.decode(PersistedWriteIntent.self, from: data) else {
                return .unavailable
            }
            return .loaded(intent)
        } catch {
            return .unavailable
        }
    }

    /// A process can terminate after the excluded staging write but before atomic install. When no canonical owner
    /// exists, recover that byte-complete candidate instead of silently losing an already-confirmed write. A
    /// canonical file always wins; staged bytes are never allowed to replace an existing one-slot owner.
    private static func recoverStagedResult(using fileSystem: FileSystem) -> LoadResult {
        guard let stagingURL = fileSystem.stagingURL,
              let canonicalURL = fileSystem.canonicalURL else { return .unavailable }
        guard fileSystem.exists(stagingURL) else { return .missing }
        do {
            try prepareStagingDirectory(using: fileSystem)
            try ensureBackupExcluded(at: stagingURL, using: fileSystem)
            let data = try fileSystem.read(stagingURL)
            if data.isEmpty { return .missing }
            guard let intent = try? decoder.decode(PersistedWriteIntent.self, from: data) else {
                return .unavailable
            }
            try fileSystem.recover(stagingURL, canonicalURL)
            guard try fileSystem.isExcludedFromBackup(canonicalURL) else { return .unavailable }
            guard try fileSystem.read(canonicalURL) == data else { return .unavailable }
            return .loaded(intent)
        } catch {
            return .unavailable
        }
    }

    private static func prepareStagingDirectory(using fileSystem: FileSystem) throws {
        guard let directoryURL = fileSystem.stagingDirectoryURL else {
            throw ProtectionError.storageUnavailable
        }
        try fileSystem.createDirectory(directoryURL)
        try ensureBackupExcluded(at: directoryURL, using: fileSystem)
    }

    private static func ensureBackupExcluded(at url: URL, using fileSystem: FileSystem) throws {
        if try fileSystem.isExcludedFromBackup(url) { return }
        try fileSystem.excludeFromBackup(url)
        guard try fileSystem.isExcludedFromBackup(url) else {
            throw ProtectionError.backupExclusionNotDurable
        }
    }

    static func clear() {
        lock.lock()
        defer { lock.unlock() }
        clearUnlocked(using: .live(in: applicationSupportRoot))
    }

    /// A late response from proposal A must never delete a newer proposal B that now owns the global slot. An
    /// unavailable slot is not a match and is never erased.
    static func clear(matching intent: PersistedWriteIntent) {
        lock.lock()
        defer { lock.unlock() }
        clearUnlocked(matching: intent, using: .live(in: applicationSupportRoot))
    }

    private static func clearUnlocked(matching intent: PersistedWriteIntent, using fileSystem: FileSystem) {
        guard case .loaded(let existing) = loadResult(using: fileSystem),
              durablyMatches(existing, intent) else { return }
        eraseCanonical(using: fileSystem)
    }

    /// Disk dates are deliberately normalized to epoch milliseconds. Compare the same canonical bytes used for
    /// persistence, not synthesized Date equality, so a live sub-millisecond intent owns its own round-tripped slot.
    private static func durablyMatches(_ lhs: PersistedWriteIntent, _ rhs: PersistedWriteIntent) -> Bool {
        guard let left = try? encoder.encode(lhs),
              let right = try? encoder.encode(rhs) else { return false }
        return left == right
    }

    private static func clearUnlocked(using fileSystem: FileSystem) {
        eraseCanonical(using: fileSystem)
        discard(fileSystem.stagingURL, using: fileSystem)
    }

    /// Prefer an empty, excluded canonical tombstone over deletion. The same protected staging path is overwritten
    /// first, so even a stranded recovery candidate is invalidated when removal fails or lies about success. Keeping
    /// the tombstone makes it win over any stale staging inode across a principal change. If creating that tombstone
    /// fails (notably ENOSPC), verified removal then allocation-free truncation erase both possible byte owners.
    private static func eraseCanonical(using fileSystem: FileSystem) {
        guard let canonicalURL = fileSystem.canonicalURL,
              let stagingURL = fileSystem.stagingURL else { return }
        do {
            try prepareStagingDirectory(using: fileSystem)
            discard(stagingURL, using: fileSystem)
            try fileSystem.write(Data(), stagingURL)
            try ensureBackupExcluded(at: stagingURL, using: fileSystem)
            guard try fileSystem.read(stagingURL).isEmpty else {
                throw ProtectionError.readBackMismatch
            }
            try fileSystem.install(stagingURL, canonicalURL)
            guard try fileSystem.isExcludedFromBackup(canonicalURL) else {
                throw ProtectionError.backupExclusionNotDurable
            }
            guard try fileSystem.read(canonicalURL).isEmpty else {
                throw ProtectionError.readBackMismatch
            }
        } catch {
            discard(stagingURL, using: fileSystem)
            _ = eraseWithoutAllocation(canonicalURL, using: fileSystem)
            _ = eraseWithoutAllocation(stagingURL, using: fileSystem)
        }
    }

    /// Deletion can fail or an adapter can falsely report success. Truncation changes the existing inode in place and
    /// needs no free block allocation; read-back verification ensures this method never mistakes a no-op for erasure.
    private static func eraseWithoutAllocation(_ url: URL, using fileSystem: FileSystem) -> Bool {
        do { try fileSystem.remove(url) } catch { /* fall through to verified existence/truncation */ }
        guard fileSystem.exists(url) else { return true }
        do {
            try fileSystem.truncate(url)
            return try fileSystem.read(url).isEmpty
        } catch {
            return false
        }
    }

    private static func discard(_ url: URL?, using fileSystem: FileSystem) {
        guard let url else { return }
        try? fileSystem.remove(url)
    }

    static func claimForTesting(_ intent: PersistedWriteIntent, using fileSystem: FileSystem) -> ClaimResult {
        lock.lock()
        defer { lock.unlock() }
        return claimUnlocked(intent, using: fileSystem)
    }

    static func loadForTesting(using fileSystem: FileSystem) -> PersistedWriteIntent? {
        lock.lock()
        defer { lock.unlock() }
        guard case .loaded(let intent) = loadResult(using: fileSystem) else { return nil }
        return intent
    }

    static func clearForTesting(matching intent: PersistedWriteIntent, using fileSystem: FileSystem) {
        lock.lock()
        defer { lock.unlock() }
        clearUnlocked(matching: intent, using: fileSystem)
    }

    static func clearForTesting(using fileSystem: FileSystem) {
        lock.lock()
        defer { lock.unlock() }
        clearUnlocked(using: fileSystem)
    }

    // Epoch-millis dates (ms-exact) so the persisted proposal's createdAt/confirmedAt round-trip identically to the
    // hash + the wire — a reloaded proposal recomputes to the SAME proposalHash on the gateway.
    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        e.dateEncodingStrategy = .custom { date, enc in
            var c = enc.singleValueContainer()
            guard let ms = ActionReceipt.safeEpochMillis(date) else {
                throw EncodingError.invalidValue(
                    date,
                    .init(codingPath: enc.codingPath, debugDescription: "date out of range")
                )
            }
            try c.encode(ms)
        }
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { dec in
            let c = try dec.singleValueContainer()
            let ms = try c.decode(Int64.self)
            return Date(timeIntervalSince1970: Double(ms) / 1000.0)
        }
        return d
    }()
}
