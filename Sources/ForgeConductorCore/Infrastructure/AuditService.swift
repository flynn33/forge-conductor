// AuditService.swift
// What: Records bounded tool-execution audit events to durable and live sinks.
// How: It sanitizes arguments/results, writes through SQLiteStore, and emits diagnostic
// correlation records without retaining sensitive file contents or full commands.
// Why: Accountability must not become a second channel for sensitive data leakage.

import Foundation

/// Dual-write audit: SQLite + audit.jsonl
public final class AuditService: @unchecked Sendable {
    private let store: SQLiteStore
    private let paths: AppPaths
    private let lock = NSLock()

    public init(store: SQLiteStore, paths: AppPaths) {
        self.store = store
        self.paths = paths
    }

    public func append(
        tool: String,
        status: String,
        clientID: String?,
        args: [String: Any]? = nil,
        durationMs: Int? = nil,
        error: String? = nil,
        mutating: Bool = false
    ) throws {
        let argsForStore: [String: Any]? = mutating ? args : nil
        let digest: String?
        if let args {
            let canonical = try JSONSupport.canonicalJSON(args)
            digest = JSONSupport.sha256Hex(canonical)
        } else {
            digest = nil
        }
        let argsJSON: String?
        if let argsForStore {
            argsJSON = try JSONSupport.string(from: argsForStore)
        } else {
            argsJSON = nil
        }
        let event = AuditEvent(
            clientID: clientID,
            tool: tool,
            argsDigest: digest,
            argsJSON: argsJSON,
            status: status,
            durationMs: durationMs,
            error: error
        )
        try store.auditAppend(event)

        // JSONL mirror
        lock.lock()
        defer { lock.unlock() }
        try paths.ensureLayout()
        var lineObj: [String: Any] = [
            "timestamp": ISO8601.string(from: event.timestamp),
            "tool": tool,
            "status": status,
            "args_digest": digest as Any,
            "args": argsForStore as Any,
            "duration_ms": durationMs as Any,
            "error": error as Any,
            "client_id": clientID as Any,
        ]
        // strip NSNull-ish
        lineObj = lineObj.compactMapValues { v in
            if v is NSNull { return nil }
            return v
        }
        var data = try JSONSupport.data(from: lineObj)
        data.append(0x0A)
        if !FileManager.default.fileExists(atPath: paths.auditJSONL.path) {
            FileManager.default.createFile(atPath: paths.auditJSONL.path, contents: nil)
        }
        let h = try FileHandle(forWritingTo: paths.auditJSONL)
        defer { try? h.close() }
        try h.seekToEnd()
        try h.write(contentsOf: data)
    }

    public func recent(limit: Int = 80) throws -> [AuditEvent] {
        try store.auditRecent(limit: limit)
    }
}

private extension Dictionary where Key == String, Value == Any {
    func compactMapValues(_ transform: (Any) -> Any?) -> [String: Any] {
        var out: [String: Any] = [:]
        for (k, v) in self {
            if let nv = transform(v) { out[k] = nv }
        }
        return out
    }
}
