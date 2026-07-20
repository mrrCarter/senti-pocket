// SentiNativeAuth — the NATIVE-DOOR login (warden #256787 / relay #256742). The phone logs in the SAME way the sl
// CLI does: a challenge-based browser-approval DEVICE FLOW, NO OAuth-client / AS-registration. It yields the USER's
// session token (human-mrrcarter) which the governed write later presents as `Authorization: Bearer <token>`.
//
// Wire DTOs are SOURCE-BOUND to create-sentinelayer/src/auth/service.js (read at H:\create-sentinelayer): the exact
// /api/v1/auth/cli/sessions/{start,poll} request+response shapes, so this interoperates with the real endpoint, not
// an inferred one.
//
// SECURITY (warden finding #2, RATIFIED): the token is LOAD-BEARING and lives in the Keychain ONLY — it is never
// logged, never printed, never returned to a caller for storage elsewhere. `login()` returns it once so the
// composition root can hand it straight to the write client; it is also persisted to the Keychain here.

import Foundation
import Security
#if canImport(AuthenticationServices)
import AuthenticationServices
#endif
#if canImport(UIKit)
import UIKit
#endif

// MARK: - Wire DTOs (source-bound to auth/service.js startCliAuthSession / pollCliAuthSession)

private struct CliStartRequest: Encodable {
    let challenge: String
    let ide: String
    let cli_version: String?
}
private struct CliStartResponse: Decodable {
    let session_id: String
    let authorize_url: String
}
private struct CliPollRequest: Encodable {
    let session_id: String
    let challenge: String
}
private struct CliPollResponse: Decodable {
    let status: String          // pending | approved | rejected | denied | cancelled | expired
    let auth_token: String?     // present IFF status == "approved"
}

enum NativeAuthError: LocalizedError, Equatable {
    case network(String)
    case rejected               // the user denied / cancelled / the session expired at the server
    case timedOut
    case malformedResponse
    case rateLimited
    case userCancelledWeb
    var errorDescription: String? {
        switch self {
        case .network(let m):    return "Login network error: \(m)"
        case .rejected:          return "Login was not approved."
        case .timedOut:          return "Login timed out waiting for approval."
        case .malformedResponse: return "The login server returned an unexpected response."
        case .rateLimited:       return "Too many login attempts — please wait a moment and retry."
        case .userCancelledWeb:  return "Login was cancelled."
        }
    }
}

// MARK: - PKCE verifier

enum PKCE {
    /// 32 cryptographically-random bytes → base64url (43 chars, no padding) — comfortably above the 32-char minimum.
    static func makeVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        precondition(status == errSecSuccess, "SecRandomCopyBytes failed")
        return Data(bytes).base64URLEncodedNoPadding()
    }
}

// MARK: - Keychain token store (USER session token; NEVER logged)

enum SessionTokenStore {
    private static let service = "com.plexaura.sentipocket.session"
    private static let account = "senti-user-session-token"

    static func save(_ token: String) throws {
        let data = Data(token.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary) // idempotent replace
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly // survives relaunch, never leaves device
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw NativeAuthError.network("keychain store failed (\(status))") }
    }

    static func load() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data, let token = String(data: data, encoding: .utf8) else { return nil }
        return token
    }

    static func delete() {
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ] as CFDictionary)
    }
}

// MARK: - The device-flow login

@MainActor
final class SentiNativeAuth: NSObject {
    private let apiBaseURL: URL
    private let ideLabel: String
    private let appVersion: String
    private let urlSession: URLSession
    /// Poll pacing — server is rate-limited 20/min, so ~2s honours it with headroom (relay #256742).
    private let pollInterval: Duration
    private let overallTimeout: Duration
    private var webSession: ASWebAuthenticationSession?

    init(apiBaseURL: URL,
         appVersion: String,
         ideLabel: String = "Senti Pocket",
         urlSession: URLSession = .shared,
         pollInterval: Duration = .seconds(2),
         overallTimeout: Duration = .seconds(180)) {
        self.apiBaseURL = apiBaseURL
        self.appVersion = appVersion
        self.ideLabel = ideLabel
        self.urlSession = urlSession
        self.pollInterval = pollInterval
        self.overallTimeout = overallTimeout
    }

    /// Full native-door flow: start → browser-approve (ASWebAuthenticationSession) → poll → USER token → Keychain.
    /// The TOKEN comes from polling (the device flow), NOT a redirect callback — the web session only presents the
    /// approval UI and is dismissed as soon as polling confirms approval. Returns Void: the token is written to the
    /// Keychain and NEVER returned/exposed (warden finding #2) — the write client reads it via `SessionTokenStore.load()`.
    func login() async throws {
        let verifier = PKCE.makeVerifier()
        let start = try await postStart(challenge: verifier)
        presentApproval(urlString: start.authorize_url)
        defer { cancelWeb() }
        let token = try await pollUntilApproved(sessionId: start.session_id, challenge: verifier)
        try SessionTokenStore.save(token)
    }

    /// True once a session token is present in the Keychain (the app is logged in for the native door).
    static var isLoggedIn: Bool { SessionTokenStore.load() != nil }

    // MARK: start

    private func postStart(challenge: String) async throws -> CliStartResponse {
        let body = CliStartRequest(challenge: challenge, ide: ideLabel, cli_version: appVersion)
        return try await postJSON(path: "/api/v1/auth/cli/sessions/start", body: body)
    }

    // MARK: poll loop

    private func pollUntilApproved(sessionId: String, challenge: String) async throws -> String {
        let deadline = ContinuousClock.now.advanced(by: overallTimeout)
        while ContinuousClock.now < deadline {
            let resp: CliPollResponse = try await postJSON(
                path: "/api/v1/auth/cli/sessions/poll",
                body: CliPollRequest(session_id: sessionId, challenge: challenge)
            )
            switch resp.status.lowercased() {
            case "approved":
                guard let token = resp.auth_token, !token.isEmpty else { throw NativeAuthError.malformedResponse }
                return token
            case "rejected", "denied", "cancelled", "expired":
                throw NativeAuthError.rejected
            default: // "pending" (or unknown-but-not-terminal) → keep waiting
                try await Task.sleep(for: pollInterval)
            }
        }
        throw NativeAuthError.timedOut
    }

    // MARK: HTTP

    private func postJSON<Req: Encodable, Res: Decodable>(path: String, body: Req) async throws -> Res {
        guard let url = URL(string: path, relativeTo: apiBaseURL) else { throw NativeAuthError.network("bad url \(path)") }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.httpBody = try JSONEncoder().encode(body)
        let (data, response): (Data, URLResponse)
        do { (data, response) = try await urlSession.data(for: req) }
        catch { throw NativeAuthError.network(error.localizedDescription) }
        if let http = response as? HTTPURLResponse {
            if http.statusCode == 429 { throw NativeAuthError.rateLimited }
            guard (200..<300).contains(http.statusCode) else { throw NativeAuthError.network("HTTP \(http.statusCode)") }
        }
        do { return try JSONDecoder().decode(Res.self, from: data) }
        catch { throw NativeAuthError.malformedResponse }
    }

    // MARK: web approval

    private func presentApproval(urlString: String) {
        #if canImport(AuthenticationServices)
        guard let url = URL(string: urlString) else { return }
        // callbackURLScheme is nil: the device flow does NOT depend on a redirect back to the app — the token is
        // retrieved by polling. The web session is dismissed when polling confirms approval (cancelWeb()).
        let session = ASWebAuthenticationSession(url: url, callbackURLScheme: nil) { _, _ in }
        session.presentationContextProvider = self
        session.prefersEphemeralWebBrowserSession = false // reuse the existing GH/Google web login if signed in
        webSession = session
        session.start()
        #endif
    }

    private func cancelWeb() {
        #if canImport(AuthenticationServices)
        webSession?.cancel()
        webSession = nil
        #endif
    }
}

#if canImport(AuthenticationServices)
extension SentiNativeAuth: ASWebAuthenticationPresentationContextProviding {
    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        // ASWebAuthenticationSession calls this on the main thread. Return the app's active key window so the
        // approval sheet presents over the current UI. (Forge: verify the anchor on-device — sim/headless can't.)
        #if canImport(UIKit)
        let keyWindow = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow }
        return keyWindow ?? ASPresentationAnchor()
        #else
        return ASPresentationAnchor()
        #endif
    }
}
#endif

// MARK: - base64url

private extension Data {
    func base64URLEncodedNoPadding() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
