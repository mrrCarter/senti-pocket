import XCTest
@testable import SentiPocketApp

/// Locks DeviceRingRegistrationClient — the device-side outbound-binding (authed POST /dial/register) that lets a ring
/// be ADDRESSED to this device. Uses a URLProtocol stub (the DialHydrationClientTests pattern) + the injectable
/// tokenProvider, so the POST is hermetic. The load-bearing test is `no humanId in the body` (warden gate #2:
/// the gateway derives humanId from auth; a body humanId would be a confused-deputy vector).
final class RegisterStubURLProtocol: URLProtocol {
    static let lock = NSLock()
    static var status: Int = 200
    static var networkError: URLError?
    static var lastRequest: URLRequest?
    static var lastBody: Data?
    static var requestCount = 0

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        Self.lastRequest = request
        Self.lastBody = Self.bodyData(request)
        Self.requestCount += 1
        let status = Self.status
        let err = Self.networkError
        Self.lock.unlock()

        if let err {
            client?.urlProtocol(self, didFailWithError: err)
            return
        }
        let resp = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil,
                                   headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("{}".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}

    /// URLSession moves `httpBody` into `httpBodyStream` by the time a URLProtocol sees the request — read the stream.
    static func bodyData(_ request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open(); defer { stream.close() }
        var data = Data(); let bufSize = 4096; var buf = [UInt8](repeating: 0, count: bufSize)
        while stream.hasBytesAvailable {
            let read = stream.read(&buf, maxLength: bufSize)
            if read <= 0 { break }
            data.append(buf, count: read)
        }
        return data
    }
}

final class DeviceRingRegistrationClientTests: XCTestCase {

    private let base = URL(string: "https://gw.example.com")!

    private func makeClient(token: String = "tok123") -> DeviceRingRegistrationClient {
        RegisterStubURLProtocol.lock.lock()
        RegisterStubURLProtocol.status = 200
        RegisterStubURLProtocol.networkError = nil
        RegisterStubURLProtocol.lastRequest = nil
        RegisterStubURLProtocol.lastBody = nil
        RegisterStubURLProtocol.lock.unlock()
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [RegisterStubURLProtocol.self]
        return DeviceRingRegistrationClient(apiBaseURL: base,
                                            urlSession: URLSession(configuration: cfg),
                                            tokenProvider: { token.isEmpty ? nil : token })
    }

    private func setStatus(_ code: Int) {
        RegisterStubURLProtocol.lock.lock(); RegisterStubURLProtocol.status = code; RegisterStubURLProtocol.lock.unlock()
    }

    private func expect(_ client: DeviceRingRegistrationClient,
                        _ want: DeviceRingRegistrationError,
                        voipToken: String = "aabbcc", sessionId: String = "6cf7e861",
                        file: StaticString = #filePath, line: UInt = #line) async {
        do {
            try await client.register(voipToken: voipToken, sessionId: sessionId)
            XCTFail("expected \(want)", file: file, line: line)
        } catch let e as DeviceRingRegistrationError {
            XCTAssertEqual(e, want, file: file, line: line)
        } catch {
            XCTFail("wrong error type: \(error)", file: file, line: line)
        }
    }

    // MARK: - success: authed POST, correct body, NO humanId

    func test_register_success_posts_authed_body_without_humanId() async throws {
        let client = makeClient()
        try await client.register(voipToken: "aabbccddeeff", sessionId: "6cf7e861", platform: "apns")

        let req = RegisterStubURLProtocol.lastRequest
        XCTAssertEqual(req?.httpMethod, "POST")
        XCTAssertEqual(req?.url?.path, "/dial/register")
        XCTAssertEqual(req?.value(forHTTPHeaderField: "Authorization"), "Bearer tok123")

        let body = try XCTUnwrap(RegisterStubURLProtocol.lastBody)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["voipToken"] as? String, "aabbccddeeff")
        XCTAssertEqual(json["sessionId"] as? String, "6cf7e861")
        XCTAssertEqual(json["platform"] as? String, "apns")
        // THE load-bearing gate: the device NEVER sends humanId — the gateway derives it from the Bearer.
        XCTAssertNil(json["humanId"], "device must NOT send humanId (confused-deputy vector)")
        XCTAssertNil(json["human_id"])
        XCTAssertEqual(json.count, 3, "body is exactly {voipToken, sessionId, platform}")
    }

    func test_platform_defaults_to_apns() async throws {
        let client = makeClient()
        try await client.register(voipToken: "aa", sessionId: "s1")   // no explicit platform
        let body = try XCTUnwrap(RegisterStubURLProtocol.lastBody)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        // gateway valid set is ['apns','fcm'] — iOS is APNs; 'ios' would 400 (relay 322300).
        XCTAssertEqual(json["platform"] as? String, "apns")
    }

    // MARK: - guards: never POST an unusable binding

    func test_missing_token_is_notLoggedIn_before_network() async {
        let client = makeClient(token: "")
        await expect(client, .notLoggedIn)
        XCTAssertNil(RegisterStubURLProtocol.lastRequest, "no token → no network")
    }

    func test_empty_voipToken_is_rejected_before_network() async {
        let client = makeClient()
        await expect(client, .rejected(400), voipToken: "")
        XCTAssertNil(RegisterStubURLProtocol.lastRequest, "empty token → no network")
    }

    func test_empty_sessionId_is_rejected_before_network() async {
        let client = makeClient()
        await expect(client, .rejected(400), sessionId: "")
        XCTAssertNil(RegisterStubURLProtocol.lastRequest, "empty session → no network")
    }

    // MARK: - status taxonomy

    func test_401_is_notAuthorized() async {
        let client = makeClient(); setStatus(401)
        await expect(client, .notAuthorized)
    }

    func test_403_is_notAuthorized_nonmember_session() async {
        let client = makeClient(); setStatus(403)   // sessionId not one the human belongs to
        await expect(client, .notAuthorized)
    }

    func test_5xx_is_retryable() async {
        let client = makeClient(); setStatus(503)
        await expect(client, .retryable(503))
    }

    func test_other_4xx_is_rejected() async {
        let client = makeClient(); setStatus(422)
        await expect(client, .rejected(422))
    }
}
