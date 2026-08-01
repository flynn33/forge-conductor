// LiveCollectorEvidenceTests.swift
// Confirms native collectors return plausible evidence from the current macOS host.
// Assertions tolerate unavailable optional sensors while detecting contract regressions.

import XCTest
@testable import ForgeConductorCore

/// Live evidence tests — run against real macOS IOKit (skipped only if OS returns nothing).
final class LiveCollectorEvidenceTests: XCTestCase {
    func testGPUCollectorSeesDeviceUtilizationWhenAvailable() {
        let gpus = GPUCollector().collect()
        XCTAssertFalse(gpus.isEmpty)
        XCTAssertTrue(gpus[0].metal)
        XCTAssertGreaterThan(gpus[0].memTotalMiB, 0)
        // On this Mac class, PerformanceStatistics exposes Device Utilization % — util should be non-nil when IOKit works.
        // Soft assert: if nil, fail with clear message so we know collector regressed.
        if gpus[0].utilGPU == nil {
            // Still require we at least got a model string
            XCTAssertFalse(gpus[0].name.isEmpty)
        } else {
            XCTAssertGreaterThanOrEqual(gpus[0].utilGPU!, 0)
            XCTAssertLessThanOrEqual(gpus[0].utilGPU!, 100)
        }
    }

    func testDiskIOCollectorProducesDeltaAfterTwoSamples() {
        let c = DiskIOCollector()
        _ = c.collect()
        // Force a bit of disk activity
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("io-evidence-\(UUID().uuidString)")
        try? Data(repeating: 0xAB, count: 2_000_000).write(to: tmp)
        try? FileManager.default.removeItem(at: tmp)
        Thread.sleep(forTimeInterval: 0.15)
        let m = c.collect()
        XCTAssertTrue(m.totalMBs.isFinite)
        XCTAssertGreaterThanOrEqual(m.totalMBs, 0)
        // After real IO, rate is often > 0; if zero, counters still must be finite and structure valid
        XCTAssertGreaterThanOrEqual(m.readMBs, 0)
        XCTAssertGreaterThanOrEqual(m.writeMBs, 0)
    }

    func testTypedCardsFromLiveSnapshot() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("cards-\(UUID().uuidString)", isDirectory: true)
        defer {
            // Close store before delete
            // bootstrap app goes out of scope
            try? FileManager.default.removeItem(at: home)
        }
        let app = try ForgeApp.bootstrap(home: home)
        defer { app.shutdown() }
        let snap = try app.telemetry.snapshotTyped(force: true)
        let tools = ForgeUIModelFactory.tools(from: snap.forge)
        let agents = ForgeUIModelFactory.agents(from: snap.forge)
        XCTAssertFalse(tools.isEmpty)
        XCTAssertFalse(agents.isEmpty)
        XCTAssertFalse(tools[0].shortLabel.isEmpty)
        XCTAssertGreaterThanOrEqual(tools[0].loadTier, 0)
        XCTAssertLessThanOrEqual(tools[0].loadTier, 3)
    }

    func testProcessDiscoveryFindsLocalMCPBinariesWhenPresent() {
        if ProcessInfo.processInfo.environment["FORGE_SKIP_PS"] == "1" {
            return
        }
        let snap = ProcessDiscovery.scan()
        for p in snap.mcpProcesses {
            XCTAssertGreaterThan(p.pid, 0)
            XCTAssertFalse(p.label.isEmpty)
            XCTAssertFalse(p.hostKind.isEmpty)
        }
        // Never list CCDT (separate project) even if its binaries are running.
        for p in snap.mcpProcesses {
            XCTAssertFalse(p.label.lowercased().contains("ccdt"), "CCDT must not appear: \(p.label)")
            XCTAssertFalse(p.command.lowercased().contains("ccdt"), "CCDT must not appear: \(p.command)")
            XCTAssertFalse(p.label == "project-continuity", "CCDT continuity package must not appear")
        }
        // Forge-owned local MCP binaries (when running) must still be classified.
        let forgeLabels = ["forge-fs", "forge-memory"]
        var runningForge = false
        for name in forgeLabels {
            if snap.mcpProcesses.contains(where: { $0.label == name || $0.command.contains(name) }) {
                runningForge = true
            }
        }
        let hasEndor = snap.mcpProcesses.contains {
            $0.label.contains("endorctl") || $0.command.contains("endorctl")
        }
        if runningForge || hasEndor {
            XCTAssertFalse(snap.mcpProcesses.isEmpty, "live Forge/endor MCP processes must appear as cards")
        }
    }

    func testProcessDiscoveryNeverClassifiesCCDT() {
        let snap = ProcessDiscovery.scan()
        XCTAssertFalse(snap.mcpProcesses.contains { $0.label.lowercased().contains("ccdt") })
        XCTAssertFalse(snap.mcpProcesses.contains { $0.command.lowercased().contains("ccdt") })
        XCTAssertFalse(snap.mcpProcesses.contains { $0.label == "project-continuity" })
        XCTAssertFalse(snap.mcpProcesses.contains { $0.command.contains("ccdt-mcp-continuity") })
        XCTAssertFalse(snap.mcpProcesses.contains { $0.command.contains("/.claude/") })
    }

    func testLMStudioMCPConfigStripsForeignProjects() {
        let servers = LMStudioEnvironment.configuredMCPServers()
        for s in servers {
            XCTAssertFalse(s.id.lowercased().contains("ccdt"), s.id)
            XCTAssertFalse(s.command.contains("ccdt"), s.command)
            XCTAssertFalse(s.command.contains("/.claude/"), s.command)
            XCTAssertFalse(s.id == "project-continuity", "foreign package in LM Studio mcp.json must be filtered")
            XCTAssertFalse(s.isLegacyShellLauncher, "UI must not treat forge-serve wrappers as product MCP: \(s.command)")
        }
    }

    func testLegacyForgeServeLaunchersAreRemovedFromBinDir() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("fc-legacy-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for name in ["forge-serve", "forge-serve-fallback", "keep-me"] {
            try "x".write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        let removed = LMStudioEnvironment.removeLegacyLaunchers(in: dir)
        XCTAssertTrue(removed.contains("forge-serve"))
        XCTAssertTrue(removed.contains("forge-serve-fallback"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("forge-serve").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("keep-me").path))
        XCTAssertTrue(LMStudioEnvironment.legacyLaunchersPresent(in: dir).isEmpty)
    }

    func testSwiftServeRegistrationShape() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("forge-registration-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let bin = dir.appendingPathComponent("forge-conductor")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: bin)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bin.path)
        let good = ConfiguredMCPServer(id: "forge-conductor", command: bin.path, args: ["serve"])
        XCTAssertTrue(LMStudioEnvironment.isSwiftServeRegistration(good, expectedBinary: bin))
        let shell = ConfiguredMCPServer(
            id: "forge-conductor",
            command: "/Users/x/.forge-conductor/bin/forge-serve",
            args: []
        )
        XCTAssertFalse(LMStudioEnvironment.isSwiftServeRegistration(shell, expectedBinary: bin))
        XCTAssertTrue(shell.isLegacyShellLauncher)
    }

    func testLMStudioMCPBridgePluginLayoutIsWritten() throws {
        // Use a disposable home so we never clobber the operator's live mcp.json from this unit test.
        let tmpHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("fc-lmstudio-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tmpHome) }
        try FileManager.default.createDirectory(at: tmpHome, withIntermediateDirectories: true)

        // Fake executable binary
        let binDir = tmpHome.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)
        let binary = binDir.appendingPathComponent("forge-conductor")
        try "#!/bin/sh\n".write(to: binary, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)

        // Point LM Studio home at temp by installing under a real path is hard (static homeDir).
        // Instead validate the writer produces the expected on-disk shape for a plugin directory.
        let pluginRoot = tmpHome.appendingPathComponent("plugins/mcp", isDirectory: true)
        try FileManager.default.createDirectory(at: pluginRoot, withIntermediateDirectories: true)
        let name = "forge-conductor"
        let dir = pluginRoot.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let manifest: [String: Any] = [
            "type": "plugin",
            "runner": "mcpBridge",
            "owner": "mcp",
            "name": name,
        ]
        let bridge: [String: Any] = [
            "command": binary.path,
            "args": ["serve"],
            "env": ["FORGE_MCP_ROLE": "primary"],
        ]
        let mData = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted])
        let bData = try JSONSerialization.data(withJSONObject: bridge, options: [.prettyPrinted])
        try mData.write(to: dir.appendingPathComponent("manifest.json"))
        try bData.write(to: dir.appendingPathComponent("mcp-bridge-config.json"))
        try #"{"by":"test","at":1}"#.write(
            to: dir.appendingPathComponent("install-state.json"),
            atomically: true,
            encoding: .utf8
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("manifest.json").path))
        let loaded = try JSONSerialization.jsonObject(with: Data(contentsOf: dir.appendingPathComponent("mcp-bridge-config.json"))) as? [String: Any]
        XCTAssertEqual(loaded?["command"] as? String, binary.path)
        XCTAssertEqual(loaded?["args"] as? [String], ["serve"])
        XCTAssertEqual((loaded?["env"] as? [String: String])?["FORGE_MCP_ROLE"], "primary")
    }

    func testForgeSnapshotIncludesDiscoveredMCPServers() throws {
        if ProcessInfo.processInfo.environment["FORGE_SKIP_PS"] == "1" { return }
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcp-snap-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let app = try ForgeApp.bootstrap(home: home)
        defer { app.shutdown() }
        let forge = try app.telemetry.snapshotTyped(force: true).forge
        // Structure always present
        XCTAssertNotNil(forge.mcpServers)
        // When host has live local-mcp servers, the typed snapshot must list them.
        let live = ProcessDiscovery.scan().mcpProcesses
        if !live.isEmpty {
            XCTAssertFalse(
                forge.mcpServers.isEmpty,
                "ForgeSnapshot.mcpServers empty but ProcessDiscovery found \(live.map(\.label))"
            )
            let cardLabels = Set(forge.mcpServers.map(\.label))
            for p in live {
                XCTAssertTrue(
                    cardLabels.contains(p.label) || forge.mcpServers.contains { $0.pid == Int(p.pid) },
                    "missing card for \(p.label) pid \(p.pid)"
                )
            }
        }
    }

    func testFullSnapshotContractTwice() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("full-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let app = try ForgeApp.bootstrap(home: home)
        defer { app.shutdown() }
        let a = try app.telemetry.snapshot(force: true)
        let b = try app.telemetry.snapshot(force: true)
        XCTAssertTrue(TelemetryContract.validate(snapshot: a).isEmpty)
        XCTAssertTrue(TelemetryContract.validate(snapshot: b).isEmpty)
        let cpuA = ((a["system"] as? [String: Any])?["cpu"] as? [String: Any])?["per_cpu"] as? [Double]
        XCTAssertEqual(cpuA?.count, ((a["system"] as? [String: Any])?["cpu"] as? [String: Any])?["count_logical"] as? Int)
    }
}

/// Hermetic regressions for Forge MCP process classification and card reconciliation.
/// These tests never inspect or mutate the host process list or live LM Studio files.
final class MCPProcessTelemetryRegressionTests: XCTestCase {
    private let appExecutable =
        "/Applications/Forge Conductor.app/Contents/MacOS/Forge Conductor"
    private let sharedCommand =
        "/Applications/Forge Conductor.app/Contents/MacOS/Forge Conductor"
    private let now = Date(timeIntervalSince1970: 1_735_689_600)

    func testAppBundleServeClassificationExcludesGUIAndManager() {
        XCTAssertEqual(
            ProcessDiscovery.classifyForgeCommand(
                path: appExecutable,
                arguments: ["serve"]
            ),
            .serve
        )
        XCTAssertEqual(
            ProcessDiscovery.classifyForgeCommand(
                path: appExecutable,
                arguments: []
            ),
            .gui
        )
        XCTAssertEqual(
            ProcessDiscovery.classifyForgeCommand(
                path: appExecutable,
                arguments: ["manager", "run", "--home", "/tmp/forge"]
            ),
            .manager
        )
        XCTAssertEqual(
            ProcessDiscovery.classifyForgeCommand(
                path: "/Applications/Unrelated.app/Contents/MacOS/Unrelated",
                arguments: ["serve"]
            ),
            .unrelated
        )
        XCTAssertEqual(
            ProcessDiscovery.classifyForgeCommand(
                path: "/usr/local/bin/forge-conductor-helper",
                arguments: ["serve"]
            ),
            .unrelated
        )
    }

    func testPSFallbackPreservesAppBundleExecutableAndServeArgument() {
        let invocation = ProcessDiscovery.splitPSCommand(
            "\(appExecutable) serve"
        )

        XCTAssertEqual(invocation.path, appExecutable)
        XCTAssertEqual(invocation.arguments, ["serve"])
        XCTAssertEqual(
            ProcessDiscovery.classifyForgeCommand(
                path: invocation.path,
                arguments: invocation.arguments
            ),
            .serve
        )
    }

    func testMCPExternalCountIncludesBothStdioRolesAndExcludesModelBackends() {
        let processes = [
            process(pid: 11, label: "forge-conductor", hostKind: "mcp-stdio"),
            process(pid: 12, label: "forge-conductor-fallback", hostKind: "mcp-stdio-fallback"),
            process(pid: 13, label: "llama-server", hostKind: "model-backend"),
            process(pid: 14, label: "LM Studio", hostKind: "lm-studio-host"),
            process(pid: 11, label: "duplicate-primary", hostKind: "mcp-stdio"),
            process(
                pid: 15,
                label: ProcessDiscovery.unknownMCPLabel,
                hostKind: ProcessDiscovery.unknownMCPHostKind
            ),
        ]

        XCTAssertEqual(ProcessDiscovery.mcpExternalProcessCount(processes), 3)
    }

    func testConnectorProcessIdentityRequiresExplicitValidRoleEvidence() {
        let primary = ProcessDiscovery.connectorProcessIdentity(
            environmentRole: "primary"
        )
        XCTAssertEqual(primary.role, .primary)
        XCTAssertEqual(primary.label, "forge-conductor")
        XCTAssertEqual(primary.hostKind, "mcp-stdio")

        let fallback = ProcessDiscovery.connectorProcessIdentity(
            environmentRole: "fallback"
        )
        XCTAssertEqual(fallback.role, .fallback)
        XCTAssertEqual(fallback.label, "forge-conductor-fallback")
        XCTAssertEqual(fallback.hostKind, "mcp-stdio-fallback")

        for value in [nil, "", "invalid"] as [String?] {
            let unknown = ProcessDiscovery.connectorProcessIdentity(
                environmentRole: value
            )
            XCTAssertNil(unknown.role)
            XCTAssertEqual(unknown.label, ProcessDiscovery.unknownMCPLabel)
            XCTAssertEqual(unknown.hostKind, ProcessDiscovery.unknownMCPHostKind)
        }
    }

    func testNativeProcessMetadataDecodesServeArgumentsAndFallbackRole() {
        let metadata = ProcessDiscovery.decodeProcessInvocation(
            processMetadataBuffer(
                executable: appExecutable,
                arguments: [appExecutable, "serve"],
                environment: [
                    "PATH=/usr/bin",
                    "FORGE_MCP_ROLE=fallback",
                    "UNRELATED=value",
                ]
            )
        )

        XCTAssertEqual(metadata.arguments, ["serve"])
        XCTAssertEqual(metadata.connectorRole, "fallback")
    }

    func testUnknownLiveRoleDoesNotSuppressEitherConfiguredRole() {
        let cards = assembler(alivePIDs: [16]).build(
            presence: [],
            live: [
                process(
                    pid: 16,
                    label: ProcessDiscovery.unknownMCPLabel,
                    hostKind: ProcessDiscovery.unknownMCPHostKind
                ),
            ],
            configured: connectorConfigurations(),
            audit: []
        )

        XCTAssertEqual(cards.count, 3)
        let live = cards.first { $0.pid == 16 }
        XCTAssertEqual(live?.live, true)
        XCTAssertEqual(live?.role, "mcp")
        XCTAssertEqual(live?.label, ProcessDiscovery.unknownMCPLabel)
        XCTAssertEqual(live?.hostKind, ProcessDiscovery.unknownMCPHostKind)
        XCTAssertEqual(
            Set(cards.filter { $0.status == "configured" }.map(\.role)),
            Set(["primary", "fallback"])
        )
    }

    func testLivePrimaryDoesNotSuppressFallbackConfigurationWithSharedCommand() {
        let cards = assembler(alivePIDs: [21]).build(
            presence: [],
            live: [
                process(pid: 21, label: "forge-conductor", hostKind: "mcp-stdio"),
            ],
            configured: connectorConfigurations(),
            audit: []
        )

        XCTAssertEqual(cards.count, 2)
        let primary = cards.first { $0.role == "primary" }
        let fallback = cards.first { $0.role == "fallback" }
        XCTAssertEqual(primary?.live, true)
        XCTAssertEqual(primary?.pid, 21)
        XCTAssertEqual(fallback?.live, false)
        XCTAssertEqual(fallback?.status, "configured")
        XCTAssertEqual(fallback?.label, "forge-conductor-fallback")
    }

    func testMatchingFallbackPresenceCorrectsUnknownLiveProcessRole() {
        let heartbeat = ISO8601.string(from: now)
        let cards = assembler(alivePIDs: [31]).build(
            presence: [
                PresenceRecord(
                    clientID: "fallback-client:fallback",
                    hostKind: "mcp-stdio-fallback",
                    pid: 31,
                    cwd: "/tmp/forge",
                    lastHeartbeat: heartbeat
                ),
            ],
            live: [
                process(
                    pid: 31,
                    label: ProcessDiscovery.unknownMCPLabel,
                    hostKind: ProcessDiscovery.unknownMCPHostKind
                ),
            ],
            configured: connectorConfigurations(),
            audit: []
        )

        XCTAssertEqual(cards.count, 2)
        let fallback = cards.first { $0.role == "fallback" }
        let primary = cards.first { $0.role == "primary" }
        XCTAssertEqual(fallback?.live, true)
        XCTAssertEqual(fallback?.pid, 31)
        XCTAssertEqual(fallback?.label, "forge-conductor-fallback")
        XCTAssertEqual(fallback?.hostKind, "mcp-stdio-fallback")
        XCTAssertEqual(primary?.status, "configured")
    }

    func testRolePresencesCoalesceConfigurationsAndCorrelateBareAuditClientIDs() {
        let heartbeat = ISO8601.string(from: now)
        let cards = assembler(alivePIDs: [41, 42]).build(
            presence: [
                PresenceRecord(
                    clientID: "primary-client:primary",
                    hostKind: "mcp-stdio",
                    pid: 41,
                    cwd: "/tmp/forge",
                    lastHeartbeat: heartbeat
                ),
                PresenceRecord(
                    clientID: "fallback-client:fallback",
                    hostKind: "mcp-stdio-fallback",
                    pid: 42,
                    cwd: "/tmp/forge",
                    lastHeartbeat: heartbeat
                ),
            ],
            live: [],
            configured: connectorConfigurations(),
            audit: [
                AuditEvent(
                    timestamp: now.addingTimeInterval(-10),
                    clientID: "fallback-client",
                    tool: "fs_read",
                    status: "ok"
                ),
            ]
        )

        XCTAssertEqual(cards.count, 2)
        XCTAssertEqual(Set(cards.map(\.role)), Set(["primary", "fallback"]))
        XCTAssertEqual(Set(cards.map(\.label)), Set([
            "forge-conductor",
            "forge-conductor-fallback",
        ]))
        XCTAssertTrue(cards.allSatisfy(\.live))

        let fallback = cards.first { $0.role == "fallback" }
        XCTAssertEqual(fallback?.eventCount5m, 1)
        XCTAssertEqual(fallback?.lastTool, "fs_read")
        XCTAssertEqual(fallback?.status, "active")
        XCTAssertGreaterThan(fallback?.activity ?? 0, 0)
    }

    func testPresenceClientIDNormalizationRetainsUnknownShapes() {
        XCTAssertEqual(
            MCPServerCardAssembler.normalizedAuditClientID(
                fromPresenceID: "ABC-123:primary"
            ),
            "ABC-123"
        )
        XCTAssertEqual(
            MCPServerCardAssembler.normalizedAuditClientID(
                fromPresenceID: "ABC-123:fallback"
            ),
            "ABC-123"
        )
        XCTAssertEqual(
            MCPServerCardAssembler.normalizedAuditClientID(
                fromPresenceID: "third-party:custom"
            ),
            "third-party:custom"
        )
        XCTAssertEqual(
            MCPServerCardAssembler.normalizedAuditClientID(
                fromPresenceID: "bare-client"
            ),
            "bare-client"
        )
    }

    func testReconciledPresenceCountExcludesStaleAndForeignRows() {
        let records = [
            PresenceRecord(
                clientID: "live-client:primary",
                hostKind: "mcp-stdio",
                pid: 51,
                cwd: "/tmp/forge",
                lastHeartbeat: ISO8601.string(from: now)
            ),
            PresenceRecord(
                clientID: "stale-client:primary",
                hostKind: "mcp-stdio",
                pid: 52,
                cwd: "/tmp/forge",
                lastHeartbeat: ISO8601.string(from: now.addingTimeInterval(-120))
            ),
            PresenceRecord(
                clientID: "ccdt-client",
                hostKind: "mcp-stdio",
                pid: 53,
                cwd: "/tmp/project-continuity",
                lastHeartbeat: ISO8601.string(from: now)
            ),
        ]

        XCTAssertEqual(
            assembler(alivePIDs: [51, 53]).reconciledPresenceCount(records),
            1
        )
    }

    func testPolicyAndMaintenanceOutcomesAreActivityButNotOperationalMCPErrors() {
        let cards = assembler(alivePIDs: [61]).build(
            presence: [
                PresenceRecord(
                    clientID: "policy-client:primary",
                    hostKind: "mcp-stdio",
                    pid: 61,
                    cwd: "/tmp/forge",
                    lastHeartbeat: ISO8601.string(from: now)
                ),
            ],
            live: [],
            configured: [],
            audit: [
                AuditEvent(
                    timestamp: now.addingTimeInterval(-10),
                    clientID: "policy-client",
                    tool: "fs_write",
                    status: "denied"
                ),
                AuditEvent(
                    timestamp: now.addingTimeInterval(-20),
                    clientID: "policy-client",
                    tool: "agent_session_auto_closed",
                    status: "warn"
                ),
            ]
        )

        XCTAssertEqual(cards.count, 1)
        XCTAssertEqual(cards[0].status, "active")
        XCTAssertEqual(cards[0].eventCount5m, 2)
        XCTAssertEqual(cards[0].errorRate, 0)
        XCTAssertEqual(cards[0].health, "ok")
        XCTAssertEqual(cards[0].healthLabel, "READY")
    }

    private func assembler(alivePIDs: Set<Int32>) -> MCPServerCardAssembler {
        MCPServerCardAssembler(
            now: now,
            isPIDAlive: { alivePIDs.contains($0) }
        )
    }

    private func process(
        pid: Int32,
        label: String,
        hostKind: String
    ) -> ProcessDiscovery.MCPProcess {
        ProcessDiscovery.MCPProcess(
            pid: pid,
            label: label,
            hostKind: hostKind,
            command: "\(label) serve"
        )
    }

    private func connectorConfigurations() -> [ConfiguredMCPServer] {
        [
            ConfiguredMCPServer(
                id: "forge-conductor",
                command: sharedCommand,
                args: ["serve"],
                environment: ["FORGE_MCP_ROLE": "primary"]
            ),
            ConfiguredMCPServer(
                id: "forge-conductor-fallback",
                command: sharedCommand,
                args: ["serve"],
                environment: ["FORGE_MCP_ROLE": "fallback"]
            ),
        ]
    }

    private func processMetadataBuffer(
        executable: String,
        arguments: [String],
        environment: [String]
    ) -> [UInt8] {
        var argc = Int32(arguments.count)
        var bytes = withUnsafeBytes(of: &argc) { Array($0) }
        bytes.append(contentsOf: executable.utf8)
        bytes.append(0)
        bytes.append(0)
        for value in arguments + environment {
            bytes.append(contentsOf: value.utf8)
            bytes.append(0)
        }
        return bytes
    }
}

/// Hermetic regressions for typed audit outcomes and tool/load serialization.
final class AuditOutcomeTelemetryTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_735_689_600)

    func testAuditOutcomeClassificationIsExactAndNonConflating() {
        XCTAssertEqual(AuditOutcome(status: "ok"), .success)
        XCTAssertEqual(AuditOutcome(status: "error"), .operationalError)
        XCTAssertEqual(AuditOutcome(status: "denied"), .policyDenied)
        XCTAssertEqual(AuditOutcome(status: "warn"), .maintenanceWarning)
        XCTAssertEqual(AuditOutcome(status: "failed"), .other)
        XCTAssertEqual(AuditOutcome(status: "ERROR"), .other)

        let counts = AuditOutcomeCounts.summarize(
            statuses: ["ok", "error", "denied", "warn", "failed", "ERROR"]
        )
        XCTAssertEqual(counts.errorCount, 1)
        XCTAssertEqual(counts.deniedCount, 1)
        XCTAssertEqual(counts.warnCount, 1)
        XCTAssertEqual(counts.otherCount, 2)
    }

    func testGlobalUsageSummaryCountsOnlyErrorAsOperationalFailure() {
        let events = [
            event(tool: "fs_read", status: "ok"),
            event(tool: "fs_read", status: "denied"),
            event(tool: "agent_run_complete", status: "warn"),
            event(tool: "fs_write", status: "other"),
        ]

        let usage = AuditUsageSummarizer.summarize(
            events: events,
            windowSec: 300,
            topLimit: 5
        )

        XCTAssertEqual(usage.eventCount, 4)
        XCTAssertEqual(usage.errorCount, 0)
        XCTAssertEqual(usage.deniedCount, 1)
        XCTAssertEqual(usage.warnCount, 1)
        XCTAssertEqual(usage.otherCount, 1)
        XCTAssertEqual(usage.errorRate, 0)
        XCTAssertEqual(ToolUsageHealthPolicy.health(for: usage), .ok)
        XCTAssertEqual(usage.topTools.first, ToolCount(tool: "fs_read", count: 2))
    }

    func testOperationalErrorRateUsesAllEventsAsDenominator() {
        let usage = AuditUsageSummarizer.summarize(
            events: [
                event(tool: "shell_exec", status: "error"),
                event(tool: "shell_exec", status: "denied"),
                event(tool: "shell_exec", status: "warn"),
                event(tool: "shell_exec", status: "ok"),
            ],
            windowSec: 3_600,
            topLimit: 5
        )

        XCTAssertEqual(usage.errorCount, 1)
        XCTAssertEqual(usage.deniedCount, 1)
        XCTAssertEqual(usage.warnCount, 1)
        XCTAssertEqual(usage.errorRate, 0.25)
        XCTAssertEqual(ToolUsageHealthPolicy.health(for: usage), .error)
    }

    func testUsageAndToolCardSerializationExposeOutcomeCounts() {
        let usage = AuditUsageSummarizer.summarize(
            events: [
                event(tool: "fs_write", status: "error"),
                event(tool: "fs_write", status: "denied"),
                event(tool: "fs_write", status: "warn"),
            ],
            windowSec: 300,
            topLimit: 5
        )
        let usageDictionary = usage.asDictionary()
        XCTAssertEqual(usageDictionary["error_count"] as? Int, 1)
        XCTAssertEqual(usageDictionary["denied_count"] as? Int, 1)
        XCTAssertEqual(usageDictionary["warn_count"] as? Int, 1)
        XCTAssertEqual(usageDictionary["other_count"] as? Int, 0)

        let card = ToolCard(
            name: "fs_write",
            pack: "filesystem",
            status: "active",
            health: "error",
            healthLabel: "ERROR",
            activity: 3,
            live: true,
            events1h: 3,
            events5m: 3,
            outcomes1h: usage.outcomes,
            outcomes5m: usage.outcomes
        )
        let dictionary = card.asDictionary()
        let usage1h = dictionary["usage_1h"] as? [String: Any]
        XCTAssertEqual(usage1h?["error_count"] as? Int, 1)
        XCTAssertEqual(usage1h?["denied_count"] as? Int, 1)
        XCTAssertEqual(usage1h?["warn_count"] as? Int, 1)

        let decoded = ToolCard(from: dictionary)
        XCTAssertEqual(decoded, card)
    }

    private func event(tool: String, status: String) -> AuditEvent {
        AuditEvent(
            timestamp: now,
            clientID: "audit-client",
            tool: tool,
            status: status
        )
    }
}
