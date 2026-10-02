#if canImport(CallKit) && canImport(PushKit)
import XCTest
@testable import SentiPocketApp

final class DialHostLifecycleTests: XCTestCase {
    func test_answer_then_activation_starts_exactly_once() {
        var lifecycle = DialCallLifecycle()
        let uuid = UUID()
        XCTAssertTrue(lifecycle.reported(callUUID: uuid, dialId: "dial-1"))
        XCTAssertEqual(
            lifecycle.answered(callUUID: uuid, dialId: "dial-1", revision: 7),
            .waiting
        )

        XCTAssertEqual(
            lifecycle.audioActivated(callUUID: uuid),
            .init(callUUID: uuid, dialId: "dial-1", revision: 7)
        )
        XCTAssertNil(lifecycle.audioActivated(callUUID: uuid), "duplicate CallKit activation must not start twice")
        XCTAssertEqual(
            lifecycle.answered(callUUID: uuid, dialId: "dial-1", revision: 8),
            .rejected
        )
    }

    func test_activation_before_answer_is_not_credited_to_a_later_answer() {
        var lifecycle = DialCallLifecycle()
        let uuid = UUID()
        XCTAssertTrue(lifecycle.reported(callUUID: uuid, dialId: "dial-2"))
        XCTAssertNil(lifecycle.audioActivated(callUUID: uuid))

        XCTAssertEqual(
            lifecycle.answered(callUUID: uuid, dialId: "dial-2", revision: 3),
            .waiting
        )
        XCTAssertEqual(
            lifecycle.audioActivated(callUUID: uuid),
            .init(callUUID: uuid, dialId: "dial-2", revision: 3)
        )
    }

    func test_end_between_answer_and_activation_makes_late_activation_inert() {
        var lifecycle = DialCallLifecycle()
        let uuid = UUID()
        XCTAssertTrue(lifecycle.reported(callUUID: uuid, dialId: "dial-3"))
        XCTAssertEqual(
            lifecycle.answered(callUUID: uuid, dialId: "dial-3", revision: 1),
            .waiting
        )

        XCTAssertEqual(lifecycle.ended(callUUID: uuid), "dial-3")
        XCTAssertNil(lifecycle.audioActivated(callUUID: uuid))
        XCTAssertEqual(
            lifecycle.answered(callUUID: uuid, dialId: "dial-3", revision: 2),
            .rejected
        )
    }

    func test_deactivation_terminates_the_credited_episode() {
        var lifecycle = DialCallLifecycle()
        let uuid = UUID()
        XCTAssertTrue(lifecycle.reported(callUUID: uuid, dialId: "dial-4"))
        XCTAssertEqual(
            lifecycle.answered(callUUID: uuid, dialId: "dial-4", revision: 4),
            .waiting
        )
        XCTAssertEqual(
            lifecycle.audioActivated(callUUID: uuid),
            .init(callUUID: uuid, dialId: "dial-4", revision: 4)
        )

        XCTAssertEqual(lifecycle.audioDeactivated(callUUID: uuid), uuid)
        XCTAssertFalse(lifecycle.isReported(uuid))
        XCTAssertEqual(
            lifecycle.answered(callUUID: uuid, dialId: "dial-4", revision: 1),
            .rejected
        )
        XCTAssertNil(lifecycle.audioDeactivated(callUUID: uuid), "late duplicate deactivation is inert")
    }

    func test_deactivation_while_waiting_for_activation_is_terminal() {
        var lifecycle = DialCallLifecycle()
        let uuid = UUID()
        XCTAssertTrue(lifecycle.reported(callUUID: uuid, dialId: "dial-waiting"))
        XCTAssertEqual(
            lifecycle.answered(callUUID: uuid, dialId: "dial-waiting", revision: 2),
            .waiting
        )

        XCTAssertEqual(lifecycle.audioDeactivated(callUUID: uuid), uuid)
        XCTAssertNil(lifecycle.audioActivated(callUUID: uuid))
        XCTAssertEqual(
            lifecycle.answered(callUUID: uuid, dialId: "dial-waiting", revision: 3),
            .rejected
        )
    }

    func test_callkit_uuid_not_dial_id_owns_the_episode() {
        var lifecycle = DialCallLifecycle()
        let owner = UUID()
        let foreign = UUID()
        XCTAssertTrue(lifecycle.reported(callUUID: owner, dialId: "repeated-dial"))
        XCTAssertFalse(
            lifecycle.reported(callUUID: foreign, dialId: "repeated-dial"),
            "maximum-one-call lifecycle refuses a second UUID even when the dial id repeats"
        )
        XCTAssertEqual(
            lifecycle.answered(callUUID: foreign, dialId: "repeated-dial", revision: 1),
            .rejected
        )
        XCTAssertNil(lifecycle.audioActivated(callUUID: foreign))
        XCTAssertNil(lifecycle.audioDeactivated(callUUID: foreign))
    }

    func test_reset_and_authorization_gate_revoke_synchronously() {
        var lifecycle = DialCallLifecycle()
        let uuid = UUID()
        XCTAssertTrue(lifecycle.reported(callUUID: uuid, dialId: "dial-5"))
        XCTAssertNil(lifecycle.audioActivated(callUUID: uuid))

        let gate = DialCallAuthorizationGate()
        gate.open(uuid)
        XCTAssertTrue(gate.permits(uuid))
        lifecycle.reset()
        gate.closeAll()

        XCTAssertFalse(lifecycle.isReported(uuid))
        XCTAssertFalse(gate.permits(uuid))
        XCTAssertEqual(
            lifecycle.answered(callUUID: uuid, dialId: "dial-5", revision: 9),
            .rejected
        )
    }
}
#endif
