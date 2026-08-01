// LMStudioConnectorReliabilityTests.swift
// Exercises connector installation, configuration revisioning, rollback, and verification.
// Environment overrides redirect every filesystem operation into a disposable fixture.

import XCTest
@testable import ForgeConductorCore

final class LMStudioConnectorReliabilityTests: XCTestCase {
    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("forge-connector-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        LMStudioEnvironment.homeDirOverride = nil
        LMStudioEnvironment.isAppInstalledOverride = nil
        try? FileManager.default.removeItem(at: scratch)
    }

    func testDeploymentVerifiesPrimaryAndFallbackBeforeAndAfterInstall() throws {
        let binary = try makeExecutable()
        let installer = RecordingInstaller(binary: binary)
        let verifier = RecordingVerifier()
        let service = makeService(installer: installer, verifier: verifier)

        let result = try service.deploy(preferredBinary: binary)

        XCTAssertTrue(result.ok)
        XCTAssertEqual(installer.installCount, 1)
        XCTAssertEqual(verifier.roles, [.primary, .fallback, .primary, .fallback])
        XCTAssertFalse(result.deploymentID.isEmpty)
    }

    func testFallbackIsPromotedWhenPrimaryDegradesAfterCommit() throws {
        let binary = try makeExecutable()
        let installer = RecordingInstaller(binary: binary)
        let verifier = RecordingVerifier { callIndex, role in
            !(callIndex >= 2 && role == .primary)
        }
        let service = makeService(installer: installer, verifier: verifier)

        let result = try service.deploy(preferredBinary: binary)

        XCTAssertFalse(result.ok)
        XCTAssertTrue(result.message.contains(LMStudioConnectionState.fallbackPromoted.rawValue))
        XCTAssertEqual(installer.installCount, 1)
        XCTAssertEqual(verifier.roles, [.primary, .fallback, .primary, .fallback])
    }

    func testRoleIdentityMismatchFailsBeforeInstallerMutation() throws {
        let binary = try makeExecutable()
        let installer = RecordingInstaller(binary: binary)
        let verifier = RecordingVerifier(serverName: { _ in LMStudioEnvironment.primaryServerID })
        let service = makeService(installer: installer, verifier: verifier)

        XCTAssertThrowsError(try service.deploy(preferredBinary: binary))
        XCTAssertEqual(installer.installCount, 0)
        XCTAssertEqual(verifier.roles, [.primary, .fallback])
    }

    func testMalformedMCPConfigurationIsPreservedWithoutReplacingLivePlugins() throws {
        let lmHome = scratch.appendingPathComponent("lmstudio", isDirectory: true)
        try FileManager.default.createDirectory(at: lmHome, withIntermediateDirectories: true)
        LMStudioEnvironment.homeDirOverride = lmHome
        LMStudioEnvironment.isAppInstalledOverride = true

        let malformed = Data("{ definitely-not-json".utf8)
        try malformed.write(to: lmHome.appendingPathComponent("mcp.json"))
        let primary = LMStudioMCPPluginInstaller.primaryPluginDirectory
        try FileManager.default.createDirectory(at: primary, withIntermediateDirectories: true)
        let sentinel = primary.appendingPathComponent("last-known-good.txt")
        try Data("keep".utf8).write(to: sentinel)
        let binary = try makeExecutable()

        XCTAssertThrowsError(try LMStudioMCPPluginInstaller.install(preferredBinary: binary))
        XCTAssertEqual(try Data(contentsOf: lmHome.appendingPathComponent("mcp.json")), malformed)
        XCTAssertEqual(try String(contentsOf: sentinel, encoding: .utf8), "keep")
        XCTAssertFalse(FileManager.default.fileExists(atPath: LMStudioMCPPluginInstaller.fallbackPluginDirectory.path))
    }

    func testTransactionalInstallPreservesForeignServersAndWritesTypedRoles() throws {
        let lmHome = scratch.appendingPathComponent("lmstudio", isDirectory: true)
        try FileManager.default.createDirectory(at: lmHome, withIntermediateDirectories: true)
        LMStudioEnvironment.homeDirOverride = lmHome
        LMStudioEnvironment.isAppInstalledOverride = true

        let existing: [String: Any] = [
            "mcpServers": [
                "keep-me": ["command": "/usr/bin/true", "args": [] as [String]],
            ] as [String: Any],
        ]
        let existingData = try JSONSerialization.data(withJSONObject: existing)
        try existingData.write(to: lmHome.appendingPathComponent("mcp.json"))
        let binary = try makeExecutable()

        let result = try LMStudioMCPPluginInstaller.install(preferredBinary: binary)

        XCTAssertTrue(result.ok)
        let root = try XCTUnwrap(
            try JSONSerialization.jsonObject(
                with: Data(contentsOf: lmHome.appendingPathComponent("mcp.json"))
            ) as? [String: Any]
        )
        let servers = try XCTUnwrap(root["mcpServers"] as? [String: Any])
        XCTAssertNotNil(servers["keep-me"])
        for role in LMStudioConnectorRole.allCases {
            let entry = try XCTUnwrap(servers[role.serverID] as? [String: Any])
            let environment = try XCTUnwrap(entry["env"] as? [String: String])
            XCTAssertEqual(entry["command"] as? String, binary.path)
            XCTAssertEqual(entry["args"] as? [String], ["serve"])
            XCTAssertEqual(environment["FORGE_MCP_ROLE"], role.rawValue)
            XCTAssertEqual(environment["FORGE_DEPLOYMENT_ID"], result.deploymentID)

            let bridgeURL = LMStudioMCPPluginInstaller.pluginDirectory(name: role.serverID)
                .appendingPathComponent("mcp-bridge-config.json")
            let bridge = try XCTUnwrap(
                try JSONSerialization.jsonObject(with: Data(contentsOf: bridgeURL)) as? [String: Any]
            )
            let bridgeEnvironment = try XCTUnwrap(bridge["env"] as? [String: String])
            XCTAssertEqual(bridgeEnvironment["FORGE_DEPLOYMENT_ID"], result.deploymentID)
        }
    }

    func testRepeatedDeploymentWritesNewRevisionToForceLMStudioReload() throws {
        let lmHome = scratch.appendingPathComponent("lmstudio", isDirectory: true)
        try FileManager.default.createDirectory(at: lmHome, withIntermediateDirectories: true)
        LMStudioEnvironment.homeDirOverride = lmHome
        LMStudioEnvironment.isAppInstalledOverride = true
        let binary = try makeExecutable()

        let first = try LMStudioMCPPluginInstaller.install(preferredBinary: binary)
        let firstData = try Data(contentsOf: lmHome.appendingPathComponent("mcp.json"))
        let second = try LMStudioMCPPluginInstaller.install(preferredBinary: binary)
        let secondData = try Data(contentsOf: lmHome.appendingPathComponent("mcp.json"))

        XCTAssertNotEqual(first.deploymentID, second.deploymentID)
        XCTAssertNotEqual(firstData, secondData, "every deploy must change mcp.json so LM Studio reloads it")
        XCTAssertEqual(
            LMStudioEnvironment.registeredDeploymentID(expectedBinary: binary),
            second.deploymentID
        )
    }

    func testConnectionStateModelsFailForwardPromotion() {
        let health = LMStudioConnectionHealth(roles: [
            LMStudioConnectorHealth(
                role: .primary,
                isReady: false,
                protocolVersion: nil,
                toolCount: 0,
                detail: "down"
            ),
            LMStudioConnectorHealth(
                role: .fallback,
                isReady: true,
                protocolVersion: "2025-11-25",
                toolCount: 25,
                detail: "ready"
            ),
        ])

        XCTAssertEqual(health.state, .fallbackPromoted)
        XCTAssertTrue(health.hasService)
        XCTAssertFalse(health.isStable)
    }

    func testHostActivationDistinguishesSynchronizedConfigFromLazyConnections() {
        let synchronized = LMStudioHostActivationResult(
            deploymentID: "revision-1",
            runningBeforeDeploy: true,
            launched: true,
            restarted: true,
            configurationSynced: true,
            readyRoles: [],
            detail: "lazy"
        )
        XCTAssertTrue(synchronized.isReady)
        XCTAssertFalse(synchronized.allRolesConnected)

        let connected = LMStudioHostActivationResult(
            deploymentID: "revision-1",
            runningBeforeDeploy: true,
            launched: false,
            restarted: false,
            configurationSynced: true,
            readyRoles: LMStudioConnectorRole.allCases.map(\.rawValue),
            detail: "connected"
        )
        XCTAssertTrue(connected.isReady)
        XCTAssertTrue(connected.allRolesConnected)
    }

    private func makeExecutable() throws -> URL {
        let binary = scratch.appendingPathComponent("forge-conductor")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: binary)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
        return binary
    }

    private func makeService(
        installer: RecordingInstaller,
        verifier: RecordingVerifier
    ) -> LMStudioDeployService {
        let home = scratch.appendingPathComponent("forge-home", isDirectory: true)
        try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let paths = AppPaths(home: home)
        let diagnostics = DiagnosticLog(paths: paths)
        LMStudioEnvironment.isAppInstalledOverride = true
        return LMStudioDeployService(
            paths: paths,
            diagnostics: diagnostics,
            installer: installer,
            verifier: verifier,
            hostActivator: RecordingHostActivator()
        )
    }
}

private final class RecordingInstaller: LMStudioPluginInstalling, @unchecked Sendable {
    private let binary: URL
    private(set) var installCount = 0

    init(binary: URL) {
        self.binary = binary
    }

    func status(preferredBinary: URL?) -> LMStudioMCPPluginInstaller.PluginStatus {
        LMStudioMCPPluginInstaller.PluginStatus(
            primaryPluginInstalled: true,
            fallbackPluginInstalled: true,
            mcpJSONRegistered: true,
            binaryPath: binary.path,
            binaryExecutable: true,
            lmStudioPresent: true,
            primaryPluginPath: "/primary",
            fallbackPluginPath: "/fallback",
            mcpConfigPath: "/mcp.json",
            deploymentID: "test-deployment",
            detail: "ready"
        )
    }

    func install(preferredBinary: URL?) throws -> LMStudioMCPPluginInstaller.InstallResult {
        installCount += 1
        return LMStudioMCPPluginInstaller.InstallResult(
            ok: true,
            binaryPath: binary.path,
            pluginsWritten: LMStudioConnectorRole.allCases.map(\.serverID),
            mcpConfigPath: "/mcp.json",
            deploymentID: "test-deployment-\(installCount)",
            message: "installed"
        )
    }
}

private final class RecordingHostActivator: LMStudioHostActivating, @unchecked Sendable {
    private(set) var deploymentIDs: [String] = []

    func activate(
        deploymentID: String,
        timeoutSec: TimeInterval
    ) throws -> LMStudioHostActivationResult {
        deploymentIDs.append(deploymentID)
        return LMStudioHostActivationResult(
            deploymentID: deploymentID,
            runningBeforeDeploy: true,
            launched: false,
            restarted: false,
            configurationSynced: true,
            readyRoles: LMStudioConnectorRole.allCases.map(\.rawValue),
            detail: "host ready"
        )
    }
}

private final class RecordingVerifier: MCPServeVerifying, @unchecked Sendable {
    private let readiness: (Int, LMStudioConnectorRole) -> Bool
    private let serverName: (LMStudioConnectorRole) -> String
    private(set) var roles: [LMStudioConnectorRole] = []

    init(
        readiness: @escaping (Int, LMStudioConnectorRole) -> Bool = { _, _ in true },
        serverName: @escaping (LMStudioConnectorRole) -> String = { $0.serverID }
    ) {
        self.readiness = readiness
        self.serverName = serverName
    }

    func verify(
        binary: URL,
        home: URL,
        role: LMStudioConnectorRole,
        timeoutSec: TimeInterval
    ) throws -> MCPServeVerifier.Result {
        let index = roles.count
        roles.append(role)
        let ready = readiness(index, role)
        return MCPServeVerifier.Result(
            ok: ready,
            protocolVersion: ready ? "2025-11-25" : nil,
            serverName: serverName(role),
            toolCount: ready ? 25 : 0,
            detail: ready ? "ready" : "down",
            durationMs: 1
        )
    }
}
