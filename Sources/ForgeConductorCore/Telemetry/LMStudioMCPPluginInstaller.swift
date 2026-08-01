// LMStudioMCPPluginInstaller.swift
// What: Implements transactional installation of both LM Studio MCP bridge roles.
// How: It validates existing JSON, stages role-specific plugins/configuration, verifies
// staged content, commits fallback then primary, atomically replaces mcp.json, and can roll back.
// Why: Connector installation must never leave the host with half a failover pair.

import Foundation

/// Installs the **LM Studio mcpBridge plugin** that wires Forge Conductor Swift stdio MCP.
///
/// LM Studio discovers MCP plugins under:
/// `~/.lmstudio/extensions/plugins/mcp/<name>/`
/// with `manifest.json` (`runner: mcpBridge`), `mcp-bridge-config.json`, and `install-state.json`,
/// plus matching entries in `~/.lmstudio/mcp.json`.
///
/// Observed from a working third-party plugin (`project-continuity`) on this machine.
public enum LMStudioMCPPluginInstaller {
    public static let installerID = "forge-conductor-app"

    public struct PluginStatus: Sendable, Equatable {
        public var primaryPluginInstalled: Bool
        public var fallbackPluginInstalled: Bool
        public var mcpJSONRegistered: Bool
        public var binaryPath: String
        public var binaryExecutable: Bool
        public var lmStudioPresent: Bool
        public var primaryPluginPath: String
        public var fallbackPluginPath: String
        public var mcpConfigPath: String
        public var deploymentID: String?
        public var detail: String

        public var isFullyInstalled: Bool {
            primaryPluginInstalled && fallbackPluginInstalled && mcpJSONRegistered && binaryExecutable
        }
    }

    public struct InstallResult: Sendable, Equatable {
        public var ok: Bool
        public var binaryPath: String
        public var pluginsWritten: [String]
        public var mcpConfigPath: String
        public var deploymentID: String
        public var message: String

        public init(
            ok: Bool,
            binaryPath: String,
            pluginsWritten: [String],
            mcpConfigPath: String,
            deploymentID: String,
            message: String
        ) {
            self.ok = ok
            self.binaryPath = binaryPath
            self.pluginsWritten = pluginsWritten
            self.mcpConfigPath = mcpConfigPath
            self.deploymentID = deploymentID
            self.message = message
        }
    }

    // MARK: - Paths

    public static var pluginsRoot: URL {
        LMStudioEnvironment.homeDir
            .appendingPathComponent("extensions", isDirectory: true)
            .appendingPathComponent("plugins", isDirectory: true)
            .appendingPathComponent("mcp", isDirectory: true)
    }

    public static func pluginDirectory(name: String) -> URL {
        pluginsRoot.appendingPathComponent(name, isDirectory: true)
    }

    public static var primaryPluginDirectory: URL {
        pluginDirectory(name: LMStudioEnvironment.primaryServerID)
    }

    public static var fallbackPluginDirectory: URL {
        pluginDirectory(name: LMStudioEnvironment.fallbackServerID)
    }

    /// Preferred executable for LM Studio to spawn with argv `serve`.
    ///
    /// Product path (v0.5+): prefer the **running app** or installed home app
    /// (`ForgeProcessEntry` → stdio MCP). CLI is fallback when no app is present.
    public static func resolveBinaryURL(preferred: URL? = nil) -> URL {
        if let preferred, FileManager.default.isExecutableFile(atPath: preferred.path) {
            return preferred.resolvingSymlinksInPath()
        }
        // Prefer running product executable first (Deploy from GUI).
        if let running = Bundle.main.executableURL,
           FileManager.default.isExecutableFile(atPath: running.path) {
            let leaf = running.lastPathComponent
            if leaf == "Forge Conductor" || leaf == "forge-conductor"
                || (Bundle.main.bundleIdentifier?.contains("forge-conductor") == true) {
                return running.resolvingSymlinksInPath()
            }
        }
        let home = AppPaths().home
        let candidates = [
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

    /// Args after the executable for mcp.json / mcpBridge (always `serve`).
    public static let serveArguments = ["serve"]

    // MARK: - Status

    public static func status(preferredBinary: URL? = nil) -> PluginStatus {
        let binary = resolveBinaryURL(preferred: preferredBinary)
        let binOK = FileManager.default.isExecutableFile(atPath: binary.path)
        let deploymentID = LMStudioEnvironment.registeredDeploymentID(expectedBinary: binary)
        let primaryOK = isPluginInstalled(
            name: LMStudioEnvironment.primaryServerID,
            expectedBinary: binary,
            expectedDeploymentID: deploymentID
        )
        let fallbackOK = isPluginInstalled(
            name: LMStudioEnvironment.fallbackServerID,
            expectedBinary: binary,
            expectedDeploymentID: deploymentID
        )
        let mcp = LMStudioEnvironment.registrationHealth(expectedBinary: binary)

        var parts: [String] = []
        if !LMStudioEnvironment.isAppInstalled {
            parts.append("LM Studio.app not found in /Applications")
        }
        if !binOK {
            parts.append("Swift binary missing at \(binary.path) — run forge-conductor install")
        }
        if !primaryOK { parts.append("primary mcpBridge plugin not installed") }
        if !fallbackOK { parts.append("fallback mcpBridge plugin not installed") }
        if !mcp.ok { parts.append("mcp.json: \(mcp.detail)") }
        if parts.isEmpty {
            parts.append("LM Studio mcpBridge plugin ready (primary+fallback)")
        }

        return PluginStatus(
            primaryPluginInstalled: primaryOK,
            fallbackPluginInstalled: fallbackOK,
            mcpJSONRegistered: mcp.ok,
            binaryPath: binary.path,
            binaryExecutable: binOK,
            lmStudioPresent: LMStudioEnvironment.isAppInstalled,
            primaryPluginPath: primaryPluginDirectory.path,
            fallbackPluginPath: fallbackPluginDirectory.path,
            mcpConfigPath: LMStudioEnvironment.mcpConfigURL.path,
            deploymentID: deploymentID,
            detail: parts.joined(separator: "; ")
        )
    }

    public static func isPluginInstalled(
        name: String,
        expectedBinary: URL,
        expectedDeploymentID: String? = nil
    ) -> Bool {
        let dir = pluginDirectory(name: name)
        let role = name == LMStudioEnvironment.fallbackServerID
            ? LMStudioConnectorRole.fallback
            : LMStudioConnectorRole.primary
        return isPluginInstalled(
            at: dir,
            expectedBinary: expectedBinary,
            expectedRole: role,
            expectedDeploymentID: expectedDeploymentID
        )
    }

    private static func isPluginInstalled(
        at dir: URL,
        expectedBinary: URL,
        expectedRole: LMStudioConnectorRole,
        expectedDeploymentID: String? = nil
    ) -> Bool {
        let manifest = dir.appendingPathComponent("manifest.json")
        let bridge = dir.appendingPathComponent("mcp-bridge-config.json")
        guard FileManager.default.fileExists(atPath: manifest.path),
              FileManager.default.fileExists(atPath: bridge.path),
              let data = try? Data(contentsOf: bridge),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let command = obj["command"] as? String,
              let args = obj["args"] as? [String],
              let environment = obj["env"] as? [String: String],
              environment["FORGE_MCP_ROLE"] == expectedRole.rawValue,
              let deploymentID = environment["FORGE_DEPLOYMENT_ID"],
              !deploymentID.isEmpty
        else {
            return false
        }
        let leaf = (command as NSString).lastPathComponent
        let isCLI = leaf == "forge-conductor"
        let isApp = leaf == "Forge Conductor" || command.contains("Forge Conductor.app/")
        guard isCLI || isApp else { return false }
        guard args.contains("serve") else { return false }
        guard FileManager.default.isExecutableFile(atPath: command) else { return false }
        if let expectedDeploymentID, deploymentID != expectedDeploymentID { return false }
        let want = expectedBinary.resolvingSymlinksInPath().path
        let got = URL(fileURLWithPath: command).resolvingSymlinksInPath().path
        return want == got
    }

    // MARK: - Install

    /// If registration drifted (wrong path, missing fallback, missing bridge), rewrite it.
    /// Safe to call on every app launch when the Swift CLI binary is present.
    @discardableResult
    public static func ensureConnection(preferredBinary: URL? = nil) throws -> InstallResult {
        let binary = resolveBinaryURL(preferred: preferredBinary)
        let st = status(preferredBinary: binary)
        if st.isFullyInstalled {
            return InstallResult(
                ok: true,
                binaryPath: binary.path,
                pluginsWritten: [LMStudioEnvironment.primaryServerID, LMStudioEnvironment.fallbackServerID],
                mcpConfigPath: LMStudioEnvironment.mcpConfigURL.path,
                deploymentID: st.deploymentID ?? "",
                message: "LM Studio connection already correct (mcp.json + mcpBridge primary/fallback)"
            )
        }
        return try install(preferredBinary: binary)
    }

    /// Write mcpBridge plugins + `mcp.json` so LM Studio can spawn Forge Conductor stdio MCP.
    ///
    /// Fail-forward design (host-level, evidence-backed):
    /// - **primary** and **fallback** are two independent MCP server registrations.
    /// - Same Swift binary, separate processes when LM Studio enables both.
    /// - If one session dies, the other remains available (unlike a single supervisor PID).
    @discardableResult
    public static func install(preferredBinary: URL? = nil) throws -> InstallResult {
        let binary = resolveBinaryURL(preferred: preferredBinary)
        let deploymentID = UUID().uuidString.lowercased()
        guard FileManager.default.isExecutableFile(atPath: binary.path) else {
            throw NSError(
                domain: "LMStudioMCPPluginInstaller",
                code: 1,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Forge Conductor Swift binary not found or not executable at \(binary.path). Build the forge-conductor CLI and run install first.",
                ]
            )
        }

        // Parse and merge before mutating any live plugin path. Malformed
        // operator configuration is preserved and reported instead of reset.
        let mergedMCPConfig = try LMStudioEnvironment.mergedMCPRegistrationData(
            binaryURL: binary,
            deploymentID: deploymentID
        )

        // Ensure ~/.lmstudio exists even if the app is not running yet.
        try FileManager.default.createDirectory(
            at: LMStudioEnvironment.homeDir,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(at: pluginsRoot, withIntermediateDirectories: true)

        let transactionRoot = pluginsRoot.appendingPathComponent(
            ".forge-conductor-install-\(UUID().uuidString)",
            isDirectory: true
        )
        let stagedRoot = transactionRoot.appendingPathComponent("staged", isDirectory: true)
        let backupRoot = transactionRoot.appendingPathComponent("backup", isDirectory: true)
        try FileManager.default.createDirectory(at: stagedRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: backupRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: transactionRoot) }

        for role in LMStudioConnectorRole.allCases {
            let staged = stagedRoot.appendingPathComponent(role.serverID, isDirectory: true)
            try writeMCPBridgePlugin(
                at: staged,
                name: role.serverID,
                binary: binary,
                role: role,
                deploymentID: deploymentID
            )
            guard isPluginInstalled(
                at: staged,
                expectedBinary: binary,
                expectedRole: role,
                expectedDeploymentID: deploymentID
            ) else {
                throw InstallError.stagedPluginInvalid(role.serverID)
            }
        }

        let fm = FileManager.default
        let configURL = LMStudioEnvironment.mcpConfigURL
        let originalConfig = try? Data(contentsOf: configURL)
        var changedRoles: [LMStudioConnectorRole] = []

        do {
            // Commit fallback first. The previous primary remains available until
            // a verified standby is installed, minimizing the upgrade outage.
            for role in [LMStudioConnectorRole.fallback, .primary] {
                let target = pluginDirectory(name: role.serverID)
                let backup = backupRoot.appendingPathComponent(role.serverID, isDirectory: true)
                let staged = stagedRoot.appendingPathComponent(role.serverID, isDirectory: true)
                changedRoles.append(role)
                if fm.fileExists(atPath: target.path) {
                    try fm.moveItem(at: target, to: backup)
                }
                try fm.moveItem(at: staged, to: target)
            }
            try mergedMCPConfig.write(to: configURL, options: .atomic)
        } catch {
            rollback(
                roles: changedRoles,
                backupRoot: backupRoot,
                originalConfig: originalConfig,
                configURL: configURL
            )
            throw InstallError.commitFailed(error.localizedDescription)
        }

        let written = LMStudioConnectorRole.allCases.map(\.serverID)

        let st = status(preferredBinary: binary)
        guard st.isFullyInstalled else {
            rollback(
                roles: changedRoles,
                backupRoot: backupRoot,
                originalConfig: originalConfig,
                configURL: configURL
            )
            throw InstallError.commitFailed("post-commit validation failed: \(st.detail)")
        }
        // Legacy wrappers are removed only after both new roles and mcp.json
        // have committed and passed final validation.
        _ = LMStudioEnvironment.removeLegacyLaunchers(in: binary.deletingLastPathComponent())
        return InstallResult(
            ok: st.isFullyInstalled,
            binaryPath: binary.path,
            pluginsWritten: written,
            mcpConfigPath: LMStudioEnvironment.mcpConfigURL.path,
            deploymentID: deploymentID,
            message: st.isFullyInstalled
                ? "Committed LM Studio configuration revision \(deploymentID): primary + failover → \(binary.path) serve."
                : "Partial deploy: \(st.detail)"
        )
    }

    /// Remove Forge mcpBridge plugins (does not delete third-party MCP plugins).
    @discardableResult
    public static func uninstall() throws -> [String] {
        let fm = FileManager.default
        var removed: [String] = []
        for name in [LMStudioEnvironment.primaryServerID, LMStudioEnvironment.fallbackServerID] {
            let dir = pluginDirectory(name: name)
            if fm.fileExists(atPath: dir.path) {
                try fm.removeItem(at: dir)
                removed.append(name)
            }
        }
        // Strip our mcp.json entries only.
        if var root = try? readMCPRootMutable(),
           var servers = root["mcpServers"] as? [String: Any] {
            servers.removeValue(forKey: LMStudioEnvironment.primaryServerID)
            servers.removeValue(forKey: LMStudioEnvironment.fallbackServerID)
            root["mcpServers"] = servers
            let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: LMStudioEnvironment.mcpConfigURL, options: .atomic)
        }
        return removed
    }

    // MARK: - Private writers

    private static func writeMCPBridgePlugin(
        at dir: URL,
        name: String,
        binary: URL,
        role: LMStudioConnectorRole,
        deploymentID: String
    ) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: dir.path) {
            try fm.removeItem(at: dir)
        }
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)

        let manifest: [String: Any] = [
            "type": "plugin",
            "runner": "mcpBridge",
            "owner": "mcp",
            "name": name,
        ]
        try writeJSON(manifest, to: dir.appendingPathComponent("manifest.json"))

        // Keep mcp-bridge-config.json aligned with mcp.json entry.
        let bridge: [String: Any] = [
            "command": binary.path,
            "args": Self.serveArguments,
            "env": LMStudioEnvironment.hostEnvironment(
                role: role,
                deploymentID: deploymentID
            ),
        ]
        try writeJSON(bridge, to: dir.appendingPathComponent("mcp-bridge-config.json"))

        let state: [String: Any] = [
            "by": installerID,
            "at": Int(Date().timeIntervalSince1970 * 1000),
            "deploymentID": deploymentID,
        ]
        try writeJSON(state, to: dir.appendingPathComponent("install-state.json"))
    }

    private static func rollback(
        roles: [LMStudioConnectorRole],
        backupRoot: URL,
        originalConfig: Data?,
        configURL: URL
    ) {
        let fm = FileManager.default
        for role in roles.reversed() {
            let target = pluginDirectory(name: role.serverID)
            let backup = backupRoot.appendingPathComponent(role.serverID, isDirectory: true)
            if fm.fileExists(atPath: target.path) {
                try? fm.removeItem(at: target)
            }
            if fm.fileExists(atPath: backup.path) {
                try? fm.moveItem(at: backup, to: target)
            }
        }
        if let originalConfig {
            try? originalConfig.write(to: configURL, options: .atomic)
        } else if fm.fileExists(atPath: configURL.path) {
            try? fm.removeItem(at: configURL)
        }
    }

    private static func writeJSON(_ object: [String: Any], to url: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        // Match LM Studio's own plugin files: unescaped path slashes (not \/).
        var text = String(data: data, encoding: .utf8) ?? ""
        text = text.replacingOccurrences(of: "\\/", with: "/")
        if !text.hasSuffix("\n") { text += "\n" }
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private static func readMCPRootMutable() throws -> [String: Any] {
        let url = LMStudioEnvironment.mcpConfigURL
        if let data = try? Data(contentsOf: url),
           let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return root
        }
        return ["mcpServers": [String: Any]()]
    }
}

extension LMStudioMCPPluginInstaller {
    public enum InstallError: Error, LocalizedError, Sendable {
        case stagedPluginInvalid(String)
        case commitFailed(String)

        public var errorDescription: String? {
            switch self {
            case .stagedPluginInvalid(let id):
                "Staged LM Studio connector failed validation: \(id). The active connection was preserved."
            case .commitFailed(let detail):
                "LM Studio connector commit failed and was rolled back: \(detail)"
            }
        }
    }
}

/// Native installer adapter used by the application-layer connector module.
public struct NativeLMStudioPluginInstaller: LMStudioPluginInstalling {
    public init() {}

    public func status(preferredBinary: URL?) -> LMStudioMCPPluginInstaller.PluginStatus {
        LMStudioMCPPluginInstaller.status(preferredBinary: preferredBinary)
    }

    public func install(preferredBinary: URL?) throws -> LMStudioMCPPluginInstaller.InstallResult {
        try LMStudioMCPPluginInstaller.install(preferredBinary: preferredBinary)
    }
}
