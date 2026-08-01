// TelemetryService.swift
// What: Coordinates host sampling, Forge composition, frame publication, and history.
// How: It owns the RealtimeMetricsEngine, periodically composes slower orchestration
// state, merges both into atomic LiveTelemetryFrames, and notifies registered listeners.
// Why: Consumers receive coherent frames without coupling to collector cadence or storage.

import Foundation

/// Telemetry facade: **continuous native host stream** + slower forge/MCP composition.
///
/// Product model is a **live stream**, not multi-second snapshots:
/// - Host metrics: `RealtimeMetricsEngine` samples ~30 Hz; every sample updates `currentFrame`
///   and notifies listeners.
/// - Forge/MCP cards: recomposed on a short utility cadence (does not gate host updates).
/// - UI / SSE: consume the stream; `snapshot*` APIs only mean “read the current live frame”
///   for edge/HTTP compatibility.
public final class TelemetryService: TelemetryProviding, @unchecked Sendable {
    public static let runtimeIdentifier = "swift-native-realtime"
    public let paths: AppPaths
    public let realtimeEngine: any RealtimeMetricsStreaming

    private let forgeCollector: any ForgeMetricsCollecting
    private let lock = NSLock()
    private var history: [HistoryPoint] = []
    private let historyMax = 900
    /// Latest live frame (host always current; forge last composed).
    private var liveFrame: TelemetrySnapshot?
    private var forgeTimer: DispatchSourceTimer?
    private let forgeQueue = DispatchQueue(label: "forge.telemetry.forge", qos: .utility)
    private var listeners: [UUID: (TelemetrySnapshot) -> Void] = [:]
    private var systemListenerID: UUID?
    private var lastForge: ForgeSnapshot?

    public init(
        paths: AppPaths,
        store: SQLiteStore,
        catalog: AgentCatalog,
        toolNames: @escaping () -> [String] = { [] },
        realtimeEngine: (any RealtimeMetricsStreaming)? = nil
    ) {
        self.paths = paths
        self.realtimeEngine = realtimeEngine ?? RealtimeMetricsEngine()
        self.forgeCollector = ForgeCollector(
            paths: paths,
            store: store,
            catalog: catalog,
            toolNames: toolNames
        )
    }

    public init(
        paths: AppPaths,
        systemCollector: any SystemMetricsCollecting,
        forgeCollector: any ForgeMetricsCollecting,
        realtimeEngine: (any RealtimeMetricsStreaming)? = nil
    ) {
        self.paths = paths
        self.realtimeEngine = realtimeEngine ?? RealtimeMetricsEngine(systemCollector: systemCollector)
        self.forgeCollector = forgeCollector
    }

    // MARK: - Lifecycle

    /// Starts continuous host sampling. `intervalSec` only controls forge/MCP recompose period.
    public func startBackgroundRefresh(intervalSec: TimeInterval = 0.5) {
        stopBackgroundRefresh()
        realtimeEngine.start(targetHz: RealtimeMetricsEngine.defaultTargetHz)

        systemListenerID = realtimeEngine.addListener { [weak self] system in
            self?.onSystemSample(system)
        }

        // Forge/MCP composition is utility work — never the host telemetry clock.
        let forgePeriod = max(0.25, intervalSec)
        let t = DispatchSource.makeTimerSource(queue: forgeQueue)
        t.schedule(
            deadline: .now(),
            repeating: .milliseconds(Int(forgePeriod * 1000)),
            leeway: .milliseconds(50)
        )
        t.setEventHandler { [weak self] in
            self?.recomposeForgeAndPublish()
        }
        t.resume()
        lock.lock()
        forgeTimer = t
        lock.unlock()

        // Seed a live frame immediately so listeners/SSE never wait for a snapshot poll.
        recomposeForgeAndPublish()
    }

    public func stopBackgroundRefresh() {
        if let id = systemListenerID {
            realtimeEngine.removeListener(id)
            systemListenerID = nil
        }
        realtimeEngine.stop()
        lock.lock()
        forgeTimer?.cancel()
        forgeTimer = nil
        lock.unlock()
    }

    @discardableResult
    public func addListener(_ block: @escaping (TelemetrySnapshot) -> Void) -> UUID {
        let id = UUID()
        lock.lock()
        listeners[id] = block
        lock.unlock()
        return id
    }

    public func removeListener(_ id: UUID) {
        lock.lock()
        listeners[id] = nil
        lock.unlock()
    }

    // MARK: - Live stream core

    private func onSystemSample(_ system: SystemMetrics) {
        lock.lock()
        let forge = lastForge ?? ForgeSnapshot.empty(home: paths.home.path)
        let point = HistoryPoint(
            ts: system.ts,
            cpu: system.cpu.percent,
            ram: system.ram.percent,
            gpu: system.gpu.first?.utilGPU,
            diskIO: system.diskIO.totalMBs,
            mcp: forge.mcpServers.count,
            orch: forge.orchestration.health
        )
        history.append(point)
        while history.count > historyMax { history.removeFirst() }
        let hist = Array(history.suffix(300))
        let frame = TelemetrySnapshot(
            system: system,
            forge: forge,
            updated: system.ts,
            history: hist,
            runtime: Self.runtimeIdentifier
        )
        liveFrame = frame
        let cbs = Array(listeners.values)
        lock.unlock()
        for cb in cbs { cb(frame) }
    }

    private func recomposeForgeAndPublish() {
        let forge = forgeCollector.collect()
        let system = realtimeEngine.latestSystem
        lock.lock()
        lastForge = forge
        history.append(
            HistoryPoint(
                ts: system.ts,
                cpu: system.cpu.percent,
                ram: system.ram.percent,
                gpu: system.gpu.first?.utilGPU,
                diskIO: system.diskIO.totalMBs,
                mcp: forge.mcpServers.count,
                orch: forge.orchestration.health
            )
        )
        while history.count > historyMax { history.removeFirst() }
        let hist = Array(history.suffix(300))
        let frame = TelemetrySnapshot(
            system: system,
            forge: forge,
            updated: system.ts,
            history: hist,
            runtime: Self.runtimeIdentifier
        )
        liveFrame = frame
        let cbs = Array(listeners.values)
        lock.unlock()
        for cb in cbs { cb(frame) }
    }

    // MARK: - Current live frame (edge / tests)

    /// Non-throwing read of the current live frame (host from engine, forge last composed).
    public func currentFrame() -> TelemetrySnapshot {
        lock.lock()
        if var frame = liveFrame {
            frame.system = realtimeEngine.latestSystem
            frame.history = Array(history.suffix(300))
            frame.updated = frame.system.ts
            lock.unlock()
            return frame
        }
        lock.unlock()
        let system = realtimeEngine.latestSystem
        let forge = lastForge ?? forgeCollector.collect()
        let frame = TelemetrySnapshot(
            system: system,
            forge: forge,
            updated: system.ts,
            history: [],
            runtime: Self.runtimeIdentifier
        )
        lock.lock()
        lastForge = forge
        liveFrame = frame
        lock.unlock()
        return frame
    }

    /// Compatibility: force=true recomposes forge once; otherwise returns live frame.
    public func snapshotTyped(force: Bool = false) throws -> TelemetrySnapshot {
        if force {
            recomposeForgeAndPublish()
        }
        return currentFrame()
    }

    public func snapshot(force: Bool = false) throws -> [String: Any] {
        try snapshotTyped(force: force).asDictionary()
    }

    public func health() -> TelemetryHealthReport {
        let hz = realtimeEngine.measuredSampleHz
        let target = realtimeEngine.targetSampleHz
        // ok = native telemetry is available (not whether the stream timer is currently armed).
        return TelemetryHealthReport(
            ok: true,
            service: "forge-telemetry",
            runtime: Self.runtimeIdentifier,
            interferesWithMCP: false,
            mode: realtimeEngine.isRunning ? "continuous-native" : "continuous-native-idle",
            collectors: "RealtimeMetricsEngine@\(String(format: "%.0f", target))Hz(meas \(String(format: "%.1f", hz)))+ForgeCollector",
            ui: "ForgeConductor.app TimelineView + Metal + SSE stream",
            nodeRequired: false
        )
    }

    public func healthDictionary() -> [String: Any] {
        var d = health().asDictionary()
        d["sample_hz_target"] = realtimeEngine.targetSampleHz
        d["sample_hz_measured"] = realtimeEngine.measuredSampleHz
        d["stream"] = "realtime"
        d["stream_running"] = realtimeEngine.isRunning
        return d
    }

    public func systemOnly(force: Bool = false) throws -> [String: Any] {
        realtimeEngine.latestSystem.asDictionary()
    }

    public func forgeOnly(force: Bool = false) throws -> [String: Any] {
        try snapshotTyped(force: force).forge.asDictionary()
    }

    public func loadStatic(_ relativePath: String) -> (Data, String)? {
        let cleaned = relativePath
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .replacingOccurrences(of: "..", with: "")
        let name = (cleaned as NSString).lastPathComponent
        let homeURL = staticDir.appendingPathComponent(cleaned)
        if let data = try? Data(contentsOf: homeURL) {
            return (data, contentType(for: name))
        }
        if let url = ResourceBundle.bundle.url(
            forResource: (name as NSString).deletingPathExtension,
            withExtension: (name as NSString).pathExtension,
            subdirectory: "TelemetryStatic"
        ), let data = try? Data(contentsOf: url) {
            return (data, contentType(for: name))
        }
        return nil
    }

    public var staticDir: URL {
        paths.home.appendingPathComponent("telemetry/static", isDirectory: true)
    }

    private func contentType(for name: String) -> String {
        switch (name as NSString).pathExtension.lowercased() {
        case "html": return "text/html; charset=utf-8"
        case "css": return "text/css; charset=utf-8"
        case "js": return "application/javascript; charset=utf-8"
        case "json": return "application/json; charset=utf-8"
        default: return "application/octet-stream"
        }
    }
}

public enum TelemetryError: Error, LocalizedError {
    case invalidExport(String)
    case missingExport(String)
    case nodeNotFound

    public var errorDescription: String? {
        switch self {
        case .invalidExport(let s): "Invalid telemetry export: \(s)"
        case .missingExport(let s): "Missing export script: \(s)"
        case .nodeNotFound: "Node.js not required (native collectors active)"
        }
    }
}

public enum TelemetryContract {
    public static let systemKeys: Set<String> = [
        "arch", "cpu", "disk", "disk_io", "gpu", "host", "platform", "processes", "ram", "ts",
    ]
    public static let forgeKeys: Set<String> = [
        "agents", "live_feed", "mcp_load", "mcp_servers", "mcp_tools",
        "orchestration", "presence", "presence_count", "ts",
    ]
    /// Current-frame keys (HTTP/JSON edge). Product delivery is the continuous stream.
    public static let snapshotKeys: Set<String> = ["system", "forge", "updated", "history"]

    public static let rigPanels: [String] = [
        "sys_strip", "load_trace", "cpu_cores", "gpu_cores", "storage", "orchestration",
        "mcp_servers", "mcp_tools", "sub_agents", "hot_processes", "live_stream",
    ]

    public static func validate(snapshot: [String: Any]) -> [String] {
        var missing: [String] = []
        for k in snapshotKeys where snapshot[k] == nil { missing.append("snapshot.\(k)") }
        if let system = snapshot["system"] as? [String: Any] {
            for k in systemKeys where system[k] == nil { missing.append("system.\(k)") }
            if let cpu = system["cpu"] as? [String: Any] {
                for k in ["percent", "per_cpu", "freq_mhz", "brand"] where cpu[k] == nil {
                    missing.append("system.cpu.\(k)")
                }
            }
            if let dio = system["disk_io"] as? [String: Any] {
                for k in ["read_mb_s", "write_mb_s", "total_mb_s"] where dio[k] == nil {
                    missing.append("system.disk_io.\(k)")
                }
            }
        } else {
            missing.append("system")
        }
        if let forge = snapshot["forge"] as? [String: Any] {
            for k in forgeKeys where forge[k] == nil { missing.append("forge.\(k)") }
        } else {
            missing.append("forge")
        }
        return missing
    }
}
