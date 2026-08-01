// ContextContinuityService.swift
// What: Owns context handoff packets and agent-continuity snapshots for chat resume.
// How: Builds packets from tool args + open agent sessions, persists SQLite/files,
// projects current-task.md, and returns MCP-ready payloads with resume seeds.
// Why: Stdio MCP clients (LM Studio) need durable cross-chat state without HTTP.

import Foundation
import Darwin

/// Context + agent continuity control plane (stdio MCP / same serve binary).
public final class ContextContinuityService: @unchecked Sendable {
    private let paths: AppPaths
    private let store: SQLiteStore
    private let sessions: AgentSessionService
    private let diagnostics: DiagnosticLog
    private let clock: any Clock
    private let lock = NSLock()
    private static let processPersistenceLock = NSLock()
    private static let persistenceLockTimeout: TimeInterval = 3

    public init(
        paths: AppPaths,
        store: SQLiteStore,
        sessions: AgentSessionService,
        diagnostics: DiagnosticLog,
        clock: any Clock = SystemClock()
    ) {
        self.paths = paths
        self.store = store
        self.sessions = sessions
        self.diagnostics = diagnostics
        self.clock = clock
        do {
            try reconcileProjections()
        } catch {
            diagnostics.warn("continuity_projection_reconcile_failed", [
                "error": "\(error)",
            ], category: .general)
        }
    }

    // MARK: - Public tool operations

    /// Soft save — write/update packet; work may continue.
    public func checkpoint(
        arguments: [String: Any],
        clientID: ClientID,
        source: HandoffSource = .model
    ) throws -> [String: Any] {
        let persisted = try mutateAndPersist {
            try buildPacket(arguments: arguments, clientID: clientID, source: source, finalize: false)
        }
        let packet = persisted.packet
        diagnostics.info("session_checkpoint", [
            "handoff_id": packet.id,
            "client_id": clientID.rawValue,
            "source": source.rawValue,
            "agents": "\(packet.agents.count)",
        ], category: .general)
        return successPayload(packet, action: "checkpoint", projectionWarning: persisted.projectionWarning)
    }

    /// Finalize for new-chat resume.
    public func handoff(
        arguments: [String: Any],
        clientID: ClientID,
        source: HandoffSource = .model
    ) throws -> [String: Any] {
        let persisted = try mutateAndPersist {
            var packet = try buildPacket(arguments: arguments, clientID: clientID, source: source, finalize: true)
            packet.resumeReady = true
            if packet.resumeSeed.isEmpty {
                packet.resumeSeed = packet.defaultResumeSeed()
                packet.resumeSeedIsCustom = false
            }
            return packet
        }
        let packet = persisted.packet
        diagnostics.info("session_handoff", [
            "handoff_id": packet.id,
            "client_id": clientID.rawValue,
            "source": source.rawValue,
            "agents": "\(packet.agents.count)",
        ], category: .general)
        var payload = successPayload(packet, action: "handoff", projectionWarning: persisted.projectionWarning)
        payload["handoff_required"] = true
        payload["message"] =
            "Handoff saved. Start a new LM Studio chat with Forge MCP enabled, then call context_get " +
            "(or use resume.seed as the first user message)."
        return payload
    }

    public func get(id: String? = nil, preferResumeReady: Bool = false) throws -> [String: Any] {
        let packet: HandoffPacket?
        if let id, !id.isEmpty {
            packet = try store.handoffGet(id: id)
        } else {
            packet = try store.handoffLatest(resumeReadyOnly: preferResumeReady)
                ?? store.handoffLatest(resumeReadyOnly: false)
        }
        guard let packet else {
            let message: String
            if let id, !id.isEmpty {
                message = "No handoff packet found for id \(id)."
            } else {
                message = "No handoff packet yet. Call session_checkpoint or session_handoff during work."
            }
            return [
                "ok": true,
                "found": false,
                "message": message,
                "bootstrap": [
                    "forge_status",
                    "session_checkpoint when you have a goal",
                ],
            ]
        }
        var payload = successPayload(packet, action: "get")
        payload["found"] = true
        return payload
    }

    public func list(limit: Int = 10) throws -> [String: Any] {
        let packets = try store.handoffList(limit: limit)
        return [
            "ok": true,
            "count": packets.count,
            "handoffs": packets.map { p in
                [
                    "id": p.id,
                    "updated_at": p.updatedAt,
                    "source": p.source.rawValue,
                    "resume_ready": p.resumeReady,
                    "goal": p.goal,
                    "status": p.status,
                    "agent_count": p.agents.count,
                ] as [String: Any]
            },
        ]
    }

    /// Compact status for forge_status.
    public func statusSummary() throws -> [String: Any] {
        let latest = try store.handoffLatest(resumeReadyOnly: false)
        let resume = try store.handoffLatest(resumeReadyOnly: true)
        let open = try store.sessionList().filter(\.status.isOpen)
        return [
            "latest_id": latest?.id as Any,
            "latest_updated_at": latest?.updatedAt as Any,
            "resume_ready": resume != nil,
            "resume_id": resume?.id as Any,
            "open_agent_sessions": open.count,
            "tools": [
                "session_checkpoint",
                "session_handoff",
                "context_get",
                "context_list",
            ],
            "note": "New chat bootstrap: call context_get over stdio MCP (forge-conductor).",
        ]
    }

    /// Auto-checkpoint used by budget policy (identical tool-loop / pressure).
    public func budgetAutoCheckpoint(clientID: ClientID, reason: String) throws -> HandoffPacket {
        let persisted = try mutateAndPersist {
            var args: [String: Any] = ["status": "budget_pressure"]
            if let latest = try store.handoffLatest(clientID: clientID.rawValue) {
                args["handoff_id"] = latest.id
            }
            var packet = try buildPacket(
                arguments: args,
                clientID: clientID,
                source: .budget,
                finalize: true
            )
            if packet.goal.isEmpty { packet.goal = "Auto-checkpoint: \(reason)" }
            if packet.nextActions.isEmpty {
                packet.nextActions = [
                    "Start a new chat if context is full",
                    "Call context_get",
                    "Continue from open agents",
                ]
            }
            let budgetNote = "Budget trigger: \(reason)"
            if packet.narrative.isEmpty {
                packet.narrative = budgetNote
            } else if !packet.narrative.contains(budgetNote) {
                packet.narrative = String(
                    "\(packet.narrative)\n\n\(budgetNote)".prefix(HandoffPacket.maxNarrativeChars)
                )
            }
            packet.resumeReady = true
            if !packet.resumeSeedIsCustom {
                packet.resumeSeed = packet.defaultResumeSeed()
            }
            return packet
        }
        let packet = persisted.packet
        diagnostics.warn("budget_handoff", [
            "handoff_id": packet.id,
            "client_id": clientID.rawValue,
            "reason": reason,
        ], category: .tools)
        return packet
    }

    // MARK: - Build / persist

    private func buildPacket(
        arguments: [String: Any],
        clientID: ClientID,
        source: HandoffSource,
        finalize: Bool
    ) throws -> HandoffPacket {
        let now = ISO8601.string(from: clock.now())
        let existingID = ToolArgHelpers.string(arguments, "handoff_id")
            ?? ToolArgHelpers.string(arguments, "id")
        let explicitResumeSeed = ToolArgHelpers.string(arguments, "resume_seed")
        var base = HandoffPacket(
            updatedAt: now,
            source: source,
            clientID: clientID.rawValue
        )
        if let existingID {
            guard let prior = try store.handoffGet(id: existingID) else {
                throw StoreError.notFound("Unknown handoff packet: \(existingID)")
            }
            base = prior
            base.updatedAt = now
            base.source = source
        } else if let latest = try store.handoffLatest(clientID: clientID.rawValue), !latest.resumeReady {
            // Continue the calling MCP client's open packet when no id is supplied.
            base = latest
            base.updatedAt = now
            base.source = source
        } else {
            base.createdAt = now
            base.updatedAt = now
        }
        base.clientID = clientID.rawValue

        if let goal = ToolArgHelpers.string(arguments, "goal"), !goal.isEmpty { base.goal = goal }
        if let status = ToolArgHelpers.string(arguments, "status"), !status.isEmpty { base.status = status }
        if let slug = ToolArgHelpers.string(arguments, "project_slug")
            ?? ToolArgHelpers.string(arguments, "project") {
            base.projectSlug = slug
        }
        if let cwd = ToolArgHelpers.string(arguments, "cwd") { base.cwd = cwd }
        if let chat = ToolArgHelpers.string(arguments, "chat_label")
            ?? ToolArgHelpers.string(arguments, "chat") {
            base.chatLabel = chat
        }
        if let narrative = ToolArgHelpers.string(arguments, "narrative")
            ?? ToolArgHelpers.string(arguments, "summary") {
            base.narrative = String(narrative.prefix(HandoffPacket.maxNarrativeChars))
        }
        if let seed = explicitResumeSeed {
            base.resumeSeed = seed
            base.resumeSeedIsCustom = !seed.isEmpty
        }

        if let blockers = arguments["blockers"] as? [String] {
            base.blockers = blockers
        } else if let b = ToolArgHelpers.string(arguments, "blockers") {
            base.blockers = b.split(separator: "\n").map { String($0).trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        }
        if let next = arguments["next_actions"] as? [String] {
            base.nextActions = next
        } else if let n = ToolArgHelpers.string(arguments, "next_actions") {
            base.nextActions = n.split(separator: "\n").map { String($0).trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        }
        if let files = arguments["key_files"] as? [String] {
            base.keyFiles = files
        } else if let f = ToolArgHelpers.string(arguments, "key_files") {
            base.keyFiles = f.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        }
        if let decisions = arguments["decisions"] as? [String] {
            base.decisions = decisions
        }

        base.agents = try snapshotAgents(clientID: clientID)

        // Fill goal/cwd from active binding if still empty.
        if let binding = sessions.binding(for: clientID) {
            if base.goal.isEmpty { base.goal = binding.goal }
            if base.cwd == nil || base.cwd?.isEmpty == true { base.cwd = binding.cwd }
        }

        if finalize {
            base.resumeReady = true
        }
        if explicitResumeSeed == nil, !base.resumeSeedIsCustom {
            base.resumeSeed = base.defaultResumeSeed()
        }
        return base
    }

    private func snapshotAgents(clientID: ClientID) throws -> [AgentContinuitySnapshot] {
        let open = try store.sessionList().filter(\.status.isOpen)

        // Deduplicate by session id
        var seen = Set<String>()
        var snaps: [AgentContinuitySnapshot] = []
        for s in open where s.clientID == clientID {
            if seen.contains(s.id.rawValue) { continue }
            seen.insert(s.id.rawValue)

            var goal = ""
            var cwd: String?
            if let body = try? store.memoryGet(key: "agent_run/\(s.id.rawValue)"),
               let data = body.data(using: .utf8),
               let obj = try? JSONSupport.object(from: data) {
                goal = obj["goal"] as? String ?? ""
                cwd = obj["cwd"] as? String
            }
            if goal.isEmpty, let binding = sessions.binding(for: clientID), binding.sessionID == s.id {
                goal = binding.goal
                cwd = binding.cwd
            }

            snaps.append(
                AgentContinuitySnapshot(
                    sessionID: s.id.rawValue,
                    agentID: s.agentID,
                    goal: goal,
                    cwd: cwd,
                    status: s.status.rawValue,
                    updatedAt: ISO8601.string(from: s.updatedAt),
                    resumeHint:
                        "agent_run_status(session_id: \"\(s.id.rawValue)\"); " +
                        "if stale, agent_run_complete then agent_run_start with same goal/cwd"
                )
            )
        }
        return snaps
    }

    private struct PersistenceOutcome {
        var packet: HandoffPacket
        var projectionWarning: String?
    }

    private func mutateAndPersist(_ mutation: () throws -> HandoffPacket) throws -> PersistenceOutcome {
        guard lock.lock(before: Date().addingTimeInterval(Self.persistenceLockTimeout)) else {
            throw posixPersistenceError(operation: "lock continuity service", code: EBUSY)
        }
        defer { lock.unlock() }
        try paths.ensureLayout()
        return try withPersistenceFileLock {
            let packet = try mutation()
            try store.handoffUpsert(packet)
            do {
                try writeProjections(packet)
                return PersistenceOutcome(packet: packet, projectionWarning: nil)
            } catch {
                diagnostics.warn("continuity_projection_write_failed", [
                    "handoff_id": packet.id,
                    "error": "\(error)",
                ], category: .general)
                return PersistenceOutcome(packet: packet, projectionWarning: "\(error)")
            }
        }
    }

    /// SQLite is authoritative. Rebuild the readable projections at process start
    /// so an interrupted write cannot leave LATEST/current-task.json out of sync.
    private func reconcileProjections() throws {
        guard lock.lock(before: Date().addingTimeInterval(Self.persistenceLockTimeout)) else {
            throw posixPersistenceError(operation: "lock continuity service", code: EBUSY)
        }
        defer { lock.unlock() }
        try paths.ensureLayout()
        try withPersistenceFileLock {
            try store.handoffRepairPointers()
            try ensureMemoryIndex()
            for packet in try store.handoffListAll() {
                do {
                    try writePacketProjection(packet)
                } catch {
                    diagnostics.warn("continuity_packet_projection_reconcile_failed", [
                        "handoff_id": packet.id,
                        "error": "\(error)",
                    ], category: .general)
                }
            }
            if let latest = try store.handoffLatest(resumeReadyOnly: false) {
                try writeLatestProjections(latest)
            }
        }
    }

    private func writeProjections(_ packet: HandoffPacket) throws {
        try writePacketProjection(packet)
        try writeLatestProjections(packet)
    }

    private func writePacketProjection(_ packet: HandoffPacket) throws {
        let fileURL = try packetProjectionURL(id: packet.id)
        let data = try JSONSupport.data(from: packet.asDictionary())
        try data.write(to: fileURL, options: .atomic)
    }

    private func writeLatestProjections(_ packet: HandoffPacket) throws {
        // Pointer for latest
        let latestURL = paths.memoryHandoffsDir.appendingPathComponent("LATEST")
        try packet.id.write(to: latestURL, atomically: true, encoding: .utf8)

        try projectCurrentTask(packet)
        try ensureMemoryIndex()
    }

    private func packetProjectionURL(id: String) throws -> URL {
        let root = paths.memoryHandoffsDir.standardizedFileURL
        let candidate = root.appendingPathComponent("\(id).json").standardizedFileURL
        guard candidate.deletingLastPathComponent() == root else {
            throw NSError(
                domain: NSCocoaErrorDomain,
                code: CocoaError.fileWriteInvalidFileName.rawValue,
                userInfo: [NSLocalizedDescriptionKey: "Invalid handoff projection id"]
            )
        }
        return candidate
    }

    /// Primary and fallback MCP processes share one home. An advisory file lock
    /// makes the SQLite write and its JSON/Markdown projections one serialized unit.
    private func withPersistenceFileLock<T>(_ body: () throws -> T) throws -> T {
        let deadline = Date().addingTimeInterval(Self.persistenceLockTimeout)
        guard Self.processPersistenceLock.lock(before: deadline) else {
            throw posixPersistenceError(operation: "lock process continuity service", code: EBUSY)
        }
        defer { Self.processPersistenceLock.unlock() }

        let mode = mode_t(S_IRUSR | S_IWUSR)
        let descriptor = paths.memoryContinuityLock.path.withCString {
            Darwin.open($0, O_CREAT | O_RDWR, mode)
        }
        guard descriptor >= 0 else {
            throw posixPersistenceError(operation: "open continuity lock")
        }
        defer { _ = Darwin.close(descriptor) }

        while Darwin.lockf(descriptor, F_TLOCK, 0) != 0 {
            let code = errno
            guard code == EACCES || code == EAGAIN else {
                throw posixPersistenceError(operation: "lock continuity projections", code: code)
            }
            guard Date() < deadline else {
                throw posixPersistenceError(operation: "lock continuity projections", code: EBUSY)
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
        defer { _ = Darwin.lockf(descriptor, F_ULOCK, 0) }
        return try body()
    }

    private func posixPersistenceError(operation: String, code: Int32 = errno) -> NSError {
        return NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(code),
            userInfo: [
                NSLocalizedDescriptionKey:
                    "Failed to \(operation): \(String(cString: strerror(code)))",
            ]
        )
    }

    private func projectCurrentTask(_ packet: HandoffPacket) throws {
        var md = """
        # Current Task

        **Status:** \(packet.status)
        **Handoff id:** `\(packet.id)`
        **Source:** \(packet.source.rawValue)
        **Resume ready:** \(packet.resumeReady)
        """
        if let slug = packet.projectSlug { md += "\n**Project slug:** \(slug)" }
        if let cwd = packet.cwd { md += "\n**Workspace / cwd:** \(cwd)" }
        md += "\n\n## Goal\n\n\(packet.goal.isEmpty ? "_(not set)_" : packet.goal)\n"
        if !packet.nextActions.isEmpty {
            md += "\n## Next actions\n\n"
            for a in packet.nextActions { md += "- [ ] \(a)\n" }
        }
        if !packet.blockers.isEmpty {
            md += "\n## Blockers\n\n"
            for b in packet.blockers { md += "- \(b)\n" }
        }
        if !packet.agents.isEmpty {
            md += "\n## Open agents\n\n"
            for a in packet.agents {
                md += "- **\(a.agentID)** `\(a.sessionID)` — \(a.status)"
                if !a.goal.isEmpty { md += " — \(a.goal)" }
                md += "\n"
            }
        }
        if !packet.narrative.isEmpty {
            md += "\n## Narrative\n\n\(packet.narrative)\n"
        }
        md += "\n## Last updated\n\n\(packet.updatedAt)\n"
        try md.write(to: paths.memoryCurrentTask, atomically: true, encoding: .utf8)
    }

    private func ensureMemoryIndex() throws {
        guard !FileManager.default.fileExists(atPath: paths.memoryIndex.path) else { return }
        let index = """
        # Forge Conductor — Durable Memory

        | Path | Purpose |
        |------|---------|
        | `INDEX.md` | This map |
        | `current-task.md` | Active goal / handoff projection |
        | `handoffs/` | Versioned context + agent continuity packets |

        Bootstrap every new chat: `forge_status` → `context_get` → continue task.
        """
        try index.write(to: paths.memoryIndex, atomically: true, encoding: .utf8)
    }

    private func successPayload(
        _ packet: HandoffPacket,
        action: String,
        projectionWarning: String? = nil
    ) -> [String: Any] {
        var payload: [String: Any] = [
            "ok": true,
            "action": action,
            "handoff_id": packet.id,
            "resume_ready": packet.resumeReady,
            "packet": packet.asDictionary(),
            "resume_seed": packet.resumeSeed.isEmpty ? packet.defaultResumeSeed() : packet.resumeSeed,
            "paths": [
                "json": paths.memoryHandoffsDir.appendingPathComponent("\(packet.id).json").path,
                "current_task": paths.memoryCurrentTask.path,
            ] as [String: Any],
        ]
        payload["projection_ok"] = projectionWarning == nil
        payload["projection_repair_pending"] = projectionWarning != nil
        if let projectionWarning {
            payload["projection_warning"] = projectionWarning
        }
        return payload
    }
}
