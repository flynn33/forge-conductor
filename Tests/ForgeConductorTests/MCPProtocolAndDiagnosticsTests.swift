// MCPProtocolAndDiagnosticsTests.swift
// Validates MCP NDJSON framing, protocol behavior, diagnostics, and bounded outputs.
// These tests guard the wire boundary independently from a graphical LM Studio session.

import XCTest
@testable import ForgeConductorCore

final class MCPProtocolAndDiagnosticsTests: XCTestCase {
    func testStdioTransportWritesSpecCompliantNDJSON() throws {
        let packet = try MCPStdioTransport.encode([
            "jsonrpc": "2.0",
            "id": 1,
            "result": ["ok": true] as [String: Any],
        ])
        let text = try XCTUnwrap(String(data: packet, encoding: .utf8))
        XCTAssertTrue(text.hasSuffix("\n"))
        XCTAssertFalse(text.localizedCaseInsensitiveContains("Content-Length"))
        XCTAssertEqual(text.filter { $0 == "\n" }.count, 1)
        let decoded = try JSONSupport.object(from: Data(text.dropLast().utf8))
        XCTAssertEqual(decoded["jsonrpc"] as? String, "2.0")
        XCTAssertEqual(decoded["id"] as? Int, 1)
    }

    func testStreamReaderRejectsOversizedContentLengthBeforeReadingBody() throws {
        let pipe = Pipe()
        let reader = MCPStreamReader(handle: pipe.fileHandleForReading, maximumMessageBytes: 64)
        try pipe.fileHandleForWriting.write(contentsOf: Data("Content-Length: 100\r\n\r\n".utf8))
        try pipe.fileHandleForWriting.close()

        XCTAssertThrowsError(try reader.readMessage()) { error in
            guard case MCPStreamError.messageTooLarge(64) = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
    }

    func testProtocolNegotiationEchoesLMStudioVersion() {
        XCTAssertEqual(
            MCPServer.negotiateProtocolVersion("2025-11-25"),
            "2025-11-25"
        )
        XCTAssertEqual(
            MCPServer.negotiateProtocolVersion("2024-11-05"),
            "2024-11-05"
        )
        // Unknown → newest supported
        XCTAssertEqual(
            MCPServer.negotiateProtocolVersion("2099-01-01"),
            MCPServer.supportedProtocolVersions[0]
        )
        XCTAssertEqual(
            MCPServer.negotiateProtocolVersion(""),
            MCPServer.supportedProtocolVersions[0]
        )
    }

    func testDiagnosticExportJSONAndMarkdown() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("forge-diag-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let paths = AppPaths(home: tmp)
        try paths.ensureLayout()
        let log = DiagnosticLog(paths: paths, role: "primary")
        log.info("unit_test_event", ["k": "v"], category: .diagnostics)
        log.warn("unit_test_warn", category: .mcp)
        log.error("unit_test_error", ["code": "1"], category: .lmstudio)

        let result = try log.export(to: tmp.appendingPathComponent("out", isDirectory: true))
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.jsonURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.markdownURL.path))
        XCTAssertGreaterThanOrEqual(result.recordCount, 3)

        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: result.jsonURL)) as? [String: Any]
        XCTAssertEqual(json?["product"] as? String, ForgeApp.productName)
        XCTAssertNotNil(json?["records"] as? [[String: Any]])

        let md = try String(contentsOf: result.markdownURL, encoding: .utf8)
        XCTAssertTrue(md.contains("# "))
        XCTAssertTrue(md.contains("unit_test_event") || md.contains("Timeline"))
    }

    func testRealtimeEngineIsContinuousNotTwoSecondSnapshot() {
        XCTAssertGreaterThanOrEqual(RealtimeMetricsEngine.defaultTargetHz, 20)
        XCTAssertLessThan(1.0 / RealtimeMetricsEngine.defaultTargetHz, 0.1)

        let engine = RealtimeMetricsEngine()
        let requiredPushes = 8
        let delivered = expectation(description: "continuous samples delivered")
        var timestamps: [TimeInterval] = []
        let lock = NSLock()
        let id = engine.addListener { metrics in
            lock.lock()
            timestamps.append(metrics.ts)
            let reachedRequiredPushes = timestamps.count == requiredPushes
            lock.unlock()
            if reachedRequiredPushes {
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
        let samples = timestamps
        lock.unlock()

        XCTAssertGreaterThanOrEqual(samples.count, requiredPushes, "must push samples to listeners (not snapshot poll); got \(samples.count)")
        XCTAssertGreaterThan(samples.last ?? 0, samples.first ?? 0, "continuous engine must advance sample timestamps")
    }

    func testDeployServiceResolvesExecutable() {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("forge-deploy-test-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let paths = AppPaths(home: tmp)
        let log = DiagnosticLog(paths: paths)
        let svc = LMStudioDeployService(paths: paths, diagnostics: log)
        let url = svc.resolveServeBinary(preferred: nil)
        // May not exist in empty temp home — still returns a concrete path candidate.
        XCTAssertFalse(url.path.isEmpty)
    }
}
