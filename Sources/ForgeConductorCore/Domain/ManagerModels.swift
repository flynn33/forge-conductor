// ManagerModels.swift
// What: Defines manager status, editable settings, patches, and telemetry health.
// How: Value types validate dictionary input and emit stable wire representations used
// by the manager client, routes, CLI, and SwiftUI settings module.
// Why: A shared contract prevents control-plane request/response drift.

import Foundation

/// Typed manager runtime status (no dictionary in domain path).
public struct ManagerStatus: Sendable, Equatable {
    public var ok: Bool
    public var isManager: Bool
    public var state: ManagerServiceState
    public var desiredRunning: Bool
    public var httpListening: Bool
    public var serviceActive: Bool
    public var pid: Int32
    public var startedAt: Date?
    public var uptimeSec: Int?
    public var restartCount: Int
    public var lastError: String?
    public var autoRestart: Bool
    public var watchdogIntervalSec: Int
    public var openBrowserOnStart: Bool
    public var dashboardHost: String
    public var dashboardPort: Int
    public var dashboardRefreshSec: Int
    public var home: String
    public var version: String

    public init(
        ok: Bool,
        isManager: Bool,
        state: ManagerServiceState,
        desiredRunning: Bool,
        httpListening: Bool,
        serviceActive: Bool,
        pid: Int32,
        startedAt: Date?,
        uptimeSec: Int?,
        restartCount: Int,
        lastError: String?,
        autoRestart: Bool,
        watchdogIntervalSec: Int,
        openBrowserOnStart: Bool,
        dashboardHost: String,
        dashboardPort: Int,
        dashboardRefreshSec: Int,
        home: String,
        version: String
    ) {
        self.ok = ok
        self.isManager = isManager
        self.state = state
        self.desiredRunning = desiredRunning
        self.httpListening = httpListening
        self.serviceActive = serviceActive
        self.pid = pid
        self.startedAt = startedAt
        self.uptimeSec = uptimeSec
        self.restartCount = restartCount
        self.lastError = lastError
        self.autoRestart = autoRestart
        self.watchdogIntervalSec = watchdogIntervalSec
        self.openBrowserOnStart = openBrowserOnStart
        self.dashboardHost = dashboardHost
        self.dashboardPort = dashboardPort
        self.dashboardRefreshSec = dashboardRefreshSec
        self.home = home
        self.version = version
    }

    /// Decodes the stable HTTP boundary without coupling the domain model to
    /// URLSession or Codable's key-shape conventions.
    public init(dictionary: [String: Any]) throws {
        guard let stateName = dictionary["state"] as? String,
              let state = ManagerServiceState(rawValue: stateName),
              let dashboard = dictionary["dashboard"] as? [String: Any],
              let port = ManagerJSONValue.int(dashboard["port"]) else {
            throw ManagerModelError.invalidStatus
        }
        self.init(
            ok: ManagerJSONValue.bool(dictionary["ok"]) ?? false,
            isManager: ManagerJSONValue.bool(dictionary["manager"]) ?? false,
            state: state,
            desiredRunning: ManagerJSONValue.bool(dictionary["desired_running"]) ?? false,
            httpListening: ManagerJSONValue.bool(dictionary["http_listening"]) ?? false,
            serviceActive: ManagerJSONValue.bool(dictionary["service_active"]) ?? false,
            pid: Int32(clamping: ManagerJSONValue.int(dictionary["pid"]) ?? 0),
            startedAt: (dictionary["started_at"] as? String).flatMap(ISO8601.date(from:)),
            uptimeSec: ManagerJSONValue.int(dictionary["uptime_sec"]),
            restartCount: ManagerJSONValue.int(dictionary["restart_count"]) ?? 0,
            lastError: dictionary["last_error"] as? String,
            autoRestart: ManagerJSONValue.bool(dictionary["auto_restart"]) ?? true,
            watchdogIntervalSec: ManagerJSONValue.int(dictionary["watchdog_interval_sec"]) ?? 3,
            openBrowserOnStart: ManagerJSONValue.bool(dictionary["open_browser_on_start"]) ?? false,
            dashboardHost: (dashboard["host"] as? String) ?? "127.0.0.1",
            dashboardPort: port,
            dashboardRefreshSec: ManagerJSONValue.int(dashboard["refresh_interval_sec"]) ?? 8,
            home: (dictionary["home"] as? String) ?? "",
            version: (dictionary["version"] as? String) ?? ""
        )
    }

    public var dashboardURL: String {
        "http://\(dashboardHost):\(dashboardPort)/"
    }

    /// Serialization boundary only (HTTP / legacy UI).
    public func asDictionary() -> [String: Any] {
        [
            "ok": ok,
            "manager": isManager,
            "state": state.rawValue,
            "desired_running": desiredRunning,
            "http_listening": httpListening,
            "service_active": serviceActive,
            "pid": Int(pid),
            "started_at": startedAt.map { ISO8601.string(from: $0) } as Any,
            "uptime_sec": uptimeSec as Any,
            "restart_count": restartCount,
            "last_error": lastError as Any,
            "auto_restart": autoRestart,
            "watchdog_interval_sec": watchdogIntervalSec,
            "open_browser_on_start": openBrowserOnStart,
            "dashboard": [
                "host": dashboardHost,
                "port": dashboardPort,
                "url": dashboardURL,
                "refresh_interval_sec": dashboardRefreshSec,
            ] as [String: Any],
            "home": home,
            "version": version,
        ]
    }
}

public struct ManagerSettings: Sendable, Equatable {
    public var dashboardHost: String
    public var dashboardPort: Int
    public var dashboardRefreshSec: Int
    public var autoRestart: Bool
    public var watchdogIntervalSec: Int
    public var openBrowserOnStart: Bool
    public var sessionIdleTTLSec: Int
    public var shellTimeoutSec: Int
    public var logLevel: String

    public init(
        dashboardHost: String,
        dashboardPort: Int,
        dashboardRefreshSec: Int,
        autoRestart: Bool,
        watchdogIntervalSec: Int,
        openBrowserOnStart: Bool,
        sessionIdleTTLSec: Int,
        shellTimeoutSec: Int,
        logLevel: String
    ) {
        self.dashboardHost = dashboardHost
        self.dashboardPort = dashboardPort
        self.dashboardRefreshSec = dashboardRefreshSec
        self.autoRestart = autoRestart
        self.watchdogIntervalSec = watchdogIntervalSec
        self.openBrowserOnStart = openBrowserOnStart
        self.sessionIdleTTLSec = sessionIdleTTLSec
        self.shellTimeoutSec = shellTimeoutSec
        self.logLevel = logLevel
    }

    public init(dictionary: [String: Any]) throws {
        guard let dashboard = dictionary["dashboard"] as? [String: Any],
              let manager = dictionary["manager"] as? [String: Any],
              let port = ManagerJSONValue.int(dashboard["port"]) else {
            throw ManagerModelError.invalidSettings
        }
        let sessions = dictionary["sessions"] as? [String: Any] ?? [:]
        let shell = dictionary["shell"] as? [String: Any] ?? [:]
        self.init(
            dashboardHost: (dashboard["host"] as? String) ?? "127.0.0.1",
            dashboardPort: port,
            dashboardRefreshSec: ManagerJSONValue.int(dashboard["refresh_interval_sec"]) ?? 8,
            autoRestart: ManagerJSONValue.bool(manager["auto_restart"]) ?? true,
            watchdogIntervalSec: ManagerJSONValue.int(manager["watchdog_interval_sec"]) ?? 3,
            openBrowserOnStart: ManagerJSONValue.bool(manager["open_browser_on_start"]) ?? false,
            sessionIdleTTLSec: ManagerJSONValue.int(sessions["idle_ttl_sec"]) ?? 14_400,
            shellTimeoutSec: ManagerJSONValue.int(shell["default_timeout_sec"]) ?? 30,
            logLevel: (dictionary["log_level"] as? String) ?? "info"
        )
    }

    public func asDictionary() -> [String: Any] {
        [
            "ok": true,
            "dashboard": [
                "host": dashboardHost,
                "port": dashboardPort,
                "refresh_interval_sec": dashboardRefreshSec,
            ] as [String: Any],
            "manager": [
                "auto_restart": autoRestart,
                "watchdog_interval_sec": watchdogIntervalSec,
                "open_browser_on_start": openBrowserOnStart,
            ] as [String: Any],
            "sessions": [
                "idle_ttl_sec": sessionIdleTTLSec,
            ] as [String: Any],
            "shell": [
                "default_timeout_sec": shellTimeoutSec,
            ] as [String: Any],
            "log_level": logLevel,
        ]
    }
}

public enum ManagerModelError: Error, LocalizedError, Sendable {
    case invalidStatus
    case invalidSettings

    public var errorDescription: String? {
        switch self {
        case .invalidStatus: "Manager returned an invalid status payload"
        case .invalidSettings: "Manager returned an invalid settings payload"
        }
    }
}

private enum ManagerJSONValue {
    static func int(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        if let value = value as? String { return Int(value) }
        return nil
    }

    static func bool(_ value: Any?) -> Bool? {
        if let value = value as? Bool { return value }
        if let value = value as? NSNumber { return value.boolValue }
        return nil
    }
}

/// Strongly typed settings patch (application → manager).
public struct ManagerSettingsPatch: Sendable, Equatable {
    public var dashboardHost: String?
    public var dashboardPort: Int?
    public var dashboardRefreshSec: Int?
    public var autoRestart: Bool?
    public var watchdogIntervalSec: Int?
    public var openBrowserOnStart: Bool?
    public var sessionIdleTTLSec: Int?
    public var shellTimeoutSec: Int?
    public var logLevel: String?

    public init(
        dashboardHost: String? = nil,
        dashboardPort: Int? = nil,
        dashboardRefreshSec: Int? = nil,
        autoRestart: Bool? = nil,
        watchdogIntervalSec: Int? = nil,
        openBrowserOnStart: Bool? = nil,
        sessionIdleTTLSec: Int? = nil,
        shellTimeoutSec: Int? = nil,
        logLevel: String? = nil
    ) {
        self.dashboardHost = dashboardHost
        self.dashboardPort = dashboardPort
        self.dashboardRefreshSec = dashboardRefreshSec
        self.autoRestart = autoRestart
        self.watchdogIntervalSec = watchdogIntervalSec
        self.openBrowserOnStart = openBrowserOnStart
        self.sessionIdleTTLSec = sessionIdleTTLSec
        self.shellTimeoutSec = shellTimeoutSec
        self.logLevel = logLevel
    }

    /// Edge adapter: config store still merges nested dict patches.
    public func asConfigPatch() -> [String: Any] {
        var dash: [String: Any] = [:]
        if let dashboardHost { dash["host"] = dashboardHost }
        if let dashboardPort { dash["port"] = dashboardPort }
        if let dashboardRefreshSec { dash["refresh_interval_sec"] = dashboardRefreshSec }
        var mgr: [String: Any] = [:]
        if let autoRestart { mgr["auto_restart"] = autoRestart }
        if let watchdogIntervalSec { mgr["watchdog_interval_sec"] = watchdogIntervalSec }
        if let openBrowserOnStart { mgr["open_browser_on_start"] = openBrowserOnStart }
        var sessions: [String: Any] = [:]
        if let sessionIdleTTLSec { sessions["idle_ttl_sec"] = sessionIdleTTLSec }
        var shell: [String: Any] = [:]
        if let shellTimeoutSec { shell["default_timeout_sec"] = shellTimeoutSec }
        var patch: [String: Any] = [:]
        if !dash.isEmpty { patch["dashboard"] = dash }
        if !mgr.isEmpty { patch["manager"] = mgr }
        if !sessions.isEmpty { patch["sessions"] = sessions }
        if !shell.isEmpty { patch["shell"] = shell }
        if let logLevel { patch["log_level"] = logLevel }
        return patch
    }
}

public struct TelemetryHealthReport: Sendable, Equatable {
    public var ok: Bool
    public var service: String
    public var runtime: String
    public var interferesWithMCP: Bool
    public var mode: String
    public var collectors: String
    public var ui: String
    public var nodeRequired: Bool

    public func asDictionary() -> [String: Any] {
        [
            "ok": ok,
            "service": service,
            "runtime": runtime,
            "interferes_with_mcp": interferesWithMCP,
            "mode": mode,
            "auth": false,
            "collectors": collectors,
            "ui": ui,
            "export_present": false,
            "static_present": false,
            "node_available": false,
            "node_required": nodeRequired,
        ]
    }
}
