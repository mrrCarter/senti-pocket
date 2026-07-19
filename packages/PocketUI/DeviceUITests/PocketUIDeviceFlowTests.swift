#if os(iOS) && canImport(XCTest)
import XCTest
import PocketUI

/// Atlas adds this file to the app's XCUITest target. PocketUI intentionally does not edit the Atlas-owned
/// XcodeGen manifest. Each scenario is deterministic, fixture-backed app composition selected at launch.
final class PocketUIDeviceFlowTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        app = XCUIApplication()
    }

    func testIncomingBriefingAnswersAndExposesBargeInAndEvidence() {
        launch(scenario: "incoming")

        XCTAssertTrue(element(PocketAccessibilityID.incomingScreen).waitForExistence(timeout: 5))
        app.buttons[PocketAccessibilityID.answer].tap()

        XCTAssertTrue(element(PocketAccessibilityID.conversationScreen).waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons[PocketAccessibilityID.interrupt].exists)
        XCTAssertTrue(app.buttons[PocketAccessibilityID.pushToTalk].exists)
        XCTAssertTrue(app.buttons[PocketAccessibilityID.stop].isHittable)
        XCTAssertTrue(app.buttons[PocketAccessibilityID.replay].isHittable)
        XCTAssertTrue(app.buttons[PocketAccessibilityID.evidenceCard("ev_1")].exists)
    }

    func testProposalRequiresExactReadBackBeforeOneConfirmation() {
        launch(scenario: "proposal")

        XCTAssertTrue(element(PocketAccessibilityID.proposalScreen).waitForExistence(timeout: 5))
        let targetSession = element(PocketAccessibilityID.proposalTargetSession)
        XCTAssertEqual(targetSession.label, "Target session")
        XCTAssertEqual(targetSession.value as? String, "954233b7-1822-42bc-9cfe-1eb95eb0357a")
        let targetSequence = element(PocketAccessibilityID.proposalTargetSequence)
        XCTAssertEqual(targetSequence.label, "Target message sequence")
        XCTAssertEqual(targetSequence.value as? String, "230180")
        let actionKind = element(PocketAccessibilityID.proposalKind)
        XCTAssertEqual(actionKind.label, "Action kind")
        XCTAssertEqual(actionKind.value as? String, "threadedReply")
        let fullMessage = element(PocketAccessibilityID.proposalMessage)
        XCTAssertEqual(fullMessage.label, "Full message text")
        XCTAssertEqual(
            fullMessage.value as? String,
            "Rotate the token but do not deploy until Omar Gate is green."
        )

        let confirm = app.buttons[PocketAccessibilityID.proposalConfirm]
        XCTAssertFalse(confirm.isEnabled)
        app.buttons[PocketAccessibilityID.proposalReadBack].tap()
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        XCTAssertTrue(confirm.isEnabled)
        confirm.tap()
        XCTAssertFalse(confirm.isEnabled, "single-use confirmation must disable synchronously")
    }

    func testCompletedReadBackExpiresWhileProposalRemainsVisible() {
        launch(scenario: "expiring-proposal")

        let confirm = app.buttons[PocketAccessibilityID.proposalConfirm]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        XCTAssertTrue(confirm.isEnabled)

        let expiry = element(PocketAccessibilityID.proposalValidationError)
        XCTAssertTrue(expiry.waitForExistence(timeout: 15))
        XCTAssertTrue(expiry.label.localizedCaseInsensitiveContains("confirmation expired"))
        XCTAssertFalse(confirm.isEnabled)
    }

    func testOfflineConfirmationRendersPendingConnectivityNotSent() {
        launch(scenario: "offline-pending")

        XCTAssertTrue(element(PocketAccessibilityID.offlineBanner).waitForExistence(timeout: 5))
        XCTAssertTrue(element(PocketAccessibilityID.receiptStatus).waitForExistence(timeout: 5))
        let status = element(PocketAccessibilityID.receiptStatus)
        XCTAssertEqual(status.label, "PENDING CONNECTIVITY")
        XCTAssertTrue((status.value as? String)?.localizedCaseInsensitiveContains("not sent") == true)
    }

    func testAccessibilityXXXLKeepsCoreContentAndControlsReachable() {
        let scenarios = [
            ("inbox", PocketAccessibilityID.inboxScreen, "pocket.inbox.item.cp_954233b7_000012", true),
            ("conversation", PocketAccessibilityID.conversationScreen, PocketAccessibilityID.pushToTalk, true),
            ("proposal", PocketAccessibilityID.proposalScreen, PocketAccessibilityID.proposalCancel, true),
            ("evidence", PocketAccessibilityID.evidenceScreen, PocketAccessibilityID.evidenceDone, true),
            ("verified-action-receipt", PocketAccessibilityID.receiptScreen, PocketAccessibilityID.receiptDone, true)
        ]

        for (scenario, screenIdentifier, criticalIdentifier, mustBeHittable) in scenarios {
            launch(
                scenario: scenario,
                extraArguments: [
                    "-UIPreferredContentSizeCategoryName",
                    "UICTContentSizeCategoryAccessibilityXXXL"
                ]
            )
            XCTAssertTrue(element(screenIdentifier).waitForExistence(timeout: 5), scenario)
            assertReachable(criticalIdentifier, mustBeHittable: mustBeHittable, scenario: scenario)
        }

        launch(
            scenario: "proposal",
            extraArguments: [
                "-UIPreferredContentSizeCategoryName",
                "UICTContentSizeCategoryAccessibilityXXXL"
            ]
        )
        XCTAssertTrue(element(PocketAccessibilityID.proposalMessage).waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons[PocketAccessibilityID.proposalReadBack].isHittable)
        XCTAssertTrue(app.buttons[PocketAccessibilityID.proposalCancel].isHittable)
    }

    func testMixedInboxSeparatesAndProtectsUnverifiedCheckpoint() {
        launch(scenario: "mixed-inbox")

        XCTAssertTrue(element(PocketAccessibilityID.inboxScreen).waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Ready to brief"].exists)
        XCTAssertTrue(app.staticTexts["Needs verification"].exists)

        let blocked = app.buttons["pocket.inbox.item.cp_blocked_private"]
        XCTAssertTrue(blocked.exists)
        XCTAssertFalse(blocked.isEnabled)
        XCTAssertFalse(app.staticTexts["SECRET BLOCKED HEADLINE"].exists)
        XCTAssertFalse(app.staticTexts["blocked-session-private"].exists)
        XCTAssertFalse(app.staticTexts["Sequences 230200–230201"].exists)

        let ready = app.buttons["pocket.inbox.item.cp_954233b7_000012"]
        XCTAssertTrue(ready.isHittable)
        ready.tap()
        XCTAssertTrue(element(PocketAccessibilityID.incomingScreen).waitForExistence(timeout: 5))
    }

    func testLongFailureTextRemainsScrollableAtAccessibilityXXXL() {
        let arguments = [
            "-UIPreferredContentSizeCategoryName",
            "UICTContentSizeCategoryAccessibilityXXXL"
        ]

        launch(scenario: "long-inbox-error", extraArguments: arguments)
        XCTAssertTrue(element(PocketAccessibilityID.inboxError).waitForExistence(timeout: 5))
        assertReachable(PocketAccessibilityID.inboxErrorEnd, mustBeHittable: true, scenario: "long-inbox-error")

        launch(scenario: "long-invalid-conversation", extraArguments: arguments)
        XCTAssertTrue(element(PocketAccessibilityID.conversationIntegrityBlocked).waitForExistence(timeout: 5))
        assertReachable(
            PocketAccessibilityID.conversationIntegrityBlockedEnd,
            mustBeHittable: true,
            scenario: "long-invalid-conversation"
        )
        XCTAssertFalse(element(PocketAccessibilityID.conversationTranscript).exists)
        XCTAssertFalse(app.buttons[PocketAccessibilityID.pushToTalk].exists)
    }

    func testPushToTalkStopsWhenAppLeavesForeground() {
        launch(scenario: "conversation")

        let pushToTalk = app.buttons[PocketAccessibilityID.pushToTalk]
        XCTAssertTrue(pushToTalk.waitForExistence(timeout: 5))
        pushToTalk.tap()
        XCTAssertEqual(pushToTalk.value as? String, "Listening")

        XCUIDevice.shared.press(.home)
        app.activate()

        XCTAssertTrue(pushToTalk.waitForExistence(timeout: 5))
        XCTAssertEqual(pushToTalk.value as? String, "Not listening")
    }

    func testInvalidCheckpointCannotBeAnswered() {
        launch(scenario: "invalid-checkpoint")

        XCTAssertTrue(element(PocketAccessibilityID.incomingScreen).waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons[PocketAccessibilityID.answer].isEnabled)
        XCTAssertFalse(element(PocketAccessibilityID.conversationScreen).exists)
    }

    func testInvalidCheckpointCannotExposeConversationContentOrControls() {
        launch(scenario: "invalid-conversation")

        XCTAssertTrue(element(PocketAccessibilityID.conversationScreen).waitForExistence(timeout: 5))
        XCTAssertTrue(element(PocketAccessibilityID.conversationIntegrityBlocked).exists)
        XCTAssertFalse(element(PocketAccessibilityID.conversationTranscript).exists)
        XCTAssertFalse(app.buttons[PocketAccessibilityID.pushToTalk].exists)
        XCTAssertFalse(app.buttons[PocketAccessibilityID.interrupt].exists)
    }

    func testReconnectingUsesQueuedNotSentLanguage() {
        launch(scenario: "reconnecting-proposal")

        XCTAssertTrue(element(PocketAccessibilityID.proposalScreen).waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons[PocketAccessibilityID.proposalConfirm].label, "Confirm and queue")
    }

    func testInvalidReceiptNeverExposesResultingSequenceAsSentProof() {
        launch(scenario: "invalid-receipt")

        let status = element(PocketAccessibilityID.receiptStatus)
        XCTAssertTrue(status.waitForExistence(timeout: 5))
        XCTAssertEqual(status.label, "Receipt verification error")
        XCTAssertFalse(element(PocketAccessibilityID.receiptResultKind).exists)
        XCTAssertFalse(element(PocketAccessibilityID.receiptActionId).exists)
        XCTAssertFalse(element(PocketAccessibilityID.receiptTargetSequence).exists)
        XCTAssertFalse(element(PocketAccessibilityID.receiptTargetCursor).exists)
        XCTAssertFalse(element(PocketAccessibilityID.receiptResultingSequence).exists)
    }

    func testVerifiedThreadReplyDisplaysActionIdentityAndExactThreadTarget() {
        launch(scenario: "verified-action-receipt")

        XCTAssertTrue(element(PocketAccessibilityID.receiptScreen).waitForExistence(timeout: 5))
        XCTAssertEqual(element(PocketAccessibilityID.receiptStatus).label, "Posted")
        XCTAssertEqual(element(PocketAccessibilityID.receiptResultKind).value as? String, "Thread action")
        XCTAssertEqual(element(PocketAccessibilityID.receiptActionId).value as? String, "action-device-1")
        XCTAssertEqual(element(PocketAccessibilityID.receiptTargetSequence).value as? String, "230180")
        XCTAssertFalse(element(PocketAccessibilityID.receiptResultingSequence).exists)
    }

    func testCoreScreensPassSystemAccessibilityAuditWhenAvailable() throws {
        guard #available(iOS 17.0, *) else {
            throw XCTSkip("performAccessibilityAudit requires iOS 17 or newer")
        }

        for scenario in [
            "inbox",
            "incoming",
            "conversation",
            "proposal",
            "evidence",
            "offline-pending",
            "verified-action-receipt",
            "invalid-checkpoint",
            "invalid-conversation",
            "long-inbox-error",
            "long-invalid-conversation",
            "invalid-receipt",
            "reconnecting-proposal",
            "mixed-inbox",
            "expiring-proposal"
        ] {
            launch(scenario: scenario)
            try app.performAccessibilityAudit()
        }
    }

    private func launch(scenario: String, extraArguments: [String] = []) {
        if app.state != .notRunning {
            app.terminate()
        }
        app.launchArguments = ["-PocketUITestScenario", scenario] + extraArguments
        app.launch()
    }

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier]
    }

    private func assertReachable(
        _ identifier: String,
        mustBeHittable: Bool,
        scenario: String,
        maxScrolls: Int = 6
    ) {
        let target = element(identifier)
        for _ in 0..<maxScrolls where !target.exists || (mustBeHittable && !target.isHittable) {
            app.swipeUp()
        }
        XCTAssertTrue(target.exists, "\(scenario): \(identifier) must exist")
        if mustBeHittable {
            XCTAssertTrue(target.isHittable, "\(scenario): \(identifier) must be reachable and hittable")
        }
    }
}
#endif
