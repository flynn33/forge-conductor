// SQLiteStore.swift
// What: Implements durable presence, session, binding, and audit repositories.
// How: One serialized SQLite connection owns schema migration, prepared statements,
// transactions, bounded queries, and typed row conversion.
// Why: A single storage adapter preserves consistency while satisfying narrow domain ports.

import Foundation
import SQLite3
import Darwin

/// Normalizes SQLite adapter failures into stable, user-readable error categories.
public enum StoreError: Error, LocalizedError, Equatable {
    case openFailed(String)
    case execFailed(String)
    case notFound(String)
    case conflict(String)

    public var errorDescription: String? {
        switch self {
        case .openFailed(let s): "SQLite open failed: \(s)"
        case .execFailed(let s): "SQLite error: \(s)"
        case .notFound(let s): s
        case .conflict(let s): s
        }
    }
}

/// SQLite3-backed store using the system library.
public final class SQLiteStore: PresenceStore, SessionStore, AuditReading, @unchecked Sendable {
    private var db: OpaquePointer?
    private let lock = NSLock()
    private static let processInitializationLock = NSLock()
    private static let initializationLockTimeout: TimeInterval = 5
    public let path: URL
    private let clock: any Clock

    /// SQLite copies the bound text; required so Swift string buffers can free.
    private static let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    public init(path: URL, clock: any Clock = SystemClock()) throws {
        self.path = path
        self.clock = clock
        try FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Self.withInitializationFileLock(databasePath: path) {
            var handle: OpaquePointer?
            let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
            guard sqlite3_open_v2(path.path, &handle, flags, nil) == SQLITE_OK, let handle else {
                let msg = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
                if let handle { sqlite3_close(handle) }
                throw StoreError.openFailed(msg)
            }
            db = handle
            do {
                // GUI manager + MCP serve share one home. Without a busy timeout, a locked
                // store can stall serve startup long enough for LM Studio's ~60s plugin timeout.
                try exec("PRAGMA busy_timeout=3000;")
                try exec("PRAGMA journal_mode=WAL;")
                try exec("PRAGMA foreign_keys=ON;")
                try migrate()
            } catch {
                sqlite3_close(handle)
                db = nil
                throw error
            }
        }
    }

    deinit {
        close()
    }

    private static func withInitializationFileLock<T>(
        databasePath: URL,
        _ body: () throws -> T
    ) throws -> T {
        let processDeadline = Date().addingTimeInterval(initializationLockTimeout)
        guard processInitializationLock.lock(before: processDeadline) else {
            throw StoreError.openFailed("timed out waiting for process initialization lock")
        }
        defer { processInitializationLock.unlock() }

        let lockURL = databasePath.appendingPathExtension("initialization.lock")
        let mode = mode_t(S_IRUSR | S_IWUSR)
        let descriptor = lockURL.path.withCString {
            Darwin.open($0, O_CREAT | O_RDWR, mode)
        }
        guard descriptor >= 0 else {
            throw StoreError.openFailed("cannot open initialization lock: \(String(cString: strerror(errno)))")
        }
        defer { _ = Darwin.close(descriptor) }

        let deadline = Date().addingTimeInterval(initializationLockTimeout)
        while Darwin.lockf(descriptor, F_TLOCK, 0) != 0 {
            let code = errno
            guard code == EACCES || code == EAGAIN else {
                throw StoreError.openFailed("cannot lock initialization: \(String(cString: strerror(code)))")
            }
            guard Date() < deadline else {
                throw StoreError.openFailed("timed out waiting for database initialization lock")
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
        defer { _ = Darwin.lockf(descriptor, F_ULOCK, 0) }
        return try body()
    }

    /// Explicit close for tests that delete the home directory after bootstrap.
    public func close() {
        lock.lock()
        defer { lock.unlock() }
        if let db {
            sqlite3_close(db)
            self.db = nil
        }
    }

    // MARK: - Schema

    public func migrate() throws {
        try exec("BEGIN IMMEDIATE;")
        do {
            try migrateLockedDatabase()
            try exec("COMMIT;")
        } catch {
            try? exec("ROLLBACK;")
            throw error
        }
    }

    private func migrateLockedDatabase() throws {
        try exec("""
        CREATE TABLE IF NOT EXISTS schema_version (version INTEGER NOT NULL);
        CREATE TABLE IF NOT EXISTS memory_notes (
            key TEXT PRIMARY KEY,
            body TEXT NOT NULL,
            tags_json TEXT NOT NULL DEFAULT '[]',
            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS agent_sessions (
            id TEXT PRIMARY KEY,
            agent_id TEXT NOT NULL,
            client_id TEXT,
            status TEXT NOT NULL,
            summary TEXT,
            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS presence (
            client_id TEXT PRIMARY KEY,
            host_kind TEXT,
            pid INTEGER,
            cwd TEXT,
            last_heartbeat TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS audit_events (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            timestamp TEXT NOT NULL,
            client_id TEXT,
            tool TEXT NOT NULL,
            args_digest TEXT,
            args_json TEXT,
            status TEXT,
            duration_ms INTEGER,
            error TEXT
        );
        CREATE TABLE IF NOT EXISTS context_handoffs (
            id TEXT PRIMARY KEY,
            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL,
            source TEXT NOT NULL,
            resume_ready INTEGER NOT NULL DEFAULT 0,
            packet_json TEXT NOT NULL,
            client_id TEXT,
            write_sequence INTEGER NOT NULL DEFAULT 0
        );
        CREATE INDEX IF NOT EXISTS idx_context_handoffs_updated
            ON context_handoffs(updated_at DESC);
        """)
        if try !tableHasColumn(table: "context_handoffs", column: "write_sequence") {
            try exec(
                "ALTER TABLE context_handoffs ADD COLUMN write_sequence INTEGER NOT NULL DEFAULT 0;"
            )
        }
        if try !tableHasColumn(table: "context_handoffs", column: "client_id") {
            try exec("ALTER TABLE context_handoffs ADD COLUMN client_id TEXT;")
        }
        try exec("""
        UPDATE context_handoffs
        SET write_sequence = rowid
        WHERE write_sequence = 0;
        CREATE INDEX IF NOT EXISTS idx_context_handoffs_sequence
            ON context_handoffs(write_sequence DESC);
        CREATE INDEX IF NOT EXISTS idx_context_handoffs_client_sequence
            ON context_handoffs(client_id, write_sequence DESC);
        """)
        let version: Int = try queryInt("SELECT version FROM schema_version LIMIT 1") ?? 0
        if version == 0 {
            try exec("INSERT INTO schema_version(version) VALUES (5);")
        } else if version < 5 {
            try exec("UPDATE schema_version SET version = 5;")
        }
    }

    // MARK: - Context handoffs

    public func handoffUpsert(_ packet: HandoffPacket) throws {
        let json = try JSONSupport.string(from: packet.asDictionary())
        let noteTimestamp = ISO8601.string(from: clock.now())
        try withTransaction {
            try withStatementUnlocked(
                """
                INSERT INTO context_handoffs(
                    id, created_at, updated_at, source, resume_ready, packet_json, client_id, write_sequence
                )
                SELECT ?, ?, ?, ?, ?, ?, ?, COALESCE(MAX(write_sequence), 0) + 1
                FROM context_handoffs
                WHERE true
                ON CONFLICT(id) DO UPDATE SET
                    updated_at=excluded.updated_at,
                    source=excluded.source,
                    resume_ready=excluded.resume_ready,
                    packet_json=excluded.packet_json,
                    client_id=excluded.client_id,
                    write_sequence=excluded.write_sequence
                """
            ) { stmt in
                bind(stmt, 1, packet.id)
                bind(stmt, 2, packet.createdAt)
                bind(stmt, 3, packet.updatedAt)
                bind(stmt, 4, packet.source.rawValue)
                sqlite3_bind_int(stmt, 5, packet.resumeReady ? 1 : 0)
                bind(stmt, 6, json)
                bind(stmt, 7, packet.clientID)
                try stepDone(stmt)
            }
            try memorySetUnlocked(
                key: "continuity/latest",
                body: packet.id,
                tags: ["continuity", "latest"],
                timestamp: noteTimestamp
            )
            if packet.resumeReady {
                try memorySetUnlocked(
                key: "continuity/resume_ready",
                body: packet.id,
                    tags: ["continuity", "resume"],
                    timestamp: noteTimestamp
                )
            }
        }
    }

    public func handoffGet(id: String) throws -> HandoffPacket? {
        try withStatement(
            "SELECT id, packet_json FROM context_handoffs WHERE id = ?"
        ) { stmt in
            bind(stmt, 1, id)
            guard sqlite3_step(stmt) == SQLITE_ROW,
                  let rowID = textCol(stmt, 0),
                  let cstr = sqlite3_column_text(stmt, 1) else { return nil }
            let text = String(cString: cstr)
            guard let data = text.data(using: .utf8),
                  let obj = try? JSONSupport.object(from: data),
                  let packet = HandoffPacket.fromDictionary(obj),
                  packet.id == rowID else { return nil }
            return packet
        }
    }

    public func handoffLatest(
        resumeReadyOnly: Bool = false,
        clientID: String? = nil
    ) throws -> HandoffPacket? {
        var predicates: [String] = []
        if resumeReadyOnly { predicates.append("resume_ready = 1") }
        if clientID != nil { predicates.append("client_id = ?") }
        let whereClause = predicates.isEmpty ? "" : " WHERE \(predicates.joined(separator: " AND "))"
        let sql = "SELECT id, packet_json FROM context_handoffs\(whereClause) ORDER BY write_sequence DESC LIMIT 1"
        return try withStatement(sql) { stmt in
            if let clientID { bind(stmt, 1, clientID) }
            guard sqlite3_step(stmt) == SQLITE_ROW,
                  let rowID = textCol(stmt, 0),
                  let cstr = sqlite3_column_text(stmt, 1) else { return nil }
            let text = String(cString: cstr)
            guard let data = text.data(using: .utf8),
                  let obj = try? JSONSupport.object(from: data),
                  let packet = HandoffPacket.fromDictionary(obj),
                  packet.id == rowID else { return nil }
            return packet
        }
    }

    public func handoffList(limit: Int = 20) throws -> [HandoffPacket] {
        let lim = max(1, min(limit, 100))
        return try handoffList(sql: "SELECT id, packet_json FROM context_handoffs ORDER BY write_sequence DESC LIMIT \(lim)")
    }

    public func handoffListAll() throws -> [HandoffPacket] {
        try handoffList(sql: "SELECT id, packet_json FROM context_handoffs ORDER BY write_sequence DESC")
    }

    private func handoffList(sql: String) throws -> [HandoffPacket] {
        try withStatement(sql) { stmt in
            var out: [HandoffPacket] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                guard let rowID = textCol(stmt, 0),
                      let cstr = sqlite3_column_text(stmt, 1) else { continue }
                let text = String(cString: cstr)
                guard let data = text.data(using: .utf8),
                      let obj = try? JSONSupport.object(from: data),
                      let packet = HandoffPacket.fromDictionary(obj),
                      packet.id == rowID else { continue }
                out.append(packet)
            }
            return out
        }
    }

    /// Rebuilds pointer notes from authoritative handoff rows. Used at bootstrap
    /// after legacy migration or recovery from an interrupted older-version write.
    public func handoffRepairPointers() throws {
        let timestamp = ISO8601.string(from: clock.now())
        try withTransaction {
            let latestID = try handoffIDUnlocked(resumeReadyOnly: false)
            let resumeID = try handoffIDUnlocked(resumeReadyOnly: true)
            try replaceContinuityPointerUnlocked(
                key: "continuity/latest",
                id: latestID,
                tags: ["continuity", "latest"],
                timestamp: timestamp
            )
            try replaceContinuityPointerUnlocked(
                key: "continuity/resume_ready",
                id: resumeID,
                tags: ["continuity", "resume"],
                timestamp: timestamp
            )
        }
    }

    private func handoffIDUnlocked(resumeReadyOnly: Bool) throws -> String? {
        let predicate = resumeReadyOnly ? " WHERE resume_ready = 1" : ""
        return try withStatementUnlocked(
            "SELECT id FROM context_handoffs\(predicate) ORDER BY write_sequence DESC LIMIT 1"
        ) { statement in
            guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
            return textCol(statement, 0)
        }
    }

    private func replaceContinuityPointerUnlocked(
        key: String,
        id: String?,
        tags: [String],
        timestamp: String
    ) throws {
        if let id {
            try memorySetUnlocked(key: key, body: id, tags: tags, timestamp: timestamp)
            return
        }
        try withStatementUnlocked("DELETE FROM memory_notes WHERE key = ?") { statement in
            bind(statement, 1, key)
            try stepDone(statement)
        }
    }

    // MARK: - Sessions

    public func sessionStart(agentID: String, clientID: ClientID?) throws -> AgentSession {
        let now = clock.now()
        let s = AgentSession(agentID: agentID, clientID: clientID, status: .open, createdAt: now, updatedAt: now)
        let ts = ISO8601.string(from: now)
        try withStatement(
            "INSERT INTO agent_sessions (id, agent_id, client_id, status, summary, created_at, updated_at) VALUES (?,?,?,?,NULL,?,?)"
        ) { stmt in
            bind(stmt, 1, s.id.rawValue)
            bind(stmt, 2, agentID)
            bind(stmt, 3, clientID?.rawValue)
            bind(stmt, 4, SessionStatus.open.rawValue)
            bind(stmt, 5, ts)
            bind(stmt, 6, ts)
            try stepDone(stmt)
        }
        return s
    }

    public func sessionGet(id: SessionID) throws -> AgentSession? {
        lock.lock()
        defer { lock.unlock() }
        return try sessionGetUnlocked(id: id)
    }

    private func sessionGetUnlocked(id: SessionID) throws -> AgentSession? {
        try withStatementUnlocked(
            "SELECT id, agent_id, client_id, status, summary, created_at, updated_at FROM agent_sessions WHERE id = ?"
        ) { stmt in
            bind(stmt, 1, id.rawValue)
            guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
            return mapSession(stmt)
        }
    }

    public func sessionReattach(
        id: SessionID,
        expectedClientID: ClientID?,
        clientID: ClientID,
        bindingBody: String,
        agentID: String,
        supersedeSummary: String
    ) throws -> AgentSession {
        lock.lock()
        defer { lock.unlock() }
        try execUnlocked("BEGIN IMMEDIATE;")
        do {
            guard let existing = try sessionGetUnlocked(id: id) else {
                throw StoreError.notFound("Unknown agent session: \(id.rawValue)")
            }
            guard existing.status.isOpen else {
                throw StoreError.notFound("Agent session is not open: \(id.rawValue)")
            }
            guard existing.clientID == expectedClientID else {
                throw StoreError.conflict(
                    "Agent session ownership changed while reattaching: \(id.rawValue)"
                )
            }

            let timestamp = ISO8601.string(from: clock.now())
            try withStatementUnlocked(
                """
                UPDATE agent_sessions
                SET status='closed', summary=?, updated_at=?
                WHERE client_id=? AND id<>? AND status IN ('open','active','running','started')
                """
            ) { statement in
                bind(statement, 1, supersedeSummary)
                bind(statement, 2, timestamp)
                bind(statement, 3, clientID.rawValue)
                bind(statement, 4, id.rawValue)
                try stepDone(statement)
            }

            if existing.clientID != clientID {
                try withStatementUnlocked(
                    """
                    UPDATE agent_sessions SET client_id=?, updated_at=?
                    WHERE id=? AND status IN ('open','active','running','started')
                    """
                ) { statement in
                    bind(statement, 1, clientID.rawValue)
                    bind(statement, 2, timestamp)
                    bind(statement, 3, id.rawValue)
                    try stepDone(statement)
                    guard changesUnlocked() == 1 else {
                        throw StoreError.conflict(
                            "Agent session changed while reattaching: \(id.rawValue)"
                        )
                    }
                }
            }

            if let expectedClientID, expectedClientID != clientID {
                try withStatementUnlocked("DELETE FROM memory_notes WHERE key = ?") { statement in
                    bind(statement, 1, "agent_active/\(expectedClientID.rawValue)")
                    try stepDone(statement)
                }
            }
            try memorySetUnlocked(
                key: "agent_active/\(clientID.rawValue)",
                body: bindingBody,
                tags: ["agent_active", agentID],
                timestamp: timestamp
            )
            guard let attached = try sessionGetUnlocked(id: id) else {
                throw StoreError.notFound("Agent session missing after attach: \(id.rawValue)")
            }
            try execUnlocked("COMMIT;")
            return attached
        } catch {
            try? execUnlocked("ROLLBACK;")
            throw error
        }
    }

    public func sessionEnd(id: SessionID, summary: String?) throws -> AgentSession {
        guard try sessionGet(id: id) != nil else {
            throw StoreError.notFound("Unknown agent session: \(id.rawValue)")
        }
        let ts = ISO8601.string(from: clock.now())
        try withStatement(
            "UPDATE agent_sessions SET status='closed', summary=?, updated_at=? WHERE id=?"
        ) { stmt in
            bind(stmt, 1, summary)
            bind(stmt, 2, ts)
            bind(stmt, 3, id.rawValue)
            try stepDone(stmt)
        }
        guard let s = try sessionGet(id: id) else {
            throw StoreError.notFound("session missing after end")
        }
        return s
    }

    public func sessionTouch(id: SessionID) throws -> Bool {
        let ts = ISO8601.string(from: clock.now())
        return try withStatement(
            """
            UPDATE agent_sessions SET updated_at=?
            WHERE id=? AND status IN ('open','active','running','started')
            """
        ) { stmt in
            bind(stmt, 1, ts)
            bind(stmt, 2, id.rawValue)
            try stepDone(stmt)
            return changesUnlocked() > 0
        }
    }

    public func sessionList(agentID: String? = nil, status: SessionStatus? = nil) throws -> [AgentSession] {
        var sql = "SELECT id, agent_id, client_id, status, summary, created_at, updated_at FROM agent_sessions WHERE 1=1"
        if agentID != nil { sql += " AND agent_id = ?" }
        if status != nil { sql += " AND status = ?" }
        sql += " ORDER BY created_at DESC"
        return try withStatement(sql) { stmt in
            var i: Int32 = 1
            if let agentID { bind(stmt, i, agentID); i += 1 }
            if let status { bind(stmt, i, status.rawValue); i += 1 }
            var out: [AgentSession] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                out.append(mapSession(stmt))
            }
            return out
        }
    }

    public func sessionCloseOpen(
        for clientID: ClientID,
        except: SessionID? = nil,
        summary: String
    ) throws -> [AgentSession] {
        var closed: [AgentSession] = []
        var seen = Set<String>()
        for st in [SessionStatus.open, .active, .running, .started] {
            for s in try sessionList(status: st) where s.clientID == clientID {
                if seen.contains(s.id.rawValue) { continue }
                seen.insert(s.id.rawValue)
                if let except, s.id == except { continue }
                closed.append(try sessionEnd(id: s.id, summary: summary))
            }
        }
        return closed
    }

    // MARK: - Memory notes

    public func memorySet(key: String, body: String, tags: [String] = []) throws {
        let ts = ISO8601.string(from: clock.now())
        lock.lock()
        defer { lock.unlock() }
        try memorySetUnlocked(key: key, body: body, tags: tags, timestamp: ts)
    }

    private func memorySetUnlocked(
        key: String,
        body: String,
        tags: [String],
        timestamp: String
    ) throws {
        // store tags as JSON array string
        let tagsArr = try JSONSerialization.data(withJSONObject: tags)
        let tagsStr = String(data: tagsArr, encoding: .utf8) ?? "[]"
        try withStatementUnlocked(
            """
            INSERT INTO memory_notes(key, body, tags_json, created_at, updated_at)
            VALUES(?,?,?,?,?)
            ON CONFLICT(key) DO UPDATE SET body=excluded.body, tags_json=excluded.tags_json, updated_at=excluded.updated_at
            """
        ) { stmt in
            bind(stmt, 1, key)
            bind(stmt, 2, body)
            bind(stmt, 3, tagsStr)
            bind(stmt, 4, timestamp)
            bind(stmt, 5, timestamp)
            try stepDone(stmt)
        }
    }

    public func memoryGet(key: String) throws -> String? {
        try withStatement("SELECT body FROM memory_notes WHERE key = ?") { stmt in
            bind(stmt, 1, key)
            guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
            return String(cString: sqlite3_column_text(stmt, 0))
        }
    }

    public func memoryDelete(key: String) throws -> Bool {
        try withStatement("DELETE FROM memory_notes WHERE key = ?") { stmt in
            bind(stmt, 1, key)
            try stepDone(stmt)
            return changesUnlocked() > 0
        }
    }

    // MARK: - Audit

    public func auditAppend(_ event: AuditEvent) throws {
        let ts = ISO8601.string(from: event.timestamp)
        try withStatement(
            """
            INSERT INTO audit_events(timestamp, client_id, tool, args_digest, args_json, status, duration_ms, error)
            VALUES(?,?,?,?,?,?,?,?)
            """
        ) { stmt in
            bind(stmt, 1, ts)
            bind(stmt, 2, event.clientID)
            bind(stmt, 3, event.tool)
            bind(stmt, 4, event.argsDigest)
            bind(stmt, 5, event.argsJSON)
            bind(stmt, 6, event.status)
            if let ms = event.durationMs {
                sqlite3_bind_int(stmt, 7, Int32(ms))
            } else {
                sqlite3_bind_null(stmt, 7)
            }
            bind(stmt, 8, event.error)
            try stepDone(stmt)
        }
    }

    public func auditRecent(limit: Int = 50) throws -> [AuditEvent] {
        try withStatement(
            """
            SELECT timestamp, client_id, tool, args_digest, args_json, status, duration_ms, error
            FROM audit_events ORDER BY id DESC LIMIT ?
            """
        ) { stmt in
            sqlite3_bind_int(stmt, 1, Int32(limit))
            var out: [AuditEvent] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                let ts = String(cString: sqlite3_column_text(stmt, 0))
                let client: String? = textCol(stmt, 1)
                let tool = String(cString: sqlite3_column_text(stmt, 2))
                let digest = textCol(stmt, 3)
                let args = textCol(stmt, 4)
                let status = textCol(stmt, 5) ?? "ok"
                let ms: Int? = sqlite3_column_type(stmt, 6) == SQLITE_NULL ? nil : Int(sqlite3_column_int(stmt, 6))
                let err = textCol(stmt, 7)
                out.append(AuditEvent(
                    timestamp: ISO8601.date(from: ts) ?? Date(),
                    clientID: client,
                    tool: tool,
                    argsDigest: digest,
                    argsJSON: args,
                    status: status,
                    durationMs: ms,
                    error: err
                ))
            }
            return out
        }
    }

    // MARK: - Presence

    public func presenceUpsert(clientID: String, hostKind: String, pid: Int32, cwd: String) throws {
        let ts = ISO8601.string(from: clock.now())
        try withStatement(
            """
            INSERT INTO presence(client_id, host_kind, pid, cwd, last_heartbeat)
            VALUES(?,?,?,?,?)
            ON CONFLICT(client_id) DO UPDATE SET
              host_kind=excluded.host_kind, pid=excluded.pid, cwd=excluded.cwd, last_heartbeat=excluded.last_heartbeat
            """
        ) { stmt in
            bind(stmt, 1, clientID)
            bind(stmt, 2, hostKind)
            sqlite3_bind_int(stmt, 3, pid)
            bind(stmt, 4, cwd)
            bind(stmt, 5, ts)
            try stepDone(stmt)
        }
    }

    public func presenceRecords() throws -> [PresenceRecord] {
        try withStatement(
            "SELECT client_id, host_kind, pid, cwd, last_heartbeat FROM presence ORDER BY last_heartbeat DESC"
        ) { stmt in
            var out: [PresenceRecord] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                out.append(PresenceRecord(
                    clientID: String(cString: sqlite3_column_text(stmt, 0)),
                    hostKind: textCol(stmt, 1) ?? "",
                    pid: sqlite3_column_int(stmt, 2),
                    cwd: textCol(stmt, 3) ?? "",
                    lastHeartbeat: textCol(stmt, 4) ?? ""
                ))
            }
            return out
        }
    }

    /// Edge adapter for HTTP / legacy callers.
    public func presenceList() throws -> [[String: Any]] {
        try presenceRecords().map { $0.asDictionary() }
    }

    public func presenceDelete(clientID: String) throws {
        try withStatement("DELETE FROM presence WHERE client_id = ?") { stmt in
            bind(stmt, 1, clientID)
            try stepDone(stmt)
        }
    }

    /// Remove presence rows whose process is gone or heartbeat is older than `maxAgeSec`.
    @discardableResult
    public func presencePrune(maxAgeSec: TimeInterval = 120) throws -> Int {
        let rows = try presenceRecords()
        var removed = 0
        let now = clock.now()
        for row in rows {
            let clientID = row.clientID
            guard !clientID.isEmpty else { continue }
            let pid = row.pid
            let hb = row.lastHeartbeat
            let age: TimeInterval?
            if let d = ISO8601.date(from: hb) {
                age = now.timeIntervalSince(d)
            } else {
                age = nil
            }
            let processDead = pid <= 0 || kill(pid, 0) != 0
            let stale = age == nil || (age ?? 0) > maxAgeSec
            if processDead && stale {
                try presenceDelete(clientID: clientID)
                removed += 1
            }
        }
        return removed
    }

    // MARK: - SQLite helpers

    private func exec(_ sql: String) throws {
        lock.lock()
        defer { lock.unlock() }
        try execUnlocked(sql)
    }

    private func execUnlocked(_ sql: String) throws {
        guard let db else { throw StoreError.openFailed("nil db") }
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &err) != SQLITE_OK {
            let msg = err.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(err)
            throw StoreError.execFailed(msg)
        }
    }

    private func changesUnlocked() -> Int {
        guard let db else { return 0 }
        return Int(sqlite3_changes(db))
    }

    private func queryInt(_ sql: String) throws -> Int? {
        try withStatement(sql) { stmt in
            guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
            return Int(sqlite3_column_int(stmt, 0))
        }
    }

    private func tableHasColumn(table: String, column: String) throws -> Bool {
        try withStatement("PRAGMA table_info(\(table))") { stmt in
            while sqlite3_step(stmt) == SQLITE_ROW {
                if textCol(stmt, 1) == column { return true }
            }
            return false
        }
    }

    private func withStatement<T>(_ sql: String, body: (OpaquePointer) throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        return try withStatementUnlocked(sql, body: body)
    }

    private func withStatementUnlocked<T>(_ sql: String, body: (OpaquePointer) throws -> T) throws -> T {
        guard let db else { throw StoreError.openFailed("nil db") }
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) != SQLITE_OK {
            throw StoreError.execFailed(String(cString: sqlite3_errmsg(db)))
        }
        guard let stmt else { throw StoreError.execFailed("nil statement") }
        defer { sqlite3_finalize(stmt) }
        return try body(stmt)
    }

    private func withTransaction<T>(_ body: () throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        try execUnlocked("BEGIN IMMEDIATE;")
        do {
            let value = try body()
            try execUnlocked("COMMIT;")
            return value
        } catch {
            try? execUnlocked("ROLLBACK;")
            throw error
        }
    }

    private func stepDone(_ stmt: OpaquePointer) throws {
        let rc = sqlite3_step(stmt)
        guard rc == SQLITE_DONE else {
            throw StoreError.execFailed(String(cString: sqlite3_errmsg(db)))
        }
    }

    private func bind(_ stmt: OpaquePointer, _ idx: Int32, _ value: String?) {
        if let value {
            value.withCString { cstr in
                _ = sqlite3_bind_text(stmt, idx, cstr, -1, Self.sqliteTransient)
            }
        } else {
            sqlite3_bind_null(stmt, idx)
        }
    }

    private func textCol(_ stmt: OpaquePointer, _ idx: Int32) -> String? {
        guard let c = sqlite3_column_text(stmt, idx) else { return nil }
        return String(cString: c)
    }

    private func mapSession(_ stmt: OpaquePointer) -> AgentSession {
        let id = String(cString: sqlite3_column_text(stmt, 0))
        let agent = String(cString: sqlite3_column_text(stmt, 1))
        let client = textCol(stmt, 2).map { ClientID($0) }
        let status = SessionStatus(rawValue: textCol(stmt, 3) ?? "closed") ?? .closed
        let summary = textCol(stmt, 4)
        let created = textCol(stmt, 5).flatMap(ISO8601.date(from:)) ?? Date()
        let updated = textCol(stmt, 6).flatMap(ISO8601.date(from:)) ?? Date()
        return AgentSession(
            id: SessionID(id),
            agentID: agent,
            clientID: client,
            status: status,
            summary: summary,
            createdAt: created,
            updatedAt: updated
        )
    }
}
