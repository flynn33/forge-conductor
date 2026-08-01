// LMStudioConnector.swift
// What: Defines connector roles, per-role health, aggregate state, and host activation.
// How: Typed value objects derive fail-forward status from independent primary/fallback
// observations without depending on filesystem or process implementations.
// Why: Connector policy remains portable and testable apart from LM Studio integration code.

import Foundation

/// The two independently launched stdio connections installed into LM Studio.
///
/// Roles are values rather than free-form strings so deployment, health checks,
/// diagnostics, and the MCP server cannot silently disagree about identity.
public enum LMStudioConnectorRole: String, CaseIterable, Codable, Sendable {
    case primary
    case fallback

    public init(environmentValue: String?) {
        self = Self(rawValue: environmentValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
            ?? .primary
    }

    public var serverID: String {
        switch self {
        case .primary: LMStudioEnvironment.primaryServerID
        case .fallback: LMStudioEnvironment.fallbackServerID
        }
    }

    public var hostKind: String {
        switch self {
        case .primary: "mcp-stdio"
        case .fallback: "mcp-stdio-fallback"
        }
    }
}

/// Evidence collected for one connection role during deployment.
public struct LMStudioConnectorHealth: Sendable, Equatable {
    public var role: LMStudioConnectorRole
    public var isReady: Bool
    public var protocolVersion: String?
    public var toolCount: Int
    public var detail: String

    public init(
        role: LMStudioConnectorRole,
        isReady: Bool,
        protocolVersion: String?,
        toolCount: Int,
        detail: String
    ) {
        self.role = role
        self.isReady = isReady
        self.protocolVersion = protocolVersion
        self.toolCount = toolCount
        self.detail = detail
    }
}

/// Aggregate health is deliberately degraded rather than binary: one live role
/// keeps the service observable while repair is attempted on the other role.
public enum LMStudioConnectionState: String, Codable, Sendable {
    case ready
    case primaryOnly = "primary_only"
    case fallbackPromoted = "fallback_promoted"
    case unavailable
}

public struct LMStudioConnectionHealth: Sendable, Equatable {
    public var roles: [LMStudioConnectorHealth]

    public init(roles: [LMStudioConnectorHealth]) {
        self.roles = roles.sorted { $0.role.rawValue < $1.role.rawValue }
    }

    public var state: LMStudioConnectionState {
        let primary = roles.first(where: { $0.role == .primary })?.isReady == true
        let fallback = roles.first(where: { $0.role == .fallback })?.isReady == true
        switch (primary, fallback) {
        case (true, true): return .ready
        case (true, false): return .primaryOnly
        case (false, true): return .fallbackPromoted
        case (false, false): return .unavailable
        }
    }

    public var isStable: Bool { state == .ready }
    public var hasService: Bool { state != .unavailable }
}

/// Evidence that LM Studio itself—not merely Forge's standalone verifier—loaded
/// the newly written configuration and completed MCP discovery for both roles.
public struct LMStudioHostActivationResult: Sendable, Equatable {
    public var deploymentID: String
    public var runningBeforeDeploy: Bool
    public var launched: Bool
    public var restarted: Bool
    public var configurationSynced: Bool
    public var readyRoles: [String]
    public var detail: String

    public init(
        deploymentID: String,
        runningBeforeDeploy: Bool,
        launched: Bool,
        restarted: Bool,
        configurationSynced: Bool,
        readyRoles: [String],
        detail: String
    ) {
        self.deploymentID = deploymentID
        self.runningBeforeDeploy = runningBeforeDeploy
        self.launched = launched
        self.restarted = restarted
        self.configurationSynced = configurationSynced
        self.readyRoles = readyRoles.sorted()
        self.detail = detail
    }

    /// LM Studio lazily starts MCP processes when a chat selects a plugin. A
    /// synchronized host configuration is therefore the deployment contract;
    /// `readyRoles` records stronger runtime evidence when the host starts them.
    public var isReady: Bool { configurationSynced }

    public var allRolesConnected: Bool {
        Set(readyRoles) == Set(LMStudioConnectorRole.allCases.map(\.rawValue))
    }
}
