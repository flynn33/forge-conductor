// ForgeCollector.swift
// What: Composes orchestration-specific state into a ForgeSnapshot.
// How: It correlates configuration, SQLite presence, audit/session data, LM Studio
// registrations, and discovered processes into health cards and bounded usage windows.
// Why: Product state needs a separate collector from host hardware telemetry.

import Foundation
import Darwin

/// Builds usage windows from already time-bounded audit events.
///
/// Status interpretation is delegated to the typed domain vocabulary so all
/// global load and per-tool summaries apply one outcome policy.
struct AuditUsageSummarizer {
    static func summarize(
        events: [AuditEvent],
        windowSec: TimeInterval,
        topLimit: Int
    ) -> UsageWindow {
        let outcomes = AuditOutcomeCounts.summarize(statuses: events.map(\.status))
        var top: [String: Int] = [:]
        for event in events {
            top[event.tool, default: 0] += 1
        }
        let topTools = top.sorted {
            if $0.value != $1.value { return $0.value > $1.value }
            return $0.key < $1.key
        }
        .prefix(max(topLimit, 0))
        .map { ToolCount(tool: $0.key, count: $0.value) }
        let minutes = max(windowSec / 60.0, 1.0)
        let last = events.first

        return UsageWindow(
            eventCount: events.count,
            errorCount: outcomes.errorCount,
            deniedCount: outcomes.deniedCount,
            warnCount: outcomes.warnCount,
            otherCount: outcomes.otherCount,
            errorRate: events.isEmpty
                ? 0
                : Double(outcomes.errorCount) / Double(events.count),
            eventsPerMin: Double(events.count) / minutes,
            lastStatus: last?.status,
            lastTool: last?.tool,
            lastTs: last.map { ISO8601.string(from: $0.timestamp) },
            topTools: topTools
        )
    }
}

/// Maps operational error rate to tool health. Policy denials and maintenance
/// warnings remain visible in outcome counts but do not change this health state.
struct ToolUsageHealthPolicy {
    static func health(for usage: UsageWindow) -> TelemetryHealth {
        if usage.errorRate >= 0.25 { return .error }
        if usage.errorRate > 0.05 { return .warn }
        return .ok
    }
}

struct OrchestrationEvidence {
    var lmStudioUp: Bool
    var managerAlive: Bool
    var managerServiceReady: Bool
    var managerServiceStopped: Bool
    var serveCount: Int
    var mcpProcessCount: Int
    var configuredRoleCount: Int
}

struct OrchestrationDecision: Equatable {
    var health: TelemetryHealth
    var label: String
    var mode: String
}

struct ManagerServiceHealthPolicy {
    static func isReady(serviceActive: Bool?, httpListening: Bool?) -> Bool {
        serviceActive == true || httpListening == true
    }
}

/// Classifies orchestration from explicit runtime and configuration evidence.
///
/// LM Studio starts MCP tools only when a chat selects them. Two valid registrations
/// with zero child processes are therefore a configured idle state, not a warning.
struct OrchestrationHealthPolicy {
    static func decide(from evidence: OrchestrationEvidence) -> OrchestrationDecision {
        let connectorActive = evidence.serveCount > 0 || evidence.mcpProcessCount > 0
        let fullyConfigured = evidence.configuredRoleCount >= LMStudioConnectorRole.allCases.count

        if evidence.lmStudioUp {
            if connectorActive {
                return OrchestrationDecision(
                    health: .ok,
                    label: "LM STUDIO + MCP",
                    mode: "lm-studio"
                )
            }
            if fullyConfigured {
                return OrchestrationDecision(
                    health: .config,
                    label: "MCP IDLE",
                    mode: "lm-studio"
                )
            }
            return OrchestrationDecision(
                health: .warn,
                label: evidence.configuredRoleCount > 0 ? "MCP PARTIAL" : "MCP NOT CONFIGURED",
                mode: "lm-studio"
            )
        }

        if evidence.managerAlive {
            if evidence.managerServiceReady {
                return OrchestrationDecision(health: .ok, label: "READY", mode: "swift-manager")
            }
            if evidence.managerServiceStopped {
                return OrchestrationDecision(
                    health: .warn,
                    label: "SERVICE STOPPED",
                    mode: "swift-manager"
                )
            }
            return OrchestrationDecision(health: .warn, label: "MANAGER", mode: "swift-manager")
        }

        if connectorActive {
            return OrchestrationDecision(
                health: .warn,
                label: evidence.serveCount > 0 ? "SERVE ONLY" : "MCP ONLY",
                mode: "mcp-only"
            )
        }

        if fullyConfigured {
            return OrchestrationDecision(health: .config, label: "CONFIGURED", mode: "configured")
        }

        return OrchestrationDecision(health: .error, label: "DOWN", mode: "none")
    }
}

/// Pure-Swift forge-side telemetry (MCP, agents, orchestration, tools, live feed).
/// Returns a fully typed `ForgeSnapshot` — dictionaries only at JSON edge via `asDictionary()`.
public final class ForgeCollector: ForgeMetricsCollecting, @unchecked Sendable {
    private let paths: AppPaths
    private let store: SQLiteStore
    private let catalog: AgentCatalog
    private let toolNamesProvider: () -> [String]

    public init(
        paths: AppPaths,
        store: SQLiteStore,
        catalog: AgentCatalog,
        toolNames: @escaping () -> [String] = { [] }
    ) {
        self.paths = paths
        self.store = store
        self.catalog = catalog
        self.toolNamesProvider = toolNames
    }

    public func collect() -> ForgeSnapshot {
        let procs = ProcessDiscovery.scan()
        let presence = (try? store.presenceRecords()) ?? []
        let sessions = (try? store.sessionList()) ?? []
        let audit = (try? store.auditRecent(limit: 200)) ?? []
        let configuredMCPServers = LMStudioEnvironment.configuredMCPServers()

        let mcpAssembler = MCPServerCardAssembler()
        let mcpServers = mcpAssembler.build(
            presence: presence,
            live: procs.mcpProcesses,
            configured: configuredMCPServers,
            audit: audit
        )
        let agents = buildAgentCards(sessions: sessions, audit: audit)
        let toolsAndPacks = buildToolCards(audit: audit)
        let liveFeed = buildLiveFeed(audit: audit, limit: 100)

        let feedStats = FeedStats(
            total: liveFeed.count,
            warn: liveFeed.filter { $0.status == "warn" }.count,
            error: liveFeed.filter { $0.status == "error" }.count,
            agentEvents: liveFeed.filter { $0.tool.hasPrefix("agent_") }.count
        )

        return ForgeSnapshot(
            ts: Date().timeIntervalSince1970,
            home: paths.home.path,
            runtime: "swift-native",
            presenceCount: mcpAssembler.reconciledPresenceCount(presence),
            mcpServers: mcpServers,
            mcpTools: toolsAndPacks.tools,
            mcpPacks: toolsAndPacks.packs,
            agents: agents,
            agentSessions: Array(sessions.prefix(25)).map(AgentSessionSummary.init(from:)),
            agentsSummary: summarizeAgents(sessions),
            liveFeed: liveFeed,
            feedStats: feedStats,
            orchestration: collectOrchestration(
                procs: procs,
                configuredMCPServers: configuredMCPServers
            ),
            mcpLoad: MCPLoadWindows(
                oneHour: summarizeTools(audit, windowSec: 3600),
                fifteenMin: summarizeTools(audit, windowSec: 900),
                fiveMin: summarizeTools(audit, windowSec: 300)
            ),
            files: ForgeFilesPresence(
                storeSQLite: FileManager.default.fileExists(atPath: paths.storeSQLite.path),
                auditJSONL: FileManager.default.fileExists(atPath: paths.auditJSONL.path),
                managerState: FileManager.default.fileExists(atPath: paths.managerState.path)
            ),
            auditRecent: Array(audit.prefix(40)).map(AuditEventSummary.init(from:))
        )
    }

    // MARK: - Orchestration

    private func collectOrchestration(
        procs: ProcessDiscovery.Snapshot,
        configuredMCPServers: [ConfiguredMCPServer]
    ) -> OrchestrationStatus {
        let managerState = readManagerState()
        let statePID = Int32(managerState?.pid ?? 0)
        let managerPID = procs.managerPIDs.first
            ?? (ProcessDiscovery.pidAlive(statePID) ? statePID : 0)
        let managerAlive = !procs.managerPIDs.isEmpty
            || (managerPID > 0 && ProcessDiscovery.pidAlive(managerPID))

        let serveCount = procs.servePIDs.count
        let lmStudioUp = !procs.lmStudioPIDs.isEmpty
        let mcpExt = ProcessDiscovery.mcpExternalProcessCount(procs.mcpProcesses)
        let decision = OrchestrationHealthPolicy.decide(from: OrchestrationEvidence(
            lmStudioUp: lmStudioUp,
            managerAlive: managerAlive,
            managerServiceReady: ManagerServiceHealthPolicy.isReady(
                serviceActive: managerState?.serviceActive,
                httpListening: managerState?.httpListening
            ),
            managerServiceStopped: managerState?.state == "stopped",
            serveCount: serveCount,
            mcpProcessCount: mcpExt,
            configuredRoleCount: validConfiguredRoleCount(configuredMCPServers)
        ))

        let heartbeatAge = managerAlive
            ? managerState?.fileAgeSec.map { min($0, 120) }
            : nil

        return OrchestrationStatus(
            home: paths.home.path,
            mode: decision.mode,
            health: decision.health.rawValue,
            healthLabel: decision.label,
            managerAlive: managerAlive,
            managerPID: managerPID > 0 ? Int(managerPID) : nil,
            serveCount: serveCount,
            superviseCount: procs.supervisePIDs.count,
            mcpExternalCount: mcpExt,
            heartbeatAgeSec: heartbeatAge,
            heartbeatSource: managerAlive ? "swift-manager" : (mcpExt > 0 ? "live-ps" : "none"),
            serviceActive: managerState?.serviceActive,
            httpListening: managerState?.httpListening,
            managerStateRaw: managerState?.state
        )
    }

    private func validConfiguredRoleCount(_ servers: [ConfiguredMCPServer]) -> Int {
        LMStudioConnectorRole.allCases.filter { role in
            guard let server = servers.first(where: { $0.id == role.serverID }) else {
                return false
            }
            return LMStudioEnvironment.isSwiftServeRegistration(
                server,
                expectedRole: role
            )
        }.count
    }

    private struct ManagerStateFile: Sendable {
        var pid: Int?
        var state: String?
        var serviceActive: Bool?
        var httpListening: Bool?
        var fileAgeSec: Int?
    }

    private func readManagerState() -> ManagerStateFile? {
        let url = paths.managerState
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let obj = try? JSONSupport.object(from: data) else { return nil }
        var file = ManagerStateFile(
            pid: obj["pid"] as? Int,
            state: obj["state"] as? String,
            serviceActive: obj["service_active"] as? Bool,
            httpListening: obj["http_listening"] as? Bool,
            fileAgeSec: nil
        )
        if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
           let mtime = attrs[.modificationDate] as? Date {
            file.fileAgeSec = Int(Date().timeIntervalSince(mtime))
        }
        return file
    }

    // MARK: - Agents

    /// Cards reflect **real use only**. Catalog presence is not activity.
    /// Previously every idle agent was painted with activity=15 / READY, which looked like load.
    private func buildAgentCards(sessions: [AgentSession], audit: [AuditEvent]) -> [AgentCard] {
        var byID: [String: AgentSession] = [:]
        for s in sessions {
            if byID[s.agentID] == nil || s.updatedAt > (byID[s.agentID]?.updatedAt ?? .distantPast) {
                byID[s.agentID] = s
            }
        }

        let now = Date()
        /// Open sessions older than this with no update are treated as abandoned for UI (not "in use").
        let activeWindow: TimeInterval = 15 * 60

        var cards: [AgentCard] = []
        var seen = Set<String>()
        for spec in catalog.all() {
            seen.insert(spec.id)
            let latest = byID[spec.id]
            cards.append(agentCard(
                id: spec.id,
                name: spec.displayName,
                description: spec.description,
                tools: spec.tools,
                session: latest,
                audit: audit,
                now: now,
                activeWindow: activeWindow
            ))
        }
        for (id, s) in byID where !seen.contains(id) {
            cards.append(agentCard(
                id: id,
                name: id,
                description: "",
                tools: [],
                session: s,
                audit: audit,
                now: now,
                activeWindow: activeWindow
            ))
        }
        return cards.sorted {
            if $0.live != $1.live { return $0.live && !$1.live }
            return $0.activity > $1.activity
        }
    }

    private func agentCard(
        id: String,
        name: String,
        description: String,
        tools: [String],
        session: AgentSession?,
        audit: [AuditEvent],
        now: Date,
        activeWindow: TimeInterval
    ) -> AgentCard {
        let openFresh: Bool = {
            guard let session, session.status.isOpen else { return false }
            return now.timeIntervalSince(session.updatedAt) <= activeWindow
        }()

        // Recent tool traffic that names this agent (agent_* tools + args/session id).
        let recentAgentHits = audit.filter { ev in
            let age = now.timeIntervalSince(ev.timestamp)
            guard age <= activeWindow else { return false }
            let tool = ev.tool.lowercased()
            guard tool.hasPrefix("agent_") else { return false }
            if tool.contains(id) { return true }
            if let args = ev.argsJSON?.lowercased(), args.contains(id.lowercased()) { return true }
            return false
        }
        let hitCount = recentAgentHits.count

        let activity: Double
        let status: String
        let live: Bool
        let healthLabel: String
        let healthReason: String

        if openFresh || hitCount > 0 {
            live = true
            status = "active"
            healthLabel = "ACTIVE"
            healthReason = openFresh ? "open session (updated \(Int(now.timeIntervalSince(session!.updatedAt)))s ago)" : "\(hitCount) agent events / 15m"
            // Scale 20…100 from event rate; open session alone = 60 baseline.
            let fromHits = min(100.0, Double(hitCount) * 12.0)
            activity = max(openFresh ? 60 : 0, fromHits)
        } else if let session, session.status.isOpen {
            // Stale open row — do not paint as busy.
            live = false
            status = "stale"
            healthLabel = "STALE"
            healthReason = "open session idle >15m — prune idle sessions"
            activity = 0
        } else {
            live = false
            status = "idle"
            healthLabel = "IDLE"
            healthReason = "no open session"
            activity = 0
        }

        return AgentCard(
            agentID: id,
            name: name,
            description: description,
            tools: tools,
            status: status,
            health: live ? "ok" : (status == "stale" ? "warn" : "ok"),
            healthLabel: healthLabel,
            healthReason: healthReason,
            live: live,
            lastSessionStatus: session?.status.rawValue,
            summary: session?.summary,
            activity: activity
        )
    }

    private func summarizeAgents(_ sessions: [AgentSession]) -> AgentsSummary {
        var byStatus: [String: Int] = [:]
        for s in sessions {
            byStatus[s.status.rawValue, default: 0] += 1
        }
        return AgentsSummary(
            total: sessions.count,
            open: sessions.filter { $0.status.isOpen }.count,
            byStatus: byStatus
        )
    }

    // MARK: - Tools

    private func buildToolCards(audit: [AuditEvent]) -> (tools: [ToolCard], packs: [ToolPackSummary]) {
        let names = Set(toolNamesProvider() + knownToolNames())
        var tools: [ToolCard] = []
        for name in names.sorted() {
            let usage = usageForTool(audit, tool: name, windowSec: 3600)
            let e5 = usageForTool(audit, tool: name, windowSec: 300)
            let status = e5.eventCount > 0 ? "active" : (usage.eventCount > 0 ? "warm" : "idle")
            let health = ToolUsageHealthPolicy.health(for: usage)
            tools.append(ToolCard(
                name: name,
                pack: packForTool(name),
                status: status,
                health: health.rawValue,
                healthLabel: health.label,
                activity: Double(min(100, usage.eventCount)),
                live: e5.eventCount > 0,
                events1h: usage.eventCount,
                events5m: e5.eventCount,
                outcomes1h: usage.outcomes,
                outcomes5m: e5.outcomes
            ))
        }
        var packMap: [String: (tools: Int, active: Int)] = [:]
        for t in tools {
            var p = packMap[t.pack] ?? (0, 0)
            p.tools += 1
            if t.status == "active" { p.active += 1 }
            packMap[t.pack] = p
        }
        let packs = packMap.keys.sorted().map { key in
            let v = packMap[key]!
            return ToolPackSummary(pack: key, toolCount: v.tools, activeCount: v.active)
        }
        return (tools, packs)
    }

    private func knownToolNames() -> [String] {
        [
            "forge_status", "agent_list", "agent_get", "agent_context", "agent_recommend",
            "agent_run_start", "agent_run_status", "agent_run_complete",
            "session_checkpoint", "session_handoff", "context_get", "context_list",
            "fs_read", "fs_write", "fs_edit", "fs_list", "fs_glob", "fs_mkdir", "fs_delete", "fs_move",
            "shell_exec", "git_status", "git_diff", "git_log", "git_add", "git_commit",
            "pdf_write", "pdf_from_file", "search_text",
        ]
    }

    private func packForTool(_ name: String) -> String {
        if name.hasPrefix("agent_") { return "agents" }
        if name.hasPrefix("session_") || name.hasPrefix("context_") { return "continuity" }
        if name.hasPrefix("fs_") { return "filesystem" }
        if name.hasPrefix("git_") { return "git" }
        if name.hasPrefix("pdf_") { return "docs" }
        if name.hasPrefix("shell_") { return "shell" }
        if name.hasPrefix("forge_") { return "forge" }
        if name.hasPrefix("search_") { return "search" }
        return "other"
    }

    // MARK: - Feed & usage

    private func buildLiveFeed(audit: [AuditEvent], limit: Int) -> [LiveFeedEvent] {
        Array(audit.prefix(limit)).map { e in
            LiveFeedEvent(
                timestamp: ISO8601.string(from: e.timestamp),
                tool: e.tool,
                status: e.status,
                clientID: e.clientID,
                durationMs: e.durationMs,
                error: e.error
            )
        }
    }

    private func summarizeTools(_ audit: [AuditEvent], windowSec: TimeInterval) -> UsageWindow {
        let window = windowEvents(audit, windowSec: windowSec)
        return AuditUsageSummarizer.summarize(
            events: window,
            windowSec: windowSec,
            topLimit: 8
        )
    }

    private func usageForTool(_ audit: [AuditEvent], tool: String, windowSec: TimeInterval) -> UsageWindow {
        usageStats(windowEvents(audit, windowSec: windowSec).filter { $0.tool == tool }, windowSec: windowSec)
    }

    private func usageStats(_ events: [AuditEvent], windowSec: TimeInterval) -> UsageWindow {
        AuditUsageSummarizer.summarize(
            events: events,
            windowSec: windowSec,
            topLimit: 5
        )
    }

    private func windowEvents(_ events: [AuditEvent], windowSec: TimeInterval) -> [AuditEvent] {
        let cutoff = Date().addingTimeInterval(-windowSec)
        return events.filter { $0.timestamp >= cutoff }
    }

}

/// Deterministically reconciles process, configuration, presence, and audit evidence
/// into one MCP card set. Runtime process enumeration stays in `ProcessDiscovery`;
/// this type owns only the pure merge and presentation-state policy.
struct MCPServerCardAssembler {
    private struct PresenceObservation {
        var record: PresenceRecord
        var processUp: Bool
    }

    private let now: Date
    private let isPIDAlive: (Int32) -> Bool

    init(
        now: Date = Date(),
        isPIDAlive: @escaping (Int32) -> Bool = ProcessDiscovery.pidAlive
    ) {
        self.now = now
        self.isPIDAlive = isPIDAlive
    }

    func build(
        presence: [PresenceRecord],
        live: [ProcessDiscovery.MCPProcess],
        configured: [ConfiguredMCPServer],
        audit: [AuditEvent]
    ) -> [MCPServerCard] {
        let observations = eligiblePresence(presence)
        var presenceByPID: [Int32: PresenceObservation] = [:]
        for observation in observations where observation.record.pid > 0 {
            let pid = observation.record.pid
            if let existing = presenceByPID[pid],
               existing.record.lastHeartbeat >= observation.record.lastHeartbeat {
                continue
            }
            presenceByPID[pid] = observation
        }

        var cards: [MCPServerCard] = []
        var consumedPresenceIDs = Set<String>()
        var consumedPresencePIDs = Set<Int32>()
        var representedConnectorRoles = Set<String>()
        var emittedLivePIDs = Set<Int32>()

        // Live processes are authoritative for liveness. Matching presence contributes
        // the role and stable client identity needed to correlate audit activity.
        for process in live where !emittedLivePIDs.contains(process.pid) {
            emittedLivePIDs.insert(process.pid)
            let processIsStdio = ProcessDiscovery.isForgeMCPStdioHostKind(
                process.hostKind
            )
            let observation = processIsStdio ? presenceByPID[process.pid] : nil
            if let observation {
                consumedPresenceIDs.insert(observation.record.clientID)
                consumedPresencePIDs.insert(observation.record.pid)
            }

            let hostKind = nonempty(observation?.record.hostKind) ?? process.hostKind
            let roleKey = connectorRoleKey(label: process.label, hostKind: hostKind)
            if let roleKey {
                representedConnectorRoles.insert(roleKey)
            }
            let label = connectorLabel(roleKey: roleKey) ?? process.label
            let auditClientID = observation.map {
                Self.normalizedAuditClientID(fromPresenceID: $0.record.clientID)
            }
            let usage = auditClientID.map {
                usageForClient(audit, clientID: $0, windowSec: 300)
            } ?? .empty
            let health = mcpHealth(live: true, usage: usage)

            cards.append(MCPServerCard(
                id: observation?.record.clientID ?? "proc-\(label)-\(process.pid)",
                label: label,
                role: roleFromLabel(label, hostKind: hostKind),
                hostKind: hostKind,
                pid: Int(process.pid),
                live: true,
                status: usage.eventCount > 0 ? "active" : "idle",
                health: health.health,
                healthLabel: health.label,
                healthReason: health.reason,
                activity: activity(for: usage),
                source: observation == nil ? "live-proc" : "live-proc+presence",
                eventsPerMin: usage.eventsPerMin,
                eventCount5m: usage.eventCount,
                errorRate: usage.errorRate,
                lastTool: usage.lastTool,
                topTools: usage.topTools.map(\.tool)
            ))
        }

        // Presence catches live app-bundle serves even if an OS process API omits argv.
        // A process already merged above must not produce a second card.
        for observation in observations {
            let record = observation.record
            if consumedPresenceIDs.contains(record.clientID)
                || (record.pid > 0 && consumedPresencePIDs.contains(record.pid)) {
                continue
            }

            let hostKind = nonempty(record.hostKind) ?? "mcp"
            let roleKey = connectorRoleKey(label: "", hostKind: hostKind)
            if let roleKey {
                representedConnectorRoles.insert(roleKey)
            }
            let label = connectorLabel(roleKey: roleKey) ?? mcpLabel(cwd: record.cwd)
            let auditClientID = Self.normalizedAuditClientID(fromPresenceID: record.clientID)
            let usage = usageForClient(audit, clientID: auditClientID, windowSec: 300)
            let health = mcpHealth(live: observation.processUp, usage: usage)

            cards.append(MCPServerCard(
                id: record.clientID.isEmpty ? "presence-\(record.pid)" : record.clientID,
                label: label,
                role: roleFromLabel(label, hostKind: hostKind),
                hostKind: hostKind,
                pid: record.pid > 0 ? Int(record.pid) : nil,
                live: observation.processUp,
                status: observation.processUp
                    ? (usage.eventCount > 0 ? "active" : "idle")
                    : "stale",
                health: health.health,
                healthLabel: health.label,
                healthReason: health.reason,
                activity: activity(for: usage),
                source: "presence",
                eventsPerMin: usage.eventsPerMin,
                eventCount5m: usage.eventCount,
                errorRate: usage.errorRate,
                lastTool: usage.lastTool,
                topTools: usage.topTools.map(\.tool)
            ))
        }

        // Configuration is reconciled by connector role, never by shared command path.
        // A live primary therefore suppresses only the primary CONFIG card; fallback
        // remains visible until independent fallback runtime evidence appears.
        var emittedConfigurationIDs = Set<String>()
        for server in configured where !emittedConfigurationIDs.contains(server.id) {
            emittedConfigurationIDs.insert(server.id)
            let roleKey = configuredConnectorRoleKey(server)
            if let roleKey, representedConnectorRoles.contains(roleKey) {
                continue
            }

            let role = roleFromLabel(server.id, hostKind: "lm-studio-mcp")
            let usage = usageForClient(audit, clientID: server.id, windowSec: 300)
            cards.append(MCPServerCard(
                id: "cfg-\(server.id)",
                label: server.id,
                role: role,
                hostKind: "lm-studio-mcp",
                pid: nil,
                live: false,
                status: "configured",
                health: "config",
                healthLabel: "CONFIG",
                healthReason: "In ~/.lmstudio/mcp.json — start when LM Studio connects",
                activity: 0,
                source: "lmstudio-mcp.json",
                eventsPerMin: usage.eventsPerMin,
                eventCount5m: usage.eventCount,
                errorRate: usage.errorRate,
                lastTool: usage.lastTool,
                topTools: usage.topTools.map(\.tool)
            ))
        }

        cards.sort {
            if $0.live != $1.live { return $0.live && !$1.live }
            if $0.label != $1.label { return $0.label < $1.label }
            return $0.id < $1.id
        }
        return cards
    }

    /// Current presence records append role to the UUID while audit events retain
    /// the bare UUID. Accept both shapes so existing databases remain readable.
    static func normalizedAuditClientID(fromPresenceID presenceID: String) -> String {
        for role in LMStudioConnectorRole.allCases {
            let suffix = ":\(role.rawValue)"
            if presenceID.hasSuffix(suffix), presenceID.count > suffix.count {
                return String(presenceID.dropLast(suffix.count))
            }
        }
        return presenceID
    }

    /// Counts the same recent, product-relevant presence observations considered
    /// by card reconciliation, excluding stale and known foreign-project rows.
    func reconciledPresenceCount(_ records: [PresenceRecord]) -> Int {
        eligiblePresence(records).count
    }

    private func eligiblePresence(_ records: [PresenceRecord]) -> [PresenceObservation] {
        records.compactMap { record in
            let identity = (record.clientID + " " + record.cwd + " " + record.hostKind).lowercased()
            if identity.contains("ccdt")
                || identity.contains("project-continuity")
                || identity.contains("/.claude/") {
                return nil
            }

            let processUp = record.pid > 0 && isPIDAlive(record.pid)
            let age = heartbeatAgeSec(record.lastHeartbeat)
            if !processUp && (age == nil || (age ?? 0) > 90) {
                return nil
            }
            return PresenceObservation(record: record, processUp: processUp)
        }
    }

    private func configuredConnectorRoleKey(_ server: ConfiguredMCPServer) -> String? {
        if let environmentRole = server.environment["FORGE_MCP_ROLE"],
           LMStudioConnectorRole(rawValue: environmentRole) != nil {
            return environmentRole
        }
        if server.id == LMStudioEnvironment.primaryServerID {
            return LMStudioConnectorRole.primary.rawValue
        }
        if server.id == LMStudioEnvironment.fallbackServerID {
            return LMStudioConnectorRole.fallback.rawValue
        }
        return nil
    }

    private func connectorRoleKey(label: String, hostKind: String) -> String? {
        if hostKind == LMStudioConnectorRole.fallback.hostKind
            || label == LMStudioEnvironment.fallbackServerID
            || label.contains("fallback") {
            return LMStudioConnectorRole.fallback.rawValue
        }
        if hostKind == LMStudioConnectorRole.primary.hostKind
            || label == LMStudioEnvironment.primaryServerID {
            return LMStudioConnectorRole.primary.rawValue
        }
        return nil
    }

    private func connectorLabel(roleKey: String?) -> String? {
        switch roleKey {
        case LMStudioConnectorRole.primary.rawValue:
            return LMStudioEnvironment.primaryServerID
        case LMStudioConnectorRole.fallback.rawValue:
            return LMStudioEnvironment.fallbackServerID
        default:
            return nil
        }
    }

    private func roleFromLabel(_ label: String, hostKind: String) -> String {
        if hostKind == "lm-studio-host" { return "host" }
        if hostKind == "model-backend" { return "model" }
        if connectorRoleKey(label: label, hostKind: hostKind) == LMStudioConnectorRole.fallback.rawValue {
            return LMStudioConnectorRole.fallback.rawValue
        }
        if connectorRoleKey(label: label, hostKind: hostKind) == LMStudioConnectorRole.primary.rawValue {
            return LMStudioConnectorRole.primary.rawValue
        }
        if label == "LM Studio" { return "host" }
        return "mcp"
    }

    private func mcpLabel(cwd: String?) -> String {
        guard let cwd, !cwd.isEmpty else { return "mcp" }
        let base = (cwd as NSString).lastPathComponent
        if base.contains("forge-conductor") {
            return LMStudioEnvironment.primaryServerID
        }
        return base
    }

    private func usageForClient(
        _ audit: [AuditEvent],
        clientID: String,
        windowSec: TimeInterval
    ) -> UsageWindow {
        let cutoff = now.addingTimeInterval(-windowSec)
        let events = audit.filter {
            $0.timestamp >= cutoff && $0.clientID == clientID
        }
        return AuditUsageSummarizer.summarize(
            events: events,
            windowSec: windowSec,
            topLimit: 5
        )
    }

    private func activity(for usage: UsageWindow) -> Double {
        Double(min(100, Int(usage.eventsPerMin / 12 * 100)))
    }

    private func mcpHealth(
        live: Bool,
        usage: UsageWindow
    ) -> (health: String, label: String, reason: String) {
        if !live { return ("error", "DOWN", "process not running") }
        if usage.errorRate >= 0.25 || usage.errorCount >= 3 {
            return ("error", "ERROR", "elevated tool errors")
        }
        if usage.errorRate > 0.05 || usage.errorCount > 0 {
            return ("warn", "WARN", "recent tool errors")
        }
        return ("ok", "READY", "live and healthy")
    }

    private func heartbeatAgeSec(_ heartbeat: String?) -> Int? {
        guard let heartbeat, let date = ISO8601.date(from: heartbeat) else {
            return nil
        }
        return max(0, Int(now.timeIntervalSince(date)))
    }

    private func nonempty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }
}
