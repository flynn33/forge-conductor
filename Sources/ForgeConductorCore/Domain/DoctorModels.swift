// DoctorModels.swift
// What: Carries structured health checks, doctor reports, and app status snapshots.
// How: Small value types normalize service results into dictionaries for CLI, MCP,
// dashboard, and tests without importing infrastructure implementations.
// Why: Typed diagnostic contracts keep every presentation surface consistent.

import Foundation

/// One doctor health check result.
public struct DoctorCheck: Sendable, Equatable {
    public var name: String
    public var ok: Bool
    public var detail: String
    public var hard: Bool

    public init(name: String, ok: Bool, detail: String, hard: Bool = true) {
        self.name = name
        self.ok = ok
        self.detail = detail
        self.hard = hard
    }

    public func asDictionary() -> [String: Any] {
        ["name": name, "ok": ok, "detail": detail]
    }
}

/// Typed doctor report (application domain). Dictionary only at HTTP/CLI edge.
public struct DoctorReport: Sendable, Equatable {
    public var ok: Bool
    public var version: String
    public var home: String
    public var checks: [DoctorCheck]
    public var telemetry: TelemetryHealthReport
    public var binaryInstalled: Bool
    public var binaryPath: String

    public init(
        ok: Bool,
        version: String,
        home: String,
        checks: [DoctorCheck],
        telemetry: TelemetryHealthReport,
        binaryInstalled: Bool,
        binaryPath: String
    ) {
        self.ok = ok
        self.version = version
        self.home = home
        self.checks = checks
        self.telemetry = telemetry
        self.binaryInstalled = binaryInstalled
        self.binaryPath = binaryPath
    }

    public func asDictionary() -> [String: Any] {
        [
            "ok": ok,
            "version": version,
            "home": home,
            "checks": checks.map { $0.asDictionary() },
            "telemetry": telemetry.asDictionary(),
            "binary": [
                "installed": binaryInstalled,
                "path": binaryPath,
            ] as [String: Any],
        ]
    }
}

/// Typed runtime status snapshot for dashboard / forge_status.
public struct AppStatusSnapshot: Sendable, Equatable {
    public var ok: Bool
    public var version: String
    public var product: String
    public var runtime: String
    public var home: String
    public var store: String
    public var agents: [String]
    public var agentCount: Int
    public var openSessions: [AgentSessionSummary]
    public var openSessionCount: Int
    public var presence: [PresenceRecord]
    public var presenceCount: Int
    public var recentAudit: [AuditEventSummary]
    public var tools: [String]
    public var telemetry: TelemetryHealthReport
    public var dashboardHost: String
    public var dashboardPort: Int
    public var pid: Int32

    public func asDictionary() -> [String: Any] {
        [
            "ok": ok,
            "version": version,
            "product": product,
            "runtime": runtime,
            "home": home,
            "store": store,
            "agents": agents,
            "agent_count": agentCount,
            "open_sessions": openSessions.map { $0.asDictionary() },
            "open_session_count": openSessionCount,
            "presence": presence.map { $0.asDictionary() },
            "presence_count": presenceCount,
            "recent_audit": recentAudit.map { $0.asDictionary() },
            "tools": tools,
            "telemetry": telemetry.asDictionary(),
            "dashboard": [
                "host": dashboardHost,
                "port": dashboardPort,
            ] as [String: Any],
            "pid": Int(pid),
        ]
    }
}
