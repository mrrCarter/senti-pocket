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
}
