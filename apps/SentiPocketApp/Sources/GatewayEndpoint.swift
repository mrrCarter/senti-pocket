// GatewayEndpoint — the ONE strict, fail-closed gateway endpoint resolver (Pulse round-7 #1) used EVERYWHERE a config
// URL feeds a credential-bearing client: auth (login), reasoning, write, device-register, and dial (TTS bearer). There
// is NO hardcoded host default anywhere. A config value is accepted ONLY if it is:
//   • non-blank + parseable,
//   • HTTPS,
//   • has a host,
//   • and carries NO userinfo / password / query / fragment (attacker-shapeable forms).
// Anything else → nil → the caller is UNAVAILABLE → ZERO wire. So a missing/blank/malformed config can never send a
// session bearer (or the demo TTS bearer) to a stale/reallocated tunnel or an attacker-shaped URL.

import Foundation

enum GatewayEndpoint {
    /// Resolve a single config string to a validated https endpoint, or nil (fail-closed).
    static func resolve(_ configured: String?) -> URL? {
        guard let raw = configured?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty,
              let comps = URLComponents(string: raw),
              comps.scheme?.lowercased() == "https",
              let host = comps.host, !host.isEmpty,
              comps.user == nil, comps.password == nil,
              comps.query == nil, comps.fragment == nil,
              let url = comps.url else { return nil }
        return url
    }

    /// Resolve from Info.plist: the FIRST of `keys` whose configured value resolves to a valid endpoint (else nil).
    static func resolve(infoPlistKeys keys: [String]) -> URL? {
        for key in keys {
            if let url = resolve(Bundle.main.object(forInfoDictionaryKey: key) as? String) { return url }
        }
        return nil
    }
}
