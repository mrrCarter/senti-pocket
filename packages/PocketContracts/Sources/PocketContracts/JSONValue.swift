import Foundation

/// A lossless JSON value for open/unknown wire payloads (event.payload, action.metadata,
/// checkpoint.tokenRange/summarySections, action-page.projection). Owned by Relay (wire layer);
/// Atlas projects typed domain values from it.
///
/// Integer-valued numbers decode as `.int` (Int64) BEFORE falling back to `.double`, so a large
/// `sequenceId` embedded in a payload round-trips exactly instead of through a lossy Double.
public enum JSONValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null; return }
        if let b = try? c.decode(Bool.self) { self = .bool(b); return }
        // Int64 before Double: an integer literal (no fractional part) must not degrade to Double.
        if let i = try? c.decode(Int64.self) { self = .int(i); return }
        if let d = try? c.decode(Double.self) { self = .double(d); return }
        if let s = try? c.decode(String.self) { self = .string(s); return }
        if let a = try? c.decode([JSONValue].self) { self = .array(a); return }
        if let o = try? c.decode([String: JSONValue].self) { self = .object(o); return }
        throw DecodingError.dataCorruptedError(in: c, debugDescription: "Unsupported JSON value")
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null:            try c.encodeNil()
        case .bool(let b):     try c.encode(b)
        case .int(let i):      try c.encode(i)
        case .double(let d):   try c.encode(d)
        case .string(let s):   try c.encode(s)
        case .array(let a):    try c.encode(a)
        case .object(let o):   try c.encode(o)
        }
    }

    // MARK: - Non-coercing accessors (a projection MUST NOT invent a value that wasn't in the wire)

    public var stringValue: String? { if case let .string(s) = self { return s }; return nil }
    public var boolValue: Bool? { if case let .bool(b) = self { return b }; return nil }
    public var arrayValue: [JSONValue]? { if case let .array(a) = self { return a }; return nil }
    public var objectValue: [String: JSONValue]? { if case let .object(o) = self { return o }; return nil }

    /// Integer accessor — EXACT integral only. A `.double` is returned ONLY if it has no fractional
    /// part (`Int64(exactly:)`, NOT `.rounded()`), so `7.5` stays `nil` instead of coercing to `8`.
    public var intValue: Int64? {
        switch self {
        case .int(let i): return i
        case .double(let d): return Int64(exactly: d)
        default: return nil
        }
    }

    /// Double accessor — an integral `.int` widens exactly; a fractional `.double` returns as-is.
    public var doubleValue: Double? {
        switch self {
        case .double(let d): return d
        case .int(let i): return Double(exactly: i)
        default: return nil
        }
    }

    public subscript(_ key: String) -> JSONValue? {
        if case let .object(o) = self { return o[key] }
        return nil
    }
}
