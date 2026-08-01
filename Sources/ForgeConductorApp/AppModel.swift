// AppModel.swift
// What: The main-actor presentation model shared by every native app module.
// How: It composes Core services, transforms typed telemetry into view state,
// and serializes user actions through observable properties and controllers.
// Why: One presentation owner prevents views from duplicating lifecycle and I/O logic.

import Foundation
import Combine
import AppKit
import ForgeConductorCore
import SwiftUI

/// Owns the macOS app's observable state and coordinates every user-facing module.
///
/// Views read immutable projections from this model and send user intent back through
/// its methods. The model keeps process control, persistence, deployment, and telemetry
/// work inside Core services so the SwiftUI layer remains declarative and testable.
@MainActor
public final class AppModel: ObservableObject {
    @Published public private(set) var system: SystemMetrics?
    @Published public private(set) var forge: ForgeSnapshot?
    @Published public private(set) var history: [HistoryPoint] = []
    @Published public private(set) var updated: Date?
    @Published public private(set) var lastError: String?
    @Published public private(set) var isLoading = false
    @Published public private(set) var version: String = ForgeApp.version
    @Published public private(set) var homePath: String = ""
    @Published public private(set) var lastTyped: TelemetrySnapshot?
    @Published public private(set) var managerStatus: ManagerStatus?
    @Published public private(set) var managerMessage: String?
    @Published public private(set) var lmStudioPluginStatus: LMStudioMCPPluginInstaller.PluginStatus?
    @Published public private(set) var lmStudioPluginMessage: String?
    @Published public private(set) var isInstallingPlugin = false
    @Published public private(set) var diagnosticPreview: [DiagnosticEnvelope] = []
    @Published public private(set) var lastExportMessage: String?
    @Published public private(set) var measuredTelemetryHz: Double = 0
    @Published public var autoRefresh = true
    @Published public var selectedTab: AppTab = .rig
    @Published public var isNavigationVisible = true

    @Published public var setHost: String = "127.0.0.1"
    @Published public var setPort: Int = 7788
    @Published public var setRefresh: Int = 8
    @Published public var setWatchdog: Int = 3
    @Published public var setIdleTTL: Int = 14_400
    @Published public var setShellTimeout: Int = 30
    @Published public var setAutoRestart: Bool = true

    public private(set) var app: ForgeApp?
    public private(set) var manager: ManagerNode?
    public private(set) var remoteManager: ManagerDashboardClient?
    public private(set) var deployController: AppDeployController?
    public private(set) var telemetryBinding = AppTelemetryBinding()

    private var managerPoll: AnyCancellable?
    private var telemetryBag: AnyCancellable?
    private var managerPollInFlight = false
    private var remoteManagerLastError: String?

    public enum AppTab: String, CaseIterable, Identifiable {
        case rig = "FORGE RIG"
        case mcp = "LM Studio MCP"
        case agents = "Agents"
        case tools = "Tools"
        case feed = "Live Feed"
        case diagnostics = "Diagnostics"
        case manager = "Manager"

        public var id: String { rawValue }

        public var accessibilityID: String {
            switch self {
            case .rig: return "rig"
            case .mcp: return "mcp"
            case .agents: return "agents"
            case .tools: return "tools"
            case .feed: return "feed"
            case .diagnostics: return "diagnostics"
            case .manager: return "manager"
            }
        }
    }

    public init() {
        bootstrap()
        startManagerPoll()
        bindTelemetryMirror()
    }

    public func bootstrap() {
        do {
            let forgeApp = try ForgeApp.bootstrap()
            self.app = forgeApp
            self.homePath = forgeApp.paths.home.path
            self.version = ForgeApp.version
            self.deployController = AppDeployController(app: forgeApp)
            telemetryBinding.attach(app: forgeApp)
            if CommandLine.arguments.contains("--uitesting") {
                managerMessage = "Manager disabled during UI tests"
            } else {
                attachToOrStartManager(app: forgeApp)
            }
            loadSettingsFromConfig()
            refreshLMStudioPluginStatus()
            refreshDiagnosticsPreview()
            forgeApp.diagnostics.info("gui_bootstrap", [
                "version": ForgeApp.version,
                "home": forgeApp.paths.home.path,
            ], category: .ui)
            refresh(force: true)
        } catch {
            lastError = "Bootstrap failed: \(error)"
        }
    }

    /// A GUI is a presentation client when the LaunchAgent manager already
    /// owns the dashboard. Only one process is ever allowed to bind the port.
    private func attachToOrStartManager(app forgeApp: ForgeApp) {
        let host = forgeApp.config.model.dashboard.host
        let port = forgeApp.config.model.dashboard.port
        let currentPID = ProcessInfo.processInfo.processIdentifier
        var externalPID = ManagerPIDFile.runningPID(paths: forgeApp.paths)
        if externalPID == currentPID {
            externalPID = nil
        }

        if externalPID == nil {
            switch DashboardPortGuard.inspect(host: host, port: port, selfPID: currentPID) {
            case .heldByOtherForge(let holder):
                externalPID = holder.pid
            default:
                break
            }
        }

        if let externalPID {
            manager = nil
            remoteManager = ManagerDashboardClient(host: host, port: port)
            managerMessage = "Attached to manager (pid \(externalPID))"
            forgeApp.diagnostics.info("gui_attached_existing_manager", [
                "manager_pid": "\(externalPID)",
                "port": "\(port)",
            ], category: .manager)
            refreshRemoteManagerStatus()
            return
        }

        let node = ManagerNode(app: forgeApp)
        manager = node
        remoteManager = nil
        do {
            managerStatus = try node.startService()
            forgeApp.diagnostics.info("gui_dashboard_bound", [
                "port": "\(managerStatus?.dashboardPort ?? 0)",
                "pid": "\(currentPID)",
            ], category: .manager)
        } catch {
            managerStatus = node.statusModel()
            lastError = "Dashboard bind failed: \(error.localizedDescription)"
            managerMessage = lastError
            forgeApp.diagnostics.error("gui_dashboard_bind_failed", [
                "error": "\(error)",
            ], category: .manager)
        }
    }

    /// Mirror complete stream frames into AppModel published fields for views.
    /// Driven by one post-apply event per frame — no snapshot polling timer.
    private func bindTelemetryMirror() {
        telemetryBag?.cancel()
        telemetryBag = telemetryBinding.updates
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.syncFromTelemetryBinding()
            }
    }

    private func syncFromTelemetryBinding() {
        let b = telemetryBinding
        system = b.system
        forge = b.forge
        history = b.history
        updated = b.updated
        lastTyped = b.lastTyped
        measuredTelemetryHz = b.measuredHz
        isLoading = b.isLoading
        if let e = b.lastError { lastError = e }
    }

    public var preferredServeBinary: URL {
        deployController?.preferredServeBinary
            ?? app?.lmStudioDeploy.resolveServeBinary(preferred: Bundle.main.executableURL)
            ?? URL(fileURLWithPath: "/usr/bin/false")
    }

    public func refreshLMStudioPluginStatus() {
        lmStudioPluginStatus = deployController?.status()
            ?? app?.lmStudioDeploy.status(preferredBinary: preferredServeBinary)
    }

    public func deployToLMStudio() {
        guard !isInstallingPlugin, let forgeApp = app else { return }
        isInstallingPlugin = true
        lmStudioPluginMessage = nil
        let binary = preferredServeBinary
        Task { [weak self] in
            do {
                let result = try await Task.detached {
                    try forgeApp.lmStudioDeploy.deploy(preferredBinary: binary)
                }.value
                await MainActor.run {
                    self?.lmStudioPluginMessage = result.message
                    self?.refreshLMStudioPluginStatus()
                    self?.isInstallingPlugin = false
                    self?.refreshDiagnosticsPreview()
                    self?.refresh(force: true)
                }
            } catch {
                await MainActor.run {
                    self?.lmStudioPluginMessage = "Deploy failed: \(error.localizedDescription)"
                    self?.refreshLMStudioPluginStatus()
                    self?.isInstallingPlugin = false
                    self?.refreshDiagnosticsPreview()
                }
            }
        }
    }

    public func installLMStudioPlugin() { deployToLMStudio() }

    private func startManagerPoll() {
        managerPoll?.cancel()
        managerPoll = Timer.publish(every: 1.0, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                guard let self else { return }
                if let manager = self.manager {
                    self.managerStatus = manager.statusModel()
                } else {
                    self.refreshRemoteManagerStatus()
                }
            }
    }

    private func refreshRemoteManagerStatus() {
        guard let client = remoteManager, !managerPollInFlight else { return }
        managerPollInFlight = true
        Task { [weak self] in
            do {
                let status = try await client.status()
                guard let self else { return }
                self.managerStatus = status
                self.managerPollInFlight = false
                if self.remoteManagerLastError != nil {
                    self.managerMessage = "Manager connection restored"
                    self.app?.diagnostics.info("gui_manager_connection_restored", [
                        "port": "\(status.dashboardPort)",
                    ], category: .manager)
                }
                self.remoteManagerLastError = nil
            } catch {
                guard let self else { return }
                self.managerPollInFlight = false
                let detail = error.localizedDescription
                if self.remoteManagerLastError != detail {
                    self.managerMessage = "Manager connection unavailable: \(detail)"
                    self.app?.diagnostics.warn("gui_manager_connection_unavailable", [
                        "error": detail,
                    ], category: .manager)
                }
                self.remoteManagerLastError = detail
            }
        }
    }

    public func refresh(force: Bool) {
        telemetryBinding.autoRefresh = autoRefresh
        telemetryBinding.refresh(force: force)
        syncFromTelemetryBinding()
    }

    // MARK: - Diagnostics

    public func refreshDiagnosticsPreview() {
        diagnosticPreview = app?.diagnostics.recent(limit: 200) ?? []
    }

    public func exportDiagnostics() {
        guard let diagnostics = app?.diagnostics else {
            lastExportMessage = "App not bootstrapped"
            return
        }
        do {
            let panel = NSOpenPanel()
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.canCreateDirectories = true
            panel.prompt = "Export Here"
            panel.message = "Choose a folder for Forge Conductor diagnostics (.json + .md)"
            if let home = app?.paths.exportsDir {
                panel.directoryURL = home
            }
            guard panel.runModal() == .OK, let dir = panel.url else {
                lastExportMessage = "Export cancelled"
                return
            }
            let result = try diagnostics.export(to: dir, basename: nil)
            lastExportMessage =
                "Exported \(result.recordCount) records →\n\(result.jsonURL.path)\n\(result.markdownURL.path)"
            refreshDiagnosticsPreview()
        } catch {
            lastExportMessage = "Export failed: \(error.localizedDescription)"
            app?.diagnostics.error("diagnostics_export_failed", [
                "error": error.localizedDescription,
            ], category: .diagnostics)
        }
    }

    public func exportDiagnosticsToDefaultFolder() {
        guard let diagnostics = app?.diagnostics, let paths = app?.paths else { return }
        do {
            let result = try diagnostics.export(to: paths.exportsDir, basename: nil)
            lastExportMessage =
                "Exported \(result.recordCount) records →\n\(result.jsonURL.path)\n\(result.markdownURL.path)"
            NSWorkspace.shared.activateFileViewerSelecting([result.jsonURL, result.markdownURL])
            refreshDiagnosticsPreview()
        } catch {
            lastExportMessage = "Export failed: \(error.localizedDescription)"
        }
    }

    // MARK: - Accessors

    public var sysStrip: SysStripModel {
        if let s = system { return SysStripModel(from: s) }
        return SysStripModel(from: emptySystem())
    }

    public var perCPU: [Double] { system?.cpu.perCPU ?? [] }
    public var diskVolumes: [DiskVolume] { system?.disk ?? [] }
    public var diskIO: DiskIOMetrics {
        system?.diskIO
            ?? DiskIOMetrics(readMBs: 0, writeMBs: 0, totalMBs: 0, readIOPS: 0, writeIOPS: 0, totalIOPS: 0)
    }
    public var hotProcesses: [ProcessMetrics] { system?.processes ?? [] }
    public var historyCPU: [Float] { history.map { Float($0.cpu) } }
    public var historyRAM: [Float] { history.map { Float($0.ram) } }
    public var historyGPU: [Float?] {
        history.map { point in point.gpu.map(Float.init) }
    }
    public var cpuPercent: Double { system?.cpu.percent ?? 0 }
    public var ramPercent: Double { system?.ram.percent ?? 0 }
    public var gpuPercent: Double? { system?.gpu.first?.utilGPU }
    public var hostName: String { system?.host ?? "host" }

    public var mcpServerCards: [MCPServerCard] { forge?.mcpServers ?? [] }
    public var toolCards: [ToolCard] { forge?.mcpTools ?? [] }
    public var agentCards: [AgentCard] { forge?.agents ?? [] }
    public var toolPacks: [ToolPackSummary] { forge?.mcpPacks ?? [] }
    public var liveFeedEvents: [LiveFeedEvent] { forge?.liveFeed ?? [] }
    public var orchestration: OrchestrationStatus? { forge?.orchestration }

    public var serviceActive: Bool { managerStatus?.serviceActive ?? false }
    public var serviceState: String { managerStatus?.state.rawValue ?? "unknown" }
    public var managerRuntimeVersion: String { managerStatus?.version ?? "unavailable" }

    /// Manager bundles may append a build qualifier (for example, "-swift").
    /// Treat that as the same release while still exposing the exact runtime string.
    public var managerVersionIsCurrent: Bool? {
        guard let managerVersion = managerStatus?.version, !managerVersion.isEmpty else {
            return nil
        }
        return managerVersion == version || managerVersion.hasPrefix("\(version)-")
    }

    public var managerVersionNotice: String? {
        guard managerVersionIsCurrent == false else { return nil }
        return "The running manager is \(managerRuntimeVersion), while this app is \(version). Reinstall the login manager from this build before relying on runtime parity."
    }

    public var telemetryModeLabel: String {
        let target = app?.telemetry.realtimeEngine.targetSampleHz ?? RealtimeMetricsEngine.defaultTargetHz
        let meas = measuredTelemetryHz
        if meas > 0.5 {
            return String(format: "Real-time native · %.0f Hz target · %.1f Hz measured", target, meas)
        }
        return String(format: "Real-time native · %.0f Hz continuous", target)
    }

    // MARK: - Manager

    public func managerStart() {
        if let client = remoteManager {
            managerMessage = "Starting service…"
            Task { [weak self] in
                do {
                    let status = try await client.startService()
                    guard let self else { return }
                    self.managerStatus = status
                    self.managerMessage = "Service started"
                    self.app?.diagnostics.info("manager_start", ["via": "loopback"], category: .manager)
                    self.refresh(force: true)
                } catch {
                    self?.recordRemoteManagerFailure(action: "Start", error: error)
                }
            }
            return
        }
        guard let manager else {
            managerMessage = "Manager is unavailable"
            return
        }
        do {
            managerStatus = try manager.startService()
            managerMessage = "Service started"
            app?.diagnostics.info("manager_start", [:], category: .manager)
            refresh(force: true)
        } catch {
            managerMessage = "Start failed: \(error)"
            app?.diagnostics.error("manager_start_failed", ["error": "\(error)"], category: .manager)
        }
    }

    public func managerStop() {
        if let client = remoteManager {
            managerMessage = "Stopping service…"
            Task { [weak self] in
                do {
                    let status = try await client.stopService()
                    guard let self else { return }
                    self.managerStatus = status
                    self.managerMessage = "Service stopped (control plane stays available)"
                    self.app?.diagnostics.info("manager_stop", ["via": "loopback"], category: .manager)
                    self.refresh(force: true)
                } catch {
                    self?.recordRemoteManagerFailure(action: "Stop", error: error)
                }
            }
            return
        }
        guard let manager else {
            managerMessage = "Manager is unavailable"
            return
        }
        do {
            managerStatus = try manager.stopService()
            managerMessage = "Service stopped (control plane stays available)"
            app?.diagnostics.info("manager_stop", [:], category: .manager)
            refresh(force: true)
        } catch {
            managerMessage = "Stop failed: \(error)"
        }
    }

    public func managerRestart() {
        if let client = remoteManager {
            managerMessage = "Restarting service…"
            Task { [weak self] in
                do {
                    let status = try await client.restartService()
                    guard let self else { return }
                    self.managerStatus = status
                    self.managerMessage = "Service restarted"
                    self.app?.diagnostics.info("manager_restart", ["via": "loopback"], category: .manager)
                    self.refresh(force: true)
                } catch {
                    self?.recordRemoteManagerFailure(action: "Restart", error: error)
                }
            }
            return
        }
        guard let manager else {
            managerMessage = "Manager is unavailable"
            return
        }
        do {
            managerStatus = try manager.restartService()
            managerMessage = "Service restarted"
            app?.diagnostics.info("manager_restart", [:], category: .manager)
            refresh(force: true)
        } catch {
            managerMessage = "Restart failed: \(error)"
        }
    }

    public func loadSettingsFromConfig() {
        guard let app else { return }
        if let m = manager {
            let s = m.settingsModel()
            apply(settings: s)
            return
        }
        setHost = app.config.string("dashboard", "host", default: "127.0.0.1")
        setPort = app.config.int("dashboard", "port", default: 7788)
        setRefresh = app.config.int("dashboard", "refresh_interval_sec", default: 8)
        setWatchdog = app.config.int("manager", "watchdog_interval_sec", default: 3)
        setIdleTTL = app.config.int("sessions", "idle_ttl_sec", default: 14_400)
        setShellTimeout = app.config.int("shell", "default_timeout_sec", default: 30)
        setAutoRestart = app.config.bool("manager", "auto_restart", default: true)
        if let client = remoteManager {
            Task { [weak self] in
                do {
                    let settings = try await client.settings()
                    self?.apply(settings: settings)
                } catch {
                    self?.recordRemoteManagerFailure(action: "Load settings", error: error)
                }
            }
        }
    }

    public func saveSettings() {
        let patch = ManagerSettingsPatch(
            dashboardHost: setHost,
            dashboardPort: setPort,
            dashboardRefreshSec: setRefresh,
            autoRestart: setAutoRestart,
            watchdogIntervalSec: setWatchdog,
            sessionIdleTTLSec: setIdleTTL,
            shellTimeoutSec: setShellTimeout
        )
        if let client = remoteManager {
            managerMessage = "Saving settings…"
            Task { [weak self] in
                do {
                    let settings = try await client.updateSettings(patch, apply: true)
                    guard let self else { return }
                    self.apply(settings: settings)
                    self.remoteManager = ManagerDashboardClient(
                        host: settings.dashboardHost,
                        port: settings.dashboardPort
                    )
                    self.managerMessage = "Settings saved"
                    self.refreshRemoteManagerStatus()
                } catch {
                    self?.recordRemoteManagerFailure(action: "Settings", error: error)
                }
            }
            return
        }
        do {
            guard let manager else {
                managerMessage = "Manager is unavailable"
                return
            }
            _ = try manager.updateSettings(patch, apply: true)
            managerStatus = manager.statusModel()
            managerMessage = "Settings saved"
        } catch {
            managerMessage = "Settings failed: \(error.localizedDescription)"
        }
    }

    private func apply(settings: ManagerSettings) {
        setHost = settings.dashboardHost
        setPort = settings.dashboardPort
        setRefresh = settings.dashboardRefreshSec
        setWatchdog = settings.watchdogIntervalSec
        setIdleTTL = settings.sessionIdleTTLSec
        setShellTimeout = settings.shellTimeoutSec
        setAutoRestart = settings.autoRestart
    }

    private func recordRemoteManagerFailure(action: String, error: Error) {
        let detail = error.localizedDescription
        managerMessage = "\(action) failed: \(detail)"
        app?.diagnostics.error("gui_manager_action_failed", [
            "action": action,
            "error": detail,
        ], category: .manager)
    }

    public func toggleNavigation() {
        isNavigationVisible.toggle()
    }

    public func selectTab(_ tab: AppTab) {
        guard selectedTab != tab else { return }
        selectedTab = tab
        app?.diagnostics.info("ui_navigation_selected", [
            "tab": tab.accessibilityID,
        ], category: .ui)
    }

    public func runDoctor() -> DoctorReport? { try? app?.doctorModel() }
    public func runDoctorDictionary() -> [String: Any]? { try? app?.doctor() }

    public func prunePresence() {
        _ = try? app?.store.presencePrune(maxAgeSec: 60)
        app?.diagnostics.info("presence_pruned", [:], category: .mcp)
        refresh(force: true)
    }

    public func pruneSessions() {
        try? app?.sessions.pruneStale()
        app?.diagnostics.info("sessions_pruned", [:], category: .agent)
        refresh(force: true)
    }

    private func emptySystem() -> SystemMetrics {
        SystemMetrics(
            ts: 0, host: "—", platform: "darwin", arch: "—",
            cpu: CPUMetrics(
                percent: 0, perCPU: [], countLogical: 0, countPhysical: 0,
                freqMHz: nil, freqPerCoreMHz: nil, loadAvg: (0, 0, 0),
                brand: "—", user: 0, system: 0, idle: 100
            ),
            ram: RAMMetrics(
                totalGB: 0, usedGB: 0, availableGB: 0, percent: 0,
                pressurePercent: 0, activeGB: 0, wiredGB: 0, compressedGB: 0
            ),
            disk: [],
            diskIO: DiskIOMetrics(readMBs: 0, writeMBs: 0, totalMBs: 0, readIOPS: 0, writeIOPS: 0, totalIOPS: 0),
            gpu: [],
            processes: [],
            power: .unknown
        )
    }
}
