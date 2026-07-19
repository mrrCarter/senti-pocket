import Foundation

// STEP 2 (behavior) for the ratified contract (docs/auth-fetch-contract.md @ 15c83561, V11) — §5a seam (A).
//
// `SessionExecuting` is the INTERNAL executor seam the broker calls to perform the actual HTTP round-trip. It is
// NOT public and takes an already-built `URLRequest` from the broker (only the broker constructs the
// credential-bearing request from a typed SessionRequestSpec — §4/§5). Its ONLY return is an opaque
// `SealedResponse` (below): NO raw `HTTPURLResponse` appears in the seam's public OR internal return surface
// (V11 R2), and the status/body are unobservable until the broker OPENS the envelope — which it does ONLY after
// the §4c generation-equality check, so a stale request's response is discarded UNOPENED (structural
// zero-observation; a stale 401 is never classified). Resolves the P1-B raw-return finding in the safe direction.
//
// Two conformers: `LiveSessionExecutor` (real ephemeral URLSession, exercised only once live sign-in is
// unblocked — §6) and a deterministic KAV executor (test target, step 3) that drives this SAME seam into the
// REAL broker, unreachable from any public/demo initializer.
protocol SessionExecuting: Sendable {
    func execute(_ request: URLRequest) async throws -> SealedResponse
}

/// Opaque sealed HTTP result. Exposes NO status/body until `open()`; the broker opens it ONLY after
/// generation-equality (§4c). `open()` yields a NORMALIZED status Int (never a raw HTTPURLResponse) + Data +
/// requestId — nothing else escapes. Its initializer is fileprivate, so only an executor in THIS file mints one.
struct SealedResponse {
    private let statusCode: Int
    private let data: Data
    private let requestId: String?
    fileprivate init(data: Data, response: HTTPURLResponse) {
        self.statusCode = response.statusCode
        self.data = data
        self.requestId = response.value(forHTTPHeaderField: "x-request-id")
    }
    /// Broker-only classification surface, called post generation-equality. Requires an `ExecutionGrant` that
    /// ONLY CredentialBroker can mint (its init is broker-file-private), so NO other current-or-future
    /// PocketSessionClient file can open a sealed response — structural, not current-call-graph-only (P1-B DiD).
    func open(_ grant: ExecutionGrant) -> (status: Int, data: Data, requestId: String?) { (statusCode, data, requestId) }
}

/// Real network executor: an ephemeral `URLSession` (no cookies/cache/credential store), redirects refused so a
/// 3xx target never receives the credential-bearing request (§2). Not public; constructed only inside the module.
struct LiveSessionExecutor: SessionExecuting {
    private let session: URLSession
    init() {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.httpCookieStorage = nil
        cfg.urlCredentialStorage = nil
        cfg.urlCache = nil
        cfg.httpShouldSetCookies = false
        self.session = URLSession(configuration: cfg, delegate: NoRedirectDelegate(), delegateQueue: nil)
    }
    func execute(_ request: URLRequest) async throws -> SealedResponse {
        let data: Data, response: URLResponse
        do { (data, response) = try await session.data(for: request) }
        catch is CancellationError { throw CancellationError() }   // structured cancellation propagates verbatim
        catch { throw TransportError.network }
        guard let http = response as? HTTPURLResponse else { throw TransportError.network }
        return SealedResponse(data: data, response: http)          // sealed; broker opens post-equality
    }
}

/// Refuses EVERY redirect: the completion handler is called with `nil`, so the origin receives the credential
/// exactly once and a 3xx target receives ZERO request and ZERO credential (§2 no-redirect).
private final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
