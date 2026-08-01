// AgentSessionService.swift
// What: Owns the lifecycle of durable agent execution sessions.
// How: It validates catalog entries, persists start/status/completion transitions,
// enforces one active binding, and checks completion reports against declared schemas.
// Why: Central lifecycle rules keep every connector consistent and recoverable.

import Foundation

/// Owns specialist session lifecycle with durable active bindings.
public final class AgentSessionService: SessionManaging, @unchecked Sendable {
    private let store: SQLiteStore
    private let catalog: AgentCatalog
    private let audit: AuditService
    private let diagnostics: DiagnosticLog
    private let clock: any Clock
    private let idleTTL: TimeInterval

    private var memoryBindings: [String: ActiveBinding] = [:]
    private let lock = NSLock()

    public init(
        store: SQLiteStore,
        catalog: AgentCatalog,
        audit: AuditService,
        diagnostics: DiagnosticLog,
        clock: any Clock = SystemClock(),
        idleTTL: TimeInterval = 14_400
    ) {
        self.store = store
        self.catalog = catalog
        self.audit = audit
        self.diagnostics = diagnostics
        self.clock = clock
        self.idleTTL = idleTTL
    }

    // MARK: - Public API

    public func start(agentID: String, goal: String, clientID: ClientID, cwd: String? = nil) throws -> [String: Any] {
        guard let spec = catalog.get(agentID) else {
            return ToolResult.failure(
                code: "agent_not_found",
                message: "Unknown agent '\(agentID)'",
                retryable: true
            ).payload
        }

        try pruneStale()
        let supersedeSummary = try JSONSupport.string(from: [
            "event": "superseded",
            "ok_to_reuse": true,
            "message": "Closed because a new agent session started",
            "new_agent_id": agentID,
        ])
        _ = try store.sessionCloseOpen(for: clientID, summary: supersedeSummary)

        let session = try store.sessionStart(agentID: agentID, clientID: clientID)
        let binding = ActiveBinding(
            sessionID: session.id,
            agentID: agentID,
            goal: goal,
            toolsPrimary: spec.tools,
            toolsForbidden: spec.toolsForbidden,
            outputSchema: spec.outputSchema,
            doneDefinition: spec.doneDefinition,
            cwd: cwd
        )
        try setBinding(clientID: clientID, binding: binding)

        let runState: [String: Any] = [
            "session_id": session.id.rawValue,
            "agent_id": agentID,
            "goal": goal,
            "cwd": cwd as Any,
            "status": "running",
            "output_schema": spec.outputSchema,
            "first_moves": spec.firstMoves,
        ]
        try store.memorySet(
            key: "agent_run/\(session.id.rawValue)",
            body: try JSONSupport.string(from: runState.compactNSNull()),
            tags: ["agent_run", agentID]
        )

        try audit.append(
            tool: "agent_run_start",
            status: "ok",
            clientID: clientID.rawValue,
            args: [
                "session_id": session.id.rawValue,
                "agent_id": agentID,
                "agent_session_id": session.id.rawValue,
                "goal": goal,
            ],
            mutating: true
        )
        diagnostics.info("agent_run_start", [
            "agent_id": agentID,
            "session_id": session.id.rawValue,
        ])

        return [
            "ok": true,
            "session": sessionDict(session),
            "session_id": session.id.rawValue,
            "goal": goal,
            "cwd": cwd as Any,
            "agent": spec.asDictionary(includeBody: true),
            "first_moves": spec.firstMoves,
            "done_definition": spec.doneDefinition,
            "output_schema": spec.outputSchema,
            "tools_primary": spec.tools,
            "tools_forbidden": spec.toolsForbidden,
            "must_complete": true,
            "next": [
                "Adopt agent.body as role instructions",
                "Execute first_moves",
                "Prefer tools_primary",
                "REQUIRED: agent_run_complete(session_id: '\(session.id.rawValue)', report: {…output_schema})",
            ],
            "token_policy": "Large context host: do not skip specialists to save tokens.",
        ]
    }

    public func status(sessionID: SessionID, clientID: ClientID?) throws -> [String: Any] {
        var session = try store.sessionGet(id: sessionID)
        var reattached = false
        if let clientID, session?.status.isOpen == true {
            reattached = try attach(sessionID: sessionID, clientID: clientID)
            session = try store.sessionGet(id: sessionID)
        }
        if let session, session.status.isOpen {
            _ = try? store.sessionTouch(id: sessionID)
        }
        var idleSec: Int?
        var abandonRisk = false
        var mustComplete = false
        var reminder: String?
        if let session, session.status.isOpen {
            mustComplete = true
            let idle = Int(clock.now().timeIntervalSince(session.updatedAt))
            idleSec = idle
            abandonRisk = idle > 300
            reminder =
                "Session \(sessionID.rawValue) is still OPEN. You MUST call agent_run_complete before finishing."
            if abandonRisk {
                reminder! += " Idle ~\(idle)s — high risk of auto-close."
            }
        }
        let binding = clientID.flatMap { getBinding(clientID: $0) }
        return [
            "ok": true,
            "session": session.map(sessionDict) as Any,
            "must_complete": mustComplete,
            "idle_sec": idleSec as Any,
            "abandon_risk": abandonRisk,
            "reattached": reattached,
            "reminder": reminder as Any,
            "active_binding": binding.map { b in
                [
                    "session_id": b.sessionID.rawValue,
                    "agent_id": b.agentID,
                    "goal": b.goal,
                ] as [String: Any]
            } as Any,
        ].compactNSNull()
    }

    public func complete(
        sessionID: SessionID,
        report: [String: Any]?,
        clientID: ClientID?
    ) throws -> [String: Any] {
        guard let session = try store.sessionGet(id: sessionID) else {
            return ToolResult.failure(
                code: "session_not_found",
                message: "Unknown session \(sessionID.rawValue)",
                retryable: true
            ).payload
        }

        let reportObj = report ?? [:]
        let runBody = try store.memoryGet(key: "agent_run/\(sessionID.rawValue)")
        var schema: [String] = []
        var goal = ""
        if let runBody,
           let run = try? JSONSupport.object(from: Data(runBody.utf8)) {
            schema = run["output_schema"] as? [String] ?? []
            goal = run["goal"] as? String ?? ""
        }
        if schema.isEmpty, let spec = catalog.get(session.agentID) {
            schema = spec.outputSchema
        }

        var missing: [String] = []
        for key in schema {
            let v = reportObj[key]
            if v == nil { missing.append(key); continue }
            if let s = v as? String, s.isEmpty { missing.append(key); continue }
            if let a = v as? [Any], a.isEmpty { missing.append(key); continue }
            if let d = v as? [String: Any], d.isEmpty { missing.append(key); continue }
        }

        let summaryObj: [String: Any] = [
            "goal": goal,
            "report": reportObj,
            "missing_schema_keys": missing,
        ]
        let summary = try JSONSupport.string(from: summaryObj)
        let closed = try store.sessionEnd(id: sessionID, summary: String(summary.prefix(4000)))

        if let clientID {
            try clearBinding(clientID: clientID, sessionID: sessionID)
        }

        let status = missing.isEmpty ? "ok" : "warn"
        try audit.append(
            tool: "agent_run_complete",
            status: status,
            clientID: clientID?.rawValue,
            args: [
                "session_id": sessionID.rawValue,
                "agent_id": session.agentID,
                "agent_session_id": sessionID.rawValue,
                "missing_schema_keys": missing,
                "schema_complete": missing.isEmpty,
                "goal": String(goal.prefix(200)),
            ],
            error: missing.isEmpty ? nil : "missing_schema_keys=\(missing)",
            mutating: true
        )

        if !missing.isEmpty {
            diagnostics.warn("agent_run_incomplete", [
                "agent_id": session.agentID,
                "session_id": sessionID.rawValue,
                "missing": missing.joined(separator: ","),
            ])
        } else {
            diagnostics.info("agent_run_complete", [
                "agent_id": session.agentID,
                "session_id": sessionID.rawValue,
            ])
        }

        return [
            "ok": true,
            "session": sessionDict(closed),
            "report": reportObj,
            "schema_complete": missing.isEmpty,
            "missing_schema_keys": missing,
            "message": missing.isEmpty
                ? "Run complete."
                : "Run complete with missing report keys: \(missing). Fill output_schema next time.",
        ]
    }

    public func binding(for clientID: ClientID) -> ActiveBinding? {
        getBinding(clientID: clientID)
    }

    @discardableResult
    public func attach(sessionID: SessionID, clientID: ClientID) throws -> Bool {
        guard let session = try store.sessionGet(id: sessionID), session.status.isOpen else {
            return false
        }
        if session.clientID == clientID,
           getBinding(clientID: clientID)?.sessionID == sessionID {
            return false
        }

        let supersedeSummary = try JSONSupport.string(from: [
            "event": "superseded",
            "ok_to_reuse": true,
            "message": "Closed because an existing agent session was reattached",
            "reattached_session_id": sessionID.rawValue,
        ])
        var goal = ""
        var cwd: String?
        var toolsPrimary: [String] = []
        var toolsForbidden: [String] = []
        var outputSchema: [String] = []
        var doneDefinition: [String] = []
        if let runBody = try store.memoryGet(key: "agent_run/\(sessionID.rawValue)"),
           let run = try? JSONSupport.object(from: Data(runBody.utf8)) {
            goal = run["goal"] as? String ?? ""
            cwd = run["cwd"] as? String
            outputSchema = run["output_schema"] as? [String] ?? []
        }
        if let spec = catalog.get(session.agentID) {
            toolsPrimary = spec.tools
            toolsForbidden = spec.toolsForbidden
            if outputSchema.isEmpty { outputSchema = spec.outputSchema }
            doneDefinition = spec.doneDefinition
        }

        let previousClient = session.clientID
        let binding = ActiveBinding(
            sessionID: sessionID,
            agentID: session.agentID,
            goal: goal,
            toolsPrimary: toolsPrimary,
            toolsForbidden: toolsForbidden,
            outputSchema: outputSchema,
            doneDefinition: doneDefinition,
            cwd: cwd
        )
        let body = try bindingBody(binding)
        _ = try store.sessionReattach(
            id: sessionID,
            expectedClientID: previousClient,
            clientID: clientID,
            bindingBody: body,
            agentID: session.agentID,
            supersedeSummary: supersedeSummary
        )
        if let previousClient, previousClient != clientID {
            removeMemoryBinding(clientID: previousClient, sessionID: sessionID)
        }
        setMemoryBinding(clientID: clientID, binding: binding)
        diagnostics.info("agent_session_reattached", [
            "agent_id": session.agentID,
            "session_id": sessionID.rawValue,
            "client_id": clientID.rawValue,
        ])
        return previousClient != clientID
    }

    public func rehydrate(clientID: ClientID) throws -> ActiveBinding? {
        if let binding = getBinding(clientID: clientID) {
            if let session = try store.sessionGet(id: binding.sessionID),
               session.status.isOpen,
               session.clientID == clientID {
                return binding
            }
            try clearBinding(clientID: clientID, sessionID: binding.sessionID)
        }
        // From memory note
        if let body = try store.memoryGet(key: "agent_active/\(clientID.rawValue)"),
           let data = body.data(using: .utf8),
           let obj = try? JSONSupport.object(from: data),
           obj["cleared"] as? Bool != true,
           let sid = obj["session_id"] as? String {
            if let sess = try store.sessionGet(id: SessionID(sid)),
               sess.status.isOpen,
               sess.clientID == clientID {
                let binding = ActiveBinding(
                    sessionID: SessionID(sid),
                    agentID: obj["agent_id"] as? String ?? sess.agentID,
                    goal: obj["goal"] as? String ?? "",
                    toolsPrimary: obj["tools_primary"] as? [String] ?? [],
                    toolsForbidden: obj["tools_forbidden"] as? [String] ?? [],
                    outputSchema: obj["output_schema"] as? [String] ?? [],
                    doneDefinition: obj["done_definition"] as? [String] ?? [],
                    cwd: obj["cwd"] as? String
                )
                setMemoryBinding(clientID: clientID, binding: binding)
                diagnostics.info("agent_binding_rehydrated", [
                    "source": "memory",
                    "agent_id": binding.agentID,
                    "session_id": sid,
                ])
                return binding
            }
        }
        // Open session fallback
        for st in [SessionStatus.open, .active, .running, .started] {
            let list = try store.sessionList(status: st).filter { $0.clientID == clientID }
            if let s = list.sorted(by: { $0.updatedAt > $1.updatedAt }).first {
                let spec = catalog.get(s.agentID)
                let binding = ActiveBinding(
                    sessionID: s.id,
                    agentID: s.agentID,
                    goal: "",
                    toolsPrimary: spec?.tools ?? [],
                    toolsForbidden: spec?.toolsForbidden ?? [],
                    outputSchema: spec?.outputSchema ?? [],
                    doneDefinition: spec?.doneDefinition ?? []
                )
                try setBinding(clientID: clientID, binding: binding)
                diagnostics.warn("agent_binding_rehydrated", [
                    "source": "open_session",
                    "agent_id": binding.agentID,
                    "session_id": s.id.rawValue,
                    "message": "In-process binding missing; rehydrated from SQLite",
                ])
                return binding
            }
        }
        return nil
    }

    public func touchIfActive(clientID: ClientID) {
        if let b = getBinding(clientID: clientID) {
            _ = try? store.sessionTouch(id: b.sessionID)
        }
    }

    public func pruneStale() throws {
        let cutoff = clock.now().addingTimeInterval(-idleTTL)
        for st in [SessionStatus.open, .active, .running, .started] {
            for s in try store.sessionList(status: st) where s.updatedAt < cutoff {
                let age = Int(clock.now().timeIntervalSince(s.updatedAt))
                let summary = try JSONSupport.string(from: [
                    "event": "auto_closed_stale",
                    "ok_to_reuse": true,
                    "age_sec": age,
                    "message": "Session abandoned without agent_run_complete (idle \(age)s).",
                ])
                _ = try store.sessionEnd(id: s.id, summary: summary)
                diagnostics.warn("agent_session_auto_closed", [
                    "agent_id": s.agentID,
                    "session_id": s.id.rawValue,
                    "age_sec": "\(age)",
                ])
                try? audit.append(
                    tool: "agent_session_auto_closed",
                    status: "warn",
                    clientID: s.clientID?.rawValue,
                    args: [
                        "session_id": s.id.rawValue,
                        "agent_id": s.agentID,
                        "age_sec": age,
                        "ok_to_reuse": true,
                    ],
                    error: "abandoned session auto-closed after \(age)s idle",
                    mutating: true
                )
            }
        }
    }

    // MARK: - Binding storage

    private func setBinding(clientID: ClientID, binding: ActiveBinding) throws {
        let body = try bindingBody(binding)
        try store.memorySet(key: "agent_active/\(clientID.rawValue)", body: body, tags: ["agent_active", binding.agentID])
        setMemoryBinding(clientID: clientID, binding: binding)
    }

    private func bindingBody(_ binding: ActiveBinding) throws -> String {
        try JSONSupport.string(from: [
            "session_id": binding.sessionID.rawValue,
            "agent_id": binding.agentID,
            "goal": binding.goal,
            "tools_primary": binding.toolsPrimary,
            "tools_forbidden": binding.toolsForbidden,
            "output_schema": binding.outputSchema,
            "done_definition": binding.doneDefinition,
            "cwd": binding.cwd as Any,
        ].compactNSNull())
    }

    private func clearBinding(clientID: ClientID, sessionID: SessionID) throws {
        removeMemoryBinding(clientID: clientID, sessionID: sessionID)
        _ = try store.memoryDelete(key: "agent_active/\(clientID.rawValue)")
    }

    private func removeMemoryBinding(clientID: ClientID, sessionID: SessionID) {
        lock.lock()
        if memoryBindings[clientID.rawValue]?.sessionID == sessionID {
            memoryBindings.removeValue(forKey: clientID.rawValue)
        }
        lock.unlock()
    }

    private func getBinding(clientID: ClientID) -> ActiveBinding? {
        lock.lock(); defer { lock.unlock() }
        return memoryBindings[clientID.rawValue]
    }

    private func setMemoryBinding(clientID: ClientID, binding: ActiveBinding) {
        lock.lock()
        memoryBindings[clientID.rawValue] = binding
        lock.unlock()
    }

    private func sessionDict(_ s: AgentSession) -> [String: Any] {
        [
            "id": s.id.rawValue,
            "agent_id": s.agentID,
            "client_id": s.clientID?.rawValue as Any,
            "status": s.status.rawValue,
            "summary": s.summary as Any,
            "created_at": ISO8601.string(from: s.createdAt),
            "updated_at": ISO8601.string(from: s.updatedAt),
        ].compactNSNull()
    }
}

public extension Dictionary where Key == String, Value == Any {
    func compactNSNull() -> [String: Any] {
        var out: [String: Any] = [:]
        for (k, v) in self {
            if v is NSNull { continue }
            // Optional Any might still hold nil via as Any
            out[k] = v
        }
        return out
    }
}
