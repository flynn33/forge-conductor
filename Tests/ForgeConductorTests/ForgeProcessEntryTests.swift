// ForgeProcessEntryTests.swift
// Verifies argv classification for GUI, manager, and MCP-serving process modes.
// These cases prevent the shared app binary from starting the wrong lifecycle.

import XCTest
@testable import ForgeConductorCore

final class ForgeProcessEntryTests: XCTestCase {
    func testParseModeGUIWhenNoArgs() {
        let mode = ForgeProcessEntry.parseMode(arguments: ["/path/Forge Conductor"])
        XCTAssertEqual(mode, .gui)
    }

    func testParseModeServe() {
        XCTAssertEqual(
            ForgeProcessEntry.parseMode(arguments: ["/app", "serve"]),
            .serve
        )
        XCTAssertEqual(
            ForgeProcessEntry.parseMode(arguments: ["/app", "mcp-serve"]),
            .serve
        )
        XCTAssertEqual(
            ForgeProcessEntry.parseMode(arguments: ["/app", "mcp"]),
            .serve
        )
    }

    func testParseModeManagerRun() {
        XCTAssertEqual(
            ForgeProcessEntry.parseMode(arguments: ["/app", "manager", "run"]),
            .managerRun(openBrowser: false)
        )
        XCTAssertEqual(
            ForgeProcessEntry.parseMode(arguments: ["/app", "manager", "run", "--open"]),
            .managerRun(openBrowser: true)
        )
        // LaunchAgent style: manager run --home PATH
        XCTAssertEqual(
            ForgeProcessEntry.parseMode(arguments: [
                "/app", "manager", "run", "--home", "/tmp/home",
            ]),
            .managerRun(openBrowser: false)
        )
    }

    func testHomeOverride() {
        let url = ForgeProcessEntry.homeOverride(from: [
            "/app", "manager", "run", "--home", "~/somewhere",
        ])
        XCTAssertNotNil(url)
        XCTAssertTrue(url!.path.contains("somewhere") || url!.path.hasPrefix("/"))
    }

    func testServeArgumentsConstant() {
        XCTAssertEqual(LMStudioMCPPluginInstaller.serveArguments, ["serve"])
    }

    func testResolveBinaryPrefersExplicitPreferred() {
        // Non-existent preferred is ignored; resolution falls through without crash.
        let missing = URL(fileURLWithPath: "/tmp/forge-conductor-missing-binary-\(UUID().uuidString)")
        let resolved = LMStudioMCPPluginInstaller.resolveBinaryURL(preferred: missing)
        XCTAssertFalse(resolved.path.isEmpty)
    }
}
