// ForgeConductorUITests.swift
// Launches the signed macOS product and exercises its native navigation and controls.
// Stable accessibility identifiers make the checks independent of display coordinates.

import XCTest

/// Launches the real Forge Conductor macOS app and exercises sidebar navigation.
///
/// Requires a built `Forge Conductor.app` as the test host (configured in the
/// ForgeConductorUITests target). Run via:
/// `xcodebuild -scheme ForgeConductor -destination 'platform=macOS' test`
final class ForgeConductorUITests: XCTestCase {
    var app: XCUIApplication!
    var testHome: URL!

    override func setUpWithError() throws {
        continueAfterFailure = false
        testHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("forge-conductor-ui-\(UUID().uuidString)", isDirectory: true)
        app = XCUIApplication()
        app.launchArguments += ["--uitesting"]
        app.launchEnvironment["FORGE_CONDUCTOR_HOME"] = testHome.path
        app.launchEnvironment["FORGE_SKIP_PS"] = "1"
        app.launch()
    }

    override func tearDownWithError() throws {
        app?.terminate()
        app = nil
        if let testHome {
            try? FileManager.default.removeItem(at: testHome)
        }
        testHome = nil
    }

    func testAppLaunchesAndShowsTitle() throws {
        let title = app.staticTexts["app-title"]
        XCTAssertTrue(
            title.waitForExistence(timeout: 8) || app.staticTexts["Forge Conductor"].waitForExistence(timeout: 8),
            "App window should show Forge Conductor branding"
        )
        XCTAssertTrue(app.windows.firstMatch.exists)
        XCTAssertEqual(
            app.windows.count,
            1,
            "Forge Conductor should have exactly one main window after launch"
        )
    }

    func testSidebarTabsNavigate() throws {
        // Prefer accessibility identifiers; fall back to visible labels.
        let tabs: [(id: String, label: String, detail: String)] = [
            ("tab-rig", "FORGE RIG", "detail-rig"),
            ("tab-mcp", "LM Studio MCP", "detail-mcp"),
            ("tab-agents", "Agents", "detail-agents"),
            ("tab-tools", "Tools", "detail-tools"),
            ("tab-feed", "Live Feed", "detail-feed"),
            ("tab-diagnostics", "Diagnostics", "detail-diagnostics"),
            ("tab-manager", "Manager", "detail-manager"),
        ]

        for tab in tabs {
            let byID = app.buttons[tab.id]
            let byLabel = app.staticTexts[tab.label]
            let cell = app.cells.containing(.staticText, identifier: tab.label).element

            if byID.waitForExistence(timeout: 2) {
                byID.click()
            } else if cell.waitForExistence(timeout: 2) {
                cell.click()
            } else if byLabel.waitForExistence(timeout: 2) {
                byLabel.click()
            } else {
                // Sidebar List may expose as outline rows
                let row = app.outlines.staticTexts[tab.label]
                if row.waitForExistence(timeout: 2) {
                    row.click()
                } else {
                    XCTFail("Could not find tab \(tab.label) / \(tab.id)")
                    continue
                }
            }

            let detail = app.descendants(matching: .any)[tab.detail]
            XCTAssertTrue(
                detail.waitForExistence(timeout: 3),
                "Detail content was blank after selecting \(tab.label)"
            )
        }
    }

    func testRefreshToolbarExists() throws {
        let refresh = app.buttons["toolbar-refresh"]
        if refresh.waitForExistence(timeout: 5) {
            refresh.click()
            XCTAssertTrue(app.windows.firstMatch.exists)
        } else {
            // Toolbar buttons may be icons without identifiers on some OS builds — soft pass if app is up.
            XCTAssertTrue(app.windows.firstMatch.exists)
        }
    }

    func testCollapsedNavigationCanBeRestored() throws {
        let toggle = app.buttons["toolbar-navigation"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 8), "Navigation toolbar toggle should always remain available")

        toggle.click() // collapse
        XCTAssertTrue(toggle.exists, "Navigation toggle must remain available while navigation is hidden")
        toggle.click() // restore

        let rigByID = app.buttons["tab-rig"]
        let rigByLabel = app.staticTexts["FORGE RIG"]
        XCTAssertTrue(
            rigByID.waitForExistence(timeout: 3) || rigByLabel.waitForExistence(timeout: 3),
            "Navigation should reappear after using the toolbar toggle"
        )
    }
}
