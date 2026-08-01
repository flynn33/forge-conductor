// JSONSupport.swift
// What: Centralizes ISO-8601 and JSON serialization used across transports/storage.
// How: Shared encoders enforce valid JSON objects, deterministic formatting choices,
// and one timestamp representation with bounded conversion helpers.
// Why: Protocol boundaries must not disagree about dates or accepted JSON shapes.

import Foundation
import CryptoKit

/// Centralizes deterministic ISO-8601 conversion for persistence and wire adapters.
///
/// `ISO8601DateFormatter` is mutable and not `Sendable`, so access to the shared
/// formatter is serialized rather than duplicating subtly different date policies.
public enum ISO8601 {
    // ISO8601DateFormatter is not Sendable; access is serialized via lock.
    private static let lock = NSLock()
    nonisolated(unsafe) private static let _formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
    nonisolated(unsafe) private static let _fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    public static func string(from date: Date) -> String {
        lock.lock()
        defer { lock.unlock() }
        return _formatter.string(from: date)
    }

    public static func date(from string: String) -> Date? {
        lock.lock()
        defer { lock.unlock() }
        if let d = _formatter.date(from: string) { return d }
        return _fractional.date(from: string)
    }
}

public enum JSONSupport {
    public static func data(from object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    public static func string(from object: [String: Any]) throws -> String {
        String(data: try data(from: object), encoding: .utf8) ?? "{}"
    }

    public static func object(from data: Data) throws -> [String: Any] {
        let o = try JSONSerialization.jsonObject(with: data)
        return o as? [String: Any] ?? [:]
    }

    public static func sha256Hex(_ string: String) -> String {
        let digest = SHA256.hash(data: Data(string.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    public static func canonicalJSON(_ object: [String: Any]) throws -> String {
        // Sort keys recursively for stable digests
        try string(from: sortKeys(object) as? [String: Any] ?? object)
    }

    private static func sortKeys(_ value: Any) -> Any {
        if let dict = value as? [String: Any] {
            var out: [String: Any] = [:]
            for k in dict.keys.sorted() {
                out[k] = sortKeys(dict[k] as Any)
            }
            return out
        }
        if let arr = value as? [Any] {
            return arr.map { sortKeys($0) }
        }
        return value
    }
}
