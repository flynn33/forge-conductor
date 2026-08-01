// AppConfigAndDoctorTests.swift
// Verifies configuration round trips, settings patches, health reports, and doctor output.
// These tests protect the typed operator-facing contracts shared by CLI and native app.

import XCTest
@testable import ForgeConductorCore

final class AppConfigAndDoctorTests: XCTestCase {
    func testAppConfigRoundTripDictionary() {
        var cfg = AppConfig.default
        cfg.dashboard.port = 8899
        cfg.manager.autoRestart = false
        cfg.logLevel = "debug"
        let restored = AppConfig.fromDictionary(cfg.asDictionary())
        XCTAssertEqual(restored.dashboard.port, 8899)
        XCTAssertEqual(restored.manager.autoRestart, false)
        XCTAssertEqual(restored.logLevel, "debug")
    }

    func testAppConfigApplySettingsPatch() {
        let cfg = AppConfig.default.applying(settings: ManagerSettingsPatch(
            dashboardPort: 9001,
            watchdogIntervalSec: 7
        ))
        XCTAssertEqual(cfg.dashboard.port, 9001)
        XCTAssertEqual(cfg.manager.watchdogIntervalSec, 7)
    }

    func testConfigStoreTypedModel() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("cfg-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let paths = AppPaths(home: home)
        try paths.ensureLayout()
        let store = ConfigStore(paths: paths)
        _ = try store.update(["dashboard": ["port": 8123] as [String: Any]], save: true)
        store.reload()
        XCTAssertEqual(store.model.dashboard.port, 8123)
        _ = try store.update(ManagerSettingsPatch(dashboardHost: "127.0.0.1", autoRestart: false), save: true)
        XCTAssertEqual(store.model.manager.autoRestart, false)
    }

    func testDoctorModelTyped() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("docm-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let app = try ForgeApp.bootstrap(home: home)
        defer { app.shutdown() }
        let report = try app.doctorModel()
        XCTAssertTrue(report.ok)
        XCTAssertFalse(report.checks.isEmpty)
        XCTAssertEqual(report.telemetry.runtime, TelemetryService.runtimeIdentifier)
        let edge = try app.doctor()
        XCTAssertEqual(edge["ok"] as? Bool, true)
    }

    func testStatusSnapshotModel() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("stat-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let app = try ForgeApp.bootstrap(home: home)
        defer { app.shutdown() }
        let snap = try app.statusSnapshotModel()
        XCTAssertTrue(snap.ok)
        XCTAssertEqual(snap.runtime, "swift")
        XCTAssertGreaterThanOrEqual(snap.agentCount, 10)
        XCTAssertFalse(snap.tools.isEmpty)
    }

    func testCPUFrequencyNonNilOnThisMac() {
        let cpu = CPUCollector().collect()
        // Effective / sysctl frequency path must always produce a value on macOS.
        XCTAssertNotNil(cpu.freqMHz, "freq_mhz should not be nil")
        XCTAssertGreaterThan(cpu.freqMHz ?? 0, 400)
        XCTAssertEqual(cpu.freqPerCoreMHz?.count, cpu.countLogical)
    }

    func testCPUFrequencyEstimatorClusterEffective() {
        let util = Array(repeating: 80.0, count: 8) + Array(repeating: 10.0, count: 4)
        let est = CPUFrequencyEstimator.estimate(
            brand: "Apple M4 Pro",
            model: "Mac16,8",
            perCoreUtilization: util
        )
        XCTAssertEqual(est.source, "cluster-util-effective")
        XCTAssertGreaterThan(est.averageMHz, 1000)
        XCTAssertEqual(est.perCoreMHz.count, 12)
        // Busy cores should report higher effective MHz than idle-ish ones.
        XCTAssertGreaterThan(est.perCoreMHz[0], est.perCoreMHz[10])
    }

    func testManagerRuntimeIsolation() {
        let rt = ManagerRuntime()
        XCTAssertEqual(rt.state, .stopped)
        rt.markRunning()
        XCTAssertEqual(rt.state, .running)
        XCTAssertNotNil(rt.startedAt)
        let n = rt.beginRestart()
        XCTAssertEqual(n, 1)
        XCTAssertEqual(rt.state, .restarting)
    }
}
