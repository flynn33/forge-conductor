// NativeTelemetryTests.swift
// Verifies the all-native telemetry path and its runtime/health declarations.
// The cases ensure the product does not silently fall back to an external runtime.

import XCTest
@testable import ForgeConductorCore

final class NativeTelemetryTests: XCTestCase {
    func testNativeSnapshotContractWithoutNode() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("forge-native-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let app = try ForgeApp.bootstrap(home: home)
        defer { app.shutdown() }
        let health = app.telemetry.health()
        XCTAssertTrue(
            health.runtime == "swift-native" || health.runtime == "swift-native-realtime",
            "runtime=\(health.runtime)"
        )
        XCTAssertEqual(health.ok, true)
        XCTAssertEqual(health.nodeRequired, false)

        let snap = try app.telemetry.snapshot(force: true)
        let missing = TelemetryContract.validate(snapshot: snap)
        XCTAssertTrue(missing.isEmpty, "Missing keys: \(missing)")

        let system = snap["system"] as? [String: Any]
        XCTAssertNotNil(system?["cpu"])
        XCTAssertNotNil(system?["ram"])

        let forge = snap["forge"] as? [String: Any]
        XCTAssertNotNil(forge?["orchestration"])
        XCTAssertNotNil(forge?["mcp_servers"])
        XCTAssertNotNil(forge?["agents"])
        let fr = forge?["runtime"] as? String ?? ""
        XCTAssertTrue(fr.contains("swift-native"), "forge runtime=\(fr)")

        let orch = forge?["orchestration"] as? [String: Any]
        XCTAssertNotNil(orch?["health"])
        XCTAssertNotNil(orch?["mode"])
    }

    func testProcessDiscoveryDoesNotCrash() {
        let snap = ProcessDiscovery.scan()
        // No assertion on counts — machine dependent — just type stability.
        XCTAssertNotNil(snap.managerPIDs)
        XCTAssertNotNil(snap.mcpProcesses)
    }

    func testDoctorUsesNativeTelemetry() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("forge-doc-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let app = try ForgeApp.bootstrap(home: home)
        defer { app.shutdown() }
        let doctor = try app.doctor()
        XCTAssertEqual(doctor["ok"] as? Bool, true, "\(doctor)")
        let checks = doctor["checks"] as? [[String: Any]] ?? []
        let names = checks.compactMap { $0["name"] as? String }
        XCTAssertTrue(names.contains("telemetry_native"))
        XCTAssertFalse(names.contains("telemetry_node"))
    }
}
