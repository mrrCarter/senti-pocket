import CryptoKit
import Darwin
import Foundation
import Security

// Registry V2's device authority is split deliberately:
//   - one installation identity: 32 random bytes, ThisDeviceOnly, never deleted on sign-out;
//   - one replaceable registry state: server fences plus local digests, never a bearer or raw APNs token.
// A push is actionable only while the persisted server fence, selected session, current credential, current
// PushKit token, and lease all agree. Any Keychain/read/shape failure is a closed gate.

enum DeviceRingContinuousClock {
    /// Sleep-inclusive, system-wide monotonic time. Values never leave the device and are used only to count down a
    /// server-issued lease; PrivacyInfo.xcprivacy declares Apple's SystemBootTime reason 35F9.1.
    static func now() -> TimeInterval? {
        let nanoseconds = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)
        guard nanoseconds > 0 else { return nil }
        let seconds = Double(nanoseconds) / 1_000_000_000
        return seconds.isFinite ? seconds : nil
    }
}

enum DeviceRingSecureStoreError: LocalizedError, Equatable, Sendable {
    case keychain(OSStatus)
    case random(OSStatus)
    case corrupt(String)

    var errorDescription: String? {
        switch self {
        case .keychain(let status):
            return "Device-ring Keychain operation failed (\(status))."
        case .random(let status):
            return "Device-ring secure random generation failed (\(status))."
        case .corrupt(let reason):
            return "Device-ring secure state is invalid: \(reason)"
        }
    }
}

protocol DeviceRingSecureStoring: Sendable {
    func read(account: String) throws -> Data?
    func insertIfAbsent(_ data: Data, account: String) throws -> Bool
    func write(_ data: Data, account: String) throws
    func delete(account: String) throws
}

/// A non-secret, independent fail-closed continuity record. Registry state lives in Keychain, but an authority-closing
/// event must survive even when that Keychain update fails, and a missing App Support record must not authorize a
/// Keychain binding that survived reinstall. Production atomically records allowed/denied; tests inject memory state.
protocol DeviceRingAuthorityDenyStoring: Sendable {
    func isDenied() throws -> Bool
    func deny() throws
    func clear() throws
}

struct DeviceRingFileAuthorityDenyStore: DeviceRingAuthorityDenyStoring {
    private static let deniedMarker = Data("senti-device-ring-authority-denied-v1".utf8)
    private static let allowedMarker = Data("senti-device-ring-authority-allowed-v1".utf8)
    private static let directoryName = "SentiPocketRegistryV2"
    private static let fileName = "ring-authority-denied"

    private func markerURL() throws -> URL {
        guard let root = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw DeviceRingSecureStoreError.corrupt("application support directory is unavailable")
        }
        return root
            .appendingPathComponent(Self.directoryName, isDirectory: true)
            .appendingPathComponent(Self.fileName, isDirectory: false)
    }

    func isDenied() throws -> Bool {
        let url = try markerURL()
        // Absence is denial, not permission. App Support can disappear independently (including an uninstall) while
        // ThisDeviceOnly Keychain state survives; only a successful receipt+state commit writes positive continuity.
        guard FileManager.default.fileExists(atPath: url.path) else { return true }
        switch try Data(contentsOf: url) {
        case Self.allowedMarker:
            return false
        case Self.deniedMarker:
            return true
        default:
            throw DeviceRingSecureStoreError.corrupt("authority-continuity marker is invalid")
        }
    }

    func deny() throws {
        try write(Self.deniedMarker)
    }

    func clear() throws {
        // "Clear denial" is deliberately a positive allowed record, never file deletion. A missing file must continue
        // to close a surviving Keychain binding after reinstall/storage loss.
        try write(Self.allowedMarker)
    }

    private func write(_ marker: Data) throws {
        let url = try markerURL()
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        try marker.write(
            to: url,
            options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
        )
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableURL = url
        try? mutableURL.setResourceValues(values)
        let handle = try FileHandle(forWritingTo: url)
        try handle.synchronize()
        try handle.close()
    }
}

/// Atomic Keychain adapter. Mutable records use update-or-add without a delete/add gap; installation identity uses
/// insertIfAbsent so concurrent launch paths converge on the one value that actually won the Keychain race.
struct DeviceRingKeychainStorage: DeviceRingSecureStoring {
    private let service = "com.plexaura.sentipocket.device-ring-v2"

    private func query(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: false,
        ]
    }

    func read(account: String) throws -> Data? {
        var request = query(account: account)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw DeviceRingSecureStoreError.keychain(status)
        }
        return data
    }

    func insertIfAbsent(_ data: Data, account: String) throws -> Bool {
        var request = query(account: account)
        request[kSecValueData as String] = data
        request[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(request as CFDictionary, nil)
        if status == errSecSuccess { return true }
        if status == errSecDuplicateItem { return false }
        throw DeviceRingSecureStoreError.keychain(status)
    }

    func write(_ data: Data, account: String) throws {
        let status = SecItemUpdate(
            query(account: account) as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else {
            throw DeviceRingSecureStoreError.keychain(status)
        }

        var add = query(account: account)
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(add as CFDictionary, nil)
        if addStatus == errSecSuccess { return }
        if addStatus == errSecDuplicateItem {
            let retry = SecItemUpdate(
                query(account: account) as CFDictionary,
                [kSecValueData as String: data] as CFDictionary
            )
            guard retry == errSecSuccess else {
                throw DeviceRingSecureStoreError.keychain(retry)
            }
            return
        }
        throw DeviceRingSecureStoreError.keychain(addStatus)
    }

    func delete(account: String) throws {
        let status = SecItemDelete(query(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw DeviceRingSecureStoreError.keychain(status)
        }
    }
}

struct DeviceInstallationIdentityStore: Sendable {
    static let encodedCharacterCount = 43
    private static let account = "installation-id"

    private let storage: any DeviceRingSecureStoring
    private let randomBytes: @Sendable (Int) throws -> Data

    init(
        storage: any DeviceRingSecureStoring = DeviceRingKeychainStorage(),
        randomBytes: @escaping @Sendable (Int) throws -> Data = { count in
            var bytes = [UInt8](repeating: 0, count: count)
            let status = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
            guard status == errSecSuccess else {
                throw DeviceRingSecureStoreError.random(status)
            }
            return Data(bytes)
        }
    ) {
        self.storage = storage
        self.randomBytes = randomBytes
    }

    func load() throws -> String? {
        guard let bytes = try storage.read(account: Self.account) else { return nil }
        guard bytes.count == 32 else {
            throw DeviceRingSecureStoreError.corrupt("installation identity is not 32 bytes")
        }
        return DeviceRingFingerprint.base64URL(bytes)
    }

    func loadOrCreate() throws -> String {
        if let existing = try load() { return existing }
        let candidate = try randomBytes(32)
        guard candidate.count == 32 else {
            throw DeviceRingSecureStoreError.corrupt("random source did not return 32 bytes")
        }
        if try storage.insertIfAbsent(candidate, account: Self.account) {
            return DeviceRingFingerprint.base64URL(candidate)
        }
        guard let winner = try load() else {
            throw DeviceRingSecureStoreError.corrupt("installation identity race produced no winner")
        }
        return winner
    }
}

enum DeviceRingFingerprint {
    static func digest(_ value: String) -> String {
        base64URL(Data(SHA256.hash(data: Data(value.utf8))))
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func isDigest(_ value: String) -> Bool {
        guard value.count == 43,
              value.range(
                of: #"^[A-Za-z0-9_-]{43}$"#,
                options: .regularExpression
              ) != nil else { return false }
        var standard = value
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        standard.append(String(repeating: "=", count: (4 - standard.count % 4) % 4))
        guard let bytes = Data(base64Encoded: standard), bytes.count == 32 else { return false }
        return base64URL(bytes) == value
    }
}

struct DeviceRingBindingFence: Codable, Equatable, Sendable {
    static let version = 2

    let v: Int
    let id: String
    let revision: Int

    init(v: Int = Self.version, id: String, revision: Int) {
        self.v = v
        self.id = id
        self.revision = revision
    }

    var isValid: Bool {
        v == Self.version &&
        id.range(of: #"^bind_[0-9a-f]{32}$"#, options: .regularExpression) != nil &&
        DeviceRingRegistryValidation.isSafeRevision(revision)
    }
}

struct DeviceRingLeaseAuthority: Codable, Equatable, Sendable {
    let serverTime: Date
    let wallTimeAtReceipt: Date
    let continuousTimeAtReceipt: TimeInterval
    let authorizedLifetime: TimeInterval
}

struct DeviceRingBindingRecord: Codable, Equatable, Sendable {
    let sessionId: String
    let platform: String
    let tokenDigest: String
    let credentialFingerprint: String
    let ownerVersion: Int
    let ownerHandle: String
    let bindingId: String
    let bindingRevision: Int
    let tokenClaimId: String
    let tokenClaimRevision: Int
    let expiresAt: Date
    let leaseAuthority: DeviceRingLeaseAuthority?

    var fence: DeviceRingBindingFence {
        DeviceRingBindingFence(id: bindingId, revision: bindingRevision)
    }

    /// Wall time is only a discontinuity/reboot sentry; lease consumption is exclusively monotonic. A missing legacy
    /// anchor remains recoverable by registrar renewal but can never authorize a push.
    func remainingLease(
        wallNow: Date,
        continuousNow: TimeInterval?,
        discontinuityTolerance: TimeInterval = 5
    ) -> TimeInterval? {
        guard let leaseAuthority,
              let continuousNow,
              continuousNow.isFinite,
              continuousNow >= leaseAuthority.continuousTimeAtReceipt else {
            return nil
        }
        let monotonicElapsed = continuousNow - leaseAuthority.continuousTimeAtReceipt
        let wallElapsed = wallNow.timeIntervalSince(leaseAuthority.wallTimeAtReceipt)
        guard monotonicElapsed.isFinite,
              wallElapsed.isFinite,
              wallElapsed >= -discontinuityTolerance,
              abs(wallElapsed - monotonicElapsed) <= discontinuityTolerance else {
            return nil
        }
        let remaining = leaseAuthority.authorizedLifetime - monotonicElapsed
        return remaining.isFinite ? remaining : nil
    }
}

struct DeviceRingPendingRegistration: Codable, Equatable, Sendable {
    let sessionId: String
    let platform: String
    let tokenDigest: String
    let credentialFingerprint: String
    let ownerVersion: Int
    let ownerHandle: String
    let idempotencyKey: String
    let expectedBindingId: String?
    let expectedBindingRevision: Int?
    let expectedTokenClaimId: String?
    let expectedTokenClaimRevision: Int?

    func matches(
        sessionId: String,
        platform: String,
        tokenDigest: String,
        credentialFingerprint: String,
        ownerVersion: Int,
        ownerHandle: String
    ) -> Bool {
        self.sessionId == sessionId &&
        self.platform == platform &&
        self.tokenDigest == tokenDigest &&
        self.credentialFingerprint == credentialFingerprint &&
        self.ownerVersion == ownerVersion &&
        self.ownerHandle == ownerHandle
    }
}

struct DeviceRingRegistryState: Codable, Equatable, Sendable {
    static let schemaVersion = 3

    let schema: Int
    var binding: DeviceRingBindingRecord?
    var pendingRegistration: DeviceRingPendingRegistration?
    var revocationRequested: Bool

    init(
        binding: DeviceRingBindingRecord? = nil,
        pendingRegistration: DeviceRingPendingRegistration? = nil,
        revocationRequested: Bool = false
    ) {
        self.schema = Self.schemaVersion
        self.binding = binding
        self.pendingRegistration = pendingRegistration
        self.revocationRequested = revocationRequested
    }

    var isEmpty: Bool {
        binding == nil && pendingRegistration == nil && !revocationRequested
    }
}

enum DeviceRingRegistryValidation {
    static let maximumSafeInteger = 9_007_199_254_740_991
    static let maximumLeaseDuration: TimeInterval = 7 * 24 * 60 * 60

    static func isSafeRevision(_ value: Int) -> Bool {
        value > 0 && value <= maximumSafeInteger
    }

    static func isCanonicalOpaque(_ value: String, maximumUTF8Bytes: Int) -> Bool {
        guard !value.isEmpty,
              value == value.trimmingCharacters(in: .whitespacesAndNewlines),
              value.lengthOfBytes(using: .utf8) <= maximumUTF8Bytes else { return false }
        return !value.unicodeScalars.contains {
            $0.value < 0x20 || (0x7f...0x9f).contains($0.value)
        }
    }

    static func validate(_ state: DeviceRingRegistryState) throws {
        guard state.schema == DeviceRingRegistryState.schemaVersion else {
            throw DeviceRingSecureStoreError.corrupt("unsupported registry-state schema")
        }
        if state.revocationRequested && state.binding == nil && state.pendingRegistration == nil {
            throw DeviceRingSecureStoreError.corrupt("revocation marker has no server operation to reconcile")
        }
        if let binding = state.binding {
            guard isCanonicalOpaque(binding.sessionId, maximumUTF8Bytes: 128),
                  binding.platform == "apns",
                  DeviceRingFingerprint.isDigest(binding.tokenDigest),
                  DeviceRingFingerprint.isDigest(binding.credentialFingerprint),
                  binding.ownerVersion == DeviceRingRegistryOwnerContext.version,
                  DeviceRingFingerprint.isDigest(binding.ownerHandle),
                  binding.fence.isValid,
                  binding.tokenClaimId.range(
                    of: #"^claim_[0-9a-f]{32}$"#,
                    options: .regularExpression
                  ) != nil,
                  isSafeRevision(binding.tokenClaimRevision),
                  binding.expiresAt.timeIntervalSince1970.isFinite,
                  binding.expiresAt.timeIntervalSince1970 > 0 else {
                throw DeviceRingSecureStoreError.corrupt("binding record failed strict validation")
            }
            if let lease = binding.leaseAuthority {
                let serverDuration = binding.expiresAt.timeIntervalSince(lease.serverTime)
                guard lease.serverTime.timeIntervalSince1970.isFinite,
                      lease.wallTimeAtReceipt.timeIntervalSince1970.isFinite,
                      lease.continuousTimeAtReceipt.isFinite,
                      lease.continuousTimeAtReceipt >= 0,
                      lease.authorizedLifetime.isFinite,
                      lease.authorizedLifetime > 0,
                      serverDuration.isFinite,
                      serverDuration > 0,
                      serverDuration <= maximumLeaseDuration,
                      lease.authorizedLifetime <= serverDuration else {
                    throw DeviceRingSecureStoreError.corrupt("binding lease authority failed strict validation")
                }
            }
        }
        if let pending = state.pendingRegistration {
            let bindingPair = (pending.expectedBindingId == nil) == (pending.expectedBindingRevision == nil)
            let claimPair = (pending.expectedTokenClaimId == nil) == (pending.expectedTokenClaimRevision == nil)
            guard isCanonicalOpaque(pending.sessionId, maximumUTF8Bytes: 128),
                  pending.platform == "apns",
                  DeviceRingFingerprint.isDigest(pending.tokenDigest),
                  DeviceRingFingerprint.isDigest(pending.credentialFingerprint),
                  pending.ownerVersion == DeviceRingRegistryOwnerContext.version,
                  DeviceRingFingerprint.isDigest(pending.ownerHandle),
                  UUID(uuidString: pending.idempotencyKey) != nil,
                  bindingPair,
                  claimPair else {
                throw DeviceRingSecureStoreError.corrupt("pending registration failed strict validation")
            }
            if let id = pending.expectedBindingId,
               let revision = pending.expectedBindingRevision {
                guard DeviceRingBindingFence(id: id, revision: revision).isValid else {
                    throw DeviceRingSecureStoreError.corrupt("pending binding fence is invalid")
                }
            }
            if let id = pending.expectedTokenClaimId,
               let revision = pending.expectedTokenClaimRevision {
                guard id.range(
                    of: #"^claim_[0-9a-f]{32}$"#,
                    options: .regularExpression
                ) != nil,
                isSafeRevision(revision) else {
                    throw DeviceRingSecureStoreError.corrupt("pending token-claim fence is invalid")
                }
            }
        }
        if let binding = state.binding, let pending = state.pendingRegistration,
           (binding.ownerVersion != pending.ownerVersion || binding.ownerHandle != pending.ownerHandle) {
            throw DeviceRingSecureStoreError.corrupt("binding and pending registration owners disagree")
        }
    }

    /// JSONDecoder intentionally tolerates unknown keys, so Keychain state gets a small structural preflight first.
    /// A future schema cannot silently downgrade into today's authority record.
    static func rejectUnknownKeys(in data: Data) throws {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DeviceRingSecureStoreError.corrupt("registry state is not a JSON object")
        }
        try requireKeys(root, allowed: ["schema", "binding", "pendingRegistration", "revocationRequested"])
        if let binding = root["binding"] as? [String: Any] {
            try requireKeys(binding, allowed: [
                "sessionId", "platform", "tokenDigest", "credentialFingerprint", "ownerVersion", "ownerHandle",
                "bindingId", "bindingRevision", "tokenClaimId", "tokenClaimRevision", "expiresAt",
                "leaseAuthority",
            ])
            if let lease = binding["leaseAuthority"] as? [String: Any] {
                try requireKeys(lease, allowed: [
                    "serverTime", "wallTimeAtReceipt", "continuousTimeAtReceipt", "authorizedLifetime",
                ])
            } else if let value = binding["leaseAuthority"], !(value is NSNull) {
                throw DeviceRingSecureStoreError.corrupt("binding lease authority is not an object")
            }
        } else if let value = root["binding"], !(value is NSNull) {
            throw DeviceRingSecureStoreError.corrupt("binding is not an object")
        }
        if let pending = root["pendingRegistration"] as? [String: Any] {
            try requireKeys(pending, allowed: [
                "sessionId", "platform", "tokenDigest", "credentialFingerprint", "ownerVersion", "ownerHandle", "idempotencyKey",
                "expectedBindingId", "expectedBindingRevision",
                "expectedTokenClaimId", "expectedTokenClaimRevision",
            ])
        } else if let value = root["pendingRegistration"], !(value is NSNull) {
            throw DeviceRingSecureStoreError.corrupt("pending registration is not an object")
        }
    }

    private static func requireKeys(_ object: [String: Any], allowed: Set<String>) throws {
        guard Set(object.keys).isSubset(of: allowed) else {
            throw DeviceRingSecureStoreError.corrupt("registry state contains unsupported fields")
        }
    }
}

struct DeviceRingRegistryStateStore: Sendable {
    private static let account = "registry-state-v3"
    private static let preOwnerContinuityAccount = "registry-state"
    private let storage: any DeviceRingSecureStoring
    private let authorityDenyStore: any DeviceRingAuthorityDenyStoring

    init(
        storage: any DeviceRingSecureStoring = DeviceRingKeychainStorage(),
        authorityDenyStore: any DeviceRingAuthorityDenyStoring = DeviceRingFileAuthorityDenyStore()
    ) {
        self.storage = storage
        self.authorityDenyStore = authorityDenyStore
    }

    func load() throws -> DeviceRingRegistryState {
        guard let data = try storage.read(account: Self.account) else {
            return DeviceRingRegistryState()
        }
        do {
            try DeviceRingRegistryValidation.rejectUnknownKeys(in: data)
            let state = try JSONDecoder().decode(DeviceRingRegistryState.self, from: data)
            try DeviceRingRegistryValidation.validate(state)
            return state
        } catch let error as DeviceRingSecureStoreError {
            throw error
        } catch {
            throw DeviceRingSecureStoreError.corrupt("registry state cannot be decoded")
        }
    }

    /// Ownerless prerelease envelopes cannot be attributed safely after bearer rotation, and uninstalling an app does
    /// not reliably erase ThisDeviceOnly Keychain items. This destructive local half of the prerelease cutover is
    /// therefore callable only after an authenticated Registry V2 owner-context response: the server boot contract for
    /// that route requires the old V2 namespace to have been quiesced and purged first. Denial is persisted before the
    /// legacy bytes are removed, so a crash or Keychain failure cannot reopen their former authority.
    func completeOwnerContinuityCutover() throws {
        guard try storage.read(account: Self.preOwnerContinuityAccount) != nil else { return }
        try authorityDenyStore.deny()
        try storage.delete(account: Self.preOwnerContinuityAccount)
    }

    func save(_ state: DeviceRingRegistryState) throws {
        try DeviceRingRegistryValidation.validate(state)
        if state.isEmpty {
            try storage.delete(account: Self.account)
            return
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try storage.write(encoder.encode(state), account: Self.account)
    }

    /// Errors are denial, never permission. The marker contains no identity/token/content and is independently durable
    /// from the Keychain envelope so a failed marker transition cannot silently reopen an old clean binding.
    func authorityIsDenied() -> Bool {
        do {
            return try authorityDenyStore.isDenied()
        } catch {
            return true
        }
    }

    func denyAuthority() throws {
        try authorityDenyStore.deny()
    }

    func clearAuthorityDenial() throws {
        try authorityDenyStore.clear()
    }

    /// Restore only the user's durable selected-session consent after a killed launch. This does not authorize a push:
    /// DeviceRingBindingGate still independently requires the exact current PushKit token/fence and a safe lease.
    func restorableSelectedSessionId(credential: String?) -> String? {
        guard let credential, !credential.isEmpty,
              !authorityIsDenied(),
              let state = try? load(),
              !state.revocationRequested,
              state.pendingRegistration == nil,
              let binding = state.binding,
              binding.platform == "apns",
              binding.credentialFingerprint == DeviceRingFingerprint.digest(credential) else {
            return nil
        }
        return binding.sessionId
    }
}

/// Minimal raw-push parser. It reads only the routing/fence fields needed to authorize the push; display/governed
/// fields remain untouched until the caller proves this exact server-issued fence is current.
enum DeviceRingPushFenceParser {
    static func parse(_ payload: [AnyHashable: Any]) -> (sessionId: String, fence: DeviceRingBindingFence)? {
        guard strictInteger(payload["v"]) == DeviceRingBindingFence.version,
              let sessionId = payload["sessionId"] as? String,
              DeviceRingRegistryValidation.isCanonicalOpaque(sessionId, maximumUTF8Bytes: 128),
              let rawBinding = payload["binding"] as? [AnyHashable: Any],
              Set(rawBinding.keys.compactMap { $0 as? String }) == Set(["v", "id", "revision"]),
              rawBinding.keys.allSatisfy({ $0 is String }),
              strictInteger(rawBinding["v"]) == DeviceRingBindingFence.version,
              let id = rawBinding["id"] as? String,
              let revision = strictInteger(rawBinding["revision"]) else { return nil }
        let fence = DeviceRingBindingFence(id: id, revision: revision)
        return fence.isValid ? (sessionId, fence) : nil
    }

    private static func strictInteger(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let double = number.doubleValue
        guard double.isFinite,
              double.rounded(.towardZero) == double,
              double > 0,
              double <= Double(DeviceRingRegistryValidation.maximumSafeInteger) else { return nil }
        return Int(double)
    }
}

@MainActor
final class DeviceRingBindingGate {
    private let stateStore: DeviceRingRegistryStateStore
    private let credentialProvider: () -> String?
    private let voipTokenProvider: () -> String?
    private let isSessionSelected: (String) -> Bool
    private let now: () -> Date
    private let continuousNow: () -> TimeInterval?
    private let expirySafetyMargin: TimeInterval
    private let discontinuityTolerance: TimeInterval

    init(
        stateStore: DeviceRingRegistryStateStore,
        credentialProvider: @escaping () -> String? = { SessionTokenStore.load() },
        voipTokenProvider: @escaping () -> String?,
        isSessionSelected: @escaping (String) -> Bool,
        now: @escaping () -> Date = Date.init,
        continuousNow: @escaping () -> TimeInterval? = DeviceRingContinuousClock.now,
        expirySafetyMargin: TimeInterval = 5 * 60,
        discontinuityTolerance: TimeInterval = 5
    ) {
        self.stateStore = stateStore
        self.credentialProvider = credentialProvider
        self.voipTokenProvider = voipTokenProvider
        self.isSessionSelected = isSessionSelected
        self.now = now
        self.continuousNow = continuousNow
        self.expirySafetyMargin = expirySafetyMargin
        self.discontinuityTolerance = discontinuityTolerance
    }

    func permits(sessionId: String, fence: DeviceRingBindingFence) -> Bool {
        guard fence.isValid,
              !stateStore.authorityIsDenied(),
              isSessionSelected(sessionId),
              let credential = credentialProvider(), !credential.isEmpty,
              let voipToken = voipTokenProvider(), !voipToken.isEmpty,
              let state = try? stateStore.load(),
              !state.revocationRequested,
              state.pendingRegistration == nil,
              let binding = state.binding,
              binding.sessionId == sessionId,
              binding.bindingId == fence.id,
              binding.bindingRevision == fence.revision,
              binding.credentialFingerprint == DeviceRingFingerprint.digest(credential),
              binding.tokenDigest == DeviceRingFingerprint.digest(voipToken),
              let remainingLease = binding.remainingLease(
                wallNow: now(),
                continuousNow: continuousNow(),
                discontinuityTolerance: discontinuityTolerance
              ),
              remainingLease > expirySafetyMargin else {
            return false
        }
        return true
    }
}
