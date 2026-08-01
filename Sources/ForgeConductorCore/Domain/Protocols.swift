// Protocols.swift
// What: Declares the dependency-injection ports between Core modules.
// How: Narrow protocols separate configuration, stores, collectors, tools, telemetry,
// deployment, manager control, and connector side effects from concrete adapters.
// Why: New connectors or test doubles can be added without rewriting framework logic.

import Foundation

// MARK: - Layer contracts (dependency inversion)
// Wire formats (JSON-RPC / HTTP) may use dictionaries *only* at adapters.
// Domain and application code use these protocols and typed models exclusively.

// MARK: Clock
// Defined in Models.swift as `Clock`.

// MARK: Configuration

/// Reads and updates the persisted application configuration through typed accessors.
public protocol ConfigurationProviding: AnyObject, Sendable {
    func string(_ keys: String..., default defaultValue: String) -> String
    func int(_ keys: String..., default defaultValue: Int) -> Int
    func bool(_ keys: String..., default defaultValue: Bool) -> Bool
    @discardableResult
    func update(_ patch: [String: Any], save: Bool) throws -> [String: Any]
    func reload()
}

// MARK: Persistence

/// Persists heartbeat records used to discover live Forge clients and MCP servers.
public protocol PresenceStore: AnyObject, Sendable {
    func presenceRecords() throws -> [PresenceRecord]
    /// Edge adapter — prefer `presenceRecords()`.
    func presenceList() throws -> [[String: Any]]
    func presenceUpsert(clientID: String, hostKind: String, pid: Int32, cwd: String) throws
    func presenceDelete(clientID: String) throws
    func presencePrune(maxAgeSec: TimeInterval) throws -> Int
}

/// Collects current memory-pressure and physical-memory measurements.
public protocol RAMMetricsCollecting: Sendable {
    func collect() -> RAMMetrics
}

/// Collects mounted-volume capacity and utilization measurements.
public protocol DiskVolumeCollecting: Sendable {
    func collect() -> [DiskVolume]
}

/// Reads typed agent sessions without exposing the persistence implementation.
public protocol SessionStore: AnyObject, Sendable {
    func sessionList(agentID: String?, status: SessionStatus?) throws -> [AgentSession]
}

/// Reads the bounded audit history consumed by diagnostics and the live feed.
public protocol AuditReading: AnyObject, Sendable {
    func auditRecent(limit: Int) throws -> [AuditEvent]
}

// MARK: Catalog & tools

/// Resolves agent playbooks and recommends a playbook for a task description.
public protocol AgentCatalogProviding: AnyObject, Sendable {
    func all() -> [AgentSpec]
    func get(_ id: String) -> AgentSpec?
    func recommend(task: String) -> AgentSpec
}

/// Exposes a named tool collection behind a uniform invocation boundary.
public protocol ToolExecuting: AnyObject, Sendable {
    var toolNames: [String] { get }
    func call(name: String, arguments: [String: Any], clientID: ClientID) throws -> ToolResult
}

// MARK: Telemetry collectors (strict SRP)

/// Samples host-wide and per-logical-core CPU utilization.
public protocol CPUMetricsCollecting: Sendable {
    func collect() -> CPUMetrics
}

/// Samples installed GPUs and their available utilization and memory evidence.
public protocol GPUMetricsCollecting: Sendable {
    func collect() -> [GPUMetrics]
}

/// Samples aggregate storage read and write throughput.
public protocol DiskIOMetricsCollecting: Sendable {
    func collect() -> DiskIOMetrics
}

/// Samples resource usage for relevant Forge and model-host processes.
public protocol ProcessMetricsCollecting: Sendable {
    func collect() -> [ProcessMetrics]
}

/// IOKit IOPowerSources (`IOPSCopyPowerSourcesInfo` / list / description).
public protocol PowerMetricsCollecting: Sendable {
    func collect() -> PowerMetrics
}

/// Composes all host collectors into one internally consistent system frame.
public protocol SystemMetricsCollecting: Sendable {
    func collectMetrics() -> SystemMetrics
}

/// Collects Forge orchestration state independently from physical host telemetry.
public protocol ForgeMetricsCollecting: Sendable {
    func collect() -> ForgeSnapshot
}

/// Supplies cached and forced telemetry snapshots to application and transport layers.
public protocol TelemetryProviding: AnyObject, Sendable {
    /// Current live frame (host from continuous engine + last forge composition).
    /// Not a multi-second poll — call freely; host half is always the latest sample.
    func currentFrame() -> TelemetrySnapshot
    /// Edge compatibility: `force` recomposes forge once; otherwise same as `currentFrame()`.
    func snapshotTyped(force: Bool) throws -> TelemetrySnapshot
    func snapshot(force: Bool) throws -> [String: Any]
    func health() -> TelemetryHealthReport
    /// Starts continuous host sampling (~30 Hz) and forge recompose cadence.
    func startBackgroundRefresh(intervalSec: TimeInterval)
    func stopBackgroundRefresh()
    /// Continuous native host metrics stream (not a multi-second poll).
    var realtimeEngine: any RealtimeMetricsStreaming { get }
    /// Receive every live frame update (host sample rate when stream is running).
    @discardableResult
    func addListener(_ block: @escaping (TelemetrySnapshot) -> Void) -> UUID
    func removeListener(_ id: UUID)
}

/// Continuous system-metrics stream driven by native host sampling (CPU/RAM/GPU/disk/process).
public protocol RealtimeMetricsStreaming: AnyObject, Sendable {
    /// Most recent host sample (lock-free enough for UI read on main).
    var latestSystem: SystemMetrics { get }
    /// Configured sample rate (Hz).
    var targetSampleHz: Double { get }
    /// Actual samples completed in the last second.
    var measuredSampleHz: Double { get }
    var isRunning: Bool { get }
    func start(targetHz: Double)
    func stop()
    @discardableResult
    func addListener(_ block: @escaping (SystemMetrics) -> Void) -> UUID
    func removeListener(_ id: UUID)
}

/// Product: Deploy Forge stdio MCP (primary + failover) into LM Studio.
public protocol LMStudioDeploying: AnyObject, Sendable {
    func status(preferredBinary: URL?) -> LMStudioMCPPluginInstaller.PluginStatus
    func deploy(preferredBinary: URL?) throws -> LMStudioMCPPluginInstaller.InstallResult
    func resolveServeBinary(preferred: URL?) -> URL
}

/// Infrastructure port used by the LM Studio connector module. Keeping the
/// installer behind an interface makes deploy orchestration deterministic and
/// testable without touching an operator's live `~/.lmstudio` directory.
public protocol LMStudioPluginInstalling: Sendable {
    func status(preferredBinary: URL?) -> LMStudioMCPPluginInstaller.PluginStatus
    func install(preferredBinary: URL?) throws -> LMStudioMCPPluginInstaller.InstallResult
}

/// Process-boundary health check for one independently spawned connector role.
public protocol MCPServeVerifying: Sendable {
    func verify(
        binary: URL,
        home: URL,
        role: LMStudioConnectorRole,
        timeoutSec: TimeInterval
    ) throws -> MCPServeVerifier.Result
}

/// Application boundary for making a committed LM Studio configuration live.
/// The native implementation first allows hot reload, then gracefully relaunches
/// LM Studio if necessary, requires its synchronized configuration revision,
/// and records host-originated tool discovery when lazy plugins are active.
public protocol LMStudioHostActivating: Sendable {
    func activate(
        deploymentID: String,
        timeoutSec: TimeInterval
    ) throws -> LMStudioHostActivationResult
}

/// Flight-recorder diagnostics (persist + export).
public protocol DiagnosticRecording: AnyObject, Sendable {
    func info(_ event: String, _ fields: [String: String], category: DiagnosticCategory)
    func warn(_ event: String, _ fields: [String: String], category: DiagnosticCategory)
    func error(_ event: String, _ fields: [String: String], category: DiagnosticCategory)
    func recent(limit: Int) -> [DiagnosticEnvelope]
    func export(to directory: URL?, basename: String?) throws -> DiagnosticLog.ExportResult
}

// MARK: Manager

/// Controls the background manager lifecycle and exposes its current status.
public protocol ManagerControlling: AnyObject, Sendable {
    func statusModel() -> ManagerStatus
    func settingsModel() -> ManagerSettings
    func isServiceActive() -> Bool
    @discardableResult func startService() throws -> ManagerStatus
    @discardableResult func stopService() throws -> ManagerStatus
    @discardableResult func restartService() throws -> ManagerStatus
    @discardableResult func updateSettings(_ patch: ManagerSettingsPatch, apply: Bool) throws -> ManagerSettings
}

// MARK: Sessions application service

/// Applies application rules when pruning stale agent sessions.
public protocol SessionManaging: AnyObject, Sendable {
    func pruneStale() throws
}
