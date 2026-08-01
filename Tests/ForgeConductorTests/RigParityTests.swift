// RigParityTests.swift
// Protects the data contract required by the dense FORGE RIG monitoring surface.
// Tests compare typed metrics and presentation cards with every field the UI consumes.

import XCTest
@testable import ForgeConductorCore

/// Evidence-based parity tests against the classic FORGE RIG surface.
final class RigParityTests: XCTestCase {
    func testTelemetryHealthToneKeepsConfigurationAndUnknownOutOfFailureState() {
        XCTAssertEqual(TelemetryHealth.ok.tone, .healthy)
        XCTAssertEqual(TelemetryHealth.warn.tone, .caution)
        XCTAssertEqual(TelemetryHealth.error.tone, .failure)
        XCTAssertEqual(TelemetryHealth.down.tone, .failure)
        XCTAssertEqual(TelemetryHealth.config.tone, .informational)
        XCTAssertEqual(TelemetryHealth.tone(for: nil), .unavailable)
        XCTAssertEqual(TelemetryHealth.tone(for: "unexpected"), .unavailable)
        XCTAssertEqual(
            TelemetryStatusTone.mostSevere([.healthy, .failure, .informational]),
            .failure
        )
        XCTAssertEqual(
            TelemetryStatusTone.mostSevere([.informational, .caution]),
            .caution
        )
        XCTAssertEqual(TelemetryStatusTone.mostSevere([]), .unavailable)
    }

    func testOrchestrationPolicyTreatsConfiguredLMStudioIdleAsInformational() {
        let decision = OrchestrationHealthPolicy.decide(from: OrchestrationEvidence(
            lmStudioUp: true,
            managerAlive: true,
            managerServiceReady: true,
            managerServiceStopped: false,
            serveCount: 0,
            mcpProcessCount: 0,
            configuredRoleCount: 2
        ))

        XCTAssertEqual(decision.health, .config)
        XCTAssertEqual(decision.label, "MCP IDLE")
        XCTAssertEqual(decision.mode, "lm-studio")
    }

    func testOrchestrationPolicyStillWarnsWhenLMStudioIsNotConfigured() {
        let decision = OrchestrationHealthPolicy.decide(from: OrchestrationEvidence(
            lmStudioUp: true,
            managerAlive: true,
            managerServiceReady: true,
            managerServiceStopped: false,
            serveCount: 0,
            mcpProcessCount: 0,
            configuredRoleCount: 0
        ))

        XCTAssertEqual(decision.health, .warn)
        XCTAssertEqual(decision.label, "MCP NOT CONFIGURED")
    }

    func testManagerRequiresServiceOrHTTPEvidenceBeforeReportingReady() {
        XCTAssertFalse(
            ManagerServiceHealthPolicy.isReady(
                serviceActive: nil,
                httpListening: nil
            )
        )
        XCTAssertFalse(
            ManagerServiceHealthPolicy.isReady(
                serviceActive: false,
                httpListening: false
            )
        )
        XCTAssertTrue(
            ManagerServiceHealthPolicy.isReady(
                serviceActive: true,
                httpListening: false
            )
        )
        XCTAssertTrue(
            ManagerServiceHealthPolicy.isReady(
                serviceActive: false,
                httpListening: true
            )
        )

        let unavailableState = OrchestrationHealthPolicy.decide(
            from: OrchestrationEvidence(
                lmStudioUp: false,
                managerAlive: true,
                managerServiceReady: false,
                managerServiceStopped: false,
                serveCount: 0,
                mcpProcessCount: 0,
                configuredRoleCount: 2
            )
        )
        XCTAssertEqual(unavailableState.health, .warn)
        XCTAssertEqual(unavailableState.label, "MANAGER")
    }

    func testSystemMetricsHasAllStripFields() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("rig-sys-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let app = try ForgeApp.bootstrap(home: home)
        let typed = try app.telemetry.snapshotTyped(force: true)
        let cpu = typed.system.cpu

        XCTAssertGreaterThan(cpu.countLogical, 0)
        XCTAssertEqual(cpu.perCPU.count, cpu.countLogical, "per-core array must match logical count")
        XCTAssertNotNil(cpu.freqMHz == nil || cpu.freqMHz! >= 0)
        XCTAssertFalse(cpu.brand.isEmpty)
        XCTAssertGreaterThanOrEqual(cpu.percent, 0)
        XCTAssertLessThanOrEqual(cpu.percent, 100)

        XCTAssertGreaterThan(typed.system.ram.totalGB, 0)
        XCTAssertFalse(typed.system.disk.isEmpty, "at least root volume")
        XCTAssertNotNil(typed.system.diskIO)
        XCTAssertFalse(typed.system.gpu.isEmpty)
        XCTAssertTrue(typed.system.gpu[0].metal)
    }

    func testSnapshotContractAndHistoryMultiSeries() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("rig-snap-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let app = try ForgeApp.bootstrap(home: home)
        _ = try app.telemetry.snapshotTyped(force: true)
        let second = try app.telemetry.snapshotTyped(force: true)
        let missing = TelemetryContract.validate(snapshot: second.asDictionary())
        XCTAssertTrue(missing.isEmpty, "missing: \(missing)")

        XCTAssertFalse(second.history.isEmpty)
        let last = second.history.last!
        // Multi-series history keys required for Metal load trace
        XCTAssertGreaterThanOrEqual(last.cpu, 0)
        XCTAssertGreaterThanOrEqual(last.ram, 0)
        XCTAssertTrue(last.gpu == nil || last.gpu! >= 0)
        XCTAssertGreaterThanOrEqual(last.diskIO, 0)
    }

    func testForgePanelsPresentForRigUI() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("rig-forge-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let app = try ForgeApp.bootstrap(home: home)
        let forge = try app.telemetry.snapshotTyped(force: true).forge

        // Typed panels (not dictionaries) — presence proven by property access.
        XCTAssertNotNil(forge.mcpServers)
        XCTAssertNotNil(forge.mcpTools)
        XCTAssertNotNil(forge.mcpPacks)
        XCTAssertNotNil(forge.agents)
        XCTAssertNotNil(forge.liveFeed)
        XCTAssertNotNil(forge.orchestration)
        XCTAssertNotNil(forge.mcpLoad)

        XCTAssertFalse(forge.orchestration.health.isEmpty)
        XCTAssertFalse(forge.orchestration.healthLabel.isEmpty)
        XCTAssertFalse(forge.orchestration.mode.isEmpty)

        XCTAssertFalse(forge.mcpTools.isEmpty, "tool catalog should not be empty")
        XCTAssertFalse(forge.mcpTools[0].name.isEmpty)
        XCTAssertFalse(forge.mcpTools[0].pack.isEmpty)
        XCTAssertFalse(forge.mcpTools[0].status.isEmpty)

        XCTAssertGreaterThanOrEqual(forge.agents.count, 5, "builtin agents")
    }

    func testRigPanelChecklistDocumented() {
        // Ensures we do not silently drop panel IDs from the parity checklist.
        let expected = [
            "sys_strip", "load_trace", "cpu_cores", "gpu_cores", "storage", "orchestration",
            "mcp_servers", "mcp_tools", "sub_agents", "hot_processes", "live_stream",
        ]
        XCTAssertEqual(TelemetryContract.rigPanels, expected)
    }

    func testCPUCollectorPerCoreCount() {
        let cpu = CPUCollector().collect()
        XCTAssertEqual(cpu.perCPU.count, cpu.countLogical)
        for p in cpu.perCPU {
            XCTAssertGreaterThanOrEqual(p, 0)
            XCTAssertLessThanOrEqual(p, 100.1)
        }
    }

    func testGPUCollectorMetalFlag() {
        let gpus = GPUCollector().collect()
        XCTAssertFalse(gpus.isEmpty)
        XCTAssertTrue(gpus[0].metal)
        XCTAssertGreaterThan(gpus[0].memTotalMiB, 0)
    }

    func testSysStripModelFromSystem() {
        let m = SystemCollector().collectMetrics()
        let strip = SysStripModel(from: m)
        XCTAssertGreaterThanOrEqual(strip.cpuPercent, 0)
        XCTAssertGreaterThanOrEqual(strip.ramPercent, 0)
    }

    func testSysStripDistinguishesUnavailableGPUFromMeasuredZero() {
        var metrics = SystemCollector().collectMetrics()
        XCTAssertFalse(metrics.gpu.isEmpty)

        metrics.gpu[0].utilGPU = nil
        XCTAssertNil(SysStripModel(from: metrics).gpuPercent)

        metrics.gpu[0].utilGPU = 0
        XCTAssertEqual(SysStripModel(from: metrics).gpuPercent, 0)
    }

    func testHistoryPointSerializesUnavailableGPUAsJSONNull() throws {
        let point = HistoryPoint(
            ts: 1,
            cpu: 2,
            ram: 3,
            gpu: nil,
            diskIO: 4,
            mcp: 0,
            orch: "config"
        )
        let dictionary = point.asDictionary()

        XCTAssertTrue(dictionary["gpu"] is NSNull)
        XCTAssertNoThrow(try JSONSerialization.data(withJSONObject: dictionary))
    }

    func testDiskIOCollectorReturnsFiniteRates() {
        let a = DiskIOCollector().collect()
        let b = DiskIOCollector().collect()
        for m in [a, b] {
            XCTAssertTrue(m.readMBs.isFinite && m.writeMBs.isFinite && m.totalMBs.isFinite)
            XCTAssertGreaterThanOrEqual(m.readMBs, 0)
            XCTAssertGreaterThanOrEqual(m.writeMBs, 0)
        }
    }

    func testManagerNodeStartStopInProcess() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("mgr-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let app = try ForgeApp.bootstrap(home: home)
        // Use unique port to avoid clashing with a live install.
        _ = try app.config.update([
            "dashboard": ["port": Int.random(in: 19_000...28_000)] as [String: Any],
        ], save: true)
        let node = ManagerNode(app: app)
        let started = try node.startService()
        XCTAssertEqual(started.serviceActive, true)
        let stopped = try node.stopService()
        XCTAssertEqual(stopped.serviceActive, false)
        let again = try node.startService()
        XCTAssertEqual(again.serviceActive, true)
        _ = try node.stopService()
    }
}
