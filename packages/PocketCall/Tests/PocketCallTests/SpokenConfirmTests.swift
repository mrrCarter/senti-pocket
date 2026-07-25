import XCTest
@testable import PocketCall

final class SpokenConfirmTests: XCTestCase {
    func testExplicitConfirmPasses() {
        XCTAssertEqual(SpokenConfirm.verdict(for: "confirm"), .confirmed)
        XCTAssertEqual(SpokenConfirm.verdict(for: "Confirm."), .confirmed)
        XCTAssertEqual(SpokenConfirm.verdict(for: "  CONFIRM  "), .confirmed)
        XCTAssertEqual(SpokenConfirm.verdict(for: "confirmed"), .confirmed)
        XCTAssertEqual(SpokenConfirm.verdict(for: "please confirm and send it"), .confirmed)
    }

    func testExplicitDeclineAborts() {
        XCTAssertEqual(SpokenConfirm.verdict(for: "cancel"), .declined)
        XCTAssertEqual(SpokenConfirm.verdict(for: "no"), .declined)
        XCTAssertEqual(SpokenConfirm.verdict(for: "don't"), .declined)
        XCTAssertEqual(SpokenConfirm.verdict(for: "do not send"), .declined)
        XCTAssertEqual(SpokenConfirm.verdict(for: "stop"), .declined)
        XCTAssertEqual(SpokenConfirm.verdict(for: "abort"), .declined)
    }

    /// SAFETY (warden bar 2b): ambient / non-explicit speech must NEVER confirm — deterministic confirm, not keyword.
    func testAmbientSpeechNeverConfirms() {
        for phrase in ["umm yeah go", "yes", "okay sure", "go ahead", "sounds good", "yeah do it", "alright"] {
            if case .confirmed = SpokenConfirm.verdict(for: phrase) {
                XCTFail("ambient '\(phrase)' must NOT confirm")
            }
        }
    }

    /// SAFETY: a negated confirm must NEVER confirm (it must re-ask, never post).
    func testNegatedConfirmNeverConfirms() {
        for phrase in ["don't confirm", "do not confirm", "no confirm", "not confirmed",
                       "cannot confirm", "won't confirm", "never confirm"] {
            if case .confirmed = SpokenConfirm.verdict(for: phrase) {
                XCTFail("negated '\(phrase)' must NOT confirm")
            }
        }
    }

    /// SAFETY belt: 'confirm' buried in a long utterance is not the deterministic response we asked for → re-ask.
    func testConfirmBuriedInLongUtteranceIsUnclear() {
        let long = "well i think if it all looks right then sure go ahead and confirm that whole thing for me"
        guard case .unclear = SpokenConfirm.verdict(for: long) else {
            return XCTFail("'confirm' buried in a long ramble → unclear, never confirmed")
        }
    }

    /// SAFETY: nothing recognized → unclear (re-ask), never a post.
    func testEmptyOrNoiseIsUnclear() {
        guard case .unclear = SpokenConfirm.verdict(for: "") else { return XCTFail("empty → unclear") }
        guard case .unclear = SpokenConfirm.verdict(for: "   ... !! ") else { return XCTFail("punctuation-only → unclear") }
        guard case .unclear = SpokenConfirm.verdict(for: "the weather is nice") else { return XCTFail("unrelated → unclear") }
    }

    /// The decline-collides-with-confirm case is unclear (re-ask), and explicitly NOT confirmed.
    func testConfirmWithNegationIsUnclearNotConfirmed() {
        guard case .unclear = SpokenConfirm.verdict(for: "don't confirm") else {
            return XCTFail("'don't confirm' → unclear (never confirmed)")
        }
    }
}
