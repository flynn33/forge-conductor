// LMStudioDeployService.swift
// What: Orchestrates the complete primary/fallback LM Studio deployment transaction.
// How: It resolves and pre-smokes a binary, commits both connector registrations,
// activates the host, post-smokes each role, derives health, logs, and rolls back on failure.
// Why: Users need one fail-closed operation rather than several partially applied steps.

import Foundation
import AppKit
import Darwin

/// Product service: Deploy Forge Conductor stdio MCP into LM Studio.
///
/// Installs **primary** (main) and **fallback** (failover) mcpBridge plugins and
/// matching `~/.lmstudio/mcp.json` entries so LM Studio can spawn:
/// `Forge Conductor serve` with `FORGE_MCP_ROLE=primary|fallback`.
///
/// After writing config, runs a local MCP smoke (initialize + tools/list) against the
/// registered binary so Deploy fails closed if the product cannot serve.
public final class LMStudioDeployService: LMStudioDeploying, @unchecked Sendable {
    private let paths: AppPaths
    private let diagnostics: any DiagnosticRecording
    private let store: SQLiteStore?
    private let installer: any LMStudioPluginInstalling
    private let verifier: any MCPServeVerifying
    private let hostActivator: any LMStudioHostActivating

    public init(
        paths: AppPaths,
        diagnostics: any DiagnosticRecording,
        store: SQLiteStore? = nil,
        installer: any LMStudioPluginInstalling = NativeLMStudioPluginInstaller(),
        verifier: any MCPServeVerifying = NativeMCPServeVerifier(),
        hostActivator: (any LMStudioHostActivating)? = nil
    ) {
        self.paths = paths
        self.diagnostics = diagnostics
        self.store = store
        self.installer = installer
        self.verifier = verifier
        self.hostActivator = hostActivator ?? NativeLMStudioHostActivator(paths: paths)
    }

    /// Prefer the **running app executable** when this is Forge Conductor (product path).
    /// Then home install app, then CLI.
    public func resolveServeBinary(preferred: URL? = nil) -> URL {
        if let preferred {
            // Explicit override: do not silently fall back (tests and operator --binary).
            return preferred.resolvingSymlinksInPath()
        }

        // 1) Running GUI / process (Deploy from the app the operator is using)
        if let running = Bundle.main.executableURL,
           FileManager.default.isExecutableFile(atPath: running.path),
           isForgeExecutable(running) {
            return running.resolvingSymlinksInPath()
        }

        let home = paths.home
        let candidates: [URL] = [
            home.appendingPathComponent("Forge Conductor.app/Contents/MacOS/Forge Conductor"),
            home.appendingPathComponent("bin/forge-conductor"),
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".local/bin/forge-conductor-swift"),
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".forge-conductor/bin/forge-conductor"),
        ]

        for url in candidates {
            let resolved = url.resolvingSymlinksInPath()
            if FileManager.default.isExecutableFile(atPath: resolved.path) {
                return resolved
            }
        }
        return candidates[0]
    }

    private func isForgeExecutable(_ url: URL) -> Bool {
        let leaf = url.lastPathComponent
        if leaf == "Forge Conductor" || leaf == "forge-conductor" { return true }
        if let bid = Bundle.main.bundleIdentifier, bid.contains("forge-conductor") { return true }
        return url.path.contains("Forge Conductor.app") || url.path.contains("Forge-Conductor")
    }

    public func status(preferredBinary: URL? = nil) -> LMStudioMCPPluginInstaller.PluginStatus {
        let binary = resolveServeBinary(preferred: preferredBinary)
        return installer.status(preferredBinary: binary)
    }

    /// Full deploy: write primary+failover, smoke-verify serve, log every step.
    @discardableResult
    public func deploy(preferredBinary: URL? = nil) throws -> LMStudioMCPPluginInstaller.InstallResult {
        let binary = resolveServeBinary(preferred: preferredBinary)
        diagnostics.info("deploy_begin", [
            "binary": binary.path,
            "lmstudio_present": LMStudioEnvironment.isAppInstalled ? "true" : "false",
            "bundle_id": Bundle.main.bundleIdentifier ?? "(none)",
        ], category: .lmstudio)

        guard FileManager.default.isExecutableFile(atPath: binary.path) else {
            diagnostics.error("deploy_binary_missing", ["path": binary.path], category: .lmstudio)
            throw DeployError.binaryNotExecutable(binary.path)
        }

        if !LMStudioEnvironment.isAppInstalled {
            diagnostics.warn("deploy_lmstudio_app_missing", [
                "hint": "Install LM Studio to /Applications first",
            ], category: .lmstudio)
        }

        if let store {
            let n = (try? store.presencePrune(maxAgeSec: 30)) ?? 0
            diagnostics.info("deploy_presence_prune", ["removed": "\(n)"], category: .mcp)
        }

        // Prove both independent roles before touching the active LM Studio
        // configuration. A role-specific startup defect must not be installed.
        let preHealth = verifyConnections(binary: binary, phase: "pre")
        guard preHealth.isStable else {
            let detail = healthDetail(preHealth)
            diagnostics.error("deploy_smoke_pre_failed", [
                "state": preHealth.state.rawValue,
                "detail": detail,
            ], category: .mcp)
            throw DeployError.smokeFailed(detail)
        }

        do {
            let result = try installer.install(preferredBinary: binary)
            diagnostics.info("deploy_plugins_written", [
                "plugins": result.pluginsWritten.joined(separator: ","),
                "mcp_json": result.mcpConfigPath,
                "ok": result.ok ? "true" : "false",
            ], category: .lmstudio)

            // Verify both installed identities. If only fallback survives, report
            // a promoted degraded state and keep it serving instead of tearing it down.
            let postHealth = verifyConnections(binary: binary, phase: "post")

            var hostActivation: LMStudioHostActivationResult?
            if result.ok && postHealth.isStable {
                hostActivation = try hostActivator.activate(
                    deploymentID: result.deploymentID,
                    timeoutSec: 24
                )
                if let hostActivation {
                    diagnostics.info("deploy_host_activated", [
                        "deployment_id": hostActivation.deploymentID,
                        "running_before": hostActivation.runningBeforeDeploy ? "true" : "false",
                        "launched": hostActivation.launched ? "true" : "false",
                        "restarted": hostActivation.restarted ? "true" : "false",
                        "configuration_synced": hostActivation.configurationSynced ? "true" : "false",
                        "roles": hostActivation.readyRoles.joined(separator: ","),
                        "detail": hostActivation.detail,
                    ], category: .lmstudio)
                }
            }

            let st = installer.status(preferredBinary: binary)
            let minimumToolCount = postHealth.roles.map(\.toolCount).min() ?? 0
            diagnostics.info("deploy_status", [
                "primary": st.primaryPluginInstalled ? "ok" : "missing",
                "fallback": st.fallbackPluginInstalled ? "ok" : "missing",
                "mcp_json": st.mcpJSONRegistered ? "ok" : "missing",
                "detail": st.detail,
                "connection_state": postHealth.state.rawValue,
                "smoke_tools_min": "\(minimumToolCount)",
            ], category: .lmstudio)

            let fullyOK = result.ok && postHealth.isStable && hostActivation?.isReady == true
            if !fullyOK {
                let detail = postHealth.hasService ? healthDetail(postHealth) : st.detail
                diagnostics.error("deploy_partial", ["detail": detail], category: .lmstudio)
                if !postHealth.hasService {
                    throw DeployError.smokeFailed(healthDetail(postHealth))
                }
            } else {
                diagnostics.info("deploy_complete", [
                    "binary": binary.path,
                    "deployment_id": result.deploymentID,
                    "tools_min": "\(minimumToolCount)",
                    "protocol": postHealth.roles.first?.protocolVersion ?? "",
                    "host_activation": hostActivation?.detail ?? "missing",
                ], category: .lmstudio)
            }

            let hostSummary: String
            if hostActivation?.allRolesConnected == true {
                hostSummary = "LM Studio synchronized revision \(result.deploymentID) and connected both hosted roles"
            } else {
                hostSummary = "LM Studio synchronized primary+failover revision \(result.deploymentID); hosted processes will start lazily when selected by a chat"
            }

            // Return install result; message distinguishes host configuration
            // synchronization from standalone per-role process verification.
            return LMStudioMCPPluginInstaller.InstallResult(
                ok: fullyOK,
                binaryPath: result.binaryPath,
                pluginsWritten: result.pluginsWritten,
                mcpConfigPath: result.mcpConfigPath,
                deploymentID: result.deploymentID,
                message: fullyOK
                    ? "Deployment complete: \(hostSummary). Standalone verification passed with at least \(minimumToolCount) tools per role."
                    : "Deployed in degraded state \(postHealth.state.rawValue): \(healthDetail(postHealth))"
            )
        } catch let e as DeployError {
            throw e
        } catch {
            diagnostics.error("deploy_failed", ["error": "\(error)"], category: .lmstudio)
            throw error
        }
    }

    private func verifyConnections(binary: URL, phase: String) -> LMStudioConnectionHealth {
        let roles = LMStudioConnectorRole.allCases.map { role -> LMStudioConnectorHealth in
            do {
                let result = try verifier.verify(
                    binary: binary,
                    home: paths.home,
                    role: role,
                    timeoutSec: 8
                )
                diagnostics.info("deploy_smoke_\(phase)", [
                    "role": role.rawValue,
                    "ok": result.ok ? "true" : "false",
                    "server": result.serverName ?? "nil",
                    "protocol": result.protocolVersion ?? "nil",
                    "tools": "\(result.toolCount)",
                    "ms": "\(result.durationMs)",
                    "detail": result.detail,
                ], category: .mcp)
                return LMStudioConnectorHealth(
                    role: role,
                    isReady: result.ok && result.serverName == role.serverID,
                    protocolVersion: result.protocolVersion,
                    toolCount: result.toolCount,
                    detail: result.detail
                )
            } catch {
                let detail = error.localizedDescription
                diagnostics.error("deploy_smoke_\(phase)_error", [
                    "role": role.rawValue,
                    "detail": detail,
                ], category: .mcp)
                return LMStudioConnectorHealth(
                    role: role,
                    isReady: false,
                    protocolVersion: nil,
                    toolCount: 0,
                    detail: detail
                )
            }
        }
        return LMStudioConnectionHealth(roles: roles)
    }

    private func healthDetail(_ health: LMStudioConnectionHealth) -> String {
        health.roles
            .map { "\($0.role.rawValue)=\($0.isReady ? "ready" : "failed")(\($0.detail))" }
            .joined(separator: "; ")
    }

    public enum DeployError: Error, LocalizedError {
        case binaryNotExecutable(String)
        case smokeFailed(String)
        case hostActivationFailed(String)
        public var errorDescription: String? {
            switch self {
            case .binaryNotExecutable(let p):
                "Forge serve binary not executable at \(p). Build and install Forge Conductor first."
            case .smokeFailed(let d):
                "MCP serve smoke failed: \(d)"
            case .hostActivationFailed(let d):
                "LM Studio did not activate the committed MCP configuration: \(d)"
            }
        }
    }
}

/// Native macOS controller that makes a committed `mcp.json` revision live.
/// A unique revision normally causes LM Studio to hot-reload its MCP processes.
/// If the host does not acknowledge both roles, it is gracefully relaunched and
/// checked again. Success requires LM Studio's synchronized copy of the exact
/// committed revision; host-originated `tools/list` is captured when lazy MCP
/// processes are active for a chat.
public final class NativeLMStudioHostActivator: LMStudioHostActivating, @unchecked Sendable {
    public static let bundleIdentifier = "ai.elementlabs.lmstudio"
    public static let applicationName = "LM Studio"

    private let diagnosticURL: URL
    private let syncedConfigurationURL: URL
    private let applicationURL: URL

    public init(
        paths: AppPaths,
        applicationURL: URL = URL(fileURLWithPath: LMStudioEnvironment.appBundlePath)
    ) {
        self.diagnosticURL = paths.masterDiagnostics
        self.syncedConfigurationURL = LMStudioEnvironment.homeDir
            .appendingPathComponent(".internal/last-synced-mcp-state.json")
        self.applicationURL = applicationURL
    }

    public func activate(
        deploymentID: String,
        timeoutSec: TimeInterval
    ) throws -> LMStudioHostActivationResult {
        guard !deploymentID.isEmpty else {
            throw HostActivationError.invalidDeploymentID
        }
        guard FileManager.default.fileExists(atPath: applicationURL.path) else {
            throw HostActivationError.appMissing(applicationURL.path)
        }

        let runningBefore = isLMStudioRunning()
        var launched = false
        var restarted = false

        if !runningBefore {
            try launch()
            launched = true
        }

        // LM Studio watches mcp.json. Give the versioned config a short window
        // to hot-reload before taking the more disruptive relaunch path.
        let hotReloadBudget = min(8, max(3, timeoutSec * 0.35))
        var roles = waitForReadyRoles(deploymentID: deploymentID, timeoutSec: hotReloadBudget)
        if roles.count == LMStudioConnectorRole.allCases.count {
            return result(
                deploymentID: deploymentID,
                runningBefore: runningBefore,
                launched: launched,
                restarted: restarted,
                roles: roles,
                configurationSynced: true,
                detail: runningBefore ? "LM Studio hot-reloaded the versioned MCP configuration" : "LM Studio launched and loaded the MCP configuration"
            )
        }

        // A newly launched host has no stale Forge child to replace. LM Studio
        // starts MCP processes lazily when a chat selects them, so synchronized
        // configuration is sufficient even when no tool provider starts yet.
        if !runningBefore,
           waitForConfigurationSync(deploymentID: deploymentID, timeoutSec: 6) {
            return result(
                deploymentID: deploymentID,
                runningBefore: runningBefore,
                launched: launched,
                restarted: restarted,
                roles: roles,
                configurationSynced: true,
                detail: "LM Studio launched and synchronized both MCP registrations; connections are ready for lazy chat activation"
            )
        }

        try relaunch()
        launched = true
        restarted = true
        let remainingBudget = max(6, timeoutSec - hotReloadBudget - 6)
        roles = waitForReadyRoles(deploymentID: deploymentID, timeoutSec: remainingBudget)
        let synchronized = waitForConfigurationSync(deploymentID: deploymentID, timeoutSec: 6)
        guard synchronized, isLMStudioRunning() else {
            throw HostActivationError.rolesNotReady(
                deploymentID: deploymentID,
                roles: roles.sorted(),
                expected: LMStudioConnectorRole.allCases.map(\.rawValue).sorted()
            )
        }
        return result(
            deploymentID: deploymentID,
            runningBefore: runningBefore,
            launched: launched,
            restarted: restarted,
            roles: roles,
            configurationSynced: true,
            detail: roles.count == LMStudioConnectorRole.allCases.count
                ? "LM Studio was relaunched and connected both MCP roles"
                : "LM Studio was relaunched and synchronized both MCP registrations; connections are ready for lazy chat activation"
        )
    }

    private func result(
        deploymentID: String,
        runningBefore: Bool,
        launched: Bool,
        restarted: Bool,
        roles: Set<String>,
        configurationSynced: Bool,
        detail: String
    ) -> LMStudioHostActivationResult {
        LMStudioHostActivationResult(
            deploymentID: deploymentID,
            runningBeforeDeploy: runningBefore,
            launched: launched,
            restarted: restarted,
            configurationSynced: configurationSynced,
            readyRoles: roles.sorted(),
            detail: detail
        )
    }

    private func runningApplications() -> [NSRunningApplication] {
        NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleIdentifier)
            .filter { !$0.isTerminated }
    }

    /// Launch Services does not always expose Electron applications through
    /// `NSRunningApplication.runningApplications(withBundleIdentifier:)` to a
    /// headless CLI process. Fall back to an exact executable-name lookup and
    /// retain only concrete positive PIDs; no wildcard process matching.
    private func runningPIDs() -> Set<Int32> {
        var pids = Set(runningApplications().map(\.processIdentifier))
        if let result = try? ProcessRunner().run(
            executable: "/usr/bin/pgrep",
            arguments: ["-x", "LM Studio"],
            timeoutSec: 2,
            maximumOutputBytes: 4_096
        ), result.exitCode == 0 {
            for line in result.stdout.split(whereSeparator: \.isNewline) {
                if let pid = Int32(line.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 1 {
                    pids.insert(pid)
                }
            }
        }
        return pids
    }

    private func isLMStudioRunning() -> Bool {
        // This AppleScript predicate queries Launch Services without launching
        // the app and remains available when process enumeration is restricted.
        if let result = try? ProcessRunner().run(
            executable: "/usr/bin/osascript",
            arguments: ["-e", "application \"\(Self.applicationName)\" is running"],
            timeoutSec: 3,
            maximumOutputBytes: 4_096
        ), result.exitCode == 0 {
            return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "true"
        }
        return !runningPIDs().isEmpty
    }

    private func launch() throws {
        var failures: [String] = []

        // `/usr/bin/open` is Apple's Launch Services client. Bundle-ID launch is
        // more reliable for LM Studio's Electron bundle than opening its path,
        // which can incorrectly return "corrupt" from a headless CLI process.
        do {
            let result = try ProcessRunner().run(
                executable: "/usr/bin/open",
                arguments: ["-a", Self.applicationName],
                timeoutSec: 8,
                maximumOutputBytes: 16_384
            )
            if result.exitCode == 0, !result.timedOut { return }
            failures.append("open: \(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
        } catch {
            failures.append("open: \(error.localizedDescription)")
        }

        // Launch Services registrations can be stale after an app update.
        // AppleScript resolves the same fixed bundle ID through macOS and proved
        // reliable on this host; arguments are constants, never operator input.
        do {
            let result = try ProcessRunner().run(
                executable: "/usr/bin/osascript",
                arguments: ["-e", "tell application \"\(Self.applicationName)\" to activate"],
                timeoutSec: 8,
                maximumOutputBytes: 16_384
            )
            if result.exitCode == 0, !result.timedOut { return }
            failures.append("osascript: \(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
        } catch {
            failures.append("osascript: \(error.localizedDescription)")
        }
        throw HostActivationError.launchFailed(failures.joined(separator: "; "))
    }

    private func relaunch() throws {
        // A graceful application-level quit works even when the caller cannot
        // enumerate Electron's process through NSWorkspace/pgrep.
        _ = try? ProcessRunner().run(
            executable: "/usr/bin/osascript",
            arguments: ["-e", "tell application \"\(Self.applicationName)\" to quit"],
            timeoutSec: 6,
            maximumOutputBytes: 4_096
        )
        let applications = runningApplications()
        let appPIDs = Set(applications.map(\.processIdentifier))
        for application in applications {
            _ = application.terminate()
        }
        for pid in runningPIDs() where !appPIDs.contains(pid) {
            _ = Darwin.kill(pid, SIGTERM)
        }
        if !waitUntilStopped(timeoutSec: 6) {
            // A wedged Electron host cannot keep the deployment permanently
            // stale. Force termination is scoped to LM Studio's bundle ID only.
            for application in runningApplications() {
                _ = application.forceTerminate()
            }
            for pid in runningPIDs() {
                _ = Darwin.kill(pid, SIGKILL)
            }
            guard waitUntilStopped(timeoutSec: 4) else {
                throw HostActivationError.terminationFailed
            }
        }
        try launch()
    }

    private func waitUntilStopped(timeoutSec: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeoutSec)
        repeat {
            if !isLMStudioRunning() { return true }
            Thread.sleep(forTimeInterval: 0.1)
        } while Date() < deadline
        return !isLMStudioRunning()
    }

    private func waitForReadyRoles(
        deploymentID: String,
        timeoutSec: TimeInterval
    ) -> Set<String> {
        let deadline = Date().addingTimeInterval(timeoutSec)
        repeat {
            let roles = readyRoles(deploymentID: deploymentID)
            if roles.count == LMStudioConnectorRole.allCases.count { return roles }
            Thread.sleep(forTimeInterval: 0.15)
        } while Date() < deadline
        return readyRoles(deploymentID: deploymentID)
    }

    private func waitForConfigurationSync(
        deploymentID: String,
        timeoutSec: TimeInterval
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeoutSec)
        repeat {
            if configurationIsSynced(deploymentID: deploymentID) { return true }
            Thread.sleep(forTimeInterval: 0.15)
        } while Date() < deadline
        return configurationIsSynced(deploymentID: deploymentID)
    }

    private func configurationIsSynced(deploymentID: String) -> Bool {
        guard let data = try? Data(contentsOf: syncedConfigurationURL),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let servers = root["mcpServers"] as? [String: Any]
        else {
            return false
        }
        return LMStudioConnectorRole.allCases.allSatisfy { role in
            guard let entry = servers[role.serverID] as? [String: Any],
                  let environment = entry["env"] as? [String: String]
            else {
                return false
            }
            return environment["FORGE_MCP_ROLE"] == role.rawValue
                && environment["FORGE_DEPLOYMENT_ID"] == deploymentID
        }
    }

    private func readyRoles(deploymentID: String) -> Set<String> {
        guard let text = try? String(contentsOf: diagnosticURL, encoding: .utf8) else {
            return []
        }
        var roles: Set<String> = []
        let decoder = JSONDecoder()
        for line in text.split(whereSeparator: \.isNewline).suffix(12_000) {
            guard let data = String(line).data(using: .utf8),
                  let event = try? decoder.decode(DiagnosticEnvelope.self, from: data),
                  event.fields["deployment_id"] == deploymentID
            else {
                continue
            }
            if event.event == "mcp_tools_list", event.fields["count"] != "0" {
                roles.insert(event.role)
            } else if event.event == "mcp_serve_end" {
                roles.remove(event.role)
            }
        }
        return roles
    }

    public enum HostActivationError: Error, LocalizedError {
        case invalidDeploymentID
        case appMissing(String)
        case launchTimedOut
        case launchFailed(String)
        case terminationFailed
        case rolesNotReady(deploymentID: String, roles: [String], expected: [String])

        public var errorDescription: String? {
            switch self {
            case .invalidDeploymentID:
                "The committed MCP configuration has no deployment revision."
            case .appMissing(let path):
                "LM Studio.app is missing at \(path)."
            case .launchTimedOut:
                "Timed out launching LM Studio."
            case .launchFailed(let detail):
                "LM Studio launch failed: \(detail)"
            case .terminationFailed:
                "LM Studio did not terminate for configuration reload."
            case .rolesNotReady(let deploymentID, let roles, let expected):
                "Revision \(deploymentID) was not acknowledged by both roles; ready=\(roles), expected=\(expected)."
            }
        }
    }
}
