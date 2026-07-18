import Foundation

// ─────────────────────────────────────────────────────────────────────────────
// PocketSyncClient — owner: claude-pocket-relay
// Narrow interface: pull bounded, signed PocketBundles to the phone and track sync
// state so playback survives offline. The phone holds NO Senti credentials; the
// gateway authenticates and hands down bundles only.
//
// INTERIM types below mirror the gateway's contracts.interim.ts and the pinned
// baseline. Replace with `import PocketContracts` (Atlas v0.1) at freeze — this is
// a re-type, not a redesign.
// ─────────────────────────────────────────────────────────────────────────────

public typealias BundleID = String

/// Opaque, signed bundle envelope. The `payload` is the Atlas-contract PocketBundle
/// (kept as Data here so this package does not fork Atlas's summary type).
public struct PocketBundleEnvelope: Codable, Equatable, Sendable {
    public let bundleId: BundleID
    public let sessionId: String
    public let startSequence: Int
    public let endSequence: Int
    public let participants: [String]
    public let builtAt: Date
    public let signature: BundleSignature
    /// Canonical JSON of the full PocketBundle (Atlas contract). Verified before use.
    public let payload: Data

    public init(bundleId: BundleID, sessionId: String, startSequence: Int, endSequence: Int,
                participants: [String], builtAt: Date, signature: BundleSignature, payload: Data) {
        self.bundleId = bundleId
        self.sessionId = sessionId
        self.startSequence = startSequence
        self.endSequence = endSequence
        self.participants = participants
        self.builtAt = builtAt
        self.signature = signature
        self.payload = payload
    }
}

public struct BundleSignature: Codable, Equatable, Sendable {
    public let alg: String   // interim "sha256-unsigned"; P3 "ed25519"
    public let value: String
    public let keyId: String?
    public init(alg: String, value: String, keyId: String? = nil) {
        self.alg = alg; self.value = value; self.keyId = keyId
    }
}

/// Server cursor for incremental sync (mirrors Senti's "seq:hash" cursor form).
public struct SyncCursor: Codable, Equatable, Sendable {
    public let value: String
    public init(_ value: String) { self.value = value }
}

public struct BundlePage: Codable, Equatable, Sendable {
    public let bundles: [PocketBundleEnvelope]
    public let nextCursor: SyncCursor?
    public init(bundles: [PocketBundleEnvelope], nextCursor: SyncCursor?) {
        self.bundles = bundles; self.nextCursor = nextCursor
    }
}

public struct SyncState: Codable, Equatable, Sendable {
    public let lastCursor: SyncCursor?
    public let cachedBundleIds: [BundleID]
    public let lastSyncedAt: Date?
    public init(lastCursor: SyncCursor?, cachedBundleIds: [BundleID], lastSyncedAt: Date?) {
        self.lastCursor = lastCursor; self.cachedBundleIds = cachedBundleIds; self.lastSyncedAt = lastSyncedAt
    }
}

/// Checkpoint bundle pull + sync-to-phone. Implementations MUST be idempotent:
/// re-pulling an already-cached bundle returns it unchanged (dedup by `bundleId`).
public protocol PocketSyncClient: Sendable {
    /// Incrementally pull bundles newer than `cursor` (nil = from the beginning).
    func pullBundles(since cursor: SyncCursor?) async throws -> BundlePage

    /// Fetch a single bundle by id (cache repair / deep link into a briefing).
    func fetchBundle(id: BundleID) async throws -> PocketBundleEnvelope

    /// Current local sync state, so the phone can resume and avoid re-download.
    func syncState() async throws -> SyncState
}

public enum PocketSyncError: Error, Equatable, Sendable {
    case signatureInvalid(BundleID)
    case notFound(BundleID)
    case offline
    case transport(String)
}
