// AgentToolPack.swift
// What: Exposes catalog lookup and durable agent-session operations as tools.
// How: The pack validates arguments with shared helpers and delegates all domain
// behavior to AgentCatalogProviding and SessionManaging dependencies.
// Why: Tool protocol adaptation stays separate from agent lifecycle implementation.

import Foundation

/// Agent lifecycle and catalog tools.
public struct AgentToolPack: ToolPackHandling {
    public init() {}

    public var toolNames: [String] {
        [
            "forge_status",
            "agent_list", "agent_get", "agent_context", "agent_recommend",
            "agent_run_start", "agent_run_status", "agent_run_complete",
        ]
    }

    public func handle(name: String, arguments: [String: Any], clientID: ClientID, app: ForgeApp) throws -> ToolResult? {
        switch name {
        case "forge_status":
            return try forgeStatus(clientID: clientID, app: app)
        case "agent_list":
            return .success(["ok": true, "agents": app.catalog.all().map { $0.asDictionary(includeBody: false) }])
        case "agent_get", "agent_context":
            let id = ToolArgHelpers.string(arguments, "agent_id")
                ?? ToolArgHelpers.string(arguments, "id")
                ?? ToolArgHelpers.string(arguments, "name")
            guard let id, let spec = app.catalog.get(id) else {
                return .failure(code: "agent_not_found", message: "Unknown agent", retryable: true)
            }
            return .success(spec.asDictionary(includeBody: true).merging(["ok": true]) { _, n in n })
        case "agent_recommend":
            let task = ToolArgHelpers.string(arguments, "task") ?? ""
            let spec = app.catalog.recommend(task: task)
            return .success([
                "ok": true,
                "agent_id": spec.id,
                "call": "agent_run_start(agent_id: '\(spec.id)', goal: ...)",
                "card": spec.asDictionary(includeBody: false),
            ])
        case "agent_run_start":
            let goal = ToolArgHelpers.string(arguments, "goal") ?? ""
            let id = ToolArgHelpers.string(arguments, "agent_id")
                ?? ToolArgHelpers.string(arguments, "id")
                ?? ToolArgHelpers.string(arguments, "name")
                ?? "explore"
            let cwd = ToolArgHelpers.string(arguments, "cwd")
            let payload = try app.sessions.start(agentID: id, goal: goal, clientID: clientID, cwd: cwd)
            return ToolResult(ok: payload["ok"] as? Bool ?? true, payload: payload)
        case "agent_run_status":
            guard let sid = ToolArgHelpers.string(arguments, "session_id") else {
                return .failure(code: "missing_session_id", message: "session_id required", retryable: true)
            }
            let payload = try app.sessions.status(sessionID: SessionID(sid), clientID: clientID)
            return ToolResult(ok: true, payload: payload)
        case "agent_run_complete":
            guard let sid = ToolArgHelpers.string(arguments, "session_id") else {
                return .failure(code: "missing_session_id", message: "session_id required", retryable: true)
            }
            let report = arguments["report"] as? [String: Any]
            let payload = try app.sessions.complete(sessionID: SessionID(sid), report: report, clientID: clientID)
            return ToolResult(ok: payload["ok"] as? Bool ?? true, payload: payload)
        default:
            return nil
        }
    }

    private func forgeStatus(clientID: ClientID, app: ForgeApp) throws -> ToolResult {
        let presence = try app.store.presenceRecords()
        let openSessions = try app.store.sessionList().filter(\.status.isOpen)
        let continuity = (try? app.continuity.statusSummary()) ?? [:]
        return .success([
            "ok": true,
            "version": ForgeApp.version,
            "runtime": "swift",
            "home": app.paths.home.path,
            "client_id": clientID.rawValue,
            "agents": app.catalog.all().map(\.id),
            "tools": app.tools.toolNames,
            "presence_count": presence.count,
            "open_sessions": openSessions.count,
            "open_session_ids": openSessions.map(\.id.rawValue),
            "continuity": continuity,
            "pid": ProcessInfo.processInfo.processIdentifier,
        ])
    }
}
