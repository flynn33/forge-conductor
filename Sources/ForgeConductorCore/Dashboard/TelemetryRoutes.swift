// TelemetryRoutes.swift
// What: Adapts telemetry snapshots and live streams to dashboard routes.
// How: It selects typed snapshot/history payloads or starts an SSE session through
// HTTPResponder while leaving sampling ownership with TelemetryService.
// Why: Transport consumers should not create competing telemetry engines.

import Foundation
import Network

/// Telemetry HTTP routes: health, current frame, system, forge, **continuous SSE stream**, static.
public final class TelemetryRoutes: @unchecked Sendable {
    private let app: ForgeApp
    private let http: HTTPResponder

    public init(app: ForgeApp, http: HTTPResponder) {
        self.app = app
        self.http = http
    }

    public func handle(method: String, path: String, connection: NWConnection) throws {
        guard method == "GET" else {
            http.respond(connection, status: 405, body: "Method Not Allowed", contentType: "text/plain")
            return
        }

        if path.hasPrefix("/static/") {
            let rel = String(path.dropFirst("/static/".count))
            if let (data, type) = app.telemetry.loadStatic(rel) {
                http.respondData(connection, status: 200, data: data, contentType: type)
            } else {
                http.respond(connection, status: 404, body: "Not Found", contentType: "text/plain")
            }
            return
        }

        // Strip query for path switch; parse query for stream Hz.
        let pathOnly = path.split(separator: "?", maxSplits: 1).first.map(String.init) ?? path
        let query = path.split(separator: "?", maxSplits: 1).dropFirst().first.map(String.init) ?? ""

        switch pathOnly {
        case "/api/health":
            http.respondJSON(connection, status: 200, object: app.telemetry.healthDictionary())
        case "/api/live", "/api/frame":
            // Preferred name for “current live frame” (not a multi-second product poll).
            var obj = app.telemetry.currentFrame().asDictionary()
            obj["stream"] = "realtime"
            obj["sample_hz"] = app.telemetry.realtimeEngine.measuredSampleHz
            http.respondJSON(connection, status: 200, object: obj)
        case "/api/snapshot":
            // Compatibility alias for current live frame.
            var obj = app.telemetry.currentFrame().asDictionary()
            obj["stream"] = "realtime"
            obj["sample_hz"] = app.telemetry.realtimeEngine.measuredSampleHz
            http.respondJSON(connection, status: 200, object: obj)
        case "/api/system":
            http.respondJSON(connection, status: 200, object: try app.telemetry.systemOnly(force: false))
        case "/api/forge":
            http.respondJSON(connection, status: 200, object: try app.telemetry.forgeOnly(force: false))
        case "/ping":
            let html = """
            <!DOCTYPE html><html><head><meta charset="utf-8"><title>Forge Telemetry OK</title></head>
            <body style="background:#02040a;color:#e8fbff;font-family:system-ui;padding:2rem">
            <h1 style="color:#18f0ff">Forge Telemetry is reachable</h1>
            <p>Integrated Swift host · continuous native collectors (~30&nbsp;Hz)</p>
            <p><a style="color:#18f0ff" href="/">Open dashboard</a> ·
            <a style="color:#18f0ff" href="/api/health">/api/health</a> ·
            <a style="color:#18f0ff" href="/api/stream">/api/stream (SSE realtime)</a> ·
            <a style="color:#18f0ff" href="/api/live">/api/live</a> ·
            <a style="color:#18f0ff" href="/control">Manager controls</a></p>
            </body></html>
            """
            http.respond(connection, status: 200, body: html, contentType: "text/html; charset=utf-8")
        default:
            if pathOnly.hasPrefix("/api/stream") {
                let hz = Self.parseStreamHz(query: query)
                // Continuous keep-alive SSE — product path for browser + tools.
                _ = http.startRealtimeSSE(
                    connection: connection,
                    telemetry: app.telemetry,
                    targetHz: hz,
                    maxDurationSec: 3600
                )
                return
            }
            http.respond(connection, status: 404, body: "Not Found", contentType: "text/plain")
        }
    }

    /// Parse `hz=` or legacy `interval=` (seconds). Legacy interval=2 is treated as outdated and
    /// upgraded to realtime default (20 Hz) so old clients still get live data.
    static func parseStreamHz(query: String) -> Double {
        var hz: Double?
        var interval: Double?
        for part in query.split(separator: "&") {
            let kv = part.split(separator: "=", maxSplits: 1).map(String.init)
            guard kv.count == 2 else { continue }
            if kv[0] == "hz", let v = Double(kv[1]) { hz = v }
            if kv[0] == "interval", let v = Double(kv[1]) { interval = v }
        }
        if let hz { return min(max(hz, 1), 60) }
        if let interval {
            // Old UI used interval=2 (0.5 Hz). Cap period at 100ms so product is still realtime.
            let period = min(max(interval, 0.016), 0.1)
            return 1.0 / period
        }
        return 20
    }
}
