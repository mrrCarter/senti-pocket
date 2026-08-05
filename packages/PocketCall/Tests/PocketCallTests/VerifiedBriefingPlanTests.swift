import XCTest
import PocketContracts
@testable import PocketCall

final class VerifiedBriefingPlanTests: XCTestCase {
    private let timestamp = Date(timeIntervalSince1970: 1_752_835_200)

    private func evidence(id: String = "ev_1") -> EvidenceRef {
        EvidenceRef(
            id: id,
            sessionId: "s1",
            sequence: 1,
            agentId: "agent-a",
            snippet: "grounded checkpoint evidence",
            ts: timestamp
        )
    }

    private func verifiedBundle(
        checkpointId: String = "cp1",
        evidence: [EvidenceRef]? = nil
    ) -> VerifiedBundle {
        let admittedEvidence = evidence ?? [self.evidence()]
        let summary = CheckpointSummary(
            checkpointId: checkpointId,
            headline: "h",
            summaryBaselineSchema: PocketBundle.expectedSummarySchema,
            grade: nil,
            perAgent: [],
            risks: [],
            blockers: []
        )
        let bundle = PocketBundle(
            contractsVersion: PocketContracts.version,
            checkpointId: checkpointId,
            sessionId: "s1",
            sequenceStart: 1,
            sequenceEnd: 2,
            summary: summary,
            evidence: admittedEvidence,
            createdAt: timestamp,
            signature: "test-only",
            signingKeyId: "test-only"
        )
        return VerifiedBundle.makeUnverifiedForTesting(bundle)
    }

    private func plan(
        checkpointId: String = "cp1",
        segments: [BriefingSegment] = [
            BriefingSegment(
                id: "seg-0",
                text: "A grounded briefing.",
                evidenceIds: ["ev_1"],
                taggedText: "[calm] A grounded briefing."
            )
        ]
    ) -> BriefingPlan {
        BriefingPlan(checkpointId: checkpointId, segments: segments)
    }

    func test_mints_only_for_exact_bundle_grounded_plan() {
        let candidate = plan()
        let bundle = verifiedBundle()
        let verified = VerifiedBriefingPlan.verify(candidate, against: bundle)
        XCTAssertEqual(verified?.plan, candidate)
        XCTAssertEqual(verified?.bundle, bundle)
    }

    func test_rejects_empty_and_cross_checkpoint_plans() {
        XCTAssertNil(VerifiedBriefingPlan.verify(
            plan(segments: []),
            against: verifiedBundle()
        ))
        XCTAssertNil(VerifiedBriefingPlan.verify(
            plan(checkpointId: "cp_other"),
            against: verifiedBundle()
        ))
    }

    func test_rejects_unicode_canonical_but_byte_distinct_checkpoint_and_citation() {
        let composedCheckpoint = "cp_caf\u{00E9}"
        let decomposedCheckpoint = "cp_cafe\u{0301}"
        XCTAssertEqual(composedCheckpoint, decomposedCheckpoint)
        XCTAssertFalse(composedCheckpoint.utf8.elementsEqual(decomposedCheckpoint.utf8))
        XCTAssertNil(VerifiedBriefingPlan.verify(
            plan(checkpointId: composedCheckpoint),
            against: verifiedBundle(checkpointId: decomposedCheckpoint)
        ))

        let composedEvidence = "ev_caf\u{00E9}"
        let decomposedEvidence = "ev_cafe\u{0301}"
        XCTAssertEqual(composedEvidence, decomposedEvidence)
        XCTAssertFalse(composedEvidence.utf8.elementsEqual(decomposedEvidence.utf8))
        XCTAssertNil(VerifiedBriefingPlan.verify(
            plan(segments: [
                BriefingSegment(id: "seg-0", text: "words", evidenceIds: [decomposedEvidence])
            ]),
            against: verifiedBundle(evidence: [evidence(id: composedEvidence)])
        ))
    }

    func test_rejects_blank_or_duplicate_segment_identity() {
        XCTAssertNil(VerifiedBriefingPlan.verify(
            plan(segments: [BriefingSegment(id: " ", text: "words", evidenceIds: ["ev_1"])]),
            against: verifiedBundle()
        ))
        XCTAssertNil(VerifiedBriefingPlan.verify(
            plan(segments: [
                BriefingSegment(id: "same", text: "first", evidenceIds: ["ev_1"]),
                BriefingSegment(id: "same", text: "second", evidenceIds: ["ev_1"])
            ]),
            against: verifiedBundle()
        ))
    }

    func test_rejects_nonvisible_or_oversized_text() {
        XCTAssertNil(VerifiedBriefingPlan.verify(
            plan(segments: [BriefingSegment(id: "seg-0", text: " \n\t ", evidenceIds: ["ev_1"])]),
            against: verifiedBundle()
        ))
        XCTAssertNil(VerifiedBriefingPlan.verify(
            plan(segments: [BriefingSegment(
                id: "seg-0",
                text: String(repeating: "x", count: PocketBundle.capSummary + 1),
                evidenceIds: ["ev_1"]
            )]),
            against: verifiedBundle()
        ))
        XCTAssertNil(VerifiedBriefingPlan.verify(
            plan(segments: [BriefingSegment(id: "seg-0", text: "words", evidenceIds: ["ev_1"], taggedText: "   ")]),
            against: verifiedBundle()
        ))
        XCTAssertNil(VerifiedBriefingPlan.verify(
            plan(segments: [BriefingSegment(
                id: "seg-0",
                text: "safe displayed words",
                evidenceIds: ["ev_1"],
                taggedText: "[calm] different spoken words"
            )]),
            against: verifiedBundle()
        ))
    }

    func test_rejects_empty_duplicate_foreign_or_malformed_citations() {
        let invalidCitationSets = [
            [],
            ["ev_1", "ev_1"],
            ["ev_foreign"],
            [" ev_1"]
        ]
        for evidenceIds in invalidCitationSets {
            let candidate = plan(segments: [
                BriefingSegment(id: "seg-0", text: "words", evidenceIds: evidenceIds)
            ])
            XCTAssertNil(VerifiedBriefingPlan.verify(candidate, against: verifiedBundle()))
        }
    }

    func test_rejects_segment_count_and_total_byte_budget_overruns() {
        let tooMany = (0...PocketBundle.capEvidence).map { index in
            BriefingSegment(id: "seg-\(index)", text: "words", evidenceIds: ["ev_1"])
        }
        XCTAssertNil(VerifiedBriefingPlan.verify(plan(segments: tooMany), against: verifiedBundle()))

        let overTotalBytes = (0..<129).map { index in
            BriefingSegment(
                id: "seg-\(index)",
                text: String(repeating: "x", count: PocketBundle.capSummary),
                evidenceIds: ["ev_1"]
            )
        }
        XCTAssertNil(VerifiedBriefingPlan.verify(plan(segments: overTotalBytes), against: verifiedBundle()))
    }

    func test_equality_preserves_admitted_plan_utf8_bytes() throws {
        let composed = "segment-caf\u{00E9}"
        let decomposed = "segment-cafe\u{0301}"
        XCTAssertEqual(composed, decomposed, "precondition: synthesized String equality is canonical")
        let bundle = verifiedBundle()
        let composedPlan = try XCTUnwrap(VerifiedBriefingPlan.verify(
            plan(segments: [BriefingSegment(id: composed, text: "words", evidenceIds: ["ev_1"])]),
            against: bundle
        ))
        let decomposedPlan = try XCTUnwrap(VerifiedBriefingPlan.verify(
            plan(segments: [BriefingSegment(id: decomposed, text: "words", evidenceIds: ["ev_1"])]),
            against: bundle
        ))

        XCTAssertNotEqual(composedPlan, decomposedPlan)

        let composedEvidence = "ev-caf\u{00E9}"
        let decomposedEvidence = "ev-cafe\u{0301}"
        let citationBundle = verifiedBundle(evidence: [
            evidence(id: composedEvidence),
            evidence(id: decomposedEvidence),
        ])
        let composedCitationPlan = try XCTUnwrap(VerifiedBriefingPlan.verify(
            plan(segments: [BriefingSegment(id: "seg-0", text: "words", evidenceIds: [composedEvidence])]),
            against: citationBundle
        ))
        let decomposedCitationPlan = try XCTUnwrap(VerifiedBriefingPlan.verify(
            plan(segments: [BriefingSegment(id: "seg-0", text: "words", evidenceIds: [decomposedEvidence])]),
            against: citationBundle
        ))

        XCTAssertEqual(composedEvidence, decomposedEvidence, "precondition: String equality aliases the citations")
        XCTAssertNotEqual(composedCitationPlan, decomposedCitationPlan)
    }
}
