// DashboardSecurityTests.swift
// Probes the loopback HTTP boundary with malformed, oversized, and untrusted requests.
// The cases preserve parser limits and host/origin protections before routing is reached.

import XCTest
@testable import ForgeConductorCore

final class DashboardSecurityTests: XCTestCase {
    func testParserRejectsMalformedAndOversizedLengths() {
        let malformed = Data("POST / HTTP/1.1\r\nHost: 127.0.0.1:7788\r\nContent-Length:\r\n\r\n".utf8)
        XCTAssertEqual(
            DashboardHTTPRequestParser.parse(malformed, streamComplete: true),
            .rejected(status: 400, message: "Invalid Content-Length")
        )

        let oversized = Data(
            "POST / HTTP/1.1\r\nHost: 127.0.0.1:7788\r\nContent-Length: \(DashboardHTTPRequestParser.maximumBodyBytes + 1)\r\n\r\n".utf8
        )
        XCTAssertEqual(
            DashboardHTTPRequestParser.parse(oversized, streamComplete: false),
            .rejected(status: 413, message: "Request body too large")
        )
    }

    func testPolicyRejectsCrossOriginAndNonJSONMutations() {
        let crossOrigin = DashboardHTTPRequest(
            method: "POST",
            target: "/api/sessions/prune",
            headers: [
                "host": "127.0.0.1:7788",
                "content-type": "application/json",
                "origin": "https://attacker.example",
            ],
            body: Data("{}".utf8)
        )
        XCTAssertEqual(
            DashboardRequestPolicy.rejection(for: crossOrigin, serverPort: 7788)?.status,
            403
        )

        let formPost = DashboardHTTPRequest(
            method: "POST",
            target: "/api/sessions/prune",
            headers: [
                "host": "127.0.0.1:7788",
                "content-type": "application/x-www-form-urlencoded",
            ],
            body: Data()
        )
        XCTAssertEqual(
            DashboardRequestPolicy.rejection(for: formPost, serverPort: 7788)?.status,
            415
        )
    }

    func testDashboardCannotInvokePrivilegedTools() throws {
        let fixture = try DashboardFixture()
        defer { fixture.stop() }

        var request = URLRequest(url: fixture.url.appendingPathComponent("api/tools/call"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(fixture.origin, forHTTPHeaderField: "Origin")
        request.httpBody = Data(#"{"name":"shell_exec","arguments":{"command":"true"}}"#.utf8)

        let (_, response) = try HTTPTestHelpers.fetch(request)
        XCTAssertEqual(response.statusCode, 404)
        XCTAssertNil(response.value(forHTTPHeaderField: "Access-Control-Allow-Origin"))
    }

    func testDashboardRejectsCrossOriginStateChange() throws {
        let fixture = try DashboardFixture()
        defer { fixture.stop() }

        var request = URLRequest(url: fixture.url.appendingPathComponent("api/sessions/prune"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("https://attacker.example", forHTTPHeaderField: "Origin")
        request.httpBody = Data("{}".utf8)

        let (_, response) = try HTTPTestHelpers.fetch(request)
        XCTAssertEqual(response.statusCode, 403)
    }
}

private final class DashboardFixture {
    let app: ForgeApp
    let server: DashboardServer
    let url: URL
    let origin: String
    private let home: URL

    init() throws {
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("forge-dashboard-security-\(UUID().uuidString)", isDirectory: true)
        app = try ForgeApp.bootstrap(home: home)
        let port = UInt16.random(in: 29_000...39_000)
        server = DashboardServer(app: app, host: "127.0.0.1", port: port)
        url = URL(string: "http://127.0.0.1:\(port)/")!
        origin = "http://127.0.0.1:\(port)"
        try server.start()
        Thread.sleep(forTimeInterval: 0.1)
    }

    func stop() {
        server.stop()
        app.shutdown()
        try? FileManager.default.removeItem(at: home)
    }
}
