// ManagerNode.swift
// What: Owns the persistent control-plane service state and dashboard listener.
// How: A synchronized runtime starts/stops/restarts one DashboardServer, applies typed
// settings, exposes doctor/status data, and records every lifecycle transition.
// Why: Central ownership prevents port races between the app, CLI, and LaunchAgent.

import Foundation
import ObjectiveC

/// Lifecycle state of the supervised dashboard HTTP service.
public enum ManagerServiceState: String, Sendable, Codable {
    case stopped
    case starting
    case running
    case restarting
    case stopping
    case failed
}

/// Supervisor that keeps the dashboard control surface available.
/// Mutable process state lives in `ManagerRuntime` (SRP).
public final class ManagerNode: ManagerControlling, @unchecked Sendable {
    private static let presencePruneInterval: TimeInterval = 60
    private static let presenceMaxAge: TimeInterval = 120

    public let app: ForgeApp
    private let lock = NSLock()
    private let runtime = ManagerRuntime()

    public init(app: ForgeApp) {
        self.app = app
    }

    deinit {
        stopWatchdog()
        tearDownDashboard()
    }

    // MARK: - Public status (typed domain)

    public var isShutdownRequested: Bool {
        lock.lock(); defer { lock.unlock() }
        return runtime.shutdownRequested
    }

    public func statusModel() -> ManagerStatus {
        lock.lock()
        defer { lock.unlock() }
        let cfg = app.config.model
        let httpUp = runtime.isHTTPUp
        let uptime: Int? = runtime.startedAt.map { Int(Date().timeIntervalSince($0)) }
        return ManagerStatus(
            ok: true,
            isManager: true,
            state: runtime.state,
            desiredRunning: runtime.desiredRunning,
            httpListening: httpUp,
            serviceActive: runtime.state == .running && httpUp,
            pid: ProcessInfo.processInfo.processIdentifier,
            startedAt: runtime.startedAt,
            uptimeSec: uptime,
            restartCount: runtime.restartCount,
            lastError: runtime.lastError,
            autoRestart: cfg.manager.autoRestart,
            watchdogIntervalSec: cfg.manager.watchdogIntervalSec,
            openBrowserOnStart: cfg.manager.openBrowserOnStart,
            dashboardHost: cfg.dashboard.host,
            dashboardPort: cfg.dashboard.port,
            dashboardRefreshSec: cfg.dashboard.refreshIntervalSec,
            home: app.paths.home.path,
            version: ForgeApp.version
        )
    }

    public func settingsModel() -> ManagerSettings {
        let cfg = app.config.model
        return ManagerSettings(
            dashboardHost: cfg.dashboard.host,
            dashboardPort: cfg.dashboard.port,
            dashboardRefreshSec: cfg.dashboard.refreshIntervalSec,
            autoRestart: cfg.manager.autoRestart,
            watchdogIntervalSec: cfg.manager.watchdogIntervalSec,
            openBrowserOnStart: cfg.manager.openBrowserOnStart,
            sessionIdleTTLSec: cfg.sessions.idleTTLSec,
            shellTimeoutSec: cfg.shell.defaultTimeoutSec,
            logLevel: cfg.logLevel
        )
    }

    public func status() -> [String: Any] {
        statusModel().asDictionary().compactNSNull()
    }

    public func settings() -> [String: Any] {
        settingsModel().asDictionary()
    }

    public func isServiceActive() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return runtime.isServiceActive
    }

    // MARK: - Lifecycle controls

    @discardableResult
    public func startService() throws -> ManagerStatus {
        pruneStalePresenceIfDue(force: true)

        lock.lock()
        runtime.desiredRunning = true
        runtime.lastError = nil
        if runtime.state == .running, runtime.isHTTPUp {
            lock.unlock()
            return statusModel()
        }
        runtime.state = .starting
        lock.unlock()

        do {
            try bindAndStartDashboard()
            lock.lock()
            runtime.markRunning()
            lock.unlock()
            persistState()
            app.diagnostics.info("manager_service_started", ["url": dashboardURLString()])
            return statusModel()
        } catch {
            lock.lock()
            runtime.markFailed(error)
            lock.unlock()
            persistState()
            app.diagnostics.error("manager_service_start_failed", [
                "error": "\(error)",
            ], category: .manager)
            throw error
        }
    }

    @discardableResult
    public func stopService() throws -> ManagerStatus {
        lock.lock()
        runtime.desiredRunning = false
        runtime.state = .stopping
        runtime.markStopped()
        lock.unlock()
        persistState()
        app.diagnostics.info("manager_service_stopped", [:])
        return statusModel()
    }

    @discardableResult
    public func restartService() throws -> ManagerStatus {
        lock.lock()
        let count = runtime.beginRestart()
        lock.unlock()

        tearDownDashboard()
        Thread.sleep(forTimeInterval: 0.2)
        do {
            try bindAndStartDashboard()
            lock.lock()
            runtime.state = .running
            runtime.startedAt = Date()
            runtime.lastError = nil
            lock.unlock()
            persistState()
            app.diagnostics.info("manager_service_restarted", ["restart_count": "\(count)"])
            return statusModel()
        } catch {
            lock.lock()
            runtime.markFailed(error)
            lock.unlock()
            persistState()
            throw error
        }
    }

    @discardableResult
    public func updateSettings(_ patch: ManagerSettingsPatch, apply: Bool = true) throws -> ManagerSettings {
        _ = try updateSettingsDictionary(patch.asConfigPatch(), apply: apply)
        return settingsModel()
    }

    @discardableResult
    public func updateSettings(_ patch: [String: Any], apply: Bool = true) throws -> [String: Any] {
        try updateSettingsDictionary(patch, apply: apply)
    }

    private func updateSettingsDictionary(_ patch: [String: Any], apply: Bool) throws -> [String: Any] {
        let before = app.config.model.dashboard
        let normalized = ManagerSettingsNormalizer.normalize(patch)
        _ = try app.config.update(normalized, save: true)
        app.config.reload()
        let after = app.config.model.dashboard
        let bindChanged = before.host != after.host || before.port != after.port

        lock.lock()
        let want = runtime.desiredRunning
        lock.unlock()

        if apply && bindChanged && want {
            _ = try restartService()
        } else if apply {
            restartWatchdog()
        }

        app.diagnostics.info("manager_settings_updated", [
            "bind_changed": bindChanged ? "true" : "false",
        ])
        var out = settings()
        out["applied"] = apply
        out["bind_changed"] = bindChanged
        out["status"] = status()
        return out
    }

    public static func normalizeSettingsPatch(_ patch: [String: Any]) -> [String: Any] {
        ManagerSettingsNormalizer.normalize(patch)
    }

    public func requestShutdown(delayMs: Int = 300) {
        lock.lock()
        runtime.requestShutdown()
        lock.unlock()
        app.diagnostics.info("manager_shutdown_requested", [:])
        runtime.queue.asyncAfter(deadline: .now() + .milliseconds(delayMs)) { [weak self] in
            self?.halt()
        }
    }

    // MARK: - Run loop

    public func run(openBrowser: Bool = false) throws {
        if let existing = ManagerPIDFile.runningPID(paths: app.paths),
           existing != ProcessInfo.processInfo.processIdentifier {
            throw NSError(
                domain: "ManagerNode",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey:
                    "Manager already running (pid \(existing)). Use: forge-conductor manager stop"]
            )
        }

        try ManagerPIDFile.write(paths: app.paths)
        defer { ManagerPIDFile.remove(paths: app.paths) }

        app.diagnostics.info("manager_run_start", [
            "pid": "\(ProcessInfo.processInfo.processIdentifier)",
            "home": app.paths.home.path,
        ])

        try startService()

        let shouldOpen = openBrowser || app.config.model.manager.openBrowserOnStart
        if shouldOpen {
            openDashboardBrowser()
        }

        startWatchdog()
        installSignalHandlers()

        fputs("Forge-Conductor manager running — \(dashboardURLString())\n", stderr)
        fputs("  controls: Start / Stop / Restart / Settings on the dashboard\n", stderr)
        fputs("  stop process: forge-conductor manager stop   or dashboard Shutdown\n", stderr)

        runtime.runLock.wait()
    }

    private func halt() {
        stopWatchdog()
        tearDownDashboard()
        ManagerPIDFile.remove(paths: app.paths)
        lock.lock()
        runtime.markStopped()
        lock.unlock()
        persistState()
        runtime.runLock.signal()
        exit(0)
    }

    // MARK: - Dashboard binding

    private func bindAndStartDashboard() throws {
        app.config.reload()
        let host = app.config.model.dashboard.host
        let port = UInt16(clamping: app.config.model.dashboard.port)

        lock.lock()
        if let existing = runtime.dashboard, existing.isRunning,
           existing.boundHost == host, existing.boundPort == port {
            existing.manager = self
            lock.unlock()
            return
        }
        lock.unlock()

        tearDownDashboard()

        let server = DashboardServer(app: app, host: host, port: port)
        server.manager = self
        try server.start()

        lock.lock()
        runtime.dashboard = server
        lock.unlock()
    }

    private func tearDownDashboard() {
        lock.lock()
        let server = runtime.dashboard
        runtime.dashboard = nil
        lock.unlock()
        server?.manager = nil
        server?.stop()
    }

    private func dashboardURLString() -> String {
        let d = app.config.model.dashboard
        return "http://\(d.host):\(d.port)/"
    }

    private func openDashboardBrowser() {
        let runner = ProcessRunner()
        let url = dashboardURLString()
        let chrome = "/Applications/Google Chrome.app"
        if FileManager.default.fileExists(atPath: chrome) {
            _ = try? runner.run(
                executable: "/usr/bin/open",
                arguments: ["-a", "Google Chrome", url],
                timeoutSec: 5
            )
        } else {
            _ = try? runner.run(
                executable: "/usr/bin/open",
                arguments: [url],
                timeoutSec: 5
            )
        }
    }

    // MARK: - Watchdog

    private func startWatchdog() {
        stopWatchdog()
        let interval = max(1, app.config.model.manager.watchdogIntervalSec)
        let timer = DispatchSource.makeTimerSource(queue: runtime.queue)
        timer.schedule(deadline: .now() + .seconds(interval), repeating: .seconds(interval))
        timer.setEventHandler { [weak self] in
            self?.watchdogTick()
        }
        timer.resume()
        lock.lock()
        runtime.watchdog = timer
        lock.unlock()
    }

    private func restartWatchdog() {
        startWatchdog()
    }

    private func stopWatchdog() {
        lock.lock()
        runtime.watchdog?.cancel()
        runtime.watchdog = nil
        lock.unlock()
    }

    private func watchdogTick() {
        lock.lock()
        let want = runtime.desiredRunning
        let auto = app.config.model.manager.autoRestart
        let httpUp = runtime.isHTTPUp
        let shutting = runtime.shutdownRequested
        let current = runtime.state
        lock.unlock()

        if shutting { return }

        pruneStalePresenceIfDue()

        if !httpUp && !shutting {
            app.diagnostics.warn("manager_watchdog_http_recover", [
                "desired_running": want ? "true" : "false",
                "state": current.rawValue,
            ])
            do {
                try bindAndStartDashboard()
                lock.lock()
                if want {
                    runtime.markRunning()
                } else if runtime.state != .stopped {
                    runtime.markStopped()
                }
                runtime.restartCount += 1
                lock.unlock()
                persistState()
            } catch {
                lock.lock()
                runtime.markFailed(error)
                lock.unlock()
                persistState()
            }
            return
        }

        if want && auto && current == .failed && httpUp {
            lock.lock()
            runtime.markRunning()
            lock.unlock()
            persistState()
        }

        persistState()
    }

    private func pruneStalePresenceIfDue(force: Bool = false) {
        let now = app.clock.now()
        lock.lock()
        let claimed = force || runtime.claimPresencePrune(
            now: now,
            minimumInterval: Self.presencePruneInterval
        )
        if force {
            runtime.lastPresencePruneAt = now
        }
        lock.unlock()
        guard claimed else { return }

        do {
            let removed = try app.store.presencePrune(maxAgeSec: Self.presenceMaxAge)
            if removed > 0 {
                app.diagnostics.info("manager_presence_pruned", [
                    "removed": "\(removed)",
                    "max_age_sec": "\(Int(Self.presenceMaxAge))",
                ], category: .manager)
            }
        } catch {
            app.diagnostics.warn("manager_presence_prune_failed", [
                "error": error.localizedDescription,
            ], category: .manager)
        }
    }

    private func installSignalHandlers() {
        signal(SIGINT, SIG_IGN)
        signal(SIGTERM, SIG_IGN)
        let sigInt = DispatchSource.makeSignalSource(signal: SIGINT, queue: runtime.queue)
        let sigTerm = DispatchSource.makeSignalSource(signal: SIGTERM, queue: runtime.queue)
        sigInt.setEventHandler { [weak self] in self?.requestShutdown(delayMs: 50) }
        sigTerm.setEventHandler { [weak self] in self?.requestShutdown(delayMs: 50) }
        sigInt.resume()
        sigTerm.resume()
        lock.lock()
        runtime.signalSources = [sigInt, sigTerm]
        lock.unlock()
    }

    private func persistState() {
        let snap = status()
        if let data = try? JSONSupport.data(from: snap) {
            try? data.write(to: app.paths.managerState, options: .atomic)
        }
    }
}
