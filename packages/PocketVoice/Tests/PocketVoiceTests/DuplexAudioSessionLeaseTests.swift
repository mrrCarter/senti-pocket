@testable import PocketVoice
import Foundation
import XCTest

final class DuplexAudioSessionLeaseTests: XCTestCase {
    func testActivatesOnFirstLeaseAndDeactivatesAfterLastRelease() throws {
        let system = RecordingDuplexAudioSessionSystem()
        let manager = DuplexAudioSessionLeaseManager(system: system)

        let microphone = try manager.acquire()
        let narration = try manager.acquire()

        XCTAssertEqual(manager.activeLeaseCount, 2)
        XCTAssertEqual(system.activationCount, 1)
        XCTAssertEqual(system.deactivationCount, 0)

        XCTAssertEqual(manager.release(microphone), .retained(activeLeaseCount: 1))
        XCTAssertEqual(manager.activeLeaseCount, 1)
        XCTAssertEqual(system.deactivationCount, 0)

        XCTAssertEqual(manager.release(narration), .deactivated)
        XCTAssertEqual(manager.activeLeaseCount, 0)
        XCTAssertEqual(system.deactivationCount, 1)
    }

    func testDuplicateAndStaleReleasesCannotAffectANewerLease() throws {
        let system = RecordingDuplexAudioSessionSystem()
        let manager = DuplexAudioSessionLeaseManager(system: system)
        let oldLease = try manager.acquire()

        XCTAssertEqual(manager.release(oldLease), .deactivated)
        XCTAssertEqual(manager.release(oldLease), .stale)
        XCTAssertEqual(system.deactivationCount, 1)

        let newLease = try manager.acquire()
        XCTAssertEqual(manager.release(oldLease), .stale)
        XCTAssertEqual(manager.activeLeaseCount, 1)
        XCTAssertEqual(system.deactivationCount, 1)

        XCTAssertEqual(manager.release(newLease), .deactivated)
        XCTAssertEqual(manager.activeLeaseCount, 0)
        XCTAssertEqual(system.activationCount, 2)
        XCTAssertEqual(system.deactivationCount, 2)
    }

    func testFailedActivationDoesNotMintALease() throws {
        let system = RecordingDuplexAudioSessionSystem()
        system.failNextActivation = true
        let manager = DuplexAudioSessionLeaseManager(system: system)

        XCTAssertThrowsError(try manager.acquire())
        XCTAssertEqual(manager.activeLeaseCount, 0)
        XCTAssertEqual(system.activationCount, 1)
        XCTAssertEqual(system.deactivationCount, 0)

        let lease = try manager.acquire()
        XCTAssertEqual(manager.activeLeaseCount, 1)
        XCTAssertEqual(system.activationCount, 2)
        manager.release(lease)
        XCTAssertEqual(system.deactivationCount, 1)
    }

    func testDeactivationFailureIsObservableAndDoesNotRetainLogicalOwnership() throws {
        let system = RecordingDuplexAudioSessionSystem()
        let manager = DuplexAudioSessionLeaseManager(system: system)
        let lease = try manager.acquire()
        system.failNextDeactivation = true

        XCTAssertEqual(
            manager.release(lease),
            .deactivationFailed("recording audio-session deactivation failed")
        )
        XCTAssertEqual(manager.activeLeaseCount, 0)
        XCTAssertEqual(system.deactivationCount, 1)

        let nextLease = try manager.acquire()
        XCTAssertEqual(system.activationCount, 2)
        XCTAssertEqual(manager.release(nextLease), .deactivated)
    }
}

private final class RecordingDuplexAudioSessionSystem: DuplexAudioSessionSystem, @unchecked Sendable {
    private enum StubError: LocalizedError {
        case activationFailed
        case deactivationFailed

        var errorDescription: String? {
            switch self {
            case .activationFailed: return "recording audio-session activation failed"
            case .deactivationFailed: return "recording audio-session deactivation failed"
            }
        }
    }

    var activationCount = 0
    var deactivationCount = 0
    var failNextActivation = false
    var failNextDeactivation = false

    func activate() throws {
        activationCount += 1
        if failNextActivation {
            failNextActivation = false
            throw StubError.activationFailed
        }
    }

    func deactivate() throws {
        deactivationCount += 1
        if failNextDeactivation {
            failNextDeactivation = false
            throw StubError.deactivationFailed
        }
    }
}
