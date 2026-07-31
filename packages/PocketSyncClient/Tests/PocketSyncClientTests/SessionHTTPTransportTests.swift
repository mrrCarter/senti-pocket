import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import PocketSyncClient

private final class SessionTransportURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var handler: ((URLRequest) -> (HTTPURLResponse, Data))?
    private static var requests: [URLRequest] = []

    static func reset(handler: @escaping (URLRequest) -> (HTTPURLResponse, Data)) {
        lock.lock()
        self.handler = handler
        requests = []
        lock.unlock()
    }

    static func capturedRequests() -> [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return requests
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        Self.requests.append(request)
        let handler = Self.handler
        Self.lock.unlock()
        guard let handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let (response, data) = handler(request)
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

final class SessionHTTPTransportTests: XCTestCase {
    private func http(_ request: URLRequest, status: Int, headers: [String: String] = [:]) -> HTTPURLResponse {
        HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: nil,
            headerFields: headers
        )!
    }

    private func makeTransport(
        origin: URL? = URL(string: "https://api.example.test")!,
        token: @escaping @Sendable () -> String? = { "session-token" },
        handler: @escaping (URLRequest) -> (HTTPURLResponse, Data)
    ) -> HTTPSessionTransport {
        SessionTransportURLProtocol.reset(handler: handler)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SessionTransportURLProtocol.self]
        return HTTPSessionTransport(
            apiBaseURL: origin,
            urlSession: URLSession(configuration: configuration),
            tokenProvider: token
        )
    }

    func test_session_list_uses_exact_route_query_and_bearer() async throws {
        let body = Data("""
        {"sessions":[{"sessionId":"room_1","status":"active","archiveStatus":"active",
        "visibility":"private","membershipRole":"owner","title":"Room","summaryText":null,
        "summaryGeneratedAt":null,"summaryModel":null,"agentCount":2,"eventCount":4,"totalCostUsd":0,
        "createdAt":null,"lastActivityAt":null,"expiresAt":null,"killedAt":null,"templateName":null,
        "codebasePath":null,"s3ArchivePath":null}],"count":1,"include_archived":true,
        "next_cursor":"next-1","has_more":true}
        """.utf8)
        let transport = makeTransport { request in
            (self.http(request, status: 200), body)
        }

        let page = try await transport.listSessions(includeArchived: true, limit: 75, cursor: "cursor-1")

        XCTAssertEqual(page.sessions.map(\.sessionId), ["room_1"])
        let request = try XCTUnwrap(SessionTransportURLProtocol.capturedRequests().first)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.url?.path, "/api/v1/sessions")
        let query = try XCTUnwrap(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: query.map { ($0.name, $0.value ?? "") }), [
            "include_archived": "true",
            "limit": "75",
            "cursor": "cursor-1"
        ])
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer session-token")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
    }

    func test_all_read_surfaces_use_source_bound_routes_and_queries() async throws {
        let transport = makeTransport { request in
            let path = request.url!.path
            let body: String
            switch path {
            case "/api/v1/sessions/room_1/events":
                body = #"{"events":[]}"#
            case "/api/v1/sessions/room_1/events/before":
                body = #"{"events":[],"count":0,"next_before_sequence":null,"has_more":false,"partial":false}"#
            case "/api/v1/sessions/room_1/actions":
                body = #"{"sessionId":"room_1","actions":[],"count":0,"projection":{}}"#
            case "/api/v1/sessions/room_1/checkpoints":
                body = #"{"checkpoints":[],"count":0}"#
            default:
                body = "{}"
            }
            return (self.http(request, status: 200), Data(body.utf8))
        }

        _ = try await transport.listEvents(sessionId: "room_1", after: "cursor-a", fromSequence: 41, limit: 80)
        _ = try await transport.listEventsBefore(sessionId: "room_1", beforeSequence: 40, limit: 60)
        _ = try await transport.listActions(
            sessionId: "room_1",
            targetSequenceId: 39,
            targetActionId: "e06bc3f7-5675-4e04-bf12-ecf0233cf6f2",
            limit: 300
        )
        _ = try await transport.listCheckpoints(sessionId: "room_1", limit: 120)

        let requests = SessionTransportURLProtocol.capturedRequests()
        XCTAssertEqual(requests.map { $0.url!.path }, [
            "/api/v1/sessions/room_1/events",
            "/api/v1/sessions/room_1/events/before",
            "/api/v1/sessions/room_1/actions",
            "/api/v1/sessions/room_1/checkpoints"
        ])
        let queries = requests.map {
            Dictionary(uniqueKeysWithValues: (URLComponents(
                url: $0.url!,
                resolvingAgainstBaseURL: false
            )?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        }
        XCTAssertEqual(queries[0], ["after": "cursor-a", "from_sequence": "41", "limit": "80"])
        XCTAssertEqual(queries[1], ["before_sequence": "40", "limit": "60"])
        XCTAssertEqual(queries[2], [
            "targetSequenceId": "39",
            "targetActionId": "e06bc3f7-5675-4e04-bf12-ecf0233cf6f2",
            "limit": "300"
        ])
        XCTAssertEqual(queries[3], ["limit": "120"])
    }

    func test_missing_or_invalid_configuration_fails_before_token_and_network() async {
        let invalidOrigins: [URL?] = [
            nil,
            URL(string: "http://api.example.test"),
            URL(string: "https://user@api.example.test"),
            URL(string: "https://api.example.test/prefix"),
            URL(string: "https://%61pi.example.test")
        ]
        for origin in invalidOrigins {
            let probe = LockedCounter()
            let transport = makeTransport(origin: origin, token: {
                probe.increment()
                return "must-not-be-read"
            }) { request in
                (self.http(request, status: 200), Data(#"{"sessions":[],"count":0,"include_archived":false,"next_cursor":null,"has_more":false}"#.utf8))
            }
            await expect(.notConfigured) {
                try await transport.listSessions(includeArchived: false, limit: 50, cursor: nil)
            }
            XCTAssertEqual(probe.value, 0)
            XCTAssertEqual(SessionTransportURLProtocol.capturedRequests().count, 0)
        }
    }

    func test_missing_token_fails_before_network() async {
        let transport = makeTransport(token: { nil }) { request in
            (self.http(request, status: 200), Data())
        }
        await expect(.notLoggedIn) {
            try await transport.listSessions(includeArchived: false, limit: 50, cursor: nil)
        }
        XCTAssertEqual(SessionTransportURLProtocol.capturedRequests().count, 0)
    }

    func test_malformed_bearer_fails_before_network() async {
        let transport = makeTransport(token: { "token\r\nX-Injected: true" }) { request in
            (self.http(request, status: 200), Data())
        }
        await expect(.invalidRequest) {
            try await transport.listSessions(includeArchived: false, limit: 50, cursor: nil)
        }
        XCTAssertEqual(SessionTransportURLProtocol.capturedRequests().count, 0)
    }

    func test_status_taxonomy_is_fail_closed_and_body_agnostic() async {
        let cases: [(Int, [String: String], SessionTransportError)] = [
            (401, [:], .reauthenticationRequired),
            (403, [:], .accessDenied),
            (429, ["Retry-After": "17"], .rateLimited(retryAfterSeconds: 17)),
            (503, [:], .service(statusCode: 503))
        ]
        for (status, headers, expected) in cases {
            let transport = makeTransport { request in
                (self.http(request, status: status, headers: headers), Data(#"{"private":"must-not-surface"}"#.utf8))
            }
            await expect(expected) {
                try await transport.listSessions(includeArchived: false, limit: 50, cursor: nil)
            }
        }
    }

    func test_not_found_taxonomy_preserves_session_existence_boundary_only() async {
        let transport = makeTransport { request in
            (self.http(request, status: 404), Data(#"{"private":"must-not-surface"}"#.utf8))
        }
        await expect(.service(statusCode: 404)) {
            try await transport.listSessions(includeArchived: false, limit: 50, cursor: nil)
        }
        await expect(.accessDenied) {
            try await transport.listEvents(sessionId: "room_1", after: nil, fromSequence: nil, limit: 50)
        }
    }

    func test_invalid_request_never_reaches_urlsession() async {
        let transport = makeTransport { request in
            (self.http(request, status: 200), Data())
        }
        await expect(.invalidRequest) {
            try await transport.listEvents(sessionId: "../other", after: nil, fromSequence: nil, limit: 50)
        }
        await expect(.invalidRequest) {
            try await transport.listEvents(sessionId: ".", after: nil, fromSequence: nil, limit: 50)
        }
        await expect(.invalidRequest) {
            try await transport.listEvents(sessionId: "..", after: nil, fromSequence: nil, limit: 50)
        }
        await expect(.invalidRequest) {
            try await transport.listEvents(sessionId: "røom", after: nil, fromSequence: nil, limit: 50)
        }
        await expect(.invalidRequest) {
            try await transport.listSessions(includeArchived: false, limit: 201, cursor: nil)
        }
        XCTAssertEqual(SessionTransportURLProtocol.capturedRequests().count, 0)
    }

    private func expect<T>(
        _ expected: SessionTransportError,
        operation: () async throws -> T,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await operation()
            XCTFail("expected \(expected)", file: file, line: line)
        } catch let error as SessionTransportError {
            XCTAssertEqual(error, expected, file: file, line: line)
        } catch {
            XCTFail("unexpected error \(error)", file: file, line: line)
        }
    }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func increment() {
        lock.lock()
        storage += 1
        lock.unlock()
    }
}
