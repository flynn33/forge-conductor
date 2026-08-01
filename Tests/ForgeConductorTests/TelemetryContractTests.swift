// TelemetryContractTests.swift
// Verifies that typed telemetry and JSON projections expose the documented schema.
// The contract suite catches collector/UI drift at the Core boundary.

import XCTest
@testable import ForgeConductorCore

/// Contract tests: native telemetry snapshot must expose UI-required keys.
final class TelemetryContractTests: XCTestCase {
    func testNativeSnapshotProducesContractKeys() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("forge-contract-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let app = try ForgeApp.bootstrap(home: home)
        let snap = try app.telemetry.snapshot(force: true)
        let missing = TelemetryContract.validate(snapshot: snap)
        XCTAssertTrue(missing.isEmpty, "Missing contract keys: \(missing)")

        let system = snap["system"] as! [String: Any]
        let forge = snap["forge"] as! [String: Any]
        XCTAssertNotNil(system["cpu"])
        XCTAssertNotNil(system["ram"])
        XCTAssertNotNil(system["gpu"])
        XCTAssertNotNil(forge["agents"])
        XCTAssertNotNil(forge["live_feed"])
        XCTAssertNotNil(forge["mcp_load"])
        XCTAssertNotNil(forge["orchestration"])
        XCTAssertNotNil(forge["mcp_servers"])
        XCTAssertNotNil(forge["mcp_tools"])

        let hist = snap["history"] as? [[String: Any]] ?? []
        XCTAssertFalse(hist.isEmpty)
    }

    func testFixtureContractKeysFile() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/telemetry_contract_keys.json")
        guard let data = try? Data(contentsOf: url),
              let gold = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw XCTSkip("fixture missing")
        }
        let systemKeys = Set(gold["system_keys"] as? [String] ?? [])
        let forgeKeys = Set(gold["forge_keys"] as? [String] ?? [])
        // Fixture may list a superset (legacy Node fields). Required contract keys must be covered.
        XCTAssertTrue(systemKeys.isSuperset(of: TelemetryContract.systemKeys)
            || systemKeys == TelemetryContract.systemKeys)
        XCTAssertTrue(forgeKeys.isSuperset(of: TelemetryContract.forgeKeys)
            || TelemetryContract.forgeKeys.isSubset(of: forgeKeys))
    }
}
