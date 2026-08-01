// DashboardTests.swift
// Starts the real native dashboard server and validates its principal HTTP resources.
// Random loopback ports keep integration coverage isolated and safe for parallel runs.

import XCTest
@testable import ForgeConductorCore

final class DashboardTests: XCTestCase {
    func testDashboardStartsAndServesStatus() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("forge-dash-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let app = try ForgeApp.bootstrap(home: home)
        let port = UInt16.random(in: 18_000...28_000)
        let server = DashboardServer(app: app, host: "127.0.0.1", port: port)
        try server.start()
        defer { server.stop(); app.shutdown() }
        Thread.sleep(forTimeInterval: 0.15)

        let url = URL(string: "http://127.0.0.1:\(port)/api/status")!
        let (data, http) = try HTTPTestHelpers.fetch(url)
        XCTAssertEqual(http.statusCode, 200)
        let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(payload?["ok"] as? Bool, true)
        XCTAssertEqual(payload?["runtime"] as? String, "swift")
        XCTAssertEqual(payload?["version"] as? String, ForgeApp.version)
    }

    func testDashboardIndexHTML() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("forge-dash2-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }

        // Seed production telemetry UI so / serves FORGE RIG (same path as live install).
        try Self.seedTelemetryStatic(into: home)

        let app = try ForgeApp.bootstrap(home: home)
        let port = UInt16.random(in: 18_000...28_000)
        let server = DashboardServer(app: app, host: "127.0.0.1", port: port)
        try server.start()
        defer { server.stop(); app.shutdown() }
        Thread.sleep(forTimeInterval: 0.15)

        let url = URL(string: "http://127.0.0.1:\(port)/")!
        let (data, http) = try HTTPTestHelpers.fetch(url)
        XCTAssertEqual(http.statusCode, 200)
        let body = String(data: data, encoding: .utf8) ?? ""
        // Package resources serve FORGE RIG; fallback control surface uses Forge-Conductor.
        let okTitle = body.contains("FORGE") || body.contains("Forge-Conductor") || body.contains("Forge Conductor")
        XCTAssertTrue(okTitle, "Unexpected index body prefix: \(body.prefix(120))")
        XCTAssertTrue(
            body.contains("/api/snapshot") || body.contains("/api/status") || body.contains("api/"),
            "Index should reference a telemetry or status API"
        )
        // Main dashboard must expose a clear shortcut to the management console.
        XCTAssertTrue(
            body.contains("href=\"/control\"") || body.contains("href='/control'"),
            "Dashboard must link to /control management console"
        )
        XCTAssertTrue(
            body.contains("MANAGEMENT CONSOLE") || body.contains("Management Console") || body.contains("Manager controls"),
            "Dashboard must label the management console shortcut clearly"
        )
    }

    /// Copy source TelemetryStatic into a test home so loadStatic serves the production UI.
    private static func seedTelemetryStatic(into home: URL) throws {
        let fm = FileManager.default
        let dest = home.appendingPathComponent("telemetry/static", isDirectory: true)
        try fm.createDirectory(at: dest, withIntermediateDirectories: true)

        let srcRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // ForgeConductorTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // repo root
            .appendingPathComponent("Sources/ForgeConductorCore/Resources/TelemetryStatic")

        for name in ["index.html", "style.css", "app.js"] {
            let src = srcRoot.appendingPathComponent(name)
            let out = dest.appendingPathComponent(name)
            if fm.fileExists(atPath: out.path) {
                try fm.removeItem(at: out)
            }
            guard fm.fileExists(atPath: src.path) else {
                XCTFail("Missing source static file: \(src.path)")
                return
            }
            try fm.copyItem(at: src, to: out)
        }
    }

    func testControlSurfaceHasManagerControls() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("forge-dash3-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let app = try ForgeApp.bootstrap(home: home)
        let port = UInt16.random(in: 18_000...28_000)
        let server = DashboardServer(app: app, host: "127.0.0.1", port: port)
        try server.start()
        defer { server.stop(); app.shutdown() }
        Thread.sleep(forTimeInterval: 0.15)

        let url = URL(string: "http://127.0.0.1:\(port)/control")!
        let (data, http) = try HTTPTestHelpers.fetch(url)
        XCTAssertEqual(http.statusCode, 200)
        let body = String(data: data, encoding: .utf8) ?? ""
        XCTAssertTrue(body.contains("/api/manager/start"), body.prefix(200).description)
        XCTAssertTrue(body.contains("/api/manager/stop"))
        XCTAssertTrue(body.contains("/api/manager/settings") || body.contains("Settings"))
        XCTAssertTrue(
            body.contains("href=\"/\"") || body.contains("Telemetry dashboard"),
            "Control surface should link back to telemetry dashboard"
        )
    }
}
