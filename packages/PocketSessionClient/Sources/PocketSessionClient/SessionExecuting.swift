import Foundation

// STEP 2 (behavior) for the ratified contract (docs/auth-fetch-contract.md @ 15c83561, V11) — §5a seam (A).
//
// `SessionExecuting` is the INTERNAL executor seam the broker calls to perform the actual HTTP round-trip.
// It is deliberately NOT public and takes an already-built `URLRequest` from the broker (the broker alone
// constructs the credential-bearing request from a typed SessionRequestSpec — §4/§5). Two conformers:
//   - `LiveSessionExecutor` (below): the real ephemeral-URLSession round-trip. Exercised only once a Pocket
//     client is registered and live sign-in is unblocked; FIXTURE-ONLY until then (§6).
//   - a deterministic KAV executor (in the test target, step 3): simulates every §4b/§4c response — status,
//     races, decode failures, incl. simulated .network/.live — by driving this SAME seam into the REAL broker.
//     It is unreachable from any public/demo initializer (§5a item 9).
//
// The seam returns the raw (Data, HTTPURLResponse) to the BROKER only; the broker classifies status privately
// and never lets a raw HTTPURLResponse escape to any caller (R2). No conformer is public.
protocol SessionExecuting: Sendable {
    func execute(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
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
    func execute(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response): (Data, URLResponse)
        do { (data, response) = try await session.data(for: request) }
        catch let urlError as URLError { throw TransportError.network }
        catch is CancellationError { throw CancellationError() }   // structured cancellation propagates verbatim
        catch { throw TransportError.network }
        guard let http = response as? HTTPURLResponse else { throw TransportError.network }
        return (data, http)
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
