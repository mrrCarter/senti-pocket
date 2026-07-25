import XCTest
@testable import PocketCall

final class DialReplyMarkerTests: XCTestCase {

    // MARK: - The load-bearing invariant: no marker -> QUESTION, never a write

    func test_no_marker_is_a_question() {
        XCTAssertEqual(DialReplyMarker.classify("did the token rotate?"), .question)
        XCTAssertEqual(DialReplyMarker.classify("what should we do about the auth scope"), .question)
    }

    /// CRITICAL: an utterance that SOUNDS like a reply but carries no marker is STILL a question — it must be
    /// answered, never posted. Ambiguity resolves toward "answer," never "post."
    func test_reply_sounding_utterance_without_marker_is_a_question() {
        XCTAssertEqual(DialReplyMarker.classify("ship it"), .question)
        XCTAssertEqual(DialReplyMarker.classify("yes, approve the change"), .question)
        XCTAssertEqual(DialReplyMarker.classify("tell them we'll do it tomorrow"), .question)
    }

    func test_empty_or_whitespace_is_a_question() {
        XCTAssertEqual(DialReplyMarker.classify(""), .question)
        XCTAssertEqual(DialReplyMarker.classify("    \n "), .question)
    }

    // MARK: - Prefix, NOT contains

    /// A marker embedded mid-sentence (not a prefix) must NOT trigger a write — it's a question about the marker.
    func test_marker_not_at_prefix_is_a_question() {
        XCTAssertEqual(DialReplyMarker.classify("what did you mean by 'my reply is'?"), .question)
        XCTAssertEqual(DialReplyMarker.classify("should my reply be shorter?"), .question)
        XCTAssertEqual(DialReplyMarker.classify("remind me how post this works"), .question)
    }

    // MARK: - Marker + dictated text -> reply(verbatim)

    func test_marker_with_text_returns_verbatim_reply() {
        XCTAssertEqual(DialReplyMarker.classify("my reply is ship the release tonight"), .reply("ship the release tonight"))
        XCTAssertEqual(DialReplyMarker.classify("here's my reply approve it"), .reply("approve it"))
        XCTAssertEqual(DialReplyMarker.classify("post this the vote passed"), .reply("the vote passed"))
    }

    func test_reply_preserves_original_casing() {
        XCTAssertEqual(DialReplyMarker.classify("my reply is Ship It To Prod"), .reply("Ship It To Prod"))
    }

    func test_marker_is_case_insensitive() {
        XCTAssertEqual(DialReplyMarker.classify("My Reply Is ship it"), .reply("ship it"))
        XCTAssertEqual(DialReplyMarker.classify("REPLY: approve"), .reply("approve"))
    }

    func test_separators_between_marker_and_reply_are_trimmed() {
        XCTAssertEqual(DialReplyMarker.classify("reply:  ship it"), .reply("ship it"))
        XCTAssertEqual(DialReplyMarker.classify("my reply is: ship it"), .reply("ship it"))
        XCTAssertEqual(DialReplyMarker.classify("my reply is - ship it"), .reply("ship it"))
    }

    // MARK: - Bare marker -> awaitingReply (caller takes the next listen verbatim)

    func test_bare_marker_awaits_the_next_utterance() {
        XCTAssertEqual(DialReplyMarker.classify("my reply is"), .awaitingReply)
        XCTAssertEqual(DialReplyMarker.classify("here is my reply"), .awaitingReply)
        XCTAssertEqual(DialReplyMarker.classify("reply:"), .awaitingReply)
        XCTAssertEqual(DialReplyMarker.classify("post this   "), .awaitingReply)
    }

    // MARK: - Every marker in the closed set is honored

    func test_all_markers_trigger() {
        for marker in DialReplyMarker.markers {
            XCTAssertEqual(DialReplyMarker.classify("\(marker) do the thing"), .reply("do the thing"),
                           "marker \(marker) should trigger a reply")
        }
    }
}
