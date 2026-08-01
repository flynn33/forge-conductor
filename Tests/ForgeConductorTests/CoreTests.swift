// CoreTests.swift
// Exercises the Core composition root, persistence, tools, sessions, and local services.
// A fresh temporary home isolates every test from the operator's installed configuration.

import XCTest
@testable import ForgeConductorCore

final class CoreTests: XCTestCase {
    private var tempHome: URL!

    override func setUpWithError() throws {
        tempHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("forge-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempHome, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempHome)
    }

    // MARK: - Bootstrap / paths

    func testBootstrapCreatesLayout() throws {
        let app = try ForgeApp.bootstrap(home: tempHome)
        XCTAssertTrue(FileManager.default.fileExists(atPath: app.paths.home.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: app.paths.storeSQLite.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: app.paths.configJSON.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: app.paths.agentsDir.path))
        XCTAssertEqual(app.paths.home.standardizedFileURL, tempHome.standardizedFileURL)
    }

    func testDoctorPasses() throws {
        let app = try ForgeApp.bootstrap(home: tempHome)
        let doc = try app.doctor()
        XCTAssertEqual(doc["ok"] as? Bool, true)
        let checks = doc["checks"] as? [[String: Any]] ?? []
        XCTAssertFalse(checks.isEmpty)
    }

    func testCatalogHasBuiltins() throws {
        let app = try ForgeApp.bootstrap(home: tempHome)
        let ids = Set(app.catalog.all().map(\.id))
        for need in [
            "explore", "implement", "docs", "debug", "precommit-audit",
            "plan", "review", "test", "security", "research",
        ] {
            XCTAssertTrue(ids.contains(need), "missing agent \(need)")
        }
        XCTAssertNotNil(app.catalog.get("docs")?.tools.contains("pdf_write"))
        XCTAssertEqual(app.catalog.get("docs")?.tools.contains("pdf_write"), true)
    }

    func testAgentPlaybooksAreRobust() throws {
        let app = try ForgeApp.bootstrap(home: tempHome)
        let agents = app.catalog.all()
        XCTAssertGreaterThanOrEqual(agents.count, 10)
        for spec in agents {
            XCTAssertFalse(spec.description.isEmpty, "\(spec.id) missing description")
            XCTAssertFalse(spec.tools.isEmpty, "\(spec.id) needs tools")
            XCTAssertFalse(spec.firstMoves.isEmpty, "\(spec.id) needs first_moves")
            XCTAssertFalse(spec.doneDefinition.isEmpty, "\(spec.id) needs done_definition")
            XCTAssertFalse(spec.outputSchema.isEmpty, "\(spec.id) needs output_schema")
            XCTAssertTrue(
                spec.body.contains("agent_run_complete") || spec.doneDefinition.contains(where: { $0.contains("agent_run_complete") }),
                "\(spec.id) must require agent_run_complete"
            )
            // Playbook body should be more than a one-liner when loaded from markdown
            XCTAssertGreaterThan(spec.body.count, 40, "\(spec.id) playbook body too thin")
        }
        // Recommend routes for specialized tasks
        XCTAssertEqual(app.catalog.recommend(task: "security audit secrets auth").id, "security")
        XCTAssertEqual(app.catalog.recommend(task: "research how the MCP server works").id, "research")
    }

    func testRecommendDocs() throws {
        let app = try ForgeApp.bootstrap(home: tempHome)
        let spec = app.catalog.recommend(task: "Write a PDF manual for the operator")
        XCTAssertEqual(spec.id, "docs")
    }

    // MARK: - Sessions

    func testSessionLifecycleComplete() throws {
        let app = try ForgeApp.bootstrap(home: tempHome)
        let client = ClientID("test-client")
        let start = try app.sessions.start(
            agentID: "explore",
            goal: "Map the test tree",
            clientID: client
        )
        XCTAssertEqual(start["ok"] as? Bool, true)
        let sid = start["session_id"] as! String
        XCTAssertFalse(sid.isEmpty)

        let status = try app.sessions.status(sessionID: SessionID(sid), clientID: client)
        XCTAssertEqual(status["must_complete"] as? Bool, true)

        let report: [String: Any] = [
            "layout": "root with Sources",
            "entry_points": "main.swift",
            "build_test_run": "swift test",
            "dependencies_config": "SPM only",
            "risks": "none",
            "next_agent": "plan",
        ]
        let done = try app.sessions.complete(
            sessionID: SessionID(sid),
            report: report,
            clientID: client
        )
        XCTAssertEqual(done["ok"] as? Bool, true)
        XCTAssertEqual(done["schema_complete"] as? Bool, true)

        let sess = try app.store.sessionGet(id: SessionID(sid))
        XCTAssertEqual(sess?.status, .closed)
    }

    func testSessionIncompleteSchemaWarns() throws {
        let app = try ForgeApp.bootstrap(home: tempHome)
        let client = ClientID("c2")
        let start = try app.sessions.start(agentID: "docs", goal: "Write README", clientID: client)
        let sid = start["session_id"] as! String
        let done = try app.sessions.complete(
            sessionID: SessionID(sid),
            report: ["summary": "only summary"],
            clientID: client
        )
        XCTAssertEqual(done["ok"] as? Bool, true)
        XCTAssertEqual(done["schema_complete"] as? Bool, false)
        let missing = done["missing_schema_keys"] as? [String] ?? []
        XCTAssertTrue(missing.contains("files_touched"))
    }

    func testSupersedeClosesPriorOpen() throws {
        let app = try ForgeApp.bootstrap(home: tempHome)
        let client = ClientID("c3")
        let a = try app.sessions.start(agentID: "explore", goal: "first", clientID: client)
        let sid1 = a["session_id"] as! String
        let b = try app.sessions.start(agentID: "debug", goal: "second", clientID: client)
        let sid2 = b["session_id"] as! String
        XCTAssertNotEqual(sid1, sid2)
        let s1 = try app.store.sessionGet(id: SessionID(sid1))
        XCTAssertEqual(s1?.status, .closed)
        let s2 = try app.store.sessionGet(id: SessionID(sid2))
        XCTAssertEqual(s2?.status, .open)
    }

    func testBindingRehydrateFromMemory() throws {
        let app = try ForgeApp.bootstrap(home: tempHome)
        let client = ClientID("c4")
        let start = try app.sessions.start(agentID: "plan", goal: "design feature X", clientID: client)
        let sid = start["session_id"] as! String
        // Simulate process restart: new service stack, same store
        let app2 = try ForgeApp.bootstrap(home: tempHome)
        let binding = try app2.sessions.rehydrate(clientID: client)
        XCTAssertNotNil(binding)
        XCTAssertEqual(binding?.sessionID.rawValue, sid)
        XCTAssertEqual(binding?.agentID, "plan")
    }

    func testPruneStaleClosesIdle() throws {
        let clock = FixedClock(Date())
        let app = try ForgeApp.bootstrap(home: tempHome, clock: clock)
        // Use short TTL by constructing service directly is hard; instead manipulate updated_at via store end/start and clock jump
        // Direct store session + advance clock past idleTTL (default 14400)
        let client = ClientID("c5")
        let s = try app.store.sessionStart(agentID: "explore", clientID: client)
        // Jump clock far past idle TTL
        clock.date = clock.date.addingTimeInterval(20_000)
        try app.sessions.pruneStale()
        let after = try app.store.sessionGet(id: s.id)
        XCTAssertEqual(after?.status, .closed)
        XCTAssertTrue(after?.summary?.contains("auto_closed") == true || after?.summary?.contains("abandoned") == true)
    }

    // MARK: - Tools

    func testForgeStatusTool() throws {
        let app = try ForgeApp.bootstrap(home: tempHome)
        let result = try app.tools.call(name: "forge_status", arguments: [:], clientID: ClientID("t1"))
        XCTAssertTrue(result.ok)
        XCTAssertEqual(result.payload["runtime"] as? String, "swift")
        XCTAssertEqual(result.payload["version"] as? String, ForgeApp.version)
    }

    func testFSWriteRead() throws {
        let app = try ForgeApp.bootstrap(home: tempHome)
        let path = tempHome.appendingPathComponent("note.txt").path
        let w = try app.tools.call(
            name: "fs_write",
            arguments: ["path": path, "content": "hello forge"],
            clientID: ClientID("t2")
        )
        XCTAssertTrue(w.ok)
        let r = try app.tools.call(name: "fs_read", arguments: ["path": path], clientID: ClientID("t2"))
        XCTAssertTrue(r.ok)
        XCTAssertEqual(r.payload["content"] as? String, "hello forge")
    }

    func testPDFWrite() throws {
        let app = try ForgeApp.bootstrap(home: tempHome)
        let path = tempHome.appendingPathComponent("manual.pdf").path
        let r = try app.tools.call(
            name: "pdf_write",
            arguments: [
                "path": path,
                "content": "# Title\n\nHello PDF export from Forge.\n\n## Section\nBody text.",
                "title": "Test Manual",
            ],
            clientID: ClientID("t3")
        )
        XCTAssertTrue(r.ok, "\(r.payload)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
        let attrs = try FileManager.default.attributesOfItem(atPath: path)
        let size = attrs[.size] as? NSNumber
        XCTAssertGreaterThan(size?.intValue ?? 0, 100)
    }

    func testFilesystemToolRejectsPathOutsideWorkspaceRoots() throws {
        let app = try ForgeApp.bootstrap(home: tempHome)
        defer { app.shutdown() }
        let outside = tempHome.deletingLastPathComponent()
            .appendingPathComponent("forge-outside-\(UUID().uuidString).txt")

        let result = try app.tools.call(
            name: "fs_write",
            arguments: ["path": outside.path, "content": "must not write"],
            clientID: ClientID("path-denied")
        )

        XCTAssertFalse(result.ok)
        XCTAssertEqual(result.payload["code"] as? String, "path_outside_allowed_roots")
        XCTAssertFalse(FileManager.default.fileExists(atPath: outside.path))
    }

    func testConfiguredWorkspaceRootAllowsFilesystemTool() throws {
        let app = try ForgeApp.bootstrap(home: tempHome)
        defer { app.shutdown() }
        let workspace = tempHome.deletingLastPathComponent()
            .appendingPathComponent("forge-workspace-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: workspace) }
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        _ = try app.config.update(["allowed_roots": [workspace.path]], save: false)
        let output = workspace.appendingPathComponent("allowed.txt")

        let result = try app.tools.call(
            name: "fs_write",
            arguments: ["path": output.path, "content": "allowed"],
            clientID: ClientID("path-allowed")
        )

        XCTAssertTrue(result.ok, "\(result.payload)")
        XCTAssertEqual(try String(contentsOf: output, encoding: .utf8), "allowed")
    }

    func testFilesystemToolRejectsSymlinkEscape() throws {
        let app = try ForgeApp.bootstrap(home: tempHome)
        defer { app.shutdown() }
        let outside = tempHome.deletingLastPathComponent()
            .appendingPathComponent("forge-symlink-target-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let link = tempHome.appendingPathComponent("escape")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)

        let result = try app.tools.call(
            name: "fs_write",
            arguments: ["path": link.appendingPathComponent("secret.txt").path, "content": "blocked"],
            clientID: ClientID("symlink-denied")
        )

        XCTAssertFalse(result.ok)
        XCTAssertEqual(result.payload["code"] as? String, "path_outside_allowed_roots")
        XCTAssertFalse(FileManager.default.fileExists(atPath: outside.appendingPathComponent("secret.txt").path))
    }

    func testActiveAgentForbiddenToolsAreEnforcedAtRouter() throws {
        let app = try ForgeApp.bootstrap(home: tempHome)
        defer { app.shutdown() }
        let client = ClientID("explore-policy")
        _ = try app.sessions.start(
            agentID: "explore",
            goal: "read only",
            clientID: client,
            cwd: tempHome.path
        )

        let result = try app.tools.call(
            name: "fs_write",
            arguments: ["path": tempHome.appendingPathComponent("blocked.txt").path, "content": "blocked"],
            clientID: client
        )

        XCTAssertFalse(result.ok)
        XCTAssertEqual(result.payload["code"] as? String, "tool_forbidden")
    }

    func testShellRequiresExplicitAgentWorkspace() throws {
        let app = try ForgeApp.bootstrap(home: tempHome)
        defer { app.shutdown() }

        let result = try app.tools.call(
            name: "shell_exec",
            arguments: ["command": "pwd"],
            clientID: ClientID("no-session-shell")
        )

        XCTAssertFalse(result.ok)
        XCTAssertEqual(result.payload["code"] as? String, "active_session_required")
    }

    func testToolAuditRedactsFileContents() throws {
        let app = try ForgeApp.bootstrap(home: tempHome)
        defer { app.shutdown() }
        let secret = "sensitive-content-\(UUID().uuidString)"
        _ = try app.tools.call(
            name: "fs_write",
            arguments: ["path": tempHome.appendingPathComponent("redacted.txt").path, "content": secret],
            clientID: ClientID("audit-redaction")
        )

        let event = try XCTUnwrap(app.audit.recent(limit: 5).first(where: { $0.tool == "fs_write" }))
        XCTAssertFalse(event.argsJSON?.contains(secret) == true)
        XCTAssertTrue(event.argsJSON?.contains("redacted") == true)
    }

    func testAgentListTool() throws {
        let app = try ForgeApp.bootstrap(home: tempHome)
        let r = try app.tools.call(name: "agent_list", arguments: [:], clientID: ClientID("t4"))
        XCTAssertTrue(r.ok)
        let agents = r.payload["agents"] as? [[String: Any]] ?? []
        XCTAssertGreaterThanOrEqual(agents.count, 8)
    }

    // MARK: - MCP

    func testMCPInitializeAndToolsList() throws {
        let app = try ForgeApp.bootstrap(home: tempHome)
        let mcp = MCPServer(app: app, clientID: ClientID("mcp-test"))
        let initResp = mcp.handle([
            "jsonrpc": "2.0",
            "id": 1,
            "method": "initialize",
            "params": ["protocolVersion": "2024-11-05"] as [String: Any],
        ])
        XCTAssertNotNil(initResp)
        XCTAssertNotNil(initResp?["result"])

        let list = mcp.handle([
            "jsonrpc": "2.0",
            "id": 2,
            "method": "tools/list",
        ])
        let result = list?["result"] as? [String: Any]
        let tools = result?["tools"] as? [[String: Any]] ?? []
        XCTAssertGreaterThanOrEqual(tools.count, 10)
        let names = tools.compactMap { $0["name"] as? String }
        XCTAssertTrue(names.contains("forge_status"))
        XCTAssertTrue(names.contains("agent_run_start"))
        XCTAssertTrue(names.contains("pdf_write"))
    }

    func testMCPToolCall() throws {
        let app = try ForgeApp.bootstrap(home: tempHome)
        let mcp = MCPServer(app: app, clientID: ClientID("mcp-call"))
        let resp = mcp.handle([
            "jsonrpc": "2.0",
            "id": 3,
            "method": "tools/call",
            "params": [
                "name": "forge_status",
                "arguments": [:] as [String: Any],
            ] as [String: Any],
        ])
        let result = resp?["result"] as? [String: Any]
        XCTAssertEqual(result?["isError"] as? Bool, false)
        let content = result?["content"] as? [[String: Any]]
        XCTAssertNotNil(content?.first?["text"] as? String)
    }

    // MARK: - JSON / domain

    func testISO8601RoundTrip() {
        let d = Date(timeIntervalSince1970: 1_700_000_000)
        let s = ISO8601.string(from: d)
        let back = ISO8601.date(from: s)
        XCTAssertNotNil(back)
        XCTAssertEqual(Int(back!.timeIntervalSince1970), 1_700_000_000)
    }

    func testAgentMarkdownParser() throws {
        let md = """
        ---
        id: custom-agent
        display_name: Custom
        description: A custom playbook
        tools: [fs_read, fs_list]
        tools_forbidden: [git_push]
        output_schema:
          - summary
          - next
        ---
        You are custom.
        """
        let spec = try AgentMarkdownParser.parse(text: md, source: "custom")
        XCTAssertEqual(spec.id, "custom-agent")
        XCTAssertEqual(spec.tools, ["fs_read", "fs_list"])
        XCTAssertEqual(spec.toolsForbidden, ["git_push"])
        XCTAssertEqual(spec.outputSchema, ["summary", "next"])
        XCTAssertTrue(spec.body.contains("custom"))
    }

    func testCustomAgentOverridesBuiltin() throws {
        let md = """
        ---
        id: explore
        display_name: Explore Custom
        description: overridden
        tools: [fs_list]
        ---
        Custom explore body.
        """
        let agentsDir = tempHome.appendingPathComponent("agents", isDirectory: true)
        try FileManager.default.createDirectory(at: agentsDir, withIntermediateDirectories: true)
        try md.write(to: agentsDir.appendingPathComponent("explore.md"), atomically: true, encoding: .utf8)
        let app = try ForgeApp.bootstrap(home: tempHome)
        let spec = app.catalog.get("explore")
        XCTAssertEqual(spec?.source, "custom")
        XCTAssertEqual(spec?.displayName, "Explore Custom")
    }

    // MARK: - Audit

    func testAuditDualWrite() throws {
        let app = try ForgeApp.bootstrap(home: tempHome)
        try app.audit.append(
            tool: "test_tool",
            status: "ok",
            clientID: "c",
            args: ["x": 1],
            durationMs: 5,
            mutating: true
        )
        let rows = try app.audit.recent(limit: 5)
        XCTAssertTrue(rows.contains(where: { $0.tool == "test_tool" }))
        let jsonl = try String(contentsOf: app.paths.auditJSONL, encoding: .utf8)
        XCTAssertTrue(jsonl.contains("test_tool"))
    }
}
