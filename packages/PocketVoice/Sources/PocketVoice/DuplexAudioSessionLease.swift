import AVFoundation
import Foundation

struct DuplexAudioSessionLease: Hashable, Sendable {
    fileprivate let id: UUID
}

enum DuplexAudioSessionReleaseOutcome: Equatable, Sendable {
    case stale
    case retained(activeLeaseCount: Int)
    case releasedUnderCallKitOwnership
    case deactivated
    case deactivationFailed(String)

    var error: VoiceError? {
        guard case .deactivationFailed(let reason) = self else { return nil }
        return .audioSessionFailed("audio-session deactivation failed: \(reason)")
    }
}

protocol DuplexAudioSessionSystem: Sendable {
    func prepareForCallKit() throws
    func activate() throws
    func deactivate() throws
}

extension DuplexAudioSessionSystem {
    func prepareForCallKit() throws {}
}

final class DuplexAudioSessionLeaseManager: @unchecked Sendable {
    static let shared = DuplexAudioSessionLeaseManager(system: SystemDuplexAudioSession())

    private let lock = NSLock()
    private let system: any DuplexAudioSessionSystem
    private var activeLeaseIDs = Set<UUID>()
    private var callKitOwnsAudioSession = false
    private var systemActivationOwned = false

    init(system: any DuplexAudioSessionSystem) {
        self.system = system
    }

    func acquire() throws -> DuplexAudioSessionLease {
        lock.lock()
        defer { lock.unlock() }

        if activeLeaseIDs.isEmpty {
            if callKitOwnsAudioSession {
                systemActivationOwned = false
            } else {
                try system.activate()
                systemActivationOwned = true
            }
        } else if !callKitOwnsAudioSession, !systemActivationOwned {
            // CallKit deactivated while an old voice operation was still unwinding. A new operation must not borrow
            // that dead session; the host's episode fence will cancel the old work and a later fresh call can retry.
            throw VoiceError.audioSessionFailed("CallKit audio session is no longer active")
        }
        let lease = DuplexAudioSessionLease(id: UUID())
        activeLeaseIDs.insert(lease.id)
        return lease
    }

    @discardableResult
    func release(_ lease: DuplexAudioSessionLease) -> DuplexAudioSessionReleaseOutcome {
        lock.lock()
        defer { lock.unlock() }

        guard activeLeaseIDs.remove(lease.id) != nil else { return .stale }
        guard activeLeaseIDs.isEmpty else {
            return .retained(activeLeaseCount: activeLeaseIDs.count)
        }
        guard systemActivationOwned else {
            return .releasedUnderCallKitOwnership
        }
        systemActivationOwned = false
        do {
            try system.deactivate()
            return .deactivated
        } catch {
            return .deactivationFailed(error.localizedDescription)
        }
    }

    var activeLeaseCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return activeLeaseIDs.count
    }

    func callKitDidActivate() {
        lock.lock()
        callKitOwnsAudioSession = true
        // CallKit is now authoritative even if it activated while a local lease was winding up. Its delegate owns
        // the matching deactivation; a later local release must not call setActive(false).
        systemActivationOwned = false
        lock.unlock()
    }

    func prepareForCallKit() throws {
        lock.lock()
        defer { lock.unlock() }
        try system.prepareForCallKit()
    }

    func callKitDidDeactivate() {
        lock.lock()
        callKitOwnsAudioSession = false
        lock.unlock()
    }
}

/// PocketDialVoice calls this from the host's CXProvider delegate bridge. Keeping the ownership bit in PocketVoice
/// lets every synthesizer/player/microphone lease share the same rule without importing CallKit into this package.
public enum CallKitAudioSessionOwnership {
    public static func prepareForAnswer() throws {
        try DuplexAudioSessionLeaseManager.shared.prepareForCallKit()
    }

    public static func didActivate() {
        DuplexAudioSessionLeaseManager.shared.callKitDidActivate()
    }

    public static func didDeactivate() {
        DuplexAudioSessionLeaseManager.shared.callKitDidDeactivate()
    }
}

private struct SystemDuplexAudioSession: DuplexAudioSessionSystem {
    func prepareForCallKit() throws {
        #if os(iOS)
        do {
            try configure(AVAudioSession.sharedInstance())
        } catch {
            throw VoiceError.audioSessionFailed(error.localizedDescription)
        }
        #endif
    }

    func activate() throws {
        #if os(iOS)
        do {
            let session = AVAudioSession.sharedInstance()
            try configure(session)
            try session.setActive(true)
        } catch {
            throw VoiceError.audioSessionFailed(error.localizedDescription)
        }
        #endif
    }

    func deactivate() throws {
        #if os(iOS)
        try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }

    #if os(iOS)
    private func configure(_ session: AVAudioSession) throws {
        try session.setCategory(
            .playAndRecord,
            mode: .voiceChat,
            options: [.defaultToSpeaker, .allowBluetooth]
        )
    }
    #endif
}
