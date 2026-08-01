// Models.swift
// What: Contains foundational identifiers and value objects shared across Core.
// How: Sendable/Codable structs model clients, sessions, agents, bindings, audit events,
// diagnostics, tool results, and injectable clock behavior.
// Why: Infrastructure and application modules communicate through stable domain values.

import Foundation

// MARK: - Identifiers

/// Strongly types the external client identity used by presence, sessions, and audits.
public struct ClientID: Hashable, Sendable, Codable {
    public let rawValue: String
    public init(_ rawValue: String = UUID().uuidString) { self.rawValue = rawValue }
}

// MARK: - Presence (typed; replaces presence row dictionaries)

public struct PresenceRecord: Sendable, Equatable, Codable {
    public var clientID: String
    public var hostKind: String
    public var pid: Int32
    public var cwd: String
    public var lastHeartbeat: String

    public init(clientID: String, hostKind: String, pid: Int32, cwd: String, lastHeartbeat: String) {
        self.clientID = clientID
        self.hostKind = hostKind
        self.pid = pid
        self.cwd = cwd
        self.lastHeartbeat = lastHeartbeat
    }

    public func asDictionary() -> [String: Any] {
        [
            "client_id": clientID,
            "host_kind": hostKind,
            "pid": Int(pid),
            "cwd": cwd,
            "last_heartbeat": lastHeartbeat,
        ]
    }
}

public struct SessionID: Hashable, Sendable, Codable {
    public let rawValue: String
    public init(_ rawValue: String = UUID().uuidString) { self.rawValue = rawValue }
}

// MARK: - Session

public enum SessionStatus: String, Sendable, Codable, CaseIterable {
    case open, active, running, started, closed, completed, failed

    public var isOpen: Bool {
        switch self {
        case .open, .active, .running, .started: true
        case .closed, .completed, .failed: false
        }
    }
}

public struct AgentSession: Sendable, Codable, Equatable {
    public var id: SessionID
    public var agentID: String
    public var clientID: ClientID?
    public var status: SessionStatus
    public var summary: String?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: SessionID = SessionID(),
        agentID: String,
        clientID: ClientID? = nil,
        status: SessionStatus = .open,
        summary: String? = nil,
        createdAt: Date = .init(),
        updatedAt: Date = .init()
    ) {
        self.id = id
        self.agentID = agentID
        self.clientID = clientID
        self.status = status
        self.summary = summary
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

// MARK: - Agent playbook

public struct AgentSpec: Sendable, Equatable {
    public var id: String
    public var displayName: String
    public var description: String
    public var tools: [String]
    public var toolsForbidden: [String]
    public var whenToUse: [String]
    public var firstMoves: [String]
    public var doneDefinition: [String]
    public var outputSchema: [String]
    public var handoff: [String]
    public var qualityBar: [String]
    public var body: String
    public var source: String

    public init(
        id: String,
        displayName: String,
        description: String,
        tools: [String] = [],
        toolsForbidden: [String] = [],
        whenToUse: [String] = [],
        firstMoves: [String] = [],
        doneDefinition: [String] = [],
        outputSchema: [String] = [],
        handoff: [String] = [],
        qualityBar: [String] = [],
        body: String = "",
        source: String = "builtin"
    ) {
        self.id = id
        self.displayName = displayName
        self.description = description
        self.tools = tools
        self.toolsForbidden = toolsForbidden
        self.whenToUse = whenToUse
        self.firstMoves = firstMoves
        self.doneDefinition = doneDefinition
        self.outputSchema = outputSchema
        self.handoff = handoff
        self.qualityBar = qualityBar
        self.body = body
        self.source = source
    }

    public func asDictionary(includeBody: Bool = true) -> [String: Any] {
        var d: [String: Any] = [
            "id": id,
            "display_name": displayName,
            "description": description,
            "tools": tools,
            "source": source,
            "playbook": [
                "when_to_use": whenToUse,
                "first_moves": firstMoves,
                "done_definition": doneDefinition,
                "output_schema": outputSchema,
                "tools_primary": tools,
                "tools_forbidden": toolsForbidden,
                "handoff": handoff,
                "quality_bar": qualityBar,
            ] as [String: Any],
        ]
        if includeBody { d["body"] = body }
        return d
    }
}

// MARK: - Active binding (durable)

public struct ActiveBinding: Sendable, Codable, Equatable {
    public var sessionID: SessionID
    public var agentID: String
    public var goal: String
    public var toolsPrimary: [String]
    public var toolsForbidden: [String]
    public var outputSchema: [String]
    public var doneDefinition: [String]
    public var cwd: String?

    public init(
        sessionID: SessionID,
        agentID: String,
        goal: String = "",
        toolsPrimary: [String] = [],
        toolsForbidden: [String] = [],
        outputSchema: [String] = [],
        doneDefinition: [String] = [],
        cwd: String? = nil
    ) {
        self.sessionID = sessionID
        self.agentID = agentID
        self.goal = goal
        self.toolsPrimary = toolsPrimary
        self.toolsForbidden = toolsForbidden
        self.outputSchema = outputSchema
        self.doneDefinition = doneDefinition
        self.cwd = cwd
    }
}

// MARK: - Audit / diagnostics

/// Typed interpretation of the audit statuses emitted by Core services.
///
/// Operational failures, authorization policy, and maintenance advisories are
/// intentionally distinct so telemetry does not turn every non-success result
/// into an execution failure.
public enum AuditOutcome: Sendable, Equatable {
    case success
    case operationalError
    case policyDenied
    case maintenanceWarning
    case other

    public init(status: String) {
        switch status {
        case "ok":
            self = .success
        case "error":
            self = .operationalError
        case "denied":
            self = .policyDenied
        case "warn":
            self = .maintenanceWarning
        default:
            self = .other
        }
    }
}

/// Counts audit outcomes without conflating policy and maintenance events with
/// operational execution errors.
public struct AuditOutcomeCounts: Sendable, Equatable {
    public var errorCount: Int
    public var deniedCount: Int
    public var warnCount: Int
    public var otherCount: Int

    public init(
        errorCount: Int = 0,
        deniedCount: Int = 0,
        warnCount: Int = 0,
        otherCount: Int = 0
    ) {
        self.errorCount = max(errorCount, 0)
        self.deniedCount = max(deniedCount, 0)
        self.warnCount = max(warnCount, 0)
        self.otherCount = max(otherCount, 0)
    }

    public static let empty = AuditOutcomeCounts()

    public mutating func record(status: String) {
        switch AuditOutcome(status: status) {
        case .success:
            break
        case .operationalError:
            errorCount += 1
        case .policyDenied:
            deniedCount += 1
        case .maintenanceWarning:
            warnCount += 1
        case .other:
            otherCount += 1
        }
    }

    public static func summarize<S: Sequence>(statuses: S) -> AuditOutcomeCounts
    where S.Element == String {
        var counts = AuditOutcomeCounts.empty
        for status in statuses {
            counts.record(status: status)
        }
        return counts
    }

    public func asDictionary() -> [String: Any] {
        [
            "error_count": errorCount,
            "denied_count": deniedCount,
            "warn_count": warnCount,
            "other_count": otherCount,
        ]
    }
}

public struct AuditEvent: Sendable, Equatable {
    public var timestamp: Date
    public var clientID: String?
    public var tool: String
    public var argsDigest: String?
    public var argsJSON: String?
    public var status: String
    public var durationMs: Int?
    public var error: String?

    public init(
        timestamp: Date = .init(),
        clientID: String? = nil,
        tool: String,
        argsDigest: String? = nil,
        argsJSON: String? = nil,
        status: String,
        durationMs: Int? = nil,
        error: String? = nil
    ) {
        self.timestamp = timestamp
        self.clientID = clientID
        self.tool = tool
        self.argsDigest = argsDigest
        self.argsJSON = argsJSON
        self.status = status
        self.durationMs = durationMs
        self.error = error
    }
}

public enum DiagnosticSeverity: String, Sendable, Codable {
    case info, warn, error, critical
}

public struct DiagnosticRecord: Sendable {
    public var ts: Date
    public var event: String
    public var severity: DiagnosticSeverity
    public var role: String
    public var category: DiagnosticCategory
    public var fields: [String: String]

    public init(
        ts: Date = .init(),
        event: String,
        severity: DiagnosticSeverity = .info,
        role: String = "primary",
        category: DiagnosticCategory = .general,
        fields: [String: String] = [:]
    ) {
        self.ts = ts
        self.event = event
        self.severity = severity
        self.role = role
        self.category = category
        self.fields = fields
    }
}

// MARK: - Tool result

public struct ToolResult: @unchecked Sendable {
    public var ok: Bool
    public var payload: [String: Any]
    public var isError: Bool

    public init(ok: Bool, payload: [String: Any], isError: Bool = false) {
        self.ok = ok
        self.payload = payload
        self.isError = isError
    }

    public static func success(_ payload: [String: Any] = ["ok": true]) -> ToolResult {
        .init(ok: true, payload: payload.merging(["ok": true]) { _, n in n })
    }

    public static func failure(code: String, message: String, retryable: Bool = false) -> ToolResult {
        .init(
            ok: false,
            payload: [
                "ok": false,
                "code": code,
                "message": message,
                "retryable": retryable,
            ],
            isError: true
        )
    }
}

// MARK: - Clock

public protocol Clock: Sendable {
    func now() -> Date
}

public struct SystemClock: Clock {
    public init() {}
    public func now() -> Date { Date() }
}

public final class FixedClock: Clock, @unchecked Sendable {
    public var date: Date
    public init(_ date: Date) { self.date = date }
    public func now() -> Date { date }
}
