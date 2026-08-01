// LMStudioEnvironment.swift
// What: Encapsulates LM Studio paths, MCP configuration shapes, and registration checks.
// How: Static helpers parse existing JSON conservatively, identify Forge-owned entries,
// merge typed roles atomically, and preserve unrelated third-party configuration.
// Why: Environment-specific connector details stay outside domain and deployment policy.

import Foundation

/// LM Studio host layout and MCP config for **local models**.
///
/// Intended architecture: LM Studio spawns **Swift** `forge-conductor serve` on stdio.
/// Primary + fallback are two registrations of the **same Swift binary** (role via env).
/// Python/bash wrappers (`forge-serve*`) are legacy and removed on install.
public enum LMStudioEnvironment {
    public static let primaryServerID = "forge-conductor"
    public static let fallbackServerID = "forge-conductor-fallback"

    /// Shell wrappers that used to front the old Python stack. Deleted by install.
    public static let legacyLauncherNames = [
        "forge-serve",
        "forge-serve-fallback",
        "forge-serve.cmd",
        "forge-serve-fallback.cmd",
    ]

    /// Test / hermetic override for `~/.lmstudio`. When set, all LM Studio paths root here.
    /// Always clear in `defer` after tests. Not for production product code.
    nonisolated(unsafe) public static var homeDirOverride: URL?

    /// Test override for LM Studio.app presence checks.
    nonisolated(unsafe) public static var isAppInstalledOverride: Bool?

    public static var applicationSupport: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/LM Studio", isDirectory: true)
    }

    public static var homeDir: URL {
        if let homeDirOverride { return homeDirOverride }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".lmstudio", isDirectory: true)
    }

    public static var mcpConfigURL: URL {
        homeDir.appendingPathComponent("mcp.json")
    }

    public static var modelsDir: URL {
        homeDir.appendingPathComponent("models", isDirectory: true)
    }

    public static var appBundlePath: String {
        "/Applications/LM Studio.app"
    }

    public static var isAppInstalled: Bool {
        if let isAppInstalledOverride { return isAppInstalledOverride }
        return FileManager.default.fileExists(atPath: appBundlePath)
    }

    // MARK: - Read

    /// Entries from `~/.lmstudio/mcp.json` that belong in this product.
    /// Strips Claude/CCDT/foreign orchestration packages from the product view.
    public static func configuredMCPServers() -> [ConfiguredMCPServer] {
        guard let root = readMCPRoot(),
              let servers = root["mcpServers"] as? [String: Any] else {
            return []
        }
        var out: [ConfiguredMCPServer] = []
        for (id, raw) in servers {
            guard let dict = raw as? [String: Any] else { continue }
            let command = dict["command"] as? String ?? ""
            let args = dict["args"] as? [String] ?? []
            let env = dict["env"] as? [String: String] ?? [:]
            if isForeignToThisProduct(id: id, command: command) { continue }
            // Never surface deleted bash/Python wrappers in the product UI.
            if legacyShellLauncherPath(command) { continue }
            out.append(ConfiguredMCPServer(
                id: id,
                command: command,
                args: args,
                environment: env
            ))
        }
        return out.sorted { $0.id < $1.id }
    }

    public static func isForeignToThisProduct(id: String, command: String) -> Bool {
        let hay = (id + " " + command).lowercased()
        if hay.contains("ccdt") { return true }
        if hay.contains("project-continuity") { return true }
        if hay.contains("/.claude/") { return true }
        if hay.contains("claude/local-mcp") { return true }
        return false
    }

    /// True when command is a Swift product binary and args include `serve` (not a shell launcher).
    /// Accepts CLI `forge-conductor` or app `Forge Conductor` (MCP via `serve` argv).
    public static func isSwiftServeRegistration(
        _ server: ConfiguredMCPServer,
        expectedBinary: URL? = nil,
        expectedRole: LMStudioConnectorRole? = nil
    ) -> Bool {
        let cmd = server.command
        let leaf = (cmd as NSString).lastPathComponent
        let isCLI = leaf == "forge-conductor"
        let isApp = leaf == "Forge Conductor" || cmd.contains("Forge Conductor.app/Contents/MacOS/")
        guard isCLI || isApp else { return false }
        if legacyShellLauncherPath(cmd) { return false }
        guard server.args.contains("serve") else { return false }
        guard FileManager.default.isExecutableFile(atPath: cmd) else { return false }
        if let expectedRole,
           server.environment["FORGE_MCP_ROLE"] != expectedRole.rawValue {
            return false
        }
        if let expectedBinary {
            let want = expectedBinary.resolvingSymlinksInPath().path
            let got = URL(fileURLWithPath: cmd).resolvingSymlinksInPath().path
            guard want == got else { return false }
        }
        return true
    }

    public static func legacyShellLauncherPath(_ path: String) -> Bool {
        let leaf = (path as NSString).lastPathComponent.lowercased()
        return legacyLauncherNames.contains(where: { $0.lowercased() == leaf })
            || leaf.hasPrefix("forge-serve")
    }

    // MARK: - Install / cleanup

    public struct RegistrationResult: Sendable, Equatable {
        public var removedLaunchers: [String]
        public var mcpConfigPath: String
        public var command: String
        public var args: [String]
        public var wroteMCPConfig: Bool
        public var message: String
    }

    /// Delete leftover bash/Python launchers under `binDir` and point LM Studio at Swift stdio.
    @discardableResult
    public static func installSwiftStdioRegistration(
        binaryURL: URL,
        binDir: URL? = nil
    ) throws -> RegistrationResult {
        let binary = binaryURL.resolvingSymlinksInPath()
        guard FileManager.default.isExecutableFile(atPath: binary.path) else {
            throw NSError(
                domain: "LMStudioEnvironment",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Swift binary not executable: \(binary.path)"]
            )
        }

        let launchersDir = binDir ?? binary.deletingLastPathComponent()
        let wrote = try writeSwiftMCPRegistration(binaryURL: binary)
        // Only retire legacy launchers after a valid replacement registration
        // has been committed. A failed upgrade must leave the prior path intact.
        let removed = removeLegacyLaunchers(in: launchersDir)

        return RegistrationResult(
            removedLaunchers: removed,
            mcpConfigPath: mcpConfigURL.path,
            command: binary.path,
            args: ["serve"],
            wroteMCPConfig: wrote,
            message: "LM Studio MCP → primary+fallback \(binary.path) serve (Swift stdio)"
        )
    }

    /// Remove `forge-serve*` wrappers from a bin directory. Returns deleted basenames.
    @discardableResult
    public static func removeLegacyLaunchers(in binDir: URL) -> [String] {
        let fm = FileManager.default
        var removed: [String] = []
        guard fm.fileExists(atPath: binDir.path) else { return removed }

        // Named leftovers + any forge-serve* residual.
        var names = Set(legacyLauncherNames)
        if let entries = try? fm.contentsOfDirectory(atPath: binDir.path) {
            for name in entries where name.lowercased().hasPrefix("forge-serve") {
                names.insert(name)
            }
        }

        for name in names.sorted() {
            let url = binDir.appendingPathComponent(name)
            guard fm.fileExists(atPath: url.path) else { continue }
            do {
                try fm.removeItem(at: url)
                removed.append(name)
            } catch {
                // Best-effort; doctor will surface if still present.
            }
        }
        return removed
    }

    /// Merge/overwrite Forge entries in `~/.lmstudio/mcp.json` to Swift `serve`.
    /// Registers **primary** and **fallback** (same binary, different `FORGE_MCP_ROLE`).
    /// Drops any entry whose command is still a bash/Python forge-serve wrapper.
    /// Preserves unrelated third-party MCP servers.
    @discardableResult
    public static func writeSwiftMCPRegistration(binaryURL: URL) throws -> Bool {
        let fm = FileManager.default
        try fm.createDirectory(at: homeDir, withIntermediateDirectories: true)

        let data = try mergedMCPRegistrationData(
            binaryURL: binaryURL,
            deploymentID: UUID().uuidString.lowercased()
        )
        try data.write(to: mcpConfigURL, options: .atomic)
        return true
    }

    /// Builds a validated, merged LM Studio configuration without mutating disk.
    /// Existing malformed JSON is an error: silently replacing it would destroy
    /// unrelated MCP registrations and violate fail-forward deployment.
    static func mergedMCPRegistrationData(binaryURL: URL, deploymentID: String) throws -> Data {
        var root = try readMCPRootStrict()
        var servers = root["mcpServers"] as? [String: Any] ?? [:]

        let dropIDs = servers.keys.filter { id in
            guard let dict = servers[id] as? [String: Any] else { return false }
            let command = dict["command"] as? String ?? ""
            return legacyShellLauncherPath(command)
        }
        for id in dropIDs {
            servers.removeValue(forKey: id)
        }

        for role in LMStudioConnectorRole.allCases {
            servers[role.serverID] = swiftServeEntry(
                binaryURL: binaryURL,
                role: role,
                deploymentID: deploymentID
            )
        }
        root["mcpServers"] = servers

        let json = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        var text = String(decoding: json, as: UTF8.self)
            .replacingOccurrences(of: "\\/", with: "/")
        if !text.hasSuffix("\n") { text += "\n" }
        return Data(text.utf8)
    }

    /// Environment LM Studio injects when spawning our stdio server.
    /// Evidence: clean-env smoke (`env -i HOME=…`) still initializes; shell tools need a sane PATH.
    public static func hostEnvironment(
        role: LMStudioConnectorRole,
        deploymentID: String? = nil
    ) -> [String: String] {
        let home = AppPaths().home.path
        var environment = [
            "FORGE_MCP_ROLE": role.rawValue,
            "FORGE_CONDUCTOR_HOME": home,
            // Minimal + Homebrew + product bin so tool packs work when LM Studio uses a sparse PATH.
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin:\(home)/bin",
        ]
        if let deploymentID, !deploymentID.isEmpty {
            // A new value on every deploy guarantees that mcp.json changes even
            // when the executable path is unchanged, which triggers LM Studio's
            // configuration watcher to replace stale in-memory plugin processes.
            environment["FORGE_DEPLOYMENT_ID"] = deploymentID
        }
        return environment
    }

    public static func hostEnvironment(role: String) -> [String: String] {
        hostEnvironment(role: LMStudioConnectorRole(environmentValue: role))
    }

    private static func swiftServeEntry(
        binaryURL: URL,
        role: LMStudioConnectorRole,
        deploymentID: String
    ) -> [String: Any] {
        [
            "command": binaryURL.path,
            // App and CLI both honor `serve` via ForgeProcessEntry / ForgeConductorMain.
            "args": LMStudioMCPPluginInstaller.serveArguments,
            "env": hostEnvironment(role: role, deploymentID: deploymentID),
        ]
    }

    /// The revision is valid only when both role registrations point at the
    /// expected executable and carry the same nonempty deployment identifier.
    public static func registeredDeploymentID(expectedBinary: URL) -> String? {
        let servers = configuredMCPServers()
        guard let primary = servers.first(where: { $0.id == primaryServerID }),
              let fallback = servers.first(where: { $0.id == fallbackServerID }),
              isSwiftServeRegistration(primary, expectedBinary: expectedBinary, expectedRole: .primary),
              isSwiftServeRegistration(fallback, expectedBinary: expectedBinary, expectedRole: .fallback),
              let primaryID = primary.environment["FORGE_DEPLOYMENT_ID"],
              !primaryID.isEmpty,
              fallback.environment["FORGE_DEPLOYMENT_ID"] == primaryID
        else {
            return nil
        }
        return primaryID
    }

    /// Doctor-facing snapshot of registration health.
    public static func registrationHealth(expectedBinary: URL) -> (ok: Bool, detail: String) {
        let binDir = expectedBinary.deletingLastPathComponent()
        let leftovers = legacyLaunchersPresent(in: binDir)
        if !leftovers.isEmpty {
            return (false, "legacy launchers still present: \(leftovers.joined(separator: ", ")) — run forge-conductor install")
        }

        let servers = configuredMCPServers()
        guard let primary = servers.first(where: { $0.id == primaryServerID }) else {
            if !fmExists(mcpConfigURL) {
                return (false, "missing \(mcpConfigURL.path) — run forge-conductor install")
            }
            return (false, "no \(primaryServerID) entry in ~/.lmstudio/mcp.json")
        }

        let fallback = servers.first(where: { $0.id == fallbackServerID })
        let primaryOK = isSwiftServeRegistration(
            primary,
            expectedBinary: expectedBinary,
            expectedRole: .primary
        )
        let fallbackOK = fallback.map {
            isSwiftServeRegistration($0, expectedBinary: expectedBinary, expectedRole: .fallback)
        } ?? false

        if primaryOK && fallbackOK {
            guard let deploymentID = registeredDeploymentID(expectedBinary: expectedBinary) else {
                return (false, "primary+fallback lack one matching deployment revision — redeploy Forge Conductor")
            }
            return (true, "primary+fallback → \(expectedBinary.path) serve [\(deploymentID)]")
        }
        if primaryOK && !fallbackOK {
            return (false, "primary OK; missing Swift fallback — run forge-conductor install")
        }
        if legacyShellLauncherPath(primary.command) {
            return (false, "still registered as shell launcher: \(primary.commandLine)")
        }
        if !primary.args.contains("serve") {
            return (false, "expected args [\"serve\"], got \(primary.args)")
        }
        return (false, "command path mismatch: \(primary.command) (want \(expectedBinary.path))")
    }

    public static func legacyLaunchersPresent(in binDir: URL) -> [String] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: binDir.path) else { return [] }
        return entries
            .filter { $0.lowercased().hasPrefix("forge-serve") || legacyLauncherNames.contains($0) }
            .sorted()
    }

    // MARK: - Private

    private static func readMCPRoot() -> [String: Any]? {
        try? readMCPRootStrict()
    }

    private static func readMCPRootStrict() throws -> [String: Any] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: mcpConfigURL.path) else {
            return ["mcpServers": [String: Any]()]
        }
        let data = try Data(contentsOf: mcpConfigURL)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MCPConfigurationError.invalidRoot(mcpConfigURL.path)
        }
        if let rawServers = root["mcpServers"], !(rawServers is [String: Any]) {
            throw MCPConfigurationError.invalidServers(mcpConfigURL.path)
        }
        return root
    }

    private static func fmExists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }
}

public enum MCPConfigurationError: Error, LocalizedError, Sendable {
    case invalidRoot(String)
    case invalidServers(String)

    public var errorDescription: String? {
        switch self {
        case .invalidRoot(let path):
            "LM Studio MCP configuration is not a JSON object: \(path). The existing file was preserved."
        case .invalidServers(let path):
            "LM Studio MCP configuration has an invalid mcpServers value: \(path). The existing file was preserved."
        }
    }
}

public struct ConfiguredMCPServer: Sendable, Equatable, Identifiable {
    public var id: String
    public var command: String
    public var args: [String]
    public var environment: [String: String]

    public init(id: String, command: String, args: [String], environment: [String: String] = [:]) {
        self.id = id
        self.command = command
        self.args = args
        self.environment = environment
    }

    public var commandLine: String {
        ([command] + args).joined(separator: " ")
    }

    public var isLegacyShellLauncher: Bool {
        LMStudioEnvironment.legacyShellLauncherPath(command)
    }
}
