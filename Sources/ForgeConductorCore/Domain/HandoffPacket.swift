// HandoffPacket.swift
// What: Versioned context + agent continuity payload for chat handoff/resume.
// How: Codable-ish dictionary wire form with stable keys for MCP/JSONL/SQLite.
// Why: New LM Studio chats must rehydrate task and open agent sessions without HTTP.

import Foundation
import CoreFoundation

/// Source that produced a handoff packet.
public enum HandoffSource: String, Sendable, Codable, Equatable {
    case model
    case budget
    case user
}

/// Snapshot of an open (or recently open) specialist agent for resume.
public struct AgentContinuitySnapshot: Sendable, Equatable {
    public var sessionID: String
    public var agentID: String
    public var goal: String
    public var cwd: String?
    public var status: String
    public var updatedAt: String?
    public var resumeHint: String

    public init(
        sessionID: String,
        agentID: String,
        goal: String = "",
        cwd: String? = nil,
        status: String = "open",
        updatedAt: String? = nil,
        resumeHint: String = ""
    ) {
        self.sessionID = sessionID
        self.agentID = agentID
        self.goal = goal
        self.cwd = cwd
        self.status = status
        self.updatedAt = updatedAt
        self.resumeHint = resumeHint
    }

    public func asDictionary() -> [String: Any] {
        var d: [String: Any] = [
            "session_id": sessionID,
            "agent_id": agentID,
            "goal": goal,
            "status": status,
            "resume_hint": resumeHint,
        ]
        if let cwd { d["cwd"] = cwd }
        if let updatedAt { d["updated_at"] = updatedAt }
        return d
    }

    public static func fromDictionary(_ d: [String: Any]) -> AgentContinuitySnapshot? {
        for key in ["session_id", "agent_id", "goal", "cwd", "status", "updated_at", "resume_hint"] {
            if d[key] != nil, !(d[key] is String) { return nil }
        }
        guard let sessionID = d["session_id"] as? String,
              !sessionID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let agentID = d["agent_id"] as? String,
              !agentID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return AgentContinuitySnapshot(
            sessionID: sessionID,
            agentID: agentID,
            goal: d["goal"] as? String ?? "",
            cwd: d["cwd"] as? String,
            status: d["status"] as? String ?? "open",
            updatedAt: d["updated_at"] as? String,
            resumeHint: d["resume_hint"] as? String ?? ""
        )
    }
}

/// Durable handoff packet (schema_version 1).
public struct HandoffPacket: Sendable, Equatable {
    public static let schemaVersion = 1
    public static let maxNarrativeChars = 4_000

    public var id: String
    public var schemaVersion: Int
    public var createdAt: String
    public var updatedAt: String
    public var source: HandoffSource
    public var resumeReady: Bool
    public var chatLabel: String?
    public var clientID: String?

    // Task
    public var goal: String
    public var status: String
    public var projectSlug: String?
    public var cwd: String?
    public var blockers: [String]
    public var nextActions: [String]

    // Working set
    public var keyFiles: [String]
    public var decisions: [String]

    // Agents
    public var agents: [AgentContinuitySnapshot]

    // Narrative + resume seed
    public var narrative: String
    public var resumeSeed: String
    public var resumeSeedIsCustom: Bool

    public init(
        id: String = UUID().uuidString.lowercased(),
        schemaVersion: Int = HandoffPacket.schemaVersion,
        createdAt: String = ISO8601.string(from: Date()),
        updatedAt: String = ISO8601.string(from: Date()),
        source: HandoffSource = .model,
        resumeReady: Bool = false,
        chatLabel: String? = nil,
        clientID: String? = nil,
        goal: String = "",
        status: String = "in_progress",
        projectSlug: String? = nil,
        cwd: String? = nil,
        blockers: [String] = [],
        nextActions: [String] = [],
        keyFiles: [String] = [],
        decisions: [String] = [],
        agents: [AgentContinuitySnapshot] = [],
        narrative: String = "",
        resumeSeed: String = "",
        resumeSeedIsCustom: Bool = false
    ) {
        self.id = id
        self.schemaVersion = schemaVersion
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.source = source
        self.resumeReady = resumeReady
        self.chatLabel = chatLabel
        self.clientID = clientID
        self.goal = goal
        self.status = status
        self.projectSlug = projectSlug
        self.cwd = cwd
        self.blockers = blockers
        self.nextActions = nextActions
        self.keyFiles = keyFiles
        self.decisions = decisions
        self.agents = agents
        self.narrative = String(narrative.prefix(Self.maxNarrativeChars))
        self.resumeSeed = resumeSeed
        self.resumeSeedIsCustom = resumeSeedIsCustom
    }

    public func asDictionary() -> [String: Any] {
        var meta: [String: Any] = [
            "id": id,
            "schema_version": schemaVersion,
            "created_at": createdAt,
            "updated_at": updatedAt,
            "source": source.rawValue,
            "resume_ready": resumeReady,
        ]
        if let chatLabel { meta["chat_label"] = chatLabel }
        if let clientID { meta["client_id"] = clientID }

        var task: [String: Any] = [
            "goal": goal,
            "status": status,
            "blockers": blockers,
            "next_actions": nextActions,
        ]
        if let projectSlug { task["project_slug"] = projectSlug }
        if let cwd { task["cwd"] = cwd }

        return [
            "schema_version": schemaVersion,
            "meta": meta,
            "task": task,
            "working_set": [
                "key_files": keyFiles,
                "decisions": decisions,
            ] as [String: Any],
            "agents": agents.map { $0.asDictionary() },
            "narrative": narrative,
            "resume": [
                "seed": resumeSeed.isEmpty ? defaultResumeSeed() : resumeSeed,
                "custom": resumeSeedIsCustom,
                "instructions": [
                    "Call context_get if you need the full packet again",
                    "Pass this handoff id to session_checkpoint/session_handoff when continuing it",
                    "Reattach open agents with agent_run_status(session_id) or complete and restart",
                    "Update memory/current-task.md via session_checkpoint as you progress",
                ],
            ] as [String: Any],
        ]
    }

    public func defaultResumeSeed() -> String {
        var lines: [String] = [
            "Forge Continuity resume (handoff \(id)).",
            "Goal: \(goal.isEmpty ? "(none recorded)" : goal)",
            "Status: \(status)",
        ]
        if let cwd, !cwd.isEmpty { lines.append("cwd: \(cwd)") }
        if let projectSlug, !projectSlug.isEmpty { lines.append("project: \(projectSlug)") }
        if !nextActions.isEmpty {
            lines.append("Next actions:")
            for a in nextActions.prefix(8) { lines.append("- \(a)") }
        }
        if !agents.isEmpty {
            lines.append("Open agents:")
            for a in agents.prefix(8) {
                lines.append(
                    "- \(a.agentID) session=\(a.sessionID) status=\(a.status) goal=\(a.goal.prefix(80))"
                )
            }
            lines.append("Use agent_run_status / agent_run_complete then continue; do not invent session state.")
        }
        if !narrative.isEmpty {
            lines.append("Summary: \(narrative.prefix(500))")
        }
        lines.append("Continue this packet with handoff_id: \(id) on later checkpoints or handoffs.")
        lines.append("Call context_get for the full structured packet, then continue the task.")
        return lines.joined(separator: "\n")
    }

    public static func fromDictionary(_ root: [String: Any]) -> HandoffPacket? {
        for key in ["meta", "task", "working_set", "resume"] {
            if root[key] != nil, !(root[key] is [String: Any]) { return nil }
        }
        let meta = root["meta"] as? [String: Any] ?? [:]
        let task = root["task"] as? [String: Any] ?? [:]
        let working = root["working_set"] as? [String: Any] ?? [:]
        let resume = root["resume"] as? [String: Any] ?? [:]
        let rootVersion: Int?
        if let raw = root["schema_version"] {
            guard let value = strictInteger(raw) else { return nil }
            rootVersion = value
        } else {
            rootVersion = nil
        }
        let metaVersion: Int?
        if let raw = meta["schema_version"] {
            guard let value = strictInteger(raw) else { return nil }
            metaVersion = value
        } else {
            metaVersion = nil
        }
        guard rootVersion == nil || rootVersion == schemaVersion,
              metaVersion == nil || metaVersion == schemaVersion,
              rootVersion == nil || metaVersion == nil || rootVersion == metaVersion else {
            return nil
        }
        if meta["id"] != nil, !(meta["id"] is String) { return nil }
        if root["id"] != nil, !(root["id"] is String) { return nil }
        guard let id = (meta["id"] as? String) ?? (root["id"] as? String),
              isSafeID(id) else {
            return nil
        }

        for key in ["created_at", "updated_at", "source", "chat_label", "client_id"] {
            if meta[key] != nil, !(meta[key] is String) { return nil }
        }
        for key in ["goal", "status", "project_slug", "cwd"] {
            if task[key] != nil, !(task[key] is String) { return nil }
        }
        for key in ["blockers", "next_actions"] {
            if task[key] != nil, !(task[key] is [String]) { return nil }
        }
        for key in ["key_files", "decisions"] {
            if working[key] != nil, !(working[key] is [String]) { return nil }
        }
        if root["narrative"] != nil, !(root["narrative"] is String) { return nil }
        if resume["seed"] != nil, !(resume["seed"] is String) { return nil }
        if resume["instructions"] != nil, !(resume["instructions"] is [String]) { return nil }

        let resumeReady: Bool
        if let raw = meta["resume_ready"] {
            guard let value = strictBoolean(raw) else { return nil }
            resumeReady = value
        } else {
            resumeReady = false
        }
        let customMarker: Bool?
        if let raw = resume["custom"] {
            guard let value = strictBoolean(raw) else { return nil }
            customMarker = value
        } else {
            customMarker = nil
        }

        let sourceRaw = meta["source"] as? String ?? HandoffSource.model.rawValue
        guard let source = HandoffSource(rawValue: sourceRaw) else { return nil }
        if root["agents"] != nil, !(root["agents"] is [[String: Any]]) { return nil }
        let rawAgents = root["agents"] as? [[String: Any]] ?? []
        var agentList: [AgentContinuitySnapshot] = []
        for rawAgent in rawAgents {
            guard let agent = AgentContinuitySnapshot.fromDictionary(rawAgent) else { return nil }
            agentList.append(agent)
        }

        let resumeSeed = resume["seed"] as? String ?? ""
        var packet = HandoffPacket(
            id: id,
            schemaVersion: rootVersion ?? metaVersion ?? schemaVersion,
            createdAt: meta["created_at"] as? String ?? ISO8601.string(from: Date()),
            updatedAt: meta["updated_at"] as? String ?? ISO8601.string(from: Date()),
            source: source,
            resumeReady: resumeReady,
            chatLabel: meta["chat_label"] as? String,
            clientID: meta["client_id"] as? String,
            goal: task["goal"] as? String ?? "",
            status: task["status"] as? String ?? "in_progress",
            projectSlug: task["project_slug"] as? String,
            cwd: task["cwd"] as? String,
            blockers: task["blockers"] as? [String] ?? [],
            nextActions: task["next_actions"] as? [String] ?? [],
            keyFiles: working["key_files"] as? [String] ?? [],
            decisions: working["decisions"] as? [String] ?? [],
            agents: agentList,
            narrative: root["narrative"] as? String ?? "",
            resumeSeed: resumeSeed,
            resumeSeedIsCustom: customMarker ?? false
        )
        if customMarker == nil {
            let generatedPrefix = "Forge Continuity resume (handoff \(id))."
            packet.resumeSeedIsCustom = !resumeSeed.isEmpty && !resumeSeed.hasPrefix(generatedPrefix)
        }
        return packet
    }

    private static func strictInteger(_ value: Any) -> Int? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let type = String(cString: number.objCType)
        guard !["f", "d"].contains(type) else { return nil }
        return number.intValue
    }

    private static func strictBoolean(_ value: Any) -> Bool? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }

    private static func isSafeID(_ id: String) -> Bool {
        guard !id.isEmpty, id.utf8.count <= 128, id != ".", id != ".." else { return false }
        let allowed = CharacterSet(
            charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_."
        )
        return id.unicodeScalars.allSatisfy(allowed.contains)
    }
}
