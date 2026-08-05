import Foundation

/// A configuration failure, not a connectivity failure. Callers must surface this as terminal until a trusted
/// build/runtime configuration supplies an endpoint; they must never invent or fall back to a public host.
enum GatewayEndpointError: LocalizedError, Equatable {
    case notConfigured

    var errorDescription: String? {
        "Senti's secure gateway is not configured for this build."
    }
}

/// The single trust boundary for API and gateway base URLs used by the app.
///
/// Only an explicit HTTPS origin is accepted. Paths, credentials, queries, and fragments are rejected because all
/// clients construct their own fixed API paths; accepting extra URL material would make the effective destination
/// ambiguous. When multiple keys are supplied, the first non-empty value is authoritative. If that value is invalid,
/// resolution fails closed instead of silently sending credentials to a lower-priority host.
enum GatewayEndpoint {
    static func resolve(_ rawValue: String?) -> URL? {
        guard let rawValue else { return nil }
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
              trimmed.rangeOfCharacter(from: .controlCharacters) == nil,
              !trimmed.contains("\\"),
              var components = URLComponents(string: trimmed),
              components.scheme?.lowercased() == "https",
              let host = components.host,
              !host.isEmpty,
              let percentEncodedHost = components.percentEncodedHost,
              !percentEncodedHost.contains("%"),
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil,
              components.percentEncodedPath.isEmpty || components.percentEncodedPath == "/"
        else {
            return nil
        }

        if let port = components.port, !(1...65_535).contains(port) {
            return nil
        }

        // Normalize an optional root slash so every accepted value denotes an origin, never a path prefix.
        components.scheme = "https"
        components.path = ""
        return components.url
    }

    static func resolve(infoDictionary: [String: Any], keys: [String]) -> URL? {
        for key in keys {
            guard let configuredValue = infoDictionary[key] else { continue }
            guard let rawValue = configuredValue as? String else { return nil }
            let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            return resolve(trimmed)
        }
        return nil
    }

    static func resolve(infoPlistKeys keys: [String], bundle: Bundle = .main) -> URL? {
        resolve(infoDictionary: bundle.infoDictionary ?? [:], keys: keys)
    }
}
