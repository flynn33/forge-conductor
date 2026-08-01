// ForgeUIModels.swift
// What: Defines presentation-ready cards derived from orchestration domain snapshots.
// How: Immutable Sendable values normalize labels, live state, health, and identifiers;
// ForgeUIModelFactory performs all domain-to-presentation mapping.
// Why: UI modules should consume stable values instead of interpreting raw dictionaries.

import Foundation

// MARK: - Typed forge-side cards (domain + UI; built by ForgeCollector)

/// Presentation-ready health and activity summary for one MCP server presence.
///
/// The card preserves typed state for native views while its explicit dictionary
/// adapter supports the dashboard's JSON boundary and legacy compatibility tests.
public struct MCPServerCard: Sendable, Equatable, Identifiable {
    public var id: String
    public var label: String
    public var role: String
    public var hostKind: String
    public var pid: Int?
    public var live: Bool
    public var status: String
    public var health: String
    public var healthLabel: String
    public var healthReason: String
    public var activity: Double
    public var source: String
    public var eventsPerMin: Double
    public var eventCount5m: Int
    public var errorRate: Double
    public var lastTool: String?
    public var topTools: [String]

    public init(
        id: String,
        label: String,
        role: String,
        hostKind: String,
        pid: Int?,
        live: Bool,
        status: String,
        health: String,
        healthLabel: String,
        healthReason: String,
        activity: Double,
        source: String,
        eventsPerMin: Double,
        eventCount5m: Int,
        errorRate: Double,
        lastTool: String?,
        topTools: [String]
    ) {
        self.id = id
        self.label = label
        self.role = role
        self.hostKind = hostKind
        self.pid = pid
        self.live = live
        self.status = status
        self.health = health
        self.healthLabel = healthLabel
        self.healthReason = healthReason
        self.activity = activity
        self.source = source
        self.eventsPerMin = eventsPerMin
        self.eventCount5m = eventCount5m
        self.errorRate = errorRate
        self.lastTool = lastTool
        self.topTools = topTools
    }

    /// Edge adapter only (JSON round-trip / legacy tests).
    public init(from dict: [String: Any]) {
        id = dict["id"] as? String ?? UUID().uuidString
        label = dict["label"] as? String ?? "mcp"
        role = dict["role"] as? String ?? "mcp"
        hostKind = dict["host_kind"] as? String ?? "mcp"
        if let p = dict["pid"] as? Int { pid = p }
        else if let p = dict["pid"] as? NSNumber { pid = p.intValue }
        else { pid = nil }
        live = dict["live"] as? Bool ?? false
        status = dict["status"] as? String ?? "idle"
        health = dict["health"] as? String ?? (live ? "ok" : "error")
        healthLabel = dict["health_label"] as? String ?? (live ? "READY" : "DOWN")
        healthReason = dict["health_reason"] as? String ?? ""
        if let a = dict["activity"] as? Int { activity = Double(a) }
        else if let a = dict["activity"] as? Double { activity = a }
        else { activity = live ? 20 : 0 }
        source = dict["source"] as? String ?? ""
        let u = dict["usage_5m"] as? [String: Any] ?? [:]
        eventsPerMin = u["events_per_min"] as? Double ?? 0
        eventCount5m = u["event_count"] as? Int ?? 0
        errorRate = u["error_rate"] as? Double ?? 0
        lastTool = u["last_tool"] as? String
        var tops: [String] = []
        if let arr = u["top_tools"] as? [[String: Any]] {
            tops = arr.compactMap { $0["tool"] as? String }
        } else if let arr = u["top_tools"] as? [String] {
            tops = arr
        }
        topTools = Array(tops.prefix(4))
    }
}

public struct ToolCard: Sendable, Equatable, Identifiable {
    public var id: String { name }
    public var name: String
    public var pack: String
    public var status: String
    public var health: String
    public var healthLabel: String
    public var activity: Double
    public var live: Bool
    public var events1h: Int
    public var events5m: Int
    public var outcomes1h: AuditOutcomeCounts
    public var outcomes5m: AuditOutcomeCounts

    public init(
        name: String,
        pack: String,
        status: String,
        health: String,
        healthLabel: String,
        activity: Double,
        live: Bool,
        events1h: Int,
        events5m: Int,
        outcomes1h: AuditOutcomeCounts = .empty,
        outcomes5m: AuditOutcomeCounts = .empty
    ) {
        self.name = name
        self.pack = pack
        self.status = status
        self.health = health
        self.healthLabel = healthLabel
        self.activity = activity
        self.live = live
        self.events1h = events1h
        self.events5m = events5m
        self.outcomes1h = outcomes1h
        self.outcomes5m = outcomes5m
    }

    public init(from dict: [String: Any]) {
        name = dict["name"] as? String ?? "?"
        pack = dict["pack"] as? String ?? "other"
        status = dict["status"] as? String ?? "idle"
        health = dict["health"] as? String ?? "ok"
        healthLabel = dict["health_label"] as? String ?? "READY"
        if let a = dict["activity"] as? Int { activity = Double(a) }
        else if let a = dict["activity"] as? Double { activity = a }
        else {
            switch status {
            case "active": activity = 70
            case "warm": activity = 35
            default: activity = 5
            }
        }
        live = dict["live"] as? Bool ?? (status == "active")
        let u1 = dict["usage_1h"] as? [String: Any] ?? [:]
        let u5 = dict["usage_5m"] as? [String: Any] ?? [:]
        events1h = u1["event_count"] as? Int ?? 0
        events5m = u5["event_count"] as? Int ?? 0
        outcomes1h = Self.outcomes(from: u1)
        outcomes5m = Self.outcomes(from: u5)
    }

    public var shortLabel: String {
        name.split(separator: "_").first.map { String($0).uppercased() } ?? "?"
    }

    public var loadTier: Int {
        if activity >= 55 || status == "active" { return 3 }
        if activity >= 25 || status == "warm" { return 2 }
        if activity > 0 { return 1 }
        return 0
    }

    private static func outcomes(from dictionary: [String: Any]) -> AuditOutcomeCounts {
        AuditOutcomeCounts(
            errorCount: dictionary["error_count"] as? Int ?? 0,
            deniedCount: dictionary["denied_count"] as? Int ?? 0,
            warnCount: dictionary["warn_count"] as? Int ?? 0,
            otherCount: dictionary["other_count"] as? Int ?? 0
        )
    }
}

public struct AgentCard: Sendable, Equatable, Identifiable {
    public var id: String { agentID }
    public var agentID: String
    public var name: String
    public var description: String
    public var tools: [String]
    public var status: String
    public var health: String
    public var healthLabel: String
    public var healthReason: String
    public var live: Bool
    public var lastSessionStatus: String?
    public var summary: String?
    public var activity: Double

    public init(
        agentID: String,
        name: String,
        description: String = "",
        tools: [String] = [],
        status: String,
        health: String,
        healthLabel: String,
        healthReason: String,
        live: Bool,
        lastSessionStatus: String?,
        summary: String?,
        activity: Double
    ) {
        self.agentID = agentID
        self.name = name
        self.description = description
        self.tools = tools
        self.status = status
        self.health = health
        self.healthLabel = healthLabel
        self.healthReason = healthReason
        self.live = live
        self.lastSessionStatus = lastSessionStatus
        self.summary = summary
        self.activity = activity
    }

    public init(from dict: [String: Any]) {
        agentID = dict["agent_id"] as? String ?? dict["name"] as? String ?? "agent"
        name = dict["name"] as? String ?? agentID
        description = dict["description"] as? String ?? ""
        tools = dict["tools"] as? [String] ?? []
        status = dict["status"] as? String ?? "ready"
        health = dict["health"] as? String ?? "ok"
        healthLabel = dict["health_label"] as? String ?? "READY"
        healthReason = dict["health_reason"] as? String ?? ""
        live = dict["live"] as? Bool ?? false
        lastSessionStatus = dict["last_session_status"] as? String
        summary = dict["summary"] as? String
        if let a = dict["activity"] as? Double {
            activity = a
        } else if let a = dict["activity"] as? Int {
            activity = Double(a)
        } else {
            // Never invent activity for idle catalog agents.
            activity = live ? 60 : 0
        }
    }
}

public struct OrchRoleCard: Sendable, Equatable {
    public var name: String
    public var live: Bool
    public var status: String
    public var gauge: Double

    public init(name: String, live: Bool, status: String, gauge: Double) {
        self.name = name
        self.live = live
        self.status = status
        self.gauge = gauge
    }
}

public enum ForgeUIModelFactory {
    public static func mcpServers(from forge: ForgeSnapshot) -> [MCPServerCard] { forge.mcpServers }
    public static func tools(from forge: ForgeSnapshot) -> [ToolCard] { forge.mcpTools }
    public static func agents(from forge: ForgeSnapshot) -> [AgentCard] { forge.agents }
    public static func packs(from forge: ForgeSnapshot) -> [ToolPackSummary] { forge.mcpPacks }

    /// Edge adapters for dictionary snapshots (HTTP / fixtures).
    public static func mcpServers(from forge: [String: Any]) -> [MCPServerCard] {
        (forge["mcp_servers"] as? [[String: Any]] ?? []).map(MCPServerCard.init(from:))
    }
    public static func tools(from forge: [String: Any]) -> [ToolCard] {
        (forge["mcp_tools"] as? [[String: Any]] ?? []).map(ToolCard.init(from:))
    }
    public static func agents(from forge: [String: Any]) -> [AgentCard] {
        (forge["agents"] as? [[String: Any]] ?? []).map(AgentCard.init(from:))
    }
    public static func packs(from forge: [String: Any]) -> [[String: Any]] {
        forge["mcp_packs"] as? [[String: Any]] ?? []
    }
}
