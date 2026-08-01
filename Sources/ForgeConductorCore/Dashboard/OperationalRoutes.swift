// OperationalRoutes.swift
// What: Serves non-manager operational endpoints such as health and status.
// How: It reads composed ForgeApp services and returns bounded snapshots without
// exposing privileged tool execution through the browser surface.
// Why: Read-oriented observability must remain separated from control-plane authority.

import Foundation
import Network

/// Read-mostly operational APIs for the local dashboard. Privileged tool calls
/// are intentionally available only through the LM Studio MCP stdio adapter.
public final class OperationalRoutes: @unchecked Sendable {
    private let app: ForgeApp
    private let http: HTTPResponder

    public init(app: ForgeApp, http: HTTPResponder) {
        self.app = app
        self.http = http
    }

    public func handle(method: String, path: String, body: Data, connection: NWConnection) throws {
        switch (method, path) {
        case ("GET", "/api/doctor"):
            http.respondJSON(connection, status: 200, object: try app.doctor())
        case ("GET", "/api/agents"):
            let agents = app.catalog.all().map { $0.asDictionary(includeBody: false) }
            http.respondJSON(connection, status: 200, object: ["ok": true, "agents": agents])
        case ("GET", "/api/sessions"):
            let open = try app.store.sessionList(status: .open)
            let all = try app.store.sessionList()
            http.respondJSON(connection, status: 200, object: [
                "ok": true,
                "open": open.map(Self.sessionJSON),
                "recent": Array(all.prefix(40)).map(Self.sessionJSON),
            ])
        case ("GET", "/api/audit"):
            let rows = try app.audit.recent(limit: 80)
            http.respondJSON(connection, status: 200, object: [
                "ok": true,
                "events": rows.map { e in
                    [
                        "timestamp": ISO8601.string(from: e.timestamp),
                        "tool": e.tool,
                        "status": e.status,
                        "client_id": e.clientID as Any,
                        "duration_ms": e.durationMs as Any,
                        "error": e.error as Any,
                    ].compactNSNull()
                },
            ])
        case ("GET", "/api/diagnostics"):
            let text = (try? String(contentsOf: app.paths.agentDiagnostics, encoding: .utf8)) ?? ""
            let lines = text.split(separator: "\n").suffix(100).map(String.init)
            http.respondJSON(connection, status: 200, object: ["ok": true, "lines": Array(lines)])
        case ("POST", "/api/sessions/prune"):
            try app.sessions.pruneStale()
            http.respondJSON(connection, status: 200, object: ["ok": true, "message": "Pruned stale sessions"])
        case ("POST", "/api/sessions/close"):
            let obj = (try? JSONSupport.object(from: body)) ?? [:]
            guard let sid = obj["session_id"] as? String else {
                http.respondJSON(connection, status: 400, object: ["ok": false, "message": "session_id required"])
                return
            }
            let summary = obj["summary"] as? String ?? "Closed from dashboard"
            let closed = try app.store.sessionEnd(id: SessionID(sid), summary: summary)
            http.respondJSON(connection, status: 200, object: ["ok": true, "session": Self.sessionJSON(closed)])
        default:
            http.respond(connection, status: 404, body: "Not Found", contentType: "text/plain")
        }
    }

    public static func sessionJSON(_ s: AgentSession) -> [String: Any] {
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
