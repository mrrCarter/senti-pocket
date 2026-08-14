import Foundation
import XCTest
import PocketContracts
@testable import SentiPocketApp

private final class ReceiptTrustStubURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var requestCountStorage = 0
    private static var responseBody = Data()
    private static var requestHook: (@Sendable () -> Void)?

    static var requestCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return requestCountStorage
    }

    static func reset(body: Data = Data(), requestHook: (@Sendable () -> Void)? = nil) {
        lock.lock()
        requestCountStorage = 0
        responseBody = body
        self.requestHook = requestHook
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        Self.requestCountStorage += 1
        let body = Self.responseBody
        let requestHook = Self.requestHook
        Self.lock.unlock()
        requestHook?()
        guard let url = request.url,
              let response = HTTPURLResponse(
                  url: url,
                  statusCode: 200,
                  httpVersion: "HTTP/1.1",
                  headerFields: ["Content-Type": "application/json"]
              ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@MainActor
final class PhoneWriteReceiptTrustTests: XCTestCase {
    override func setUp() {
        super.setUp()
        OutboxStore.clear()
        ReceiptTrustStubURLProtocol.reset()
    }

    override func tearDown() {
        OutboxStore.clear()
        ReceiptTrustStubURLProtocol.reset()
        super.tearDown()
    }

    private func intent(
        sessionId: String = "session-A",
        message: String = "exact confirmed words",
        createdAt: Date = Date(timeIntervalSince1970: 1_784_000_000)
    ) -> PersistedWriteIntent {
        let proposal = PocketWriteClient.makeHumanMessageProposal(
            sessionId: sessionId,
            message: message,
            at: createdAt
        )
        return PersistedWriteIntent(
            proposal: proposal,
            confirmation: GovernedWriteConfirmation(
                proposalId: proposal.id,
                confirmedProposalHash: proposal.proposalHash,
                confirmedAt: createdAt.addingTimeInterval(1)
            )
        )
    }

    private func untrustedPostedReceipt(for intent: PersistedWriteIntent) -> ActionReceipt {
        ActionReceipt(
            id: intent.proposal.id,
            proposalId: intent.proposal.id,
            status: .posted,
            result: .sequence(sequenceId: 101),
            targetSessionId: intent.proposal.targetSessionId,
            confirmedByHumanAt: intent.confirmation.confirmedAt,
            confirmedProposalHash: intent.proposal.proposalHash,
            executedAt: intent.confirmation.confirmedAt.addingTimeInterval(1),
            failureReason: nil,
            signature: "AA",
            signingKeyId: PocketDemoGatewayKey.signingKeyId
        )
    }

    private func client(tokenProvider: @escaping () -> String? = { "test-token" }) -> PocketWriteClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ReceiptTrustStubURLProtocol.self]
        return PocketWriteClient(
            apiBaseURL: URL(string: "https://trusted-gateway.example"),
            urlSession: URLSession(configuration: configuration),
            tokenProvider: tokenProvider
        )
    }

    private func wireBody(_ receipt: ActionReceipt) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(receipt)
    }

    func testClientRejectsRawNonpostedReceiptAtItsTypeBoundary() async throws {
        let intent = intent()
        let pending = ActionReceipt(
            id: intent.proposal.id,
            proposalId: intent.proposal.id,
            status: .pendingConnectivity,
            result: nil,
            targetSessionId: intent.proposal.targetSessionId,
            confirmedByHumanAt: intent.confirmation.confirmedAt,
            confirmedProposalHash: intent.proposal.proposalHash,
            executedAt: nil,
            failureReason: nil,
            signature: nil,
            signingKeyId: nil
        )
        ReceiptTrustStubURLProtocol.reset(body: try wireBody(pending))

        do {
            _ = try await client().execute(
                proposal: intent.proposal,
                confirmation: intent.confirmation
            )
            XCTFail("a raw non-posted receipt must not escape as client success")
        } catch let error as PocketWriteError {
            XCTAssertEqual(error, .unverifiableReceipt)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
        XCTAssertEqual(ReceiptTrustStubURLProtocol.requestCount, 1)
    }

    func testUntrustedPostedReceiptNeverRendersSentAndPreservesExactOutboxOwner() async throws {
        let persisted = intent()
        OutboxStore.save(persisted)
        ReceiptTrustStubURLProtocol.reset(body: try wireBody(untrustedPostedReceipt(for: persisted)))
        let viewModel = PhoneWriteViewModel(
            sessionId: "session-A",
            client: client()
        )

        guard case .pending = viewModel.state else {
            return XCTFail("precondition: the exact confirmed intent must restore as pending")
        }
        viewModel.retryPending()
        for _ in 0..<100 {
            if ReceiptTrustStubURLProtocol.requestCount == 1,
               case .pending(let message) = viewModel.state,
               message.contains("could not be authenticated") { break }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }

        guard case .pending(let message) = viewModel.state else {
            return XCTFail("an untrusted receipt must remain pending for reconciliation")
        }
        XCTAssertTrue(message.contains("could not be authenticated"))
        let retained = try XCTUnwrap(OutboxStore.load())
        XCTAssertEqual(retained, persisted)
        XCTAssertEqual(ReceiptTrustStubURLProtocol.requestCount, 1)
    }

    func testMalformedSuccessResponsePreservesConfirmedIntentForReconciliation() async throws {
        ReceiptTrustStubURLProtocol.reset(body: Data("{".utf8))
        let viewModel = PhoneWriteViewModel(sessionId: "session-A", client: client())

        viewModel.draft("ambiguous malformed response")
        viewModel.confirm()
        for _ in 0..<100 {
            if ReceiptTrustStubURLProtocol.requestCount == 1,
               case .pending(let message) = viewModel.state,
               message.contains("could not be authenticated") { break }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }

        guard case .pending(let message) = viewModel.state else {
            return XCTFail("a malformed response after POST must remain reconcilable")
        }
        XCTAssertTrue(message.contains("could not be authenticated"))
        let retained = try XCTUnwrap(OutboxStore.load())
        XCTAssertEqual(retained.proposal.renderedPreview, "ambiguous malformed response")
        XCTAssertEqual(retained.binding(to: "session-A"), .matching)
    }

    func testLateUntrustedReceiptForACannotDeleteReplacementOutboxOwnerB() async throws {
        let intentA = intent(sessionId: "session-A", message: "A")
        let intentB = intent(
            sessionId: "session-B",
            message: "B",
            createdAt: Date(timeIntervalSince1970: 1_784_000_100)
        )
        OutboxStore.save(intentA)
        ReceiptTrustStubURLProtocol.reset(
            body: try wireBody(untrustedPostedReceipt(for: intentA)),
            requestHook: { OutboxStore.save(intentB) }
        )
        let viewModel = PhoneWriteViewModel(sessionId: "session-A", client: client())

        guard case .pending = viewModel.state else {
            return XCTFail("precondition: intent A must restore as pending")
        }
        viewModel.retryPending()
        for _ in 0..<100 {
            if ReceiptTrustStubURLProtocol.requestCount == 1,
               case .pending(let message) = viewModel.state,
               message.contains("could not be authenticated") { break }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }

        guard case .pending = viewModel.state else {
            return XCTFail("a stale unauthenticated receipt must never become sent")
        }
        XCTAssertEqual(OutboxStore.load(), intentB)
        XCTAssertEqual(ReceiptTrustStubURLProtocol.requestCount, 1)
    }
}
