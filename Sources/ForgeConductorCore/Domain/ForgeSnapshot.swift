// ForgeSnapshot.swift
// What: Represents a composed point-in-time view of Forge orchestration health.
// How: It aggregates tool, session, connector, process, usage, file, and audit values
// into immutable domain summaries with explicit dictionary projections.
// Why: Consumers receive one stable contract instead of coordinating many live services.

import Foundation

/// Fully typed forge-side telemetry frame (no [String: Any] in domain).
/// Name retained for API stability; this is a live-composed frame, not a multi-second poll product.
public struct ForgeSnapshot: Sendable, Equatable {
    public var ts: TimeInterval
    public var home: String
    public var runtime: String
    public var presenceCount: Int
    public var mcpServers: [MCPServerCard]
    public var mcpTools: [ToolCard]
    public var mcpPacks: [ToolPackSummary]
    public var agents: [AgentCard]
    public var agentSessions: [AgentSessionSummary]
    public var agentsSummary: AgentsSummary
    public var liveFeed: [LiveFeedEvent]
    public var feedStats: FeedStats
    public var orchestration: OrchestrationStatus
    public var mcpLoad: MCPLoadWindows
    public var files: ForgeFilesPresence
    public var auditRecent: [AuditEventSummary]

    public init(
        ts: TimeInterval,
        home: String,
        runtime: String,
        presenceCount: Int,
        mcpServers: [MCPServerCard],
        mcpTools: [ToolCard],
        mcpPacks: [ToolPackSummary],
        agents: [AgentCard],
        agentSessions: [AgentSessionSummary],
        agentsSummary: AgentsSummary,
        liveFeed: [LiveFeedEvent],
        feedStats: FeedStats,
        orchestration: OrchestrationStatus,
        mcpLoad: MCPLoadWindows,
        files: ForgeFilesPresence,
        auditRecent: [AuditEventSummary]
    ) {
        self.ts = ts
        self.home = home
        self.runtime = runtime
        self.presenceCount = presenceCount
        self.mcpServers = mcpServers
        self.mcpTools = mcpTools
        self.mcpPacks = mcpPacks
        self.agents = agents
        self.agentSessions = agentSessions
        self.agentsSummary = agentsSummary
        self.liveFeed = liveFeed
        self.feedStats = feedStats
        self.orchestration = orchestration
        self.mcpLoad = mcpLoad
        self.files = files
        self.auditRecent = auditRecent
    }

    /// Placeholder until the first forge composition runs (host stream still live).
    public static func empty(home: String) -> ForgeSnapshot {
        let emptyWindow = UsageWindow.empty
        return ForgeSnapshot(
            ts: Date().timeIntervalSince1970,
            home: home,
            runtime: "swift-native-realtime",
            presenceCount: 0,
            mcpServers: [],
            mcpTools: [],
            mcpPacks: [],
            agents: [],
            agentSessions: [],
            agentsSummary: AgentsSummary(total: 0, open: 0, byStatus: [:]),
            liveFeed: [],
            feedStats: FeedStats(total: 0, warn: 0, error: 0, agentEvents: 0),
            orchestration: OrchestrationStatus.empty(home: home),
            mcpLoad: MCPLoadWindows(oneHour: emptyWindow, fifteenMin: emptyWindow, fiveMin: emptyWindow),
            files: ForgeFilesPresence(storeSQLite: false, auditJSONL: false, managerState: false),
            auditRecent: []
        )
    }

    public func asDictionary() -> [String: Any] {
        return [
            "ts": ts,
            "home": home,
            "runtime": runtime,
            "presence_count": presenceCount,
            "presence": [] as [[String: Any]], // raw rows not needed by native UI
            "mcp_servers": mcpServers.map { $0.asDictionary() },
            "mcp_tools": mcpTools.map { $0.asDictionary() },
            "mcp_packs": mcpPacks.map { $0.asDictionary() },
            "agents": agents.map { $0.asDictionary() },
            "agent_sessions": agentSessions.map { $0.asDictionary() },
            "agents_summary": agentsSummary.asDictionary(),
            "jobs": [] as [[String: Any]],
            "live_feed": liveFeed.map { $0.asDictionary() },
            "feed_stats": feedStats.asDictionary(),
            "orchestration": orchestration.asDictionary(),
            "mcp_load": mcpLoad.asDictionary(),
            "files": files.asDictionary(),
            "audit_recent": auditRecent.map { $0.asDictionary() },
        ]
    }
}

public struct ToolPackSummary: Sendable, Equatable {
    public var pack: String
    public var toolCount: Int
    public var activeCount: Int

    public func asDictionary() -> [String: Any] {
        ["pack": pack, "tools": toolCount, "active": activeCount]
    }
}

public struct AgentSessionSummary: Sendable, Equatable {
    public var id: String
    public var agentID: String
    public var clientID: String?
    public var status: String
    public var summary: String?
    public var createdAt: String
    public var updatedAt: String

    public init(from session: AgentSession) {
        id = session.id.rawValue
        agentID = session.agentID
        clientID = session.clientID?.rawValue
        status = session.status.rawValue
        summary = session.summary
        createdAt = ISO8601.string(from: session.createdAt)
        updatedAt = ISO8601.string(from: session.updatedAt)
    }

    public func asDictionary() -> [String: Any] {
        [
            "id": id,
            "agent_id": agentID,
            "client_id": clientID as Any,
            "status": status,
            "summary": summary as Any,
            "created_at": createdAt,
            "updated_at": updatedAt,
        ]
    }
}

public struct AgentsSummary: Sendable, Equatable {
    public var total: Int
    public var open: Int
    public var byStatus: [String: Int]

    public init(total: Int, open: Int, byStatus: [String: Int]) {
        self.total = total
        self.open = open
        self.byStatus = byStatus
    }

    public func asDictionary() -> [String: Any] {
        ["total": total, "open": open, "by_status": byStatus]
    }
}

public struct LiveFeedEvent: Sendable, Equatable {
    public var timestamp: String
    public var tool: String
    public var status: String
    public var clientID: String?
    public var durationMs: Int?
    public var error: String?

    public func asDictionary() -> [String: Any] {
        [
            "timestamp": timestamp,
            "tool": tool,
            "status": status,
            "client_id": clientID as Any,
            "duration_ms": durationMs as Any,
            "error": error as Any,
        ]
    }
}

public struct FeedStats: Sendable, Equatable {
    public var total: Int
    public var warn: Int
    public var error: Int
    public var agentEvents: Int

    public init(total: Int, warn: Int, error: Int, agentEvents: Int) {
        self.total = total
        self.warn = warn
        self.error = error
        self.agentEvents = agentEvents
    }

    public func asDictionary() -> [String: Any] {
        ["total": total, "warn": warn, "error": error, "agent_events": agentEvents]
    }
}

public struct OrchestrationStatus: Sendable, Equatable {
    public var home: String
    public var mode: String
    public var health: String
    public var healthLabel: String
    public var managerAlive: Bool
    public var managerPID: Int?
    public var serveCount: Int
    public var superviseCount: Int
    public var mcpExternalCount: Int
    public var heartbeatAgeSec: Int?
    public var heartbeatSource: String
    public var serviceActive: Bool?
    public var httpListening: Bool?
    public var managerStateRaw: String?

    public init(
        home: String,
        mode: String,
        health: String,
        healthLabel: String,
        managerAlive: Bool,
        managerPID: Int?,
        serveCount: Int,
        superviseCount: Int,
        mcpExternalCount: Int,
        heartbeatAgeSec: Int?,
        heartbeatSource: String,
        serviceActive: Bool?,
        httpListening: Bool?,
        managerStateRaw: String?
    ) {
        self.home = home
        self.mode = mode
        self.health = health
        self.healthLabel = healthLabel
        self.managerAlive = managerAlive
        self.managerPID = managerPID
        self.serveCount = serveCount
        self.superviseCount = superviseCount
        self.mcpExternalCount = mcpExternalCount
        self.heartbeatAgeSec = heartbeatAgeSec
        self.heartbeatSource = heartbeatSource
        self.serviceActive = serviceActive
        self.httpListening = httpListening
        self.managerStateRaw = managerStateRaw
    }

    public static func empty(home: String) -> OrchestrationStatus {
        OrchestrationStatus(
            home: home,
            mode: "none",
            health: "unknown",
            healthLabel: "—",
            managerAlive: false,
            managerPID: nil,
            serveCount: 0,
            superviseCount: 0,
            mcpExternalCount: 0,
            heartbeatAgeSec: nil,
            heartbeatSource: "none",
            serviceActive: nil,
            httpListening: nil,
            managerStateRaw: nil
        )
    }

    public func asDictionary() -> [String: Any] {
        var managerState: [String: Any] = [:]
        if let serviceActive { managerState["service_active"] = serviceActive }
        if let httpListening { managerState["http_listening"] = httpListening }
        if let managerStateRaw { managerState["state"] = managerStateRaw }
        managerState["process_alive"] = managerAlive

        return [
            "home": home,
            "mode": mode,
            "health": health,
            "health_label": healthLabel,
            "manager_alive": managerAlive,
            "manager_pid": managerPID as Any,
            "manager_state": managerState,
            "primary_alive": false,
            "fallback_alive": false,
            "watchdog_alive": false,
            "orchestrator_alive": false,
            "serve_count": serveCount,
            "supervise_count": superviseCount,
            "mcp_external_count": mcpExternalCount,
            "heartbeat_age_sec": heartbeatAgeSec as Any,
            "heartbeat": [
                "manager_pid": managerPID ?? 0,
                "source": heartbeatSource,
                "ts": ISO8601.string(from: Date()),
            ] as [String: Any],
            "failover_events_1h": 0,
            "supervisor_tail": [] as [String],
            "orchestrator_tail": [] as [String],
            "role_events": [] as [[String: Any]],
        ]
    }
}

public struct UsageWindow: Sendable, Equatable {
    public var eventCount: Int
    public var outcomes: AuditOutcomeCounts
    public var errorRate: Double
    public var eventsPerMin: Double
    public var lastStatus: String?
    public var lastTool: String?
    public var lastTs: String?
    public var topTools: [ToolCount]

    public var errorCount: Int { outcomes.errorCount }
    public var deniedCount: Int { outcomes.deniedCount }
    public var warnCount: Int { outcomes.warnCount }
    public var otherCount: Int { outcomes.otherCount }

    public init(
        eventCount: Int,
        errorCount: Int,
        deniedCount: Int = 0,
        warnCount: Int = 0,
        otherCount: Int = 0,
        errorRate: Double,
        eventsPerMin: Double,
        lastStatus: String?,
        lastTool: String?,
        lastTs: String?,
        topTools: [ToolCount]
    ) {
        self.eventCount = eventCount
        self.outcomes = AuditOutcomeCounts(
            errorCount: errorCount,
            deniedCount: deniedCount,
            warnCount: warnCount,
            otherCount: otherCount
        )
        self.errorRate = errorRate
        self.eventsPerMin = eventsPerMin
        self.lastStatus = lastStatus
        self.lastTool = lastTool
        self.lastTs = lastTs
        self.topTools = topTools
    }

    public static let empty = UsageWindow(
        eventCount: 0,
        errorCount: 0,
        errorRate: 0,
        eventsPerMin: 0,
        lastStatus: nil,
        lastTool: nil,
        lastTs: nil,
        topTools: []
    )

    public func asDictionary() -> [String: Any] {
        [
            "event_count": eventCount,
            "error_count": errorCount,
            "denied_count": deniedCount,
            "warn_count": warnCount,
            "other_count": otherCount,
            "error_rate": errorRate,
            "events_per_min": eventsPerMin,
            "last_status": lastStatus as Any,
            "last_tool": lastTool as Any,
            "last_ts": lastTs as Any,
            "top_tools": topTools.map { $0.asDictionary() },
        ]
    }
}

public struct ToolCount: Sendable, Equatable {
    public var tool: String
    public var count: Int
    public init(tool: String, count: Int) {
        self.tool = tool
        self.count = count
    }
    public func asDictionary() -> [String: Any] { ["tool": tool, "count": count] }
}

public struct MCPLoadWindows: Sendable, Equatable {
    public var oneHour: UsageWindow
    public var fifteenMin: UsageWindow
    public var fiveMin: UsageWindow

    public init(oneHour: UsageWindow, fifteenMin: UsageWindow, fiveMin: UsageWindow) {
        self.oneHour = oneHour
        self.fifteenMin = fifteenMin
        self.fiveMin = fiveMin
    }

    public func asDictionary() -> [String: Any] {
        ["1h": oneHour.asDictionary(), "15m": fifteenMin.asDictionary(), "5m": fiveMin.asDictionary()]
    }
}

public struct ForgeFilesPresence: Sendable, Equatable {
    public var storeSQLite: Bool
    public var auditJSONL: Bool
    public var managerState: Bool

    public init(storeSQLite: Bool, auditJSONL: Bool, managerState: Bool) {
        self.storeSQLite = storeSQLite
        self.auditJSONL = auditJSONL
        self.managerState = managerState
    }

    public func asDictionary() -> [String: Any] {
        [
            "store_sqlite": storeSQLite,
            "audit_jsonl": auditJSONL,
            "manager_state": managerState,
        ]
    }
}

public struct AuditEventSummary: Sendable, Equatable {
    public var timestamp: String
    public var clientID: String?
    public var tool: String
    public var status: String
    public var durationMs: Int?
    public var error: String?

    public init(from event: AuditEvent) {
        timestamp = ISO8601.string(from: event.timestamp)
        clientID = event.clientID
        tool = event.tool
        status = event.status
        durationMs = event.durationMs
        error = event.error
    }

    public func asDictionary() -> [String: Any] {
        [
            "timestamp": timestamp,
            "client_id": clientID as Any,
            "tool": tool,
            "status": status,
            "duration_ms": durationMs as Any,
            "error": error as Any,
            "args_json": NSNull(),
        ]
    }
}

// MARK: - Card dictionary adapters (edge / tests)

extension MCPServerCard {
    public func asDictionary() -> [String: Any] {
        [
            "id": id,
            "label": label,
            "role": role,
            "host_kind": hostKind,
            "pid": pid as Any,
            "live": live,
            "status": status,
            "health": health,
            "health_label": healthLabel,
            "health_reason": healthReason,
            "activity": Int(activity),
            "source": source,
            "usage_5m": [
                "events_per_min": eventsPerMin,
                "event_count": eventCount5m,
                "error_rate": errorRate,
                "last_tool": lastTool as Any,
                "top_tools": topTools.map { ["tool": $0, "count": 1] as [String: Any] },
            ] as [String: Any],
        ]
    }
}

extension ToolCard {
    public func asDictionary() -> [String: Any] {
        var usage1h = outcomes1h.asDictionary()
        usage1h["event_count"] = events1h
        var usage5m = outcomes5m.asDictionary()
        usage5m["event_count"] = events5m

        return [
            "name": name,
            "pack": pack,
            "status": status,
            "health": health,
            "health_label": healthLabel,
            "activity": Int(activity),
            "live": live,
            "usage_1h": usage1h,
            "usage_5m": usage5m,
        ]
    }
}

extension AgentCard {
    public func asDictionary() -> [String: Any] {
        [
            "agent_id": agentID,
            "name": name,
            "description": description,
            "tools": tools,
            "status": status,
            "health": health,
            "health_label": healthLabel,
            "health_reason": healthReason,
            "live": live,
            "last_session_status": lastSessionStatus as Any,
            "summary": summary as Any,
        ]
    }
}
