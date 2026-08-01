// DiagnosticLog.swift
// What: Implements the append-only structured diagnostic event store and exporter.
// How: Thread-safe JSONL writes feed bounded recent reads, severity/category envelopes,
// and paired machine-readable JSON plus operator-readable Markdown exports.
// Why: Failures need durable, correlatable evidence across short-lived process roles.

import Foundation

/// Persistent, structured diagnostic logging for Forge Conductor.
///
/// - Append-only JSONL on disk under `~/.forge-conductor/logs/`
/// - In-memory ring for recent UI inspection
/// - Export to `.json` (structured array) and `.md` (operator-readable)
public final class DiagnosticLog: DiagnosticRecording, @unchecked Sendable {
    public static let masterLogName = "forge-diagnostics.jsonl"
    public static let ringCapacity = 4_000
    /// Rotate master JSONL when larger than this (bytes).
    public static let maxMasterLogBytes: UInt64 = 8 * 1024 * 1024

    private let paths: AppPaths
    private let role: String
    private let lock = NSLock()
    private var ring: [DiagnosticEnvelope] = []

    public init(paths: AppPaths, role: String = "primary") {
        self.paths = paths
        self.role = role
    }

    // MARK: - Write

    public func log(_ record: DiagnosticRecord) {
        lock.lock()
        defer { lock.unlock() }
        do {
            try paths.ensureLayout()
            let envelope = DiagnosticEnvelope(
                ts: record.ts,
                event: record.event,
                severity: record.severity,
                role: record.role.isEmpty ? role : record.role,
                pid: ProcessInfo.processInfo.processIdentifier,
                category: record.category,
                fields: record.fields
            )
            ring.append(envelope)
            if ring.count > Self.ringCapacity {
                ring.removeFirst(ring.count - Self.ringCapacity)
            }

            let data = try envelope.jsonLine()
            try append(data, to: paths.masterDiagnostics)
            try append(data, to: paths.toolDiagnostics)

            if record.event.hasPrefix("agent_") || record.event == "agent_health" {
                try append(data, to: paths.agentDiagnostics)
            }
            if record.severity == .warn || record.severity == .error || record.severity == .critical
                || record.event.hasPrefix("agent_")
                || record.category == .mcp
                || record.category == .lmstudio {
                try append(data, to: paths.failoverDiagnostics)
            }
        } catch {
            fputs("diagnostic log error: \(error)\n", stderr)
        }
    }

    public func info(_ event: String, _ fields: [String: String] = [:], category: DiagnosticCategory = .general) {
        log(DiagnosticRecord(event: event, severity: .info, role: role, category: category, fields: fields))
    }

    public func warn(_ event: String, _ fields: [String: String] = [:], category: DiagnosticCategory = .general) {
        log(DiagnosticRecord(event: event, severity: .warn, role: role, category: category, fields: fields))
    }

    public func error(_ event: String, _ fields: [String: String] = [:], category: DiagnosticCategory = .general) {
        log(DiagnosticRecord(event: event, severity: .error, role: role, category: category, fields: fields))
    }

    public func critical(_ event: String, _ fields: [String: String] = [:], category: DiagnosticCategory = .general) {
        log(DiagnosticRecord(event: event, severity: .critical, role: role, category: category, fields: fields))
    }

    // MARK: - Read

    /// Recent records from the in-memory ring (newest last).
    public func recent(limit: Int = 200) -> [DiagnosticEnvelope] {
        lock.lock()
        defer { lock.unlock() }
        return Array(ring.suffix(limit))
    }

    /// Load all on-disk master JSONL records (best-effort; large files may be capped).
    public func loadPersisted(maxLines: Int = 50_000) throws -> [DiagnosticEnvelope] {
        let url = paths.masterDiagnostics
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let text = try String(contentsOf: url, encoding: .utf8)
        var out: [DiagnosticEnvelope] = []
        out.reserveCapacity(min(maxLines, 4_096))
        for line in text.split(whereSeparator: \.isNewline).suffix(maxLines) {
            let s = String(line).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !s.isEmpty, let data = s.data(using: .utf8) else { continue }
            if let env = try? JSONDecoder().decode(DiagnosticEnvelope.self, from: data) {
                out.append(env)
            }
        }
        return out
    }

    // MARK: - Export

    public struct ExportResult: Sendable, Equatable {
        public var jsonURL: URL
        public var markdownURL: URL
        public var recordCount: Int
        public var exportedAt: Date
    }

    /// Write a point-in-time export combining ring + disk into JSON + Markdown.
    public func export(
        to directory: URL? = nil,
        basename: String? = nil
    ) throws -> ExportResult {
        try paths.ensureLayout()
        let dir = directory ?? paths.exportsDir
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        var merged = try loadPersisted()
        lock.lock()
        let live = ring
        lock.unlock()
        // Prefer disk order; append any ring entries not already present by (ts,event,pid)
        let seen = Set(merged.map(\.identityKey))
        for e in live where !seen.contains(e.identityKey) {
            merged.append(e)
        }
        merged.sort { $0.ts < $1.ts }

        let stamp = ISO8601DateFormatter()
        stamp.formatOptions = [.withInternetDateTime]
        let name = basename ?? "forge-diagnostics-\(Self.fileStamp())"
        let jsonURL = dir.appendingPathComponent("\(name).json")
        let mdURL = dir.appendingPathComponent("\(name).md")

        let payload: [String: Any] = [
            "product": ForgeApp.productName,
            "version": ForgeApp.version,
            "exported_at": stamp.string(from: Date()),
            "home": paths.home.path,
            "record_count": merged.count,
            "records": merged.map { $0.asDictionary() },
        ]
        let jsonData = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
        try jsonData.write(to: jsonURL, options: .atomic)

        let md = Self.renderMarkdown(
            product: ForgeApp.productName,
            version: ForgeApp.version,
            home: paths.home.path,
            records: merged
        )
        try md.write(to: mdURL, atomically: true, encoding: .utf8)

        info("diagnostics_exported", [
            "json": jsonURL.path,
            "markdown": mdURL.path,
            "count": "\(merged.count)",
        ], category: .diagnostics)

        return ExportResult(
            jsonURL: jsonURL,
            markdownURL: mdURL,
            recordCount: merged.count,
            exportedAt: Date()
        )
    }

    // MARK: - Private

    private func append(_ data: Data, to url: URL) throws {
        if url.lastPathComponent == Self.masterLogName {
            try rotateMasterIfNeeded()
        }
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        let h = try FileHandle(forWritingTo: url)
        defer { try? h.close() }
        try h.seekToEnd()
        try h.write(contentsOf: data)
    }

    private func rotateMasterIfNeeded() throws {
        let url = paths.masterDiagnostics
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return }
        let attrs = try fm.attributesOfItem(atPath: url.path)
        let size = (attrs[.size] as? NSNumber)?.uint64Value ?? 0
        guard size >= Self.maxMasterLogBytes else { return }
        let stamp = Self.fileStamp()
        let archive = paths.logsDir.appendingPathComponent("forge-diagnostics-\(stamp).jsonl.bak")
        if fm.fileExists(atPath: archive.path) {
            try fm.removeItem(at: archive)
        }
        try fm.moveItem(at: url, to: archive)
        fm.createFile(atPath: url.path, contents: nil)
    }

    private static func fileStamp() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f.string(from: Date())
    }

    private static func renderMarkdown(
        product: String,
        version: String,
        home: String,
        records: [DiagnosticEnvelope]
    ) -> String {
        var lines: [String] = []
        lines.append("# \(product) Diagnostic Export")
        lines.append("")
        lines.append("- **Version:** \(version)")
        lines.append("- **Home:** `\(home)`")
        lines.append("- **Exported:** \(ISO8601.string(from: Date()))")
        lines.append("- **Records:** \(records.count)")
        lines.append("")
        lines.append("## Summary by severity")
        lines.append("")
        var bySev: [String: Int] = [:]
        var byCat: [String: Int] = [:]
        for r in records {
            bySev[r.severity.rawValue, default: 0] += 1
            byCat[r.category.rawValue, default: 0] += 1
        }
        for k in bySev.keys.sorted() {
            lines.append("- \(k): \(bySev[k] ?? 0)")
        }
        lines.append("")
        lines.append("## Summary by category")
        lines.append("")
        for k in byCat.keys.sorted() {
            lines.append("- \(k): \(byCat[k] ?? 0)")
        }
        lines.append("")
        lines.append("## Timeline")
        lines.append("")
        lines.append("| Time (UTC) | Severity | Category | Event | Fields |")
        lines.append("|---|---|---|---|---|")
        for r in records.suffix(2_000) {
            let fields = r.fields
                .map { "\($0.key)=\($0.value)" }
                .sorted()
                .joined(separator: "; ")
                .replacingOccurrences(of: "|", with: "\\|")
            let event = r.event.replacingOccurrences(of: "|", with: "\\|")
            lines.append(
                "| \(r.tsISO) | \(r.severity.rawValue) | \(r.category.rawValue) | \(event) | \(fields) |"
            )
        }
        lines.append("")
        lines.append("_End of export._")
        lines.append("")
        return lines.joined(separator: "\n")
    }
}

// MARK: - Models

public enum DiagnosticCategory: String, Sendable, Codable, CaseIterable {
    case general
    case bootstrap
    case telemetry
    case mcp
    case lmstudio
    case manager
    case tools
    case agent
    case diagnostics
    case ui
}

public enum DiagnosticExportError: Error, LocalizedError {
    case cancelled
    public var errorDescription: String? {
        switch self {
        case .cancelled: "Export cancelled"
        }
    }
}

/// On-disk / export envelope (Codable).
public struct DiagnosticEnvelope: Sendable, Codable, Equatable {
    public var ts: Date
    public var event: String
    public var severity: DiagnosticSeverity
    public var role: String
    public var pid: Int32
    public var category: DiagnosticCategory
    public var fields: [String: String]

    public var tsISO: String { ISO8601.string(from: ts) }

    public var identityKey: String {
        "\(tsISO)|\(event)|\(pid)|\(role)"
    }

    public func asDictionary() -> [String: Any] {
        var obj: [String: Any] = [
            "ts": tsISO,
            "event": event,
            "severity": severity.rawValue,
            "role": role,
            "pid": Int(pid),
            "category": category.rawValue,
        ]
        if !fields.isEmpty {
            obj["fields"] = fields
        }
        return obj
    }

    public func jsonLine() throws -> Data {
        var data = try JSONSerialization.data(withJSONObject: asDictionary(), options: [.sortedKeys])
        data.append(0x0A)
        return data
    }

    enum CodingKeys: String, CodingKey {
        case ts, event, severity, role, pid, category, fields
    }

    public init(
        ts: Date,
        event: String,
        severity: DiagnosticSeverity,
        role: String,
        pid: Int32,
        category: DiagnosticCategory,
        fields: [String: String]
    ) {
        self.ts = ts
        self.event = event
        self.severity = severity
        self.role = role
        self.pid = pid
        self.category = category
        self.fields = fields
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let s = try? c.decode(String.self, forKey: .ts), let d = ISO8601.date(from: s) {
            ts = d
        } else {
            ts = (try? c.decode(Date.self, forKey: .ts)) ?? Date()
        }
        event = try c.decode(String.self, forKey: .event)
        severity = (try? c.decode(DiagnosticSeverity.self, forKey: .severity)) ?? .info
        role = (try? c.decode(String.self, forKey: .role)) ?? "primary"
        if let i = try? c.decode(Int.self, forKey: .pid) {
            pid = Int32(i)
        } else {
            pid = (try? c.decode(Int32.self, forKey: .pid)) ?? 0
        }
        category = (try? c.decode(DiagnosticCategory.self, forKey: .category)) ?? .general
        fields = (try? c.decode([String: String].self, forKey: .fields)) ?? [:]
    }
}

// Extend DiagnosticRecord with category (backward compatible init below in Models)
