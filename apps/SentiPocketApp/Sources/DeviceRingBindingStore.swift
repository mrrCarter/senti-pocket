// DeviceRingBindingStore — installation-global authorization state for Registry V2.
//
// One Keychain record owns the random installation id, monotonic uint64 generation, pending transition, completed
// binding descriptor, and current server binding. Keeping these values together matters: revocation advances the
// generation and clears the accepted push proof in ONE Keychain update, so a killed/relaunched app cannot briefly
// resurrect the prior principal. `AfterFirstUnlockThisDeviceOnly` supports background PushKit delivery while ensuring
// neither iCloud restore nor device migration clones an installation identity.

import CryptoKit
import Foundation
import Security

struct DeviceRingBinding: Codable, Equatable, Sendable {
    static let registryVersion = 2

    let registryVersion: Int
    let sessionId: String
    let tokenFingerprint: String
    let installationGeneration: String
    let bindingId: String
    let bindingRevision: String
    let leaseExpiresAtSec: Int64

    func authorizes(
        sessionId incomingSessionId: String,
        bindingVersion: Int?,
        bindingId incomingBindingId: String?,
        bindingRevision incomingBindingRevision: String?,
        installationGeneration incomingGeneration: String?,
        nowEpochSec: Int64
    ) -> Bool {
        registryVersion == Self.registryVersion &&
        leaseExpiresAtSec > nowEpochSec &&
        sessionId == incomingSessionId &&
        bindingVersion == Self.registryVersion &&
        bindingId == incomingBindingId &&
        bindingRevision == incomingBindingRevision &&
        installationGeneration == incomingGeneration
    }
}

struct DeviceRingRegistrationAttempt: Codable, Equatable, Sendable {
    let installationId: String
    let installationGeneration: String
    let sessionId: String
    let tokenFingerprint: String
}

struct DeviceRingUnregistrationAttempt: Codable, Equatable, Sendable {
    let installationId: String
    let installationGeneration: String
    let previousInstallationGeneration: String
    let sessionId: String
    let bindingId: String
    let bindingRevision: String
}

enum DeviceRingBindingStoreError: LocalizedError, Equatable {
    case secureRandom(Int32)
    case secureStorage(Int32)
    case corruptState

    var errorDescription: String? {
        switch self {
        case .secureRandom(let status):
            return "Secure installation identity generation failed (\(status))."
        case .secureStorage(let status):
            return "Secure installation binding storage failed (\(status))."
        case .corruptState:
            return "The secure installation binding state is malformed."
        }
    }
}

/// Injectable facade used by DeviceRingRegistrar. Tests provide an in-memory implementation; Release uses Keychain.
struct DeviceRingInstallationController {
    let beginRegistration: (_ sessionId: String, _ voipToken: String, _ forceNewGeneration: Bool) throws -> DeviceRingRegistrationAttempt
    let commitRegistration: (_ attempt: DeviceRingRegistrationAttempt, _ binding: DeviceRingBinding) throws -> Void
    let beginRevocation: (_ binding: DeviceRingBinding?) throws -> DeviceRingUnregistrationAttempt?
    let completeUnregistration: (_ attempt: DeviceRingUnregistrationAttempt) throws -> Void
    let loadCurrentBinding: () -> DeviceRingBinding?

    private static let liveStore = DeviceRingInstallationStateStore(
        persistence: DeviceRingKeychainPersistence.persistence
    )
    static let live = liveStore.controller
}

enum DeviceRingTokenFingerprint {
    static func make(_ token: String) -> String {
        let digest = SHA256.hash(data: Data(token.utf8))
        return Data(digest).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// Lock-backed because PushKit callbacks and authenticated client completions can cross executor boundaries.
final class DeviceRingBindingGate: @unchecked Sendable {
    private let lock = NSLock()
    private let nowEpochSec: @Sendable () -> Int64
    private var binding: DeviceRingBinding?

    init(
        initialBinding: DeviceRingBinding? = DeviceRingInstallationController.live.loadCurrentBinding(),
        nowEpochSec: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970) }
    ) {
        self.binding = initialBinding
        self.nowEpochSec = nowEpochSec
    }

    func replace(with binding: DeviceRingBinding?) {
        lock.lock()
        self.binding = binding
        lock.unlock()
    }

    func permits(
        sessionId: String,
        bindingVersion: Int?,
        bindingId: String?,
        bindingRevision: String?,
        installationGeneration: String?
    ) -> Bool {
        lock.lock()
        let current = binding
        lock.unlock()
        return current?.authorizes(
            sessionId: sessionId,
            bindingVersion: bindingVersion,
            bindingId: bindingId,
            bindingRevision: bindingRevision,
            installationGeneration: installationGeneration,
            nowEpochSec: nowEpochSec()
        ) == true
    }
}

struct DeviceRingInstallationPersistence {
    let load: () throws -> Data?
    let save: (Data) throws -> Void
}

/// The transition engine is instance-backed so tests can exercise restart/crash behavior over an in-memory persistence
/// seam. Production owns one app-lifetime instance whose persistence is the single ThisDeviceOnly Keychain record.
final class DeviceRingInstallationStateStore {
    struct CompletedRegistration: Codable, Equatable {
        let installationGeneration: String
        let sessionId: String
        let tokenFingerprint: String
    }

    enum PendingTransition: Codable, Equatable {
        case register(DeviceRingRegistrationAttempt)
        case unregister(DeviceRingUnregistrationAttempt)
    }

    struct State: Codable, Equatable {
        let schemaVersion: Int
        var installationId: String
        var generation: String
        var pending: PendingTransition?
        var completed: CompletedRegistration?
        var currentBinding: DeviceRingBinding?
        /// Last server proof retained solely for compare-delete. It never authorizes a push: only currentBinding is
        /// exposed through loadCurrentBinding. Keeping cleanup proof separate means a renewal can fail or the process
        /// can die after clearing live authority without making the prior lease impossible to unregister.
        var revocableBinding: DeviceRingBinding? = nil
    }

    private let persistence: DeviceRingInstallationPersistence
    private let lock = NSLock()

    init(persistence: DeviceRingInstallationPersistence) {
        self.persistence = persistence
    }

    var controller: DeviceRingInstallationController {
        DeviceRingInstallationController(
            beginRegistration: { [self] sessionId, token, forceNew in
                try beginRegistration(
                    sessionId: sessionId,
                    voipToken: token,
                    forceNewGeneration: forceNew
                )
            },
            commitRegistration: { [self] attempt, binding in
                try commitRegistration(attempt: attempt, binding: binding)
            },
            beginRevocation: { [self] binding in
                try beginRevocation(binding: binding)
            },
            completeUnregistration: { [self] attempt in
                try completeUnregistration(attempt: attempt)
            },
            loadCurrentBinding: { [self] in loadCurrentBinding() }
        )
    }

    func beginRegistration(
        sessionId: String,
        voipToken: String,
        forceNewGeneration: Bool
    ) throws -> DeviceRingRegistrationAttempt {
        try locked {
            var state = try loadOrCreate()
            let fingerprint = DeviceRingTokenFingerprint.make(voipToken)
            if !forceNewGeneration {
                if case .register(let pending) = state.pending,
                   pending.sessionId == sessionId,
                   pending.tokenFingerprint == fingerprint {
                    return pending
                }
                if state.pending == nil,
                   let completed = state.completed,
                   completed.sessionId == sessionId,
                   completed.tokenFingerprint == fingerprint {
                    let renewal = DeviceRingRegistrationAttempt(
                        installationId: state.installationId,
                        installationGeneration: completed.installationGeneration,
                        sessionId: sessionId,
                        tokenFingerprint: fingerprint
                    )
                    state.pending = .register(renewal)
                    if let current = state.currentBinding {
                        state.revocableBinding = current
                    }
                    state.currentBinding = nil
                    try save(state)
                    return renewal
                }
            }
            let generation = try advanceGeneration(&state)
            let attempt = DeviceRingRegistrationAttempt(
                installationId: state.installationId,
                installationGeneration: generation,
                sessionId: sessionId,
                tokenFingerprint: fingerprint
            )
            state.pending = .register(attempt)
            state.currentBinding = nil
            try save(state)
            return attempt
        }
    }

    func commitRegistration(
        attempt: DeviceRingRegistrationAttempt,
        binding: DeviceRingBinding
    ) throws {
        try locked {
            var state = try loadOrCreate()
            guard case .register(let pending) = state.pending,
                  pending == attempt,
                  state.installationId == attempt.installationId,
                  state.generation == attempt.installationGeneration,
                  isValid(binding),
                  binding.sessionId == attempt.sessionId,
                  binding.tokenFingerprint == attempt.tokenFingerprint,
                  binding.installationGeneration == attempt.installationGeneration else {
                throw DeviceRingBindingStoreError.corruptState
            }
            state.completed = CompletedRegistration(
                installationGeneration: attempt.installationGeneration,
                sessionId: attempt.sessionId,
                tokenFingerprint: attempt.tokenFingerprint
            )
            state.currentBinding = binding
            state.revocableBinding = binding
            state.pending = nil
            try save(state)
        }
    }

    /// Advances local authority before any cleanup request. When a current binding exists, the returned compare-delete
    /// carries the newly persisted tombstone generation. With only an in-flight registration, the generation still
    /// advances and the accepted binding is cleared, so the next principal necessarily overtakes the delayed request.
    func beginRevocation(binding suppliedBinding: DeviceRingBinding?) throws -> DeviceRingUnregistrationAttempt? {
        try locked {
            var state = try loadOrCreate()
            // A previous compare-delete may have failed after the local proof was cleared. Preserve and retry the exact
            // persisted tombstone request across repeated revokes and process restarts; never advance past and discard it.
            if case .unregister(let pending) = state.pending {
                state.currentBinding = nil
                state.completed = nil
                try save(state)
                return pending
            }
            let binding = suppliedBinding ?? state.currentBinding ?? state.revocableBinding
            let previousInstallationId = state.installationId
            let generation = try advanceGeneration(&state)
            state.currentBinding = nil
            state.completed = nil
            // At UInt64.max, advanceGeneration rotates to a fresh installation identity at generation 1. The old
            // binding cannot form a valid compare-delete under that new identity, so persist the cleared rotation and
            // let the old server lease age out. Most importantly, a restart can never reload the old local proof.
            if state.installationId != previousInstallationId {
                state.pending = nil
                try save(state)
                return nil
            }
            guard let binding else {
                state.pending = nil
                state.revocableBinding = nil
                try save(state)
                return nil
            }
            let attempt = DeviceRingUnregistrationAttempt(
                installationId: state.installationId,
                installationGeneration: generation,
                previousInstallationGeneration: binding.installationGeneration,
                sessionId: binding.sessionId,
                bindingId: binding.bindingId,
                bindingRevision: binding.bindingRevision
            )
            state.pending = .unregister(attempt)
            state.revocableBinding = binding
            try save(state)
            return attempt
        }
    }

    func completeUnregistration(attempt: DeviceRingUnregistrationAttempt) throws {
        try locked {
            var state = try loadOrCreate()
            if case .unregister(let pending) = state.pending, pending == attempt {
                state.pending = nil
                state.revocableBinding = nil
                try save(state)
            }
        }
    }

    func loadCurrentBinding() -> DeviceRingBinding? {
        lockedNoThrow {
            do {
                guard let state = try load(), isValid(state) else { return nil }
                return state.currentBinding
            } catch {
                return nil
            }
        }
    }

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    private func lockedNoThrow<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    private func loadOrCreate() throws -> State {
        if let state = try load() {
            guard isValid(state) else { throw DeviceRingBindingStoreError.corruptState }
            return state
        }
        return State(
            schemaVersion: DeviceRingBinding.registryVersion,
            installationId: try randomOpaqueId(),
            generation: "0",
            pending: nil,
            completed: nil,
            currentBinding: nil,
            revocableBinding: nil
        )
    }

    private func isValid(_ state: State) -> Bool {
        guard state.schemaVersion == DeviceRingBinding.registryVersion,
              isOpaque(state.installationId),
              let stateGeneration = parseGeneration(state.generation) else { return false }

        if let completed = state.completed {
            guard let completedGeneration = parsePositiveGeneration(completed.installationGeneration),
                  completedGeneration <= stateGeneration,
                  isValidSession(completed.sessionId),
                  isOpaque(completed.tokenFingerprint),
                  let revocable = state.revocableBinding,
                  revocable.installationGeneration == completed.installationGeneration,
                  revocable.sessionId == completed.sessionId,
                  revocable.tokenFingerprint == completed.tokenFingerprint else { return false }
        }

        if let revocable = state.revocableBinding {
            guard isValid(revocable),
                  let revocableGeneration = parsePositiveGeneration(revocable.installationGeneration),
                  revocableGeneration <= stateGeneration else { return false }
        }

        switch state.pending {
        case .register(let attempt):
            guard attempt.installationId == state.installationId,
                  attempt.installationGeneration == state.generation,
                  parsePositiveGeneration(attempt.installationGeneration) != nil,
                  isValidSession(attempt.sessionId),
                  isOpaque(attempt.tokenFingerprint),
                  state.currentBinding == nil else { return false }
        case .unregister(let attempt):
            guard attempt.installationId == state.installationId,
                  attempt.installationGeneration == state.generation,
                  let generation = parsePositiveGeneration(attempt.installationGeneration),
                  let previous = parsePositiveGeneration(attempt.previousInstallationGeneration),
                  generation > previous,
                  isValidSession(attempt.sessionId),
                  isOpaque(attempt.bindingId),
                  isOpaque(attempt.bindingRevision),
                  state.currentBinding == nil,
                  state.completed == nil,
                  let revocable = state.revocableBinding,
                  revocable.installationGeneration == attempt.previousInstallationGeneration,
                  revocable.sessionId == attempt.sessionId,
                  revocable.bindingId == attempt.bindingId,
                  revocable.bindingRevision == attempt.bindingRevision else { return false }
        case nil:
            break
        }

        if let binding = state.currentBinding {
            guard state.pending == nil,
                  isValid(binding),
                  binding.installationGeneration == state.generation,
                  let completed = state.completed,
                  completed.installationGeneration == binding.installationGeneration,
                  completed.sessionId == binding.sessionId,
                  completed.tokenFingerprint == binding.tokenFingerprint,
                  state.revocableBinding == binding else { return false }
        } else if state.pending == nil, state.completed != nil {
            return false
        } else if state.pending == nil, state.revocableBinding != nil {
            return false
        }
        return true
    }

    private func advanceGeneration(_ state: inout State) throws -> String {
        guard let current = parseGeneration(state.generation) else {
            throw DeviceRingBindingStoreError.corruptState
        }
        if current == UInt64.max {
            // Practically unreachable. Rotating the installation id is safer than wrapping and reusing generation 1
            // under an old durable server head.
            state = State(
                schemaVersion: DeviceRingBinding.registryVersion,
                installationId: try randomOpaqueId(),
                generation: "1",
                pending: nil,
                completed: nil,
                currentBinding: nil,
                revocableBinding: nil
            )
            return "1"
        }
        let next = current + 1
        state.generation = String(next)
        return state.generation
    }

    private func parseGeneration(_ value: String) -> UInt64? {
        guard !value.isEmpty,
              value == "0" || (value.first != "0" && value.allSatisfy(\.isNumber)) else { return nil }
        return UInt64(value)
    }

    private func parsePositiveGeneration(_ value: String) -> UInt64? {
        guard value != "0" else { return nil }
        return parseGeneration(value)
    }

    private func isValidSession(_ value: String) -> Bool {
        !value.isEmpty &&
        value == value.trimmingCharacters(in: .whitespacesAndNewlines) &&
        value.utf8.count <= 256
    }

    private func isValid(_ binding: DeviceRingBinding) -> Bool {
        binding.registryVersion == DeviceRingBinding.registryVersion &&
        isValidSession(binding.sessionId) &&
        isOpaque(binding.tokenFingerprint) &&
        parsePositiveGeneration(binding.installationGeneration) != nil &&
        isOpaque(binding.bindingId) &&
        isOpaque(binding.bindingRevision) &&
        binding.leaseExpiresAtSec > 0
    }

    private func isOpaque(_ value: String) -> Bool {
        let bytes = value.utf8
        return (22...128).contains(bytes.count) &&
        bytes.allSatisfy {
            (48...57).contains($0) ||
            (65...90).contains($0) ||
            (97...122).contains($0) ||
            $0 == 95 ||
            $0 == 45
        }
    }

    private func randomOpaqueId() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else { throw DeviceRingBindingStoreError.secureRandom(status) }
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private func load() throws -> State? {
        guard let data = try persistence.load() else { return nil }
        do { return try JSONDecoder().decode(State.self, from: data) }
        catch { throw DeviceRingBindingStoreError.corruptState }
    }

    private func save(_ state: State) throws {
        guard isValid(state) else { throw DeviceRingBindingStoreError.corruptState }
        let data: Data
        do { data = try JSONEncoder().encode(state) }
        catch { throw DeviceRingBindingStoreError.corruptState }
        try persistence.save(data)
    }
}

private enum DeviceRingKeychainPersistence {
    private static let service = "com.plexaura.sentipocket.device-ring"
    private static let account = "installation-authority-v2"

    static let persistence = DeviceRingInstallationPersistence(
        load: load,
        save: save
    )

    private static func query() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    private static func load() throws -> Data? {
        var request = query()
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var output: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &output)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = output as? Data else {
            throw DeviceRingBindingStoreError.secureStorage(status)
        }
        return data
    }

    private static func save(_ data: Data) throws {
        let base = query()
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        var status = SecItemUpdate(base as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var add = base
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(add as CFDictionary, nil)
            if status == errSecDuplicateItem {
                status = SecItemUpdate(base as CFDictionary, attributes as CFDictionary)
            }
        }
        guard status == errSecSuccess else { throw DeviceRingBindingStoreError.secureStorage(status) }
    }
}
