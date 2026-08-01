// G1G10AcceptanceTests.swift
// Implements automated end-to-end acceptance for the ten documented product gates.
// The suite combines real binaries with isolated homes so results are user-state independent.

import XCTest
@testable import ForgeConductorCore

/// Automated acceptance for G1–G10. No human/LM Studio UI required.
final class G1G10AcceptanceTests: XCTestCase {
    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("forge-g1g10-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        LMStudioEnvironment.homeDirOverride = nil
        LMStudioEnvironment.isAppInstalledOverride = nil
        try? FileManager.default.removeItem(at: scratch)
    }

    /// Locates the server-capable CLI produced beside the active test bundle.
    ///
    /// Xcode and SwiftPM both place their test bundle and executable products in
    /// the same configuration directory. Looking there first makes this
    /// acceptance test hermetic: an unrelated, stale executable in another
    /// build system's output directory can no longer create a false result.
    ///
    /// The repository-relative fallback supports direct XCTest invocations
    /// whose bundle does not expose the normal products directory.
    private func locateBuiltCLI() -> URL? {
        let activeProducts = Bundle(for: Self.self).bundleURL
            .deletingLastPathComponent()
        let activeCLI = activeProducts.appendingPathComponent("forge-conductor")
        if FileManager.default.isExecutableFile(atPath: activeCLI.path) {
            return activeCLI
        }

        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        let swiftPM = root.appendingPathComponent(".build/debug/forge-conductor")
        if FileManager.default.isExecutableFile(atPath: swiftPM.path) {
            return swiftPM
        }

        let dd = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Developer/Xcode/DerivedData", isDirectory: true)
        guard let enumr = FileManager.default.enumerator(
            at: dd,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return nil }
        while let item = enumr.nextObject() as? URL {
            if item.lastPathComponent == "forge-conductor",
               item.path.contains("/Build/Products/"),
               item.path.contains("Debug"),
               FileManager.default.isExecutableFile(atPath: item.path) {
                return item
            }
        }
        return nil
    }

    private func installCLIIntoForgeHome(_ forgeHome: URL) throws -> URL {
        guard let src = locateBuiltCLI() else {
            throw XCTSkip("No active forge-conductor product; build the forge-conductor target first")
        }
        let bin = forgeHome.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let dest = bin.appendingPathComponent("forge-conductor")
        if FileManager.default.fileExists(atPath: dest.path) {
            try FileManager.default.removeItem(at: dest)
        }
        try FileManager.default.copyItem(at: src, to: dest)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dest.path)

        // Framework next to CLI
        let fwName = "ForgeConductorCore.framework"
        let srcFW = src.deletingLastPathComponent().appendingPathComponent(fwName)
        let destFW = bin.appendingPathComponent(fwName)
        if FileManager.default.fileExists(atPath: srcFW.path) {
            if FileManager.default.fileExists(atPath: destFW.path) {
                try FileManager.default.removeItem(at: destFW)
            }
            try FileManager.default.copyItem(at: srcFW, to: destFW)
        }
        return dest
    }

    // MARK: G1 + G2 + G7 + G9 — full deploy product path (hermetic)

    func testG1G2G7_DeployPrimaryFailoverAndMCPSmoke() throws {
        let forgeHome = scratch.appendingPathComponent("forge", isDirectory: true)
        let lmHome = scratch.appendingPathComponent("lmstudio", isDirectory: true)
        try FileManager.default.createDirectory(at: forgeHome, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: lmHome, withIntermediateDirectories: true)

        LMStudioEnvironment.homeDirOverride = lmHome
        LMStudioEnvironment.isAppInstalledOverride = true

        let binary = try installCLIIntoForgeHome(forgeHome)
        let paths = AppPaths(home: forgeHome)
        try paths.ensureLayout()
        let log = DiagnosticLog(paths: paths)
        let deploy = LMStudioDeployService(
            paths: paths,
            diagnostics: log,
            hostActivator: HermeticLMStudioHostActivator()
        )

        let result = try deploy.deploy(preferredBinary: binary)
        XCTAssertTrue(result.ok, result.message)
        XCTAssertEqual(result.pluginsWritten.sorted(), ["forge-conductor", "forge-conductor-fallback"])

        // G2: both plugins + mcp.json
        let primaryCfg = lmHome
            .appendingPathComponent("extensions/plugins/mcp/forge-conductor/mcp-bridge-config.json")
        let fallbackCfg = lmHome
            .appendingPathComponent("extensions/plugins/mcp/forge-conductor-fallback/mcp-bridge-config.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: primaryCfg.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fallbackCfg.path))

        let primary = try JSONSerialization.jsonObject(with: Data(contentsOf: primaryCfg)) as? [String: Any]
        let fallback = try JSONSerialization.jsonObject(with: Data(contentsOf: fallbackCfg)) as? [String: Any]
        XCTAssertEqual(primary?["command"] as? String, binary.path)
        XCTAssertEqual(primary?["args"] as? [String], ["serve"])
        XCTAssertEqual((primary?["env"] as? [String: String])?["FORGE_MCP_ROLE"], "primary")
        XCTAssertEqual(fallback?["command"] as? String, binary.path)
        XCTAssertEqual((fallback?["env"] as? [String: String])?["FORGE_MCP_ROLE"], "fallback")

        let mcpRoot = try JSONSerialization.jsonObject(with: Data(contentsOf: lmHome.appendingPathComponent("mcp.json"))) as? [String: Any]
        let servers = mcpRoot?["mcpServers"] as? [String: Any]
        XCTAssertNotNil(servers?["forge-conductor"])
        XCTAssertNotNil(servers?["forge-conductor-fallback"])

        // G7: process-level smoke already ran inside deploy; re-verify + tool call in-process
        let smoke = try MCPServeVerifier.verify(binary: binary, home: forgeHome, role: "primary")
        XCTAssertTrue(smoke.ok, smoke.detail)
        XCTAssertEqual(smoke.protocolVersion, "2025-11-25")
        XCTAssertGreaterThanOrEqual(smoke.toolCount, 20)
        XCTAssertTrue(MCPServeVerifier.requiredContinuityTools.isSubset(of: Set(smoke.toolNames)))

        let app = try ForgeApp.bootstrap(home: forgeHome)
        defer { app.shutdown() }
        let server = MCPServer(app: app)
        let call: [String: Any] = [
            "jsonrpc": "2.0", "id": 9, "method": "tools/call",
            "params": ["name": "agent_list", "arguments": [:] as [String: Any]] as [String: Any],
        ]
        let resp = server.handle(call)
        let isError = (resp?["result"] as? [String: Any])?["isError"] as? Bool ?? true
        XCTAssertFalse(isError, "agent_list must succeed")

        // G6: diagnostics include deploy + smoke
        let events = Set(log.recent(limit: 100).map(\.event))
        XCTAssertTrue(events.contains("deploy_begin"))
        XCTAssertTrue(events.contains("deploy_complete") || events.contains("deploy_plugins_written"))
        XCTAssertTrue(events.contains("deploy_smoke_pre") || events.contains("deploy_smoke_post"))
    }

    // MARK: G5 realtime

    func testG5_RealtimeEngineSustainedSampling() {
        let engine = RealtimeMetricsEngine()
        let requiredSamples = 8
        let delivered = expectation(description: "sustained realtime samples delivered")
        var stamps: [TimeInterval] = []
        let lock = NSLock()
        let id = engine.addListener { metrics in
            lock.lock()
            stamps.append(metrics.ts)
            let reachedRequiredSamples = stamps.count == requiredSamples
            lock.unlock()
            if reachedRequiredSamples {
                delivered.fulfill()
            }
        }
        engine.start(targetHz: 30)
        defer {
            engine.stop()
            engine.removeListener(id)
        }

        wait(for: [delivered], timeout: 2.0)
        lock.lock()
        let samples = stamps
        lock.unlock()
        let unique = Set(samples.map { Int($0 * 100) }) // 10ms buckets
        XCTAssertGreaterThanOrEqual(unique.count, 3, "must keep advancing samples")
        XCTAssertTrue(engine.isRunning)
        XCTAssertGreaterThanOrEqual(engine.targetSampleHz, 20)
    }

    // MARK: G6 diagnostics export completeness

    func testG6_DiagnosticsExportContainsRequiredCategories() throws {
        let forgeHome = scratch.appendingPathComponent("diag", isDirectory: true)
        try FileManager.default.createDirectory(at: forgeHome, withIntermediateDirectories: true)
        let paths = AppPaths(home: forgeHome)
        try paths.ensureLayout()
        let log = DiagnosticLog(paths: paths)
        log.info("t_bootstrap", [:], category: .bootstrap)
        log.info("t_deploy", [:], category: .lmstudio)
        log.info("t_mcp", [:], category: .mcp)
        log.info("t_tools", [:], category: .tools)
        log.info("t_telemetry", [:], category: .telemetry)
        log.info("t_manager", [:], category: .manager)
        let exp = try log.export(to: forgeHome.appendingPathComponent("out", isDirectory: true))
        XCTAssertTrue(FileManager.default.fileExists(atPath: exp.jsonURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: exp.markdownURL.path))
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: exp.jsonURL)) as? [String: Any]
        let records = json?["records"] as? [[String: Any]] ?? []
        let cats = Set(records.compactMap { $0["category"] as? String })
        for need in ["bootstrap", "lmstudio", "mcp", "tools", "telemetry", "manager"] {
            XCTAssertTrue(cats.contains(need), "missing category \(need)")
        }
        let md = try String(contentsOf: exp.markdownURL, encoding: .utf8)
        XCTAssertTrue(md.contains("Timeline"))
        XCTAssertGreaterThanOrEqual(exp.recordCount, 6)
    }

    // MARK: G8 port ownership

    func testG8_SecondDashboardBindFailsClosed() throws {
        let forgeHome = scratch.appendingPathComponent("port", isDirectory: true)
        try FileManager.default.createDirectory(at: forgeHome, withIntermediateDirectories: true)
        let app1 = try ForgeApp.bootstrap(home: forgeHome)
        defer { app1.shutdown() }
        // Pick a free high port
        let port = 58_844
        _ = try app1.config.update([
            "dashboard": ["host": "127.0.0.1", "port": port] as [String: Any],
        ], save: true)
        app1.config.reload()

        let m1 = ManagerNode(app: app1)
        do {
            _ = try m1.startService()
        } catch {
            // If port busy from environment, skip rather than false fail
            throw XCTSkip("Could not bind test port \(port): \(error)")
        }

        let app2Home = scratch.appendingPathComponent("port2", isDirectory: true)
        try FileManager.default.createDirectory(at: app2Home, withIntermediateDirectories: true)
        let app2 = try ForgeApp.bootstrap(home: app2Home)
        defer { app2.shutdown() }
        _ = try app2.config.update([
            "dashboard": ["host": "127.0.0.1", "port": port] as [String: Any],
        ], save: true)
        app2.config.reload()
        let m2 = ManagerNode(app: app2)
        XCTAssertThrowsError(try m2.startService()) { err in
            let s = "\(err)"
            XCTAssertTrue(
                s.localizedCaseInsensitiveContains("port")
                    || s.localizedCaseInsensitiveContains("use")
                    || s.localizedCaseInsensitiveContains("Address")
                    || s.localizedCaseInsensitiveContains("Forge"),
                "expected port conflict error, got \(s)"
            )
        }
        _ = try? m1.stopService()
    }

    // MARK: G3/G4/G9/G10 meta

    func testG3_VersionIsDefined() {
        XCTAssertFalse(ForgeApp.version.isEmpty)
        XCTAssertEqual(ForgeApp.version, "0.7.0")
    }

    func testG9_ResolvePrefersExplicitBinary() {
        let paths = AppPaths(home: scratch)
        let log = DiagnosticLog(paths: paths)
        let deploy = LMStudioDeployService(paths: paths, diagnostics: log)
        let explicit = URL(fileURLWithPath: "/tmp/explicit-forge-bin-\(UUID().uuidString)")
        let got = deploy.resolveServeBinary(preferred: explicit)
        XCTAssertEqual(got.path, explicit.path)
    }

    func testG4_ProtocolsAreConcrete() {
        let paths = AppPaths(home: scratch)
        let log = DiagnosticLog(paths: paths)
        let deploy: any LMStudioDeploying = LMStudioDeployService(paths: paths, diagnostics: log)
        let engine: any RealtimeMetricsStreaming = RealtimeMetricsEngine()
        let diag: any DiagnosticRecording = log
        _ = deploy.resolveServeBinary(preferred: nil)
        _ = engine.isRunning
        diag.info("g4_ok", [:], category: .general)
    }
}

private struct HermeticLMStudioHostActivator: LMStudioHostActivating {
    func activate(
        deploymentID: String,
        timeoutSec: TimeInterval
    ) throws -> LMStudioHostActivationResult {
        LMStudioHostActivationResult(
            deploymentID: deploymentID,
            runningBeforeDeploy: true,
            launched: false,
            restarted: false,
            configurationSynced: true,
            readyRoles: LMStudioConnectorRole.allCases.map(\.rawValue),
            detail: "hermetic host acknowledgement"
        )
    }
}
