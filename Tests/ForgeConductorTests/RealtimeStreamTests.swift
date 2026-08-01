// RealtimeStreamTests.swift
// Verifies continuous native sampling, listener delivery, and advancing timestamps.
// Rate and ordering checks distinguish a live stream from repeated cached snapshots.

import XCTest
import Darwin
@testable import ForgeConductorCore

/// Proves host telemetry is a continuous stream — not a multi-second snapshot product.
final class RealtimeStreamTests: XCTestCase {
    func testHostStreamAdvancesWithoutSnapshotAPI() {
        let engine = RealtimeMetricsEngine()
        let requiredSamples = 8
        let delivered = expectation(description: "realtime samples delivered")
        delivered.expectedFulfillmentCount = requiredSamples
        var samples: [TimeInterval] = []
        let lock = NSLock()
        let id = engine.addListener { m in
            lock.lock()
            samples.append(m.ts)
            let shouldFulfill = samples.count <= requiredSamples
            lock.unlock()
            if shouldFulfill {
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
        let count = samples.count
        let unique = Set(samples.map { Int($0 * 100) })
        lock.unlock()

        XCTAssertGreaterThanOrEqual(count, requiredSamples, "tiered engine must push many samples; got \(count)")
        XCTAssertGreaterThanOrEqual(unique.count, 5, "timestamps must advance; unique=\(unique.count)")
        XCTAssertTrue(engine.isRunning)
        XCTAssertGreaterThanOrEqual(engine.targetSampleHz, 20)
    }

    func testTelemetryServicePublishesOnEverySample() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("forge-stream-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let app = try ForgeApp.bootstrap(home: home)
        defer { app.shutdown() }

        let requiredFrames = 8
        let delivered = expectation(description: "continuous telemetry frames delivered")
        var frames = 0
        var lastTs: TimeInterval = 0
        let lock = NSLock()
        let id = app.telemetry.addListener { frame in
            lock.lock()
            frames += 1
            lastTs = frame.updated
            let reachedRequiredFrames = frames == requiredFrames
            lock.unlock()
            if reachedRequiredFrames {
                delivered.fulfill()
            }
        }
        defer { app.telemetry.removeListener(id) }
        app.telemetry.startBackgroundRefresh(intervalSec: 0.5)

        wait(for: [delivered], timeout: 2.0)
        lock.lock()
        let frameCount = frames
        let ts = lastTs
        lock.unlock()

        XCTAssertGreaterThanOrEqual(frameCount, requiredFrames, "listeners must receive continuous frames; got \(frameCount)")
        XCTAssertGreaterThan(ts, 0)

        let a = app.telemetry.currentFrame().system.ts
        Thread.sleep(forTimeInterval: 0.08)
        let b = app.telemetry.currentFrame().system.ts
        XCTAssertGreaterThanOrEqual(b, a)
    }

    func testContinuousSSESendsMultipleEvents() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("forge-sse-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let app = try ForgeApp.bootstrap(home: home)
        defer { app.shutdown() }
        app.telemetry.startBackgroundRefresh(intervalSec: 0.5)

        let port = UInt16.random(in: 19_000...29_000)
        let server = DashboardServer(app: app, host: "127.0.0.1", port: port)
        try server.start()
        defer { server.stop() }
        Thread.sleep(forTimeInterval: 0.12)

        // Current-frame endpoint (compat name /api/snapshot still works).
        let liveURL = URL(string: "http://127.0.0.1:\(port)/api/live")!
        let (liveData, liveHTTP) = try HTTPTestHelpers.fetch(liveURL)
        XCTAssertEqual(liveHTTP.statusCode, 200)
        let liveJSON = try JSONSerialization.jsonObject(with: liveData) as? [String: Any]
        XCTAssertEqual(liveJSON?["stream"] as? String, "realtime")
        XCTAssertNotNil(liveJSON?["system"])

        // Raw TCP client — reliable for keep-alive SSE (URLSession often waits on EOS).
        let text = try Self.readSSE(host: "127.0.0.1", port: Int(port), durationSec: 0.9)
        let dataEvents = text.components(separatedBy: "data: ").count - 1
        XCTAssertTrue(text.contains("text/event-stream") || text.contains("200"), "headers: \(text.prefix(120))")
        XCTAssertGreaterThanOrEqual(
            dataEvents, 3,
            "SSE must push multiple live frames, not one-shot. events=\(dataEvents) body=\(text.prefix(280))"
        )
        XCTAssertTrue(
            text.contains("system") || text.contains("realtime"),
            "expected realtime payload content"
        )
    }

    /// Blocking read of SSE stream over a plain TCP socket for ~durationSec.
    private static func readSSE(host: String, port: Int, durationSec: TimeInterval) throws -> String {
        let sock = socket(AF_INET, SOCK_STREAM, 0)
        guard sock >= 0 else { throw NSError(domain: "sse", code: 1) }
        defer { close(sock) }

        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        _ = setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(port).bigEndian)
        addr.sin_addr = in_addr(s_addr: inet_addr(host))

        let connectResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connectResult == 0 else {
            throw NSError(domain: "sse", code: 2, userInfo: [NSLocalizedDescriptionKey: "connect failed errno=\(errno)"])
        }

        let req =
            "GET /api/stream?hz=20 HTTP/1.1\r\n" +
            "Host: \(host):\(port)\r\n" +
            "Accept: text/event-stream\r\n" +
            "Connection: keep-alive\r\n" +
            "\r\n"
        _ = req.withCString { write(sock, $0, strlen($0)) }

        var collected = Data()
        let deadline = Date().addingTimeInterval(durationSec)
        var buf = [UInt8](repeating: 0, count: 16_384)
        while Date() < deadline {
            let n = read(sock, &buf, buf.count)
            if n > 0 {
                collected.append(contentsOf: buf[0..<n])
                let soFar = String(data: collected, encoding: .utf8) ?? ""
                if soFar.components(separatedBy: "data: ").count - 1 >= 3 {
                    break
                }
            } else if n == 0 {
                break
            } else {
                // EAGAIN / timeout — keep waiting until deadline
                Thread.sleep(forTimeInterval: 0.02)
            }
        }
        return String(data: collected, encoding: .utf8) ?? ""
    }

    func testStreamHzParserUpgradesLegacyInterval() {
        XCTAssertEqual(TelemetryRoutes.parseStreamHz(query: "hz=25"), 25)
        // Legacy interval=2 must not force 0.5 Hz product behavior.
        let upgraded = TelemetryRoutes.parseStreamHz(query: "interval=2")
        XCTAssertGreaterThanOrEqual(upgraded, 10)
        XCTAssertEqual(TelemetryRoutes.parseStreamHz(query: ""), 20)
    }

    func testHealthReportsContinuousMode() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("forge-health-rt-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let app = try ForgeApp.bootstrap(home: home)
        defer { app.shutdown() }
        app.telemetry.startBackgroundRefresh(intervalSec: 0.5)
        Thread.sleep(forTimeInterval: 0.2)
        let h = app.telemetry.healthDictionary()
        let mode = h["mode"] as? String ?? ""
        XCTAssertTrue(mode.contains("continuous-native"), "mode=\(mode)")
        XCTAssertEqual(h["stream"] as? String, "realtime")
        XCTAssertEqual(h["runtime"] as? String, "swift-native-realtime")
        XCTAssertEqual(h["ok"] as? Bool, true)
    }
}
