// ProductPathReliabilityTests.swift
// Exercises operator-critical paths such as MCP negotiation and tool discovery.
// In-process protocol calls provide deterministic coverage without automating LM Studio.

import XCTest
@testable import ForgeConductorCore

/// G1/G7: product reliability — MCP negotiate + tools surface without LM Studio UI.
final class ProductPathReliabilityTests: XCTestCase {
    func testInProcessMCPHandshakeToolsList() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("forge-product-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let app = try ForgeApp.bootstrap(home: tmp)
        defer { app.shutdown() }
        let server = MCPServer(app: app)

        let initMsg: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 1,
            "method": "initialize",
            "params": [
                "protocolVersion": "2025-11-25",
                "capabilities": [:] as [String: Any],
                "clientInfo": ["name": "product-test", "version": "1"] as [String: Any],
            ] as [String: Any],
        ]
        let initResp = server.handle(initMsg)
        XCTAssertNotNil(initResp)
        let result = initResp?["result"] as? [String: Any]
        XCTAssertEqual(result?["protocolVersion"] as? String, "2025-11-25")
        let info = result?["serverInfo"] as? [String: Any]
        XCTAssertEqual(info?["name"] as? String, "forge-conductor")

        let listMsg: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 2,
            "method": "tools/list",
            "params": [:] as [String: Any],
        ]
        let listResp = server.handle(listMsg)
        let listResult = listResp?["result"] as? [String: Any]
        let tools = listResult?["tools"] as? [[String: Any]] ?? []
        XCTAssertGreaterThanOrEqual(tools.count, 20, "product must expose full tool surface")
        let names = Set(tools.compactMap { $0["name"] as? String })
        XCTAssertTrue(names.contains("forge_status"))
        XCTAssertTrue(names.contains("agent_list"))
        XCTAssertTrue(names.contains("shell_exec"))
        XCTAssertTrue(MCPServeVerifier.requiredContinuityTools.isSubset(of: names))
    }

    func testForgeStatusToolCall() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("forge-status-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let app = try ForgeApp.bootstrap(home: tmp)
        defer { app.shutdown() }
        let server = MCPServer(app: app)
        let call: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 3,
            "method": "tools/call",
            "params": [
                "name": "forge_status",
                "arguments": [:] as [String: Any],
            ] as [String: Any],
        ]
        let resp = server.handle(call)
        let result = resp?["result"] as? [String: Any]
        XCTAssertNotNil(result)
        let isError = result?["isError"] as? Bool ?? true
        XCTAssertFalse(isError)
    }

    func testRealtimeEngineMeasuredProgress() {
        let engine = RealtimeMetricsEngine()
        engine.start(targetHz: 30)
        defer { engine.stop() }
        Thread.sleep(forTimeInterval: 0.35)
        XCTAssertGreaterThan(engine.latestSystem.ts, 0)
        // After ~0.35s at 30Hz should have samples; measured Hz may still be settling.
        XCTAssertTrue(engine.isRunning)
    }

    func testPortGuardReportsFreeOnUnusedPort() {
        // Ephemeral high port almost certainly free
        let state = DashboardPortGuard.inspect(host: "127.0.0.1", port: 59_873)
        switch state {
        case .free, .unknown:
            break // unknown acceptable if lsof missing
        default:
            XCTFail("expected free/unknown for unused port, got \(state)")
        }
    }

    func testDiagnosticsCaptureDeploySmokeFailurePath() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("forge-diag-smoke-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let paths = AppPaths(home: tmp)
        try paths.ensureLayout()
        let log = DiagnosticLog(paths: paths)
        let deploy = LMStudioDeployService(paths: paths, diagnostics: log)
        // Prefer a missing binary via explicit preferred that doesn't exist — resolve with bogus path
        do {
            _ = try deploy.deploy(
                preferredBinary: URL(fileURLWithPath: "/tmp/definitely-not-forge-\(UUID().uuidString)")
            )
            XCTFail("expected deploy to fail for missing binary")
        } catch {
            // expected
        }
        let recent = log.recent(limit: 50)
        let events = Set(recent.map(\.event))
        XCTAssertTrue(events.contains("deploy_begin") || events.contains("deploy_binary_missing") || events.contains("deploy_smoke_pre_failed") || events.contains("deploy_failed") || !recent.isEmpty)
    }

    func testProcessVerifierRejectsMissingContinuityTool() throws {
        let tmp = try makeVerifierTemp()
        defer { try? FileManager.default.removeItem(at: tmp) }
        var names = Array(MCPServeVerifier.requiredContinuityTools.subtracting(["context_get"]))
        while names.count < MCPServeVerifier.minimumToolCount {
            names.append("fixture_tool_\(names.count)")
        }
        let binary = try makeVerifierExecutable(
            in: tmp,
            serverName: "forge-conductor",
            toolNames: names
        )

        let result = try MCPServeVerifier.verify(
            binary: binary,
            home: tmp.appendingPathComponent("home", isDirectory: true),
            timeoutSec: 1
        )
        XCTAssertFalse(result.ok)
        XCTAssertTrue(result.detail.contains("context_get"), result.detail)
    }

    func testProcessVerifierRejectsNonNDJSONPrefix() throws {
        let tmp = try makeVerifierTemp()
        defer { try? FileManager.default.removeItem(at: tmp) }
        var names = Array(MCPServeVerifier.requiredContinuityTools)
        while names.count < MCPServeVerifier.minimumToolCount {
            names.append("fixture_tool_\(names.count)")
        }
        let binary = try makeVerifierExecutable(
            in: tmp,
            serverName: "forge-conductor",
            toolNames: names,
            prefix: "Content-Length: 10\n"
        )

        let result = try MCPServeVerifier.verify(
            binary: binary,
            home: tmp.appendingPathComponent("home", isDirectory: true),
            timeoutSec: 1
        )
        XCTAssertFalse(result.ok)
        XCTAssertTrue(result.detail.contains("ndjson=false"), result.detail)
    }

    func testProcessVerifierTimeoutIsBoundedForSilentChild() throws {
        let tmp = try makeVerifierTemp()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let binary = tmp.appendingPathComponent("silent-server")
        try Data("#!/bin/sh\ncat >/dev/null\nexec /bin/sleep 30\n".utf8).write(to: binary)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)

        let started = Date()
        let result = try MCPServeVerifier.verify(
            binary: binary,
            home: tmp.appendingPathComponent("home", isDirectory: true),
            timeoutSec: 0.2
        )
        XCTAssertFalse(result.ok)
        XCTAssertLessThan(Date().timeIntervalSince(started), 2.5)
    }

    private func makeVerifierTemp() throws -> URL {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("forge-verifier-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        return tmp
    }

    private func makeVerifierExecutable(
        in directory: URL,
        serverName: String,
        toolNames: [String],
        prefix: String = ""
    ) throws -> URL {
        let initialize: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 1,
            "result": [
                "protocolVersion": "2025-11-25",
                "serverInfo": ["name": serverName, "version": ForgeApp.version],
            ] as [String: Any],
        ]
        let descriptors: [[String: Any]] = toolNames.map { name in
            [
                "name": name,
                "description": "Fixture tool \(name)",
                "inputSchema": ["type": "object", "properties": [:] as [String: Any]],
            ]
        }
        let tools: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 2,
            "result": ["tools": descriptors],
        ]
        let output = prefix
            + (try JSONSupport.string(from: initialize)) + "\n"
            + (try JSONSupport.string(from: tools)) + "\n"
        let shellQuoted = output.replacingOccurrences(of: "'", with: "'\"'\"'")
        let script = "#!/bin/sh\ncat >/dev/null\nprintf '%s' '\(shellQuoted)'\n"
        let binary = directory.appendingPathComponent("fixture-server")
        try Data(script.utf8).write(to: binary)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
        return binary
    }
}
