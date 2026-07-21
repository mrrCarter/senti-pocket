import AVFoundation
import Foundation

struct DuplexAudioSessionLease: Hashable, Sendable {
    fileprivate let id: UUID
}

enum DuplexAudioSessionReleaseOutcome: Equatable, Sendable {
    case stale
    case retained(activeLeaseCount: Int)
    case deactivated
    case deactivationFailed(String)

    var error: VoiceError? {
        guard case .deactivationFailed(let reason) = self else { return nil }
        return .audioSessionFailed("audio-session deactivation failed: \(reason)")
    }
}

protocol DuplexAudioSessionSystem: Sendable {
    func activate() throws
    func deactivate() throws
}

final class DuplexAudioSessionLeaseManager: @unchecked Sendable {
    static let shared = DuplexAudioSessionLeaseManager(system: SystemDuplexAudioSession())

    private let lock = NSLock()
    private let system: any DuplexAudioSessionSystem
    private var activeLeaseIDs = Set<UUID>()

    init(system: any DuplexAudioSessionSystem) {
        self.system = system
    }

    func acquire() throws -> DuplexAudioSessionLease {
        lock.lock()
        defer { lock.unlock() }

        if activeLeaseIDs.isEmpty {
            try system.activate()
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
}

private struct SystemDuplexAudioSession: DuplexAudioSessionSystem {
    func activate() throws {
        #if os(iOS)
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(
                .playAndRecord,
                mode: .voiceChat,
                options: [.defaultToSpeaker, .allowBluetooth]
            )
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
}
