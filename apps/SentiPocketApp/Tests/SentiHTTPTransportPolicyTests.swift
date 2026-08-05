import XCTest
@testable import SentiPocketApp

final class SentiHTTPTransportPolicyTests: XCTestCase {
    func test_production_session_has_bounded_interactive_deadlines() {
        let configuration = SentiHTTPTransportPolicy.makeConfiguration()
        XCTAssertEqual(configuration.timeoutIntervalForRequest, 15)
        XCTAssertEqual(configuration.timeoutIntervalForResource, 60)
        XCTAssertGreaterThanOrEqual(
            configuration.timeoutIntervalForResource,
            configuration.timeoutIntervalForRequest
        )

        let session = SentiHTTPTransportPolicy.liveSession
        XCTAssertEqual(session.configuration.timeoutIntervalForRequest, 15)
        XCTAssertEqual(session.configuration.timeoutIntervalForResource, 60)
    }

    func test_checkpoint_session_is_ephemeral_content_free_and_bounded() {
        let configuration = SentiHTTPTransportPolicy.makeCheckpointConfiguration()
        XCTAssertEqual(configuration.timeoutIntervalForRequest, 15)
        XCTAssertEqual(configuration.timeoutIntervalForResource, 60)
        XCTAssertEqual(configuration.requestCachePolicy, .reloadIgnoringLocalCacheData)
        XCTAssertNil(configuration.urlCache)
        XCTAssertFalse(configuration.httpShouldSetCookies)
        XCTAssertNil(configuration.httpCookieStorage)
        XCTAssertNil(configuration.urlCredentialStorage)

        let session = SentiHTTPTransportPolicy.checkpointSession
        XCTAssertEqual(session.configuration.timeoutIntervalForRequest, 15)
        XCTAssertEqual(session.configuration.timeoutIntervalForResource, 60)
        XCTAssertEqual(session.configuration.requestCachePolicy, .reloadIgnoringLocalCacheData)
        XCTAssertNil(session.configuration.urlCache)
        XCTAssertFalse(session.configuration.httpShouldSetCookies)
        XCTAssertNil(session.configuration.httpCookieStorage)
        XCTAssertNil(session.configuration.urlCredentialStorage)
    }
}
