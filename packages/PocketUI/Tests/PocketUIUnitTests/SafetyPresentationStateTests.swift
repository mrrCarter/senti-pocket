import Foundation
import XCTest
import PocketContracts
@testable import PocketCall
@testable import PocketUI

final class SafetyPresentationStateTests: XCTestCase {
    func testOnlyKnownOnlineStateCanDescribeImmediatePosting() {
        XCTAssertFalse(PocketConnectivity.online.requiresQueuedWrite)
        XCTAssertTrue(PocketConnectivity.offline(cachedAt: nil).requiresQueuedWrite)
        XCTAssertTrue(PocketConnectivity.reconnecting.requiresQueuedWrite)
    }

    func testCrossSessionPresentationIdentifiersCannotCollide() {
        XCTAssertNotEqual(
            CheckpointInboxItem.ID(sessionId: "session-a", checkpointId: "checkpoint"),
            CheckpointInboxItem.ID(sessionId: "session-b", checkpointId: "checkpoint")
        )
        XCTAssertNotEqual(
            PresentedEvidenceSelection.ID(
                sessionId: "session-a",
                checkpointId: "checkpoint",
                evidenceId: "evidence"
            ),
            PresentedEvidenceSelection.ID(
                sessionId: "session-b",
                checkpointId: "checkpoint",
                evidenceId: "evidence"
            )
        )
    }

    func testNarrationSegmentChangesDoNotChangeAccessibilityPhase() {
        XCTAssertEqual(
            VoiceConversationState.speaking(segmentId: "segment-1").accessibilityPhase,
            VoiceConversationState.speaking(segmentId: "segment-2").accessibilityPhase
        )
        XCTAssertNotEqual(
            VoiceConversationState.speaking(segmentId: "segment-2").accessibilityPhase,
            VoiceConversationState.listening.accessibilityPhase
        )
    }

    func testInvalidCheckpointFailsClosedForBriefing() {
        XCTAssertFalse(BundleIntegrityState.unverified(reason: "fixture only").allowsBriefing)
        XCTAssertFalse(BundleIntegrityState.invalid(reason: "signature mismatch").allowsBriefing)
        XCTAssertEqual(
            BundleIntegrityState.invalid(reason: "signature mismatch").failureReason,
            "signature mismatch"
        )
    }

    func testTrustedIntegrityRequiresVerifiedBundleAndRejectsMismatchedContent() throws {
        let bundle = try canonicalBundle()
        let verifiedBundle = VerifiedBundle.makeUnverifiedForTesting(bundle)
        let trusted = BundleIntegrityState(verifiedBundle: verifiedBundle)
        let inboxItem = CheckpointInboxItem(
            verifiedBundle: verifiedBundle,
            attention: .unheard,
            cachedForOffline: true
        )

        XCTAssertTrue(trusted.allowsBriefing)
        XCTAssertEqual(trusted.signingKeyId, bundle.signingKeyId)
        XCTAssertEqual(
            inboxItem.id,
            CheckpointInboxItem.ID(sessionId: bundle.sessionId, checkpointId: bundle.checkpointId)
        )

        let otherBundle = try canonicalBundle(replacingCheckpointIdWith: "cp_other")
        let mismatched = IncomingBriefingState(bundle: otherBundle, integrity: trusted)
        XCTAssertFalse(mismatched.integrity.allowsBriefing)
        XCTAssertNotNil(mismatched.integrity.failureReason)
    }

    func testEvidenceSelectionResolvesOnlyInCurrentVerifiedConversation() throws {
        let bundle = try canonicalBundle()
        let verifiedBundle = VerifiedBundle.makeUnverifiedForTesting(bundle)
        let evidence = try XCTUnwrap(bundle.evidence.first)
        let selection = try XCTUnwrap(PresentedEvidenceSelection(
            evidence: evidence,
            verifiedBundle: verifiedBundle
        ))
        XCTAssertEqual(
            selection.id,
            PresentedEvidenceSelection.ID(
                sessionId: bundle.sessionId,
                checkpointId: bundle.checkpointId,
                evidenceId: evidence.id
            )
        )
        let verifiedConversation = ConversationState(
            verifiedBundle: verifiedBundle,
            briefingPlan: PocketFixtures.briefingPlan,
            transcript: [],
            voiceState: .idle,
            isPushToTalkActive: false
        )
        XCTAssertNotNil(verifiedConversation.evidenceSelection(for: evidence))

        let sameIdentifierWithChangedContent = EvidenceRef(
            id: evidence.id,
            sessionId: evidence.sessionId,
            sequence: evidence.sequence,
            agentId: evidence.agentId,
            snippet: "caller-supplied replacement",
            ts: evidence.ts
        )
        XCTAssertNil(verifiedConversation.evidenceSelection(for: sameIdentifierWithChangedContent))

        let ambiguousBundle = PocketBundle(
            contractsVersion: bundle.contractsVersion,
            checkpointId: bundle.checkpointId,
            sessionId: bundle.sessionId,
            sequenceStart: bundle.sequenceStart,
            sequenceEnd: bundle.sequenceEnd,
            summary: bundle.summary,
            evidence: bundle.evidence + [evidence],
            createdAt: bundle.createdAt,
            signature: bundle.signature,
            signingKeyId: bundle.signingKeyId
        )
        XCTAssertNil(PresentedEvidenceSelection(
            evidence: evidence,
            verifiedBundle: VerifiedBundle.makeUnverifiedForTesting(ambiguousBundle)
        ))

        let visible = PocketUIState(
            destination: .conversation(verifiedConversation),
            connectivity: .online,
            presentedEvidence: selection
        )
        XCTAssertEqual(visible.resolvedPresentedEvidence, evidence)

        let navigatedAway = PocketUIState(
            destination: .inbox(CheckpointInboxState(items: [])),
            connectivity: .online,
            presentedEvidence: selection
        )
        XCTAssertNil(navigatedAway.resolvedPresentedEvidence)

        let invalidConversation = ConversationState(
            bundle: bundle,
            integrity: .invalid(reason: "signature changed"),
            briefingPlan: PocketFixtures.briefingPlan,
            transcript: [],
            voiceState: .idle,
            isPushToTalkActive: false
        )
        let invalidated = PocketUIState(
            destination: .conversation(invalidConversation),
            connectivity: .online,
            presentedEvidence: selection
        )
        XCTAssertNil(invalidated.resolvedPresentedEvidence)

        let otherBundle = try canonicalBundle(replacingCheckpointIdWith: "cp_other")
        let wrongConversation = ConversationState(
            verifiedBundle: VerifiedBundle.makeUnverifiedForTesting(otherBundle),
            briefingPlan: PocketFixtures.briefingPlan,
            transcript: [],
            voiceState: .idle,
            isPushToTalkActive: false
        )
        let wrongBundle = PocketUIState(
            destination: .conversation(wrongConversation),
            connectivity: .online,
            presentedEvidence: selection
        )
        XCTAssertNil(wrongBundle.resolvedPresentedEvidence)
    }

    private func canonicalBundle(replacingCheckpointIdWith replacement: String? = nil) throws -> PocketBundle {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("PocketContracts/Fixtures/canonical_checkpoint.json")
        var json = try String(contentsOf: url, encoding: .utf8)
        if let replacement {
            json = json.replacingOccurrences(of: "cp_954233b7_000012", with: replacement)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(PocketBundle.self, from: Data(json.utf8))
    }
}
