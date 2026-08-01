// DashboardServer.swift
// What: Owns the native Network.framework loopback HTTP listener.
// How: It accepts bounded connections, delegates parsing/policy and route selection,
// and uses HTTPResponder for transport output while ManagerNode owns server lifetime.
// Why: One listener module prevents routes from mixing business logic with socket state.

import Foundation
import Network

/// Synchronizes the listener's asynchronous bind result with the thread waiting in
/// `DashboardServer.start()`. Network.framework invokes state callbacks concurrently,
/// so a locked reference avoids capturing and mutating a local variable across tasks.
private final class DashboardBindResult: @unchecked Sendable {
    private let lock = NSLock()
    private var error: Error?

    func record(error: Error) {
        lock.lock()
        self.error = error
        lock.unlock()
    }

    func recordedError() -> Error? {
        lock.lock()
        defer { lock.unlock() }
        return error
    }
}

/// Loopback HTTP control surface: status, agents, sessions, audit, diagnostics, manager controls.
/// Routing is delegated to modular route handlers (Telemetry / Manager / Operational).
public final class DashboardServer: @unchecked Sendable {
    private let app: ForgeApp
    private let host: String
    private let port: UInt16
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "forge.dashboard", qos: .userInitiated)
    private let lock = NSLock()
    private let http = HTTPResponder()
    public private(set) var isRunning = false

    /// Optional supervisor; when set, manager control APIs are available.
    public weak var manager: ManagerNode?

    public var boundHost: String { host }
    public var boundPort: UInt16 { port }

    public init(app: ForgeApp, host: String? = nil, port: UInt16? = nil) {
        self.app = app
        self.host = host ?? app.config.string("dashboard", "host", default: "127.0.0.1")
        let cfgPort = app.config.int("dashboard", "port", default: 7788)
        self.port = port ?? UInt16(clamping: cfgPort)
    }

    public var baseURL: URL {
        URL(string: "http://\(host):\(port)/")!
    }

    public func start() throws {
        lock.lock()
        guard !isRunning else {
            lock.unlock()
            return
        }
        lock.unlock()

        guard DashboardRequestPolicy.isConfiguredLoopbackHost(host) else {
            throw DashboardError.nonLoopbackHost(host)
        }

        // Fail closed if another process already owns the port (dual Forge / foreign app).
        let state = DashboardPortGuard.inspect(host: host, port: Int(port))
        switch state {
        case .free, .heldBySelf:
            break
        case .heldByOtherForge(let h):
            let msg = "Dashboard port \(port) held by another Forge process pid=\(h.pid.map(String.init) ?? "?") cmd=\(h.command ?? "?"). Stop the other instance or run only one product (LaunchAgent manager OR GUI), not both claiming HTTP."
            app.diagnostics.error("dashboard_port_conflict_forge", [
                "port": "\(port)",
                "holder_pid": h.pid.map(String.init) ?? "",
                "holder": h.command ?? "",
            ], category: .manager)
            throw DashboardError.portInUse(msg)
        case .heldByForeign(let h):
            let msg = "Dashboard port \(port) held by non-Forge process pid=\(h.pid.map(String.init) ?? "?") cmd=\(h.command ?? "?")."
            app.diagnostics.error("dashboard_port_conflict_foreign", [
                "port": "\(port)",
                "holder_pid": h.pid.map(String.init) ?? "",
                "holder": h.command ?? "",
            ], category: .manager)
            throw DashboardError.portInUse(msg)
        case .unknown(let d):
            app.diagnostics.warn("dashboard_port_unknown", ["detail": d], category: .manager)
        }

        let params = NWParameters.tcp
        // Do NOT reuse address for product dashboard — second instance must fail clearly.
        params.allowLocalEndpointReuse = false
        if host == "127.0.0.1" || host == "localhost" {
            params.requiredInterfaceType = .loopback
        }

        let listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
        let gate = DispatchSemaphore(value: 0)
        let bindResult = DashboardBindResult()
        listener.newConnectionHandler = { [weak self] conn in
            self?.handle(connection: conn)
        }
        listener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.app.diagnostics.info("dashboard_ready", [
                    "url": self?.baseURL.absoluteString ?? "",
                    "pid": "\(ProcessInfo.processInfo.processIdentifier)",
                ], category: .manager)
                gate.signal()
            case .failed(let err):
                self?.app.diagnostics.error("dashboard_failed", [
                    "error": "\(err)",
                    "port": "\(self?.port ?? 0)",
                ], category: .manager)
                bindResult.record(error: err)
                gate.signal()
            case .cancelled:
                break
            default:
                break
            }
        }
        listener.start(queue: queue)
        let wait = gate.wait(timeout: .now() + 3)
        if wait == .timedOut {
            listener.cancel()
            app.diagnostics.error("dashboard_bind_timeout", ["port": "\(port)"], category: .manager)
            throw DashboardError.bindTimeout(port)
        }
        if let bindError = bindResult.recordedError() {
            listener.cancel()
            throw bindError
        }

        lock.lock()
        self.listener = listener
        isRunning = true
        lock.unlock()
    }

    public func stop() {
        lock.lock()
        defer { lock.unlock() }
        listener?.cancel()
        listener = nil
        isRunning = false
    }

    /// Run until interrupted (SIGINT/SIGTERM).
    public func runForever() throws {
        try start()
        fputs("Forge-Conductor dashboard: \(baseURL.absoluteString)\n", stderr)
        let sem = DispatchSemaphore(value: 0)
        let sigInt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
        let sigTerm = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global())
        signal(SIGINT, SIG_IGN)
        signal(SIGTERM, SIG_IGN)
        sigInt.setEventHandler { sem.signal() }
        sigTerm.setEventHandler { sem.signal() }
        sigInt.resume()
        sigTerm.resume()
        sem.wait()
        stop()
    }

    // MARK: - Connection

    private func handle(connection: NWConnection) {
        connection.start(queue: queue)
        receive(on: connection, buffer: Data())
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else {
                connection.cancel()
                return
            }
            if let error {
                self.app.diagnostics.warn("dashboard_recv_error", ["error": "\(error)"])
                connection.cancel()
                return
            }
            var buf = buffer
            if let data { buf.append(data) }
            switch DashboardHTTPRequestParser.parse(buf, streamComplete: isComplete) {
            case .incomplete:
                self.receive(on: connection, buffer: buf)
            case .rejected(let status, let message):
                self.http.respond(connection, status: status, body: message, contentType: "text/plain")
            case .request(let request):
                if let rejection = DashboardRequestPolicy.rejection(for: request, serverPort: self.port) {
                    self.http.respond(
                        connection,
                        status: rejection.status,
                        body: rejection.message,
                        contentType: "text/plain"
                    )
                    return
                }
                self.route(request: request, connection: connection)
            }
        }
    }

    private func route(request: DashboardHTTPRequest, connection: NWConnection) {
        let rawPath = request.target
        let pathOnly = rawPath.split(separator: "?", maxSplits: 1).first.map(String.init) ?? rawPath
        let path = pathOnly.hasPrefix("/") ? pathOnly : "/" + pathOnly
        let m = request.method
        let body = request.body

        do {
            if path.hasPrefix("/api/manager") {
                guard let manager else {
                    http.respondJSON(connection, status: 503, object: [
                        "ok": false,
                        "code": "no_manager",
                        "message": "Not running under manager. Start with: forge-conductor manager run",
                    ])
                    return
                }
                try ManagerRoutes(manager: manager, http: http)
                    .handle(method: m, path: path, body: body, connection: connection)
                return
            }

            if pathOnly.hasPrefix("/api/snapshot") || pathOnly.hasPrefix("/api/live")
                || pathOnly.hasPrefix("/api/frame") || pathOnly.hasPrefix("/api/system")
                || pathOnly.hasPrefix("/api/forge") || pathOnly.hasPrefix("/api/stream")
                || pathOnly.hasPrefix("/api/health") || pathOnly.hasPrefix("/static/")
                || pathOnly == "/ping" {
                // Pass raw path (with query) so /api/stream?hz=20 can parse target rate.
                try TelemetryRoutes(app: app, http: http)
                    .handle(method: m, path: rawPath.hasPrefix("/") ? rawPath : "/" + rawPath, connection: connection)
                return
            }

            switch (m, path) {
            case ("GET", "/"), ("GET", "/index.html"):
                if let (data, type) = app.telemetry.loadStatic("index.html") {
                    http.respondData(connection, status: 200, data: data, contentType: type)
                } else {
                    http.respond(connection, status: 200, body: DashboardHTML.index, contentType: "text/html; charset=utf-8")
                }
            case ("GET", "/control"), ("GET", "/manager"):
                http.respond(connection, status: 200, body: DashboardHTML.index, contentType: "text/html; charset=utf-8")
            case ("GET", "/api/status"):
                var snap = try app.statusSnapshot()
                if let manager {
                    snap["manager"] = manager.status()
                    snap["service_active"] = manager.isServiceActive()
                } else {
                    snap["service_active"] = true
                    snap["manager"] = ["manager": false, "state": "standalone"] as [String: Any]
                }
                http.respondJSON(connection, status: 200, object: snap)
            case ("OPTIONS", _):
                http.respond(connection, status: 405, body: "Method Not Allowed", contentType: "text/plain")
            default:
                if let manager, !manager.isServiceActive(), path.hasPrefix("/api/") {
                    http.respondJSON(connection, status: 503, object: [
                        "ok": false,
                        "code": "service_stopped",
                        "message": "Operational APIs paused. Telemetry remains at / and /api/snapshot.",
                        "manager": manager.status(),
                    ])
                    return
                }
                try OperationalRoutes(app: app, http: http)
                    .handle(method: m, path: path, body: body, connection: connection)
            }
        } catch {
            http.respondJSON(connection, status: 500, object: ["ok": false, "message": "\(error)"])
        }
    }
}

public enum DashboardError: Error, LocalizedError {
    case portInUse(String)
    case bindTimeout(UInt16)
    case nonLoopbackHost(String)

    public var errorDescription: String? {
        switch self {
        case .portInUse(let msg): msg
        case .bindTimeout(let p): "Timed out binding dashboard on port \(p)"
        case .nonLoopbackHost(let host):
            "Dashboard host must be loopback-only (localhost, 127.0.0.1, or ::1); got \(host)"
        }
    }
}
