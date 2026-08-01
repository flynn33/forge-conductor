// NativeAppSmokeTests.swift
// Smoke-tests the Core composition consumed by the macOS SwiftUI application.
// It verifies that telemetry, manager, and agent modules can coexist in one runtime.

import XCTest
@testable import ForgeConductorCore

/// Smoke coverage for native app composition (stand-in until XCUITest host is expanded).
/// Verifies the modules the GUI binds to: telemetry typed path, manager control, catalog playbooks.
final class NativeAppSmokeTests: XCTestCase {
    func testNativeCompositionRootReadyForGUI() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("gui-smoke-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let app = try ForgeApp.bootstrap(home: home)
        defer { app.shutdown() }

        // Unique port so parallel tests / live install never clash.
        _ = try app.config.update([
            "dashboard": ["port": Int.random(in: 19_000...28_000)] as [String: Any],
        ], save: true)

        let node = ManagerNode(app: app)
        let started = try node.startService()
        XCTAssertTrue(started.serviceActive)
        XCTAssertEqual(started.state, .running)

        let snap = try app.telemetry.snapshotTyped(force: true)
        XCTAssertEqual(snap.runtime, TelemetryService.runtimeIdentifier)
        XCTAssertFalse(snap.system.cpu.perCPU.isEmpty)
        XCTAssertNotNil(snap.system.cpu.freqMHz)
        XCTAssertFalse(snap.forge.mcpTools.isEmpty)
        XCTAssertGreaterThanOrEqual(snap.forge.agents.count, 10)

        // Manager settings patch (typed) round-trips into ConfigStore model
        _ = try node.updateSettings(
            ManagerSettingsPatch(dashboardRefreshSec: 11, autoRestart: true),
            apply: true
        )
        XCTAssertEqual(app.config.model.dashboard.refreshIntervalSec, 11)

        let doctor = try app.doctorModel()
        XCTAssertTrue(doctor.ok)

        _ = try node.stopService()
        XCTAssertFalse(node.isServiceActive())
    }

    func testAllAgentPlaybooksRequireCompletion() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("play-smoke-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let app = try ForgeApp.bootstrap(home: home)
        defer { app.shutdown() }
        for agent in app.catalog.all() {
            let completeMentions =
                agent.body.localizedCaseInsensitiveContains("agent_run_complete")
                || agent.doneDefinition.contains { $0.localizedCaseInsensitiveContains("agent_run_complete") }
            XCTAssertTrue(completeMentions, "\(agent.id) must require agent_run_complete")
            XCTAssertFalse(agent.outputSchema.isEmpty, "\(agent.id) needs output_schema")
        }
    }
}
