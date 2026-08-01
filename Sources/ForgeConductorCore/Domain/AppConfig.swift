// AppConfig.swift
// What: Defines the durable, typed configuration contract for every module.
// How: Codable nested values provide defaults, dictionary migration, patch merging,
// and validation without exposing persistence details to consumers.
// Why: One domain model prevents CLI, GUI, and manager settings from drifting.

import Foundation

/// Fully typed application configuration (Codable domain model).
/// Dictionaries exist only when merging legacy JSON patches at the store edge.
public struct AppConfig: Sendable, Equatable, Codable {
    public var logLevel: String
    public var allowedRoots: [String]
    public var shell: ShellConfig
    public var dashboard: DashboardConfig
    public var manager: ManagerConfigSection
    public var mcp: MCPConfig
    public var sessions: SessionsConfig
    public var coordinator: CoordinatorConfig

    public struct ShellConfig: Sendable, Equatable, Codable {
        public var defaultTimeoutSec: Int
        public init(defaultTimeoutSec: Int = 30) { self.defaultTimeoutSec = defaultTimeoutSec }

        enum CodingKeys: String, CodingKey { case defaultTimeoutSec = "default_timeout_sec" }
    }

    public struct DashboardConfig: Sendable, Equatable, Codable {
        public var host: String
        public var port: Int
        public var refreshIntervalSec: Int
        public init(host: String = "127.0.0.1", port: Int = 7788, refreshIntervalSec: Int = 8) {
            self.host = host
            self.port = port
            self.refreshIntervalSec = refreshIntervalSec
        }

        enum CodingKeys: String, CodingKey {
            case host, port
            case refreshIntervalSec = "refresh_interval_sec"
        }
    }

    public struct ManagerConfigSection: Sendable, Equatable, Codable {
        public var autoRestart: Bool
        public var watchdogIntervalSec: Int
        public var openBrowserOnStart: Bool
        public init(autoRestart: Bool = true, watchdogIntervalSec: Int = 3, openBrowserOnStart: Bool = false) {
            self.autoRestart = autoRestart
            self.watchdogIntervalSec = watchdogIntervalSec
            self.openBrowserOnStart = openBrowserOnStart
        }

        enum CodingKeys: String, CodingKey {
            case autoRestart = "auto_restart"
            case watchdogIntervalSec = "watchdog_interval_sec"
            case openBrowserOnStart = "open_browser_on_start"
        }
    }

    public struct MCPConfig: Sendable, Equatable, Codable {
        public var role: String
        public init(role: String = "primary") { self.role = role }
    }

    public struct SessionsConfig: Sendable, Equatable, Codable {
        public var idleTTLSec: Int
        public init(idleTTLSec: Int = 14_400) { self.idleTTLSec = idleTTLSec }
        enum CodingKeys: String, CodingKey { case idleTTLSec = "idle_ttl_sec" }
    }

    public struct CoordinatorConfig: Sendable, Equatable, Codable {
        public var enabled: Bool
        public var leaseTTLSec: Int
        public var presenceTTLSec: Int
        public init(enabled: Bool = true, leaseTTLSec: Int = 60, presenceTTLSec: Int = 30) {
            self.enabled = enabled
            self.leaseTTLSec = leaseTTLSec
            self.presenceTTLSec = presenceTTLSec
        }

        enum CodingKeys: String, CodingKey {
            case enabled
            case leaseTTLSec = "lease_ttl_sec"
            case presenceTTLSec = "presence_ttl_sec"
        }
    }

    public static let `default` = AppConfig(
        logLevel: "info",
        allowedRoots: [],
        shell: ShellConfig(),
        dashboard: DashboardConfig(),
        manager: ManagerConfigSection(),
        mcp: MCPConfig(),
        sessions: SessionsConfig(),
        coordinator: CoordinatorConfig()
    )

    public init(
        logLevel: String = "info",
        allowedRoots: [String] = [],
        shell: ShellConfig = ShellConfig(),
        dashboard: DashboardConfig = DashboardConfig(),
        manager: ManagerConfigSection = ManagerConfigSection(),
        mcp: MCPConfig = MCPConfig(),
        sessions: SessionsConfig = SessionsConfig(),
        coordinator: CoordinatorConfig = CoordinatorConfig()
    ) {
        self.logLevel = logLevel
        self.allowedRoots = allowedRoots
        self.shell = shell
        self.dashboard = dashboard
        self.manager = manager
        self.mcp = mcp
        self.sessions = sessions
        self.coordinator = coordinator
    }

    enum CodingKeys: String, CodingKey {
        case logLevel = "log_level"
        case allowedRoots = "allowed_roots"
        case shell, dashboard, manager, mcp, sessions, coordinator
    }

    /// Dictionary form for atomic JSON write / deep-merge edge.
    public func asDictionary() -> [String: Any] {
        [
            "log_level": logLevel,
            "allowed_roots": allowedRoots,
            "shell": ["default_timeout_sec": shell.defaultTimeoutSec] as [String: Any],
            "dashboard": [
                "host": dashboard.host,
                "port": dashboard.port,
                "refresh_interval_sec": dashboard.refreshIntervalSec,
            ] as [String: Any],
            "manager": [
                "auto_restart": manager.autoRestart,
                "watchdog_interval_sec": manager.watchdogIntervalSec,
                "open_browser_on_start": manager.openBrowserOnStart,
            ] as [String: Any],
            "mcp": ["role": mcp.role] as [String: Any],
            "sessions": ["idle_ttl_sec": sessions.idleTTLSec] as [String: Any],
            "coordinator": [
                "enabled": coordinator.enabled,
                "lease_ttl_sec": coordinator.leaseTTLSec,
                "presence_ttl_sec": coordinator.presenceTTLSec,
            ] as [String: Any],
        ]
    }

    public static func fromDictionary(_ dict: [String: Any]) -> AppConfig {
        var base = AppConfig.default
        if let v = dict["log_level"] as? String { base.logLevel = v }
        if let v = dict["allowed_roots"] as? [String] { base.allowedRoots = v }
        if let shell = dict["shell"] as? [String: Any] {
            if let t = shell["default_timeout_sec"] as? Int { base.shell.defaultTimeoutSec = t }
            else if let t = shell["default_timeout_sec"] as? Double { base.shell.defaultTimeoutSec = Int(t) }
        }
        if let dash = dict["dashboard"] as? [String: Any] {
            if let h = dash["host"] as? String { base.dashboard.host = h }
            if let p = dash["port"] as? Int { base.dashboard.port = p }
            else if let p = dash["port"] as? Double { base.dashboard.port = Int(p) }
            if let r = dash["refresh_interval_sec"] as? Int { base.dashboard.refreshIntervalSec = r }
            else if let r = dash["refresh_interval_sec"] as? Double { base.dashboard.refreshIntervalSec = Int(r) }
        }
        if let mgr = dict["manager"] as? [String: Any] {
            if let v = mgr["auto_restart"] as? Bool { base.manager.autoRestart = v }
            if let v = mgr["watchdog_interval_sec"] as? Int { base.manager.watchdogIntervalSec = v }
            else if let v = mgr["watchdog_interval_sec"] as? Double { base.manager.watchdogIntervalSec = Int(v) }
            if let v = mgr["open_browser_on_start"] as? Bool { base.manager.openBrowserOnStart = v }
        }
        if let mcp = dict["mcp"] as? [String: Any], let role = mcp["role"] as? String {
            base.mcp.role = role
        }
        if let sessions = dict["sessions"] as? [String: Any] {
            if let t = sessions["idle_ttl_sec"] as? Int { base.sessions.idleTTLSec = t }
            else if let t = sessions["idle_ttl_sec"] as? Double { base.sessions.idleTTLSec = Int(t) }
        }
        if let c = dict["coordinator"] as? [String: Any] {
            if let v = c["enabled"] as? Bool { base.coordinator.enabled = v }
            if let v = c["lease_ttl_sec"] as? Int { base.coordinator.leaseTTLSec = v }
            if let v = c["presence_ttl_sec"] as? Int { base.coordinator.presenceTTLSec = v }
        }
        return base
    }

    /// Apply a nested dictionary patch (legacy / HTTP) onto this model.
    public func applying(patch: [String: Any]) -> AppConfig {
        AppConfig.fromDictionary(deepMerge(asDictionary(), patch))
    }

    public func applying(settings: ManagerSettingsPatch) -> AppConfig {
        applying(patch: settings.asConfigPatch())
    }

    private func deepMerge(_ base: [String: Any], _ over: [String: Any]) -> [String: Any] {
        var out = base
        for (k, v) in over {
            if let bv = base[k] as? [String: Any], let ov = v as? [String: Any] {
                out[k] = deepMerge(bv, ov)
            } else {
                out[k] = v
            }
        }
        return out
    }
}
