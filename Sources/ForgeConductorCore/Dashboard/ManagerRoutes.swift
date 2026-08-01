// ManagerRoutes.swift
// What: Handles typed manager status, settings, and lifecycle HTTP endpoints.
// How: It maps validated dashboard requests to ManagerControlling operations and
// returns only structured dictionaries for the transport layer to encode.
// Why: Manager behavior stays reusable without depending on HTTP connection objects.

import Foundation
import Network

/// Manager control plane routes: start/stop/restart/settings/shutdown.
public final class ManagerRoutes: @unchecked Sendable {
    private let manager: ManagerNode
    private let http: HTTPResponder

    public init(manager: ManagerNode, http: HTTPResponder) {
        self.manager = manager
        self.http = http
    }

    public func handle(method: String, path: String, body: Data, connection: NWConnection) throws {
        switch (method, path) {
        case ("GET", "/api/manager/status"):
            http.respondJSON(connection, status: 200, object: manager.status())
        case ("GET", "/api/manager/settings"):
            http.respondJSON(connection, status: 200, object: manager.settings())
        case ("POST", "/api/manager/start"):
            let st = try manager.startService()
            http.respondJSON(connection, status: 200, object: st.asDictionary())
        case ("POST", "/api/manager/stop"):
            let st = try manager.stopService()
            http.respondJSON(connection, status: 200, object: st.asDictionary())
        case ("POST", "/api/manager/restart"):
            let st = try manager.restartService()
            http.respondJSON(connection, status: 200, object: st.asDictionary())
        case ("POST", "/api/manager/shutdown"):
            http.respondJSON(connection, status: 200, object: [
                "ok": true,
                "message": "Manager shutting down",
                "state": "stopping",
            ])
            manager.requestShutdown(delayMs: 350)
        case ("POST", "/api/manager/settings"), ("PUT", "/api/manager/settings"):
            let obj = (try? JSONSupport.object(from: body)) ?? [:]
            let apply = (obj["apply"] as? Bool) ?? true
            let patch = obj["settings"] as? [String: Any] ?? obj
            let result = try manager.updateSettings(patch, apply: apply)
            http.respondJSON(connection, status: 200, object: result)
        default:
            http.respond(connection, status: 404, body: "Not Found", contentType: "text/plain")
        }
    }
}
