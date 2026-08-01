// ContinuityTests.swift
// Context + agent continuity: checkpoint, handoff, resume, budget loop.

import XCTest
import SQLite3
@testable import ForgeConductorCore

final class ContinuityTests: XCTestCase {
    private var tempHome: URL!

    override func setUpWithError() throws {
        tempHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("forge-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempHome, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempHome)
    }

    func testMemoryLayoutCreatedOnBootstrap() throws {
        let app = try ForgeApp.bootstrap(home: tempHome)
        defer { app.shutdown() }
        XCTAssertTrue(FileManager.default.fileExists(atPath: app.paths.memoryDir.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: app.paths.memoryHandoffsDir.path))
    }

    func testCheckpointAndContextGetRoundTrip() throws {
        let app = try ForgeApp.bootstrap(home: tempHome)
        defer { app.shutdown() }
        let client = ClientID("continuity-1")

        let cp = try app.tools.call(
            name: "session_checkpoint",
            arguments: [
                "goal": "Fix Mirmir upscale crash",
                "status": "investigating",
                "cwd": "/Users/jimdaley/GitHub/Mirmir",
                "project_slug": "mirmir",
                "next_actions": ["Read pipeline", "Reproduce crash"],
                "narrative": "Looking at VTEncoder logs",
                "key_files": ["AVFoundationMediaPipeline.swift"],
            ],
            clientID: client
        )
        XCTAssertTrue(cp.ok, "\(cp.payload)")
        let handoffID = cp.payload["handoff_id"] as? String
        XCTAssertNotNil(handoffID)
        XCTAssertEqual(cp.payload["resume_ready"] as? Bool, false)

        let get = try app.tools.call(name: "context_get", arguments: [:], clientID: client)
        XCTAssertTrue(get.ok)
        XCTAssertEqual(get.payload["found"] as? Bool, true)
        XCTAssertEqual(get.payload["handoff_id"] as? String, handoffID)

        let packet = get.payload["packet"] as? [String: Any]
        let task = packet?["task"] as? [String: Any]
        XCTAssertEqual(task?["goal"] as? String, "Fix Mirmir upscale crash")
        XCTAssertTrue(FileManager.default.fileExists(atPath: app.paths.memoryCurrentTask.path))
    }

    func testHandoffMarksResumeReadyAndSnapshotsAgents() throws {
        let app = try ForgeApp.bootstrap(home: tempHome)
        defer { app.shutdown() }
        let client = ClientID("continuity-agents")

        let start = try app.tools.call(
            name: "agent_run_start",
            arguments: [
                "agent_id": "debug",
                "goal": "Trace upscale crash",
                "cwd": tempHome.path,
            ],
            clientID: client
        )
        XCTAssertTrue(start.ok, "\(start.payload)")
        let sessionID = start.payload["session_id"] as? String
        XCTAssertNotNil(sessionID)

        let handoff = try app.tools.call(
            name: "session_handoff",
            arguments: [
                "goal": "Trace upscale crash",
                "status": "blocked_on_context",
                "cwd": tempHome.path,
                "narrative": "Need new chat to continue debugging",
            ],
            clientID: client
        )
        XCTAssertTrue(handoff.ok, "\(handoff.payload)")
        XCTAssertEqual(handoff.payload["resume_ready"] as? Bool, true)
        XCTAssertEqual(handoff.payload["handoff_required"] as? Bool, true)
        let seed = handoff.payload["resume_seed"] as? String ?? ""
        XCTAssertTrue(seed.contains("context_get") || seed.contains("Forge Continuity"))

        let packet = handoff.payload["packet"] as? [String: Any]
        let agents = packet?["agents"] as? [[String: Any]] ?? []
        XCTAssertFalse(agents.isEmpty, "expected open agent snapshot")
        XCTAssertEqual(agents.first?["session_id"] as? String, sessionID)
        XCTAssertEqual(agents.first?["agent_id"] as? String, "debug")

        let status = try app.tools.call(name: "forge_status", arguments: [:], clientID: client)
        let continuity = status.payload["continuity"] as? [String: Any]
        XCTAssertEqual(continuity?["resume_ready"] as? Bool, true)
    }

    func testContextListAndGetById() throws {
        let app = try ForgeApp.bootstrap(home: tempHome)
        defer { app.shutdown() }
        let client = ClientID("list")
        _ = try app.tools.call(
            name: "session_handoff",
            arguments: ["goal": "A", "status": "done"],
            clientID: client
        )
        _ = try app.tools.call(
            name: "session_handoff",
            arguments: ["goal": "B", "status": "done"],
            clientID: ClientID("list-2")
        )
        let list = try app.tools.call(name: "context_list", arguments: ["limit": 5], clientID: client)
        XCTAssertTrue(list.ok)
        let count = list.payload["count"] as? Int ?? 0
        XCTAssertGreaterThanOrEqual(count, 2)
    }

    func testLatestHandoffUsesWriteOrderWhenTimestampsTie() throws {
        let clock = FixedClock(Date(timeIntervalSince1970: 1_000))
        let app = try ForgeApp.bootstrap(home: tempHome, clock: clock)
        defer { app.shutdown() }

        let first = try app.tools.call(
            name: "session_handoff",
            arguments: ["goal": "First handoff"],
            clientID: ClientID("tie-first")
        )
        let second = try app.tools.call(
            name: "session_handoff",
            arguments: ["goal": "Second handoff"],
            clientID: ClientID("tie-second")
        )

        let latest = try app.tools.call(
            name: "context_get",
            arguments: [:],
            clientID: ClientID("tie-reader")
        )
        XCTAssertNotEqual(first.payload["handoff_id"] as? String, second.payload["handoff_id"] as? String)
        XCTAssertEqual(latest.payload["handoff_id"] as? String, second.payload["handoff_id"] as? String)

        let listed = try app.tools.call(
            name: "context_list",
            arguments: ["limit": 2],
            clientID: ClientID("tie-reader")
        )
        let handoffs = listed.payload["handoffs"] as? [[String: Any]]
        XCTAssertEqual(handoffs?.first?["id"] as? String, second.payload["handoff_id"] as? String)

        let firstID = try XCTUnwrap(first.payload["handoff_id"] as? String)
        let updatedFirst = try app.tools.call(
            name: "session_handoff",
            arguments: ["handoff_id": firstID, "goal": "First handoff, updated"],
            clientID: ClientID("tie-first")
        )
        XCTAssertEqual(updatedFirst.payload["handoff_id"] as? String, firstID)

        let latestAfterUpdate = try app.tools.call(
            name: "context_get",
            arguments: [:],
            clientID: ClientID("tie-reader")
        )
        XCTAssertEqual(latestAfterUpdate.payload["handoff_id"] as? String, firstID)

        let listedAfterUpdate = try app.tools.call(
            name: "context_list",
            arguments: ["limit": 2],
            clientID: ClientID("tie-reader")
        )
        let reordered = listedAfterUpdate.payload["handoffs"] as? [[String: Any]]
        XCTAssertEqual(reordered?.compactMap { $0["id"] as? String }, [firstID, second.payload["handoff_id"] as? String].compactMap { $0 })
    }

    func testCheckpointUpdateRegeneratesDefaultResumeSeed() throws {
        let app = try ForgeApp.bootstrap(home: tempHome)
        defer { app.shutdown() }
        let client = ClientID("seed-refresh")

        let initial = try app.tools.call(
            name: "session_checkpoint",
            arguments: ["goal": "Old goal", "next_actions": ["Old action"]],
            clientID: client
        )
        let handoffID = try XCTUnwrap(initial.payload["handoff_id"] as? String)

        let updated = try app.tools.call(
            name: "session_checkpoint",
            arguments: [
                "handoff_id": handoffID,
                "goal": "Current goal",
                "next_actions": ["Current action"],
            ],
            clientID: client
        )
        let seed = try XCTUnwrap(updated.payload["resume_seed"] as? String)
        XCTAssertTrue(seed.contains("Current goal"), seed)
        XCTAssertTrue(seed.contains("Current action"), seed)
        XCTAssertFalse(seed.contains("Old goal"), seed)
        XCTAssertFalse(seed.contains("Old action"), seed)
    }

    func testCheckpointUpdatePreservesExplicitResumeSeed() throws {
        let app = try ForgeApp.bootstrap(home: tempHome)
        defer { app.shutdown() }
        let client = ClientID("custom-seed")
        let initial = try app.continuity.checkpoint(
            arguments: [
                "goal": "Initial goal",
                "resume_seed": "Use the operator-provided recovery sequence",
            ],
            clientID: client
        )
        let handoffID = try XCTUnwrap(initial["handoff_id"] as? String)

        let updated = try app.continuity.checkpoint(
            arguments: [
                "handoff_id": handoffID,
                "goal": "Updated goal",
            ],
            clientID: client
        )
        XCTAssertEqual(updated["resume_seed"] as? String, "Use the operator-provided recovery sequence")
        let packet = try XCTUnwrap(app.store.handoffGet(id: handoffID))
        XCTAssertTrue(packet.resumeSeedIsCustom)
        XCTAssertEqual(packet.resumeSeed, "Use the operator-provided recovery sequence")
    }

    func testBudgetHandoffPreservesExplicitAndLegacyCustomResumeSeeds() throws {
        let app = try ForgeApp.bootstrap(home: tempHome)
        defer { app.shutdown() }
        let client = ClientID("budget-custom-seed")
        let customSeed = "Follow the operator recovery sequence exactly"
        let checkpoint = try app.continuity.checkpoint(
            arguments: ["goal": "Preserve custom resume", "resume_seed": customSeed],
            clientID: client
        )
        let handoffID = try XCTUnwrap(checkpoint["handoff_id"] as? String)

        let budget = try app.continuity.budgetAutoCheckpoint(
            clientID: client,
            reason: "custom seed preservation"
        )
        XCTAssertEqual(budget.id, handoffID)
        XCTAssertEqual(budget.resumeSeed, customSeed)
        XCTAssertTrue(budget.resumeSeedIsCustom)

        var legacyCustom = HandoffPacket(
            id: "legacy-custom-seed",
            resumeSeed: "Use the legacy operator sequence"
        ).asDictionary()
        var customResume = try XCTUnwrap(legacyCustom["resume"] as? [String: Any])
        customResume.removeValue(forKey: "custom")
        legacyCustom["resume"] = customResume
        let decodedCustom = try XCTUnwrap(HandoffPacket.fromDictionary(legacyCustom))
        XCTAssertTrue(decodedCustom.resumeSeedIsCustom)

        var generatedPacket = HandoffPacket(id: "legacy-generated-seed", goal: "Legacy generated")
        generatedPacket.resumeSeed = generatedPacket.defaultResumeSeed()
        var legacyGenerated = generatedPacket.asDictionary()
        var generatedResume = try XCTUnwrap(legacyGenerated["resume"] as? [String: Any])
        generatedResume.removeValue(forKey: "custom")
        legacyGenerated["resume"] = generatedResume
        XCTAssertFalse(try XCTUnwrap(HandoffPacket.fromDictionary(legacyGenerated)).resumeSeedIsCustom)
    }

    func testUnknownExplicitHandoffIDFailsWithoutMutation() throws {
        let app = try ForgeApp.bootstrap(home: tempHome)
        defer { app.shutdown() }
        let client = ClientID("unknown-handoff")
        let original = try app.tools.call(
            name: "session_checkpoint",
            arguments: ["goal": "Original state"],
            clientID: client
        )
        let originalID = try XCTUnwrap(original.payload["handoff_id"] as? String)

        let rejected = try app.tools.call(
            name: "session_checkpoint",
            arguments: [
                "handoff_id": "missing-handoff",
                "goal": "Must not overwrite or create state",
            ],
            clientID: client
        )
        XCTAssertFalse(rejected.ok)
        XCTAssertTrue(rejected.isError)

        let packets = try app.store.handoffList(limit: 10)
        XCTAssertEqual(packets.map(\.id), [originalID])
        XCTAssertEqual(packets.first?.goal, "Original state")
    }

    func testPacketDecoderRejectsUnsupportedOrCorruptIdentityMetadata() throws {
        let packet = HandoffPacket(id: "valid-handoff", goal: "Valid")

        var unsupported = packet.asDictionary()
        unsupported["schema_version"] = HandoffPacket.schemaVersion + 1
        XCTAssertNil(HandoffPacket.fromDictionary(unsupported))

        var conflicting = packet.asDictionary()
        var conflictingMeta = try XCTUnwrap(conflicting["meta"] as? [String: Any])
        conflictingMeta["schema_version"] = HandoffPacket.schemaVersion + 1
        conflicting["meta"] = conflictingMeta
        XCTAssertNil(HandoffPacket.fromDictionary(conflicting))

        var unknownSource = packet.asDictionary()
        var sourceMeta = try XCTUnwrap(unknownSource["meta"] as? [String: Any])
        sourceMeta["source"] = "unknown"
        unknownSource["meta"] = sourceMeta
        XCTAssertNil(HandoffPacket.fromDictionary(unknownSource))

        var emptyID = packet.asDictionary()
        var emptyIDMeta = try XCTUnwrap(emptyID["meta"] as? [String: Any])
        emptyIDMeta["id"] = "  "
        emptyID["meta"] = emptyIDMeta
        XCTAssertNil(HandoffPacket.fromDictionary(emptyID))

        var pathEscape = packet.asDictionary()
        var pathEscapeMeta = try XCTUnwrap(pathEscape["meta"] as? [String: Any])
        pathEscapeMeta["id"] = "../escape"
        pathEscape["meta"] = pathEscapeMeta
        XCTAssertNil(HandoffPacket.fromDictionary(pathEscape))

        var malformedAgent = packet.asDictionary()
        malformedAgent["agents"] = [["session_id": "", "agent_id": "debug"]]
        XCTAssertNil(HandoffPacket.fromDictionary(malformedAgent))
    }

    func testPacketDecoderEnforcesJSONScalarAndContainerTypes() throws {
        let packet = HandoffPacket(id: "strict-json-types", resumeReady: true, goal: "Strict")
        func roundTrip(_ object: [String: Any]) -> HandoffPacket? {
            guard let data = try? JSONSupport.data(from: object),
                  let decoded = try? JSONSupport.object(from: data) else { return nil }
            return HandoffPacket.fromDictionary(decoded)
        }
        XCTAssertNotNil(roundTrip(packet.asDictionary()))

        var booleanVersion = packet.asDictionary()
        booleanVersion["schema_version"] = true
        XCTAssertNil(roundTrip(booleanVersion))

        var floatingVersion = packet.asDictionary()
        floatingVersion["schema_version"] = 1.5
        XCTAssertNil(roundTrip(floatingVersion))

        var numericReady = packet.asDictionary()
        var readyMeta = try XCTUnwrap(numericReady["meta"] as? [String: Any])
        readyMeta["resume_ready"] = 1
        numericReady["meta"] = readyMeta
        XCTAssertNil(roundTrip(numericReady))

        var numericCustom = packet.asDictionary()
        var resume = try XCTUnwrap(numericCustom["resume"] as? [String: Any])
        resume["custom"] = 1
        numericCustom["resume"] = resume
        XCTAssertNil(roundTrip(numericCustom))

        var malformedTask = packet.asDictionary()
        malformedTask["task"] = "not-an-object"
        XCTAssertNil(roundTrip(malformedTask))

        var malformedTaskField = packet.asDictionary()
        var task = try XCTUnwrap(malformedTaskField["task"] as? [String: Any])
        task["next_actions"] = [1]
        malformedTaskField["task"] = task
        XCTAssertNil(roundTrip(malformedTaskField))
    }

    func testMissingExplicitContextIDIsDistinguishedFromEmptyStore() throws {
        let app = try ForgeApp.bootstrap(home: tempHome)
        defer { app.shutdown() }
        _ = try app.continuity.handoff(
            arguments: ["goal": "Existing packet"],
            clientID: ClientID("existing-context")
        )

        let missing = try app.continuity.get(id: "missing-context")
        XCTAssertEqual(missing["found"] as? Bool, false)
        let message = missing["message"] as? String ?? ""
        XCTAssertTrue(message.contains("missing-context"), message)
        XCTAssertFalse(message.contains("No handoff packet yet"), message)
    }

    func testContinuityArgumentLimitsCannotOverflowAndSensitiveStateIsRedacted() throws {
        let app = try ForgeApp.bootstrap(home: tempHome)
        defer { app.shutdown() }
        let result = try app.tools.call(
            name: "context_list",
            arguments: ["limit": 1e300],
            clientID: ClientID("large-limit")
        )
        XCTAssertTrue(result.ok)
        XCTAssertEqual(result.payload["count"] as? Int, 0)

        let secret = "continuity-secret-\(UUID().uuidString)"
        let sanitized = ToolAuditSanitizer.sanitize([
            "narrative": secret,
            "summary": secret,
            "resume_seed": secret,
            "blockers": [secret],
            "next_actions": [secret],
            "decisions": [secret],
            "key_files": [secret],
            "cwd": secret,
            "project_slug": secret,
            "project": secret,
            "chat_label": secret,
            "chat": secret,
            "status": secret,
            "handoff_id": "safe-id",
        ])
        let encoded = try JSONSupport.string(from: sanitized)
        XCTAssertFalse(encoded.contains(secret), encoded)
        XCTAssertEqual(sanitized["handoff_id"] as? String, "safe-id")

        let auditClient = ClientID("redacted-aliases")
        let checkpoint = try app.tools.call(
            name: "session_checkpoint",
            arguments: [
                "goal": secret,
                "project": secret,
                "chat": secret,
                "status": secret,
            ],
            clientID: auditClient
        )
        XCTAssertTrue(checkpoint.ok)
        let audit = try XCTUnwrap(
            app.audit.recent(limit: 20).first {
                $0.tool == "session_checkpoint" && $0.clientID == auditClient.rawValue
            }
        )
        let persistedArguments = try XCTUnwrap(audit.argsJSON)
        XCTAssertFalse(persistedArguments.contains(secret), persistedArguments)
    }

    func testHandoffFinalizesCallingClientsOpenCheckpoint() throws {
        let app = try ForgeApp.bootstrap(home: tempHome)
        defer { app.shutdown() }
        let client = ClientID("checkpoint-owner")

        let checkpoint = try app.tools.call(
            name: "session_checkpoint",
            arguments: [
                "goal": "Preserve checkpoint state",
                "blockers": ["Waiting for evidence"],
                "next_actions": ["Resume investigation"],
                "key_files": ["Sources/Continuity.swift"],
                "decisions": ["Use stdio MCP"],
            ],
            clientID: client
        )
        let checkpointID = try XCTUnwrap(checkpoint.payload["handoff_id"] as? String)

        let handoff = try app.tools.call(
            name: "session_handoff",
            arguments: ["status": "ready_for_new_chat"],
            clientID: client
        )
        XCTAssertEqual(handoff.payload["handoff_id"] as? String, checkpointID)
        XCTAssertEqual(handoff.payload["resume_ready"] as? Bool, true)

        let packet = try XCTUnwrap(handoff.payload["packet"] as? [String: Any])
        let meta = try XCTUnwrap(packet["meta"] as? [String: Any])
        let task = try XCTUnwrap(packet["task"] as? [String: Any])
        let workingSet = try XCTUnwrap(packet["working_set"] as? [String: Any])
        XCTAssertEqual(meta["client_id"] as? String, client.rawValue)
        XCTAssertEqual(task["goal"] as? String, "Preserve checkpoint state")
        XCTAssertEqual(task["blockers"] as? [String], ["Waiting for evidence"])
        XCTAssertEqual(task["next_actions"] as? [String], ["Resume investigation"])
        XCTAssertEqual(workingSet["key_files"] as? [String], ["Sources/Continuity.swift"])
        XCTAssertEqual(workingSet["decisions"] as? [String], ["Use stdio MCP"])
    }

    func testBudgetHandoffPreservesCallingClientsCheckpointState() throws {
        let app = try ForgeApp.bootstrap(home: tempHome)
        defer { app.shutdown() }
        let client = ClientID("budget-owner")
        let checkpoint = try app.tools.call(
            name: "session_checkpoint",
            arguments: [
                "goal": "Keep the real task",
                "narrative": "Evidence collected before the loop",
                "blockers": ["Context pressure"],
                "next_actions": ["Continue the real task"],
                "key_files": ["Sources/RealTask.swift"],
                "decisions": ["Preserve structured state"],
            ],
            clientID: client
        )
        let checkpointID = try XCTUnwrap(checkpoint.payload["handoff_id"] as? String)
        let path = tempHome.appendingPathComponent("budget-state.txt").path
        _ = try app.tools.call(
            name: "fs_write",
            arguments: ["path": path, "content": "value"],
            clientID: client
        )

        var budgetResult: ToolResult?
        for _ in 0..<4 {
            budgetResult = try app.tools.call(
                name: "fs_read",
                arguments: ["path": path],
                clientID: client
            )
        }
        let result = try XCTUnwrap(budgetResult)
        XCTAssertEqual(result.payload["handoff_required"] as? Bool, true)
        XCTAssertEqual(result.payload["handoff_id"] as? String, checkpointID)

        let restored = try app.continuity.get(id: checkpointID)
        let packet = try XCTUnwrap(restored["packet"] as? [String: Any])
        let task = try XCTUnwrap(packet["task"] as? [String: Any])
        let workingSet = try XCTUnwrap(packet["working_set"] as? [String: Any])
        XCTAssertEqual(task["goal"] as? String, "Keep the real task")
        XCTAssertEqual(task["blockers"] as? [String], ["Context pressure"])
        XCTAssertEqual(task["next_actions"] as? [String], ["Continue the real task"])
        XCTAssertEqual(workingSet["key_files"] as? [String], ["Sources/RealTask.swift"])
        XCTAssertEqual(workingSet["decisions"] as? [String], ["Preserve structured state"])
        XCTAssertTrue((packet["narrative"] as? String)?.contains("Evidence collected before the loop") == true)
    }

    func testBudgetHandoffReusesRichResumeReadyPacket() throws {
        let app = try ForgeApp.bootstrap(home: tempHome)
        defer { app.shutdown() }
        let client = ClientID("budget-ready-owner")
        let handoff = try app.tools.call(
            name: "session_handoff",
            arguments: [
                "goal": "Preserve completed handoff",
                "blockers": ["Needs another chat"],
                "next_actions": ["Resume the task"],
                "key_files": ["Sources/Ready.swift"],
                "decisions": ["Keep this packet authoritative"],
            ],
            clientID: client
        )
        let handoffID = try XCTUnwrap(handoff.payload["handoff_id"] as? String)

        let budget = try app.continuity.budgetAutoCheckpoint(
            clientID: client,
            reason: "test ready packet preservation"
        )
        XCTAssertEqual(budget.id, handoffID)
        XCTAssertEqual(budget.goal, "Preserve completed handoff")
        XCTAssertEqual(budget.blockers, ["Needs another chat"])
        XCTAssertEqual(budget.nextActions, ["Resume the task"])
        XCTAssertEqual(budget.keyFiles, ["Sources/Ready.swift"])
        XCTAssertEqual(budget.decisions, ["Keep this packet authoritative"])
    }

    func testHandoffSnapshotsOnlyCallingClientsOpenAgents() throws {
        let app = try ForgeApp.bootstrap(home: tempHome)
        defer { app.shutdown() }
        let firstClient = ClientID("agent-owner-a")
        let secondClient = ClientID("agent-owner-b")

        let first = try app.tools.call(
            name: "agent_run_start",
            arguments: ["agent_id": "debug", "goal": "First task", "cwd": tempHome.path],
            clientID: firstClient
        )
        let second = try app.tools.call(
            name: "agent_run_start",
            arguments: ["agent_id": "review", "goal": "Second task", "cwd": tempHome.path],
            clientID: secondClient
        )
        let firstID = try XCTUnwrap(first.payload["session_id"] as? String)
        let secondID = try XCTUnwrap(second.payload["session_id"] as? String)

        let handoff = try app.tools.call(
            name: "session_handoff",
            arguments: ["goal": "First task"],
            clientID: firstClient
        )
        let packet = try XCTUnwrap(handoff.payload["packet"] as? [String: Any])
        let agents = try XCTUnwrap(packet["agents"] as? [[String: Any]])
        XCTAssertEqual(agents.map { $0["session_id"] as? String }, [firstID])
        XCTAssertFalse(agents.contains { $0["session_id"] as? String == secondID })
    }

    func testNewClientStatusReattachesOpenAgentSession() throws {
        let originalClient = ClientID("agent-original")
        let resumedClient = ClientID("agent-resumed")

        let sessionID: String
        do {
            let app = try ForgeApp.bootstrap(home: tempHome)
            defer { app.shutdown() }
            let started = try app.tools.call(
                name: "agent_run_start",
                arguments: [
                    "agent_id": "debug",
                    "goal": "Resume this specialist",
                    "cwd": tempHome.path,
                ],
                clientID: originalClient
            )
            sessionID = try XCTUnwrap(started.payload["session_id"] as? String)
        }

        let restarted = try ForgeApp.bootstrap(home: tempHome)
        defer { restarted.shutdown() }
        let status = try restarted.tools.call(
            name: "agent_run_status",
            arguments: ["session_id": sessionID],
            clientID: resumedClient
        )
        XCTAssertEqual(status.payload["reattached"] as? Bool, true)
        let binding = try XCTUnwrap(restarted.sessions.binding(for: resumedClient))
        XCTAssertEqual(binding.sessionID.rawValue, sessionID)
        XCTAssertEqual(binding.goal, "Resume this specialist")
        XCTAssertEqual(binding.cwd, tempHome.path)
        XCTAssertEqual(try restarted.store.sessionGet(id: SessionID(sessionID))?.clientID, resumedClient)

        XCTAssertNil(try restarted.sessions.rehydrate(clientID: originalClient))
        let statusAudit = try XCTUnwrap(
            restarted.audit.recent(limit: 20).first {
                $0.tool == "agent_run_status" && $0.clientID == resumedClient.rawValue
            }
        )
        XCTAssertNotNil(statusAudit.argsJSON, "agent_run_status transfers ownership and must retain sanitized audit args")
    }

    func testConcurrentAgentReattachUsesAtomicOwnershipCompareAndSwap() throws {
        let primary = try ForgeApp.bootstrap(home: tempHome)
        let originalClient = ClientID("reattach-original")
        let started = try primary.tools.call(
            name: "agent_run_start",
            arguments: ["agent_id": "debug", "goal": "Atomic reattach", "cwd": tempHome.path],
            clientID: originalClient
        )
        let sessionID = SessionID(try XCTUnwrap(started.payload["session_id"] as? String))
        let fallback = try ForgeApp.bootstrap(home: tempHome)
        defer {
            primary.shutdown()
            fallback.shutdown()
        }

        let clients = [ClientID("reattach-a"), ClientID("reattach-b")]
        let stores = [primary.store, fallback.store]
        let bodies = try clients.map { client in
            try JSONSupport.string(from: [
                "session_id": sessionID.rawValue,
                "agent_id": "debug",
                "goal": "Claimed by \(client.rawValue)",
            ])
        }
        let outcomes = LockedFailureMessages()
        DispatchQueue.concurrentPerform(iterations: clients.count) { index in
            do {
                _ = try stores[index].sessionReattach(
                    id: sessionID,
                    expectedClientID: originalClient,
                    clientID: clients[index],
                    bindingBody: bodies[index],
                    agentID: "debug",
                    supersedeSummary: "superseded for atomic test"
                )
                outcomes.append("success:\(clients[index].rawValue)")
            } catch StoreError.conflict {
                outcomes.append("conflict:\(clients[index].rawValue)")
            } catch {
                outcomes.append("unexpected:\(error)")
            }
        }

        let result = outcomes.snapshot
        let winners = result.filter { $0.hasPrefix("success:") }
        XCTAssertEqual(winners.count, 1, result.joined(separator: ", "))
        XCTAssertEqual(result.filter { $0.hasPrefix("conflict:") }.count, 1, result.joined(separator: ", "))
        XCTAssertFalse(result.contains { $0.hasPrefix("unexpected:") }, result.joined(separator: ", "))
        let winner = String(try XCTUnwrap(winners.first).dropFirst("success:".count))
        XCTAssertEqual(try primary.store.sessionGet(id: sessionID)?.clientID?.rawValue, winner)
        XCTAssertNil(try primary.store.memoryGet(key: "agent_active/\(originalClient.rawValue)"))
        for client in clients {
            let note = try primary.store.memoryGet(key: "agent_active/\(client.rawValue)")
            XCTAssertEqual(note != nil, client.rawValue == winner, client.rawValue)
        }
    }

    func testContinuitySurvivesAppRestartWithDurableProjections() throws {
        let client = ClientID("restart-writer")
        let app = try ForgeApp.bootstrap(home: tempHome)
        let handoff = try app.tools.call(
            name: "session_handoff",
            arguments: [
                "goal": "Resume after restart",
                "next_actions": ["Reload durable state"],
                "narrative": "State written before process shutdown",
            ],
            clientID: client
        )
        let handoffID = try XCTUnwrap(handoff.payload["handoff_id"] as? String)
        let packetURL = app.paths.memoryHandoffsDir.appendingPathComponent("\(handoffID).json")
        let latestURL = app.paths.memoryHandoffsDir.appendingPathComponent("LATEST")
        let currentTaskURL = app.paths.memoryCurrentTask
        _ = try app.store.memoryDelete(key: "continuity/latest")
        _ = try app.store.memoryDelete(key: "continuity/resume_ready")
        app.shutdown()

        try FileManager.default.removeItem(at: packetURL)
        try FileManager.default.removeItem(at: latestURL)
        try "stale projection".write(to: currentTaskURL, atomically: true, encoding: .utf8)

        let restarted = try ForgeApp.bootstrap(home: tempHome)
        defer { restarted.shutdown() }
        let server = MCPServer(app: restarted, clientID: ClientID("restart-reader"))
        let response = server.handle([
            "jsonrpc": "2.0",
            "id": 7,
            "method": "tools/call",
            "params": [
                "name": "context_get",
                "arguments": ["handoff_id": handoffID],
            ] as [String: Any],
        ])
        let mcpResult = try XCTUnwrap(response?["result"] as? [String: Any])
        XCTAssertEqual(mcpResult["isError"] as? Bool, false)
        let restored = try XCTUnwrap(mcpResult["structuredContent"] as? [String: Any])

        XCTAssertEqual(restored["found"] as? Bool, true)
        XCTAssertEqual(restored["handoff_id"] as? String, handoffID)
        let packet = restored["packet"] as? [String: Any]
        let task = packet?["task"] as? [String: Any]
        XCTAssertEqual(task?["goal"] as? String, "Resume after restart")

        XCTAssertTrue(FileManager.default.fileExists(atPath: packetURL.path))
        let projectedPacket = try XCTUnwrap(
            JSONSupport.object(from: Data(contentsOf: packetURL))["meta"] as? [String: Any]
        )
        XCTAssertEqual(projectedPacket["id"] as? String, handoffID)
        let latestID = try String(
            contentsOf: latestURL,
            encoding: .utf8
        )
        XCTAssertEqual(latestID, handoffID)
        let currentTask = try String(contentsOf: currentTaskURL, encoding: .utf8)
        XCTAssertTrue(currentTask.contains("Resume after restart"), currentTask)
        XCTAssertEqual(try restarted.store.memoryGet(key: "continuity/latest"), handoffID)
        XCTAssertEqual(try restarted.store.memoryGet(key: "continuity/resume_ready"), handoffID)

        let continued = try restarted.tools.call(
            name: "session_checkpoint",
            arguments: [
                "handoff_id": handoffID,
                "goal": "Continued after restart",
            ],
            clientID: ClientID("restart-reader")
        )
        XCTAssertEqual(continued.payload["handoff_id"] as? String, handoffID)
        XCTAssertEqual(try restarted.store.handoffGet(id: handoffID)?.goal, "Continued after restart")
    }

    func testNewChatRecoversGoalAndAgentThenReattachesOverMCP() throws {
        let originalClient = ClientID("combined-original")
        let handoffID: String
        let sessionID: String
        do {
            let app = try ForgeApp.bootstrap(home: tempHome)
            defer { app.shutdown() }
            let started = try app.tools.call(
                name: "agent_run_start",
                arguments: [
                    "agent_id": "debug",
                    "goal": "Inspect combined continuity",
                    "cwd": tempHome.path,
                ],
                clientID: originalClient
            )
            sessionID = try XCTUnwrap(started.payload["session_id"] as? String)
            let handoff = try app.tools.call(
                name: "session_handoff",
                arguments: ["goal": "Recover the combined task"],
                clientID: originalClient
            )
            handoffID = try XCTUnwrap(handoff.payload["handoff_id"] as? String)
        }

        let restarted = try ForgeApp.bootstrap(home: tempHome)
        defer { restarted.shutdown() }
        let resumedClient = ClientID("combined-new-chat")
        let server = MCPServer(app: restarted, clientID: resumedClient)
        let contextResponse = server.handle([
            "jsonrpc": "2.0",
            "id": 1,
            "method": "tools/call",
            "params": [
                "name": "context_get",
                "arguments": ["handoff_id": handoffID],
            ] as [String: Any],
        ])
        let contextResult = try XCTUnwrap(contextResponse?["result"] as? [String: Any])
        let context = try XCTUnwrap(contextResult["structuredContent"] as? [String: Any])
        let packet = try XCTUnwrap(context["packet"] as? [String: Any])
        let task = try XCTUnwrap(packet["task"] as? [String: Any])
        let agents = try XCTUnwrap(packet["agents"] as? [[String: Any]])
        XCTAssertEqual(task["goal"] as? String, "Recover the combined task")
        XCTAssertEqual(agents.map { $0["session_id"] as? String }, [sessionID])

        let statusResponse = server.handle([
            "jsonrpc": "2.0",
            "id": 2,
            "method": "tools/call",
            "params": [
                "name": "agent_run_status",
                "arguments": ["session_id": sessionID],
            ] as [String: Any],
        ])
        let statusResult = try XCTUnwrap(statusResponse?["result"] as? [String: Any])
        let status = try XCTUnwrap(statusResult["structuredContent"] as? [String: Any])
        XCTAssertEqual(status["reattached"] as? Bool, true)
        XCTAssertEqual(try restarted.store.sessionGet(id: SessionID(sessionID))?.clientID, resumedClient)
    }

    func testStartupRepairsEveryMissingPacketProjection() throws {
        let app = try ForgeApp.bootstrap(home: tempHome)
        let older = try app.continuity.handoff(
            arguments: ["goal": "Older projection"],
            clientID: ClientID("older-projection")
        )
        let newer = try app.continuity.handoff(
            arguments: ["goal": "Newer projection"],
            clientID: ClientID("newer-projection")
        )
        let olderID = try XCTUnwrap(older["handoff_id"] as? String)
        let newerID = try XCTUnwrap(newer["handoff_id"] as? String)
        let olderURL = app.paths.memoryHandoffsDir.appendingPathComponent("\(olderID).json")
        let latestURL = app.paths.memoryHandoffsDir.appendingPathComponent("LATEST")
        app.shutdown()
        try FileManager.default.removeItem(at: olderURL)

        let restarted = try ForgeApp.bootstrap(home: tempHome)
        defer { restarted.shutdown() }
        XCTAssertTrue(FileManager.default.fileExists(atPath: olderURL.path))
        let olderProjection = try JSONSupport.object(from: Data(contentsOf: olderURL))
        let olderTask = try XCTUnwrap(olderProjection["task"] as? [String: Any])
        XCTAssertEqual(olderTask["goal"] as? String, "Older projection")
        XCTAssertEqual(try String(contentsOf: latestURL, encoding: .utf8), newerID)
    }

    func testProjectionFailureKeepsAuthoritativeWriteAndRepairsOnRestart() throws {
        let client = ClientID("projection-failure")
        let app = try ForgeApp.bootstrap(home: tempHome)
        let initial = try app.continuity.checkpoint(
            arguments: ["goal": "Before projection failure"],
            clientID: client
        )
        let handoffID = try XCTUnwrap(initial["handoff_id"] as? String)
        let packetURL = app.paths.memoryHandoffsDir.appendingPathComponent("\(handoffID).json")
        try FileManager.default.removeItem(at: packetURL)
        try FileManager.default.createDirectory(at: packetURL, withIntermediateDirectories: false)

        let updated = try app.continuity.checkpoint(
            arguments: [
                "handoff_id": handoffID,
                "goal": "Durable despite projection failure",
            ],
            clientID: client
        )
        XCTAssertEqual(updated["ok"] as? Bool, true)
        XCTAssertEqual(updated["projection_ok"] as? Bool, false)
        XCTAssertEqual(updated["projection_repair_pending"] as? Bool, true)
        XCTAssertEqual(try app.store.handoffGet(id: handoffID)?.goal, "Durable despite projection failure")
        app.shutdown()

        try FileManager.default.removeItem(at: packetURL)
        let restarted = try ForgeApp.bootstrap(home: tempHome)
        defer { restarted.shutdown() }
        XCTAssertTrue(FileManager.default.fileExists(atPath: packetURL.path))
        XCTAssertEqual(try restarted.store.handoffGet(id: handoffID)?.goal, "Durable despite projection failure")
        let projection = try JSONSupport.object(from: Data(contentsOf: packetURL))
        let task = try XCTUnwrap(projection["task"] as? [String: Any])
        XCTAssertEqual(task["goal"] as? String, "Durable despite projection failure")
    }

    func testPointerWriteFailureRollsBackHandoffRow() throws {
        let app = try ForgeApp.bootstrap(home: tempHome)
        defer { app.shutdown() }
        try withSQLiteFixture(at: app.paths.storeSQLite) { database in
            try executeSQLiteFixture(
                database,
                sql: """
                CREATE TRIGGER fail_continuity_latest
                BEFORE INSERT ON memory_notes
                WHEN NEW.key = 'continuity/latest'
                BEGIN
                    SELECT RAISE(ABORT, 'forced continuity pointer failure');
                END;
                """
            )
        }

        XCTAssertThrowsError(
            try app.continuity.handoff(
                arguments: ["goal": "Must roll back"],
                clientID: ClientID("pointer-rollback")
            )
        )
        XCTAssertEqual(try app.store.handoffList(limit: 10), [])
        XCTAssertNil(try app.store.memoryGet(key: "continuity/latest"))

        try withSQLiteFixture(at: app.paths.storeSQLite) { database in
            try executeSQLiteFixture(database, sql: "DROP TRIGGER fail_continuity_latest;")
        }
        let recovered = try app.continuity.handoff(
            arguments: ["goal": "Writes after rollback"],
            clientID: ClientID("pointer-rollback")
        )
        XCTAssertEqual(recovered["ok"] as? Bool, true)
        XCTAssertEqual(try app.store.handoffList(limit: 10).count, 1)
    }

    func testVersionThreeStoreMigratesWithoutLosingHandoff() throws {
        let databaseURL = tempHome.appendingPathComponent("store.sqlite")
        let legacyPacket = HandoffPacket(
            id: "legacy-v3-handoff",
            createdAt: "2026-01-01T00:00:00Z",
            updatedAt: "2026-01-01T00:00:00Z",
            source: .model,
            resumeReady: true,
            goal: "Recover legacy continuity state",
            nextActions: ["Migrate in place"]
        )
        let legacyJSON = try JSONSupport.string(from: legacyPacket.asDictionary())

        try withSQLiteFixture(at: databaseURL) { database in
            try executeSQLiteFixture(
                database,
                sql: """
                CREATE TABLE schema_version (version INTEGER NOT NULL);
                INSERT INTO schema_version(version) VALUES (3);
                CREATE TABLE context_handoffs (
                    id TEXT PRIMARY KEY,
                    created_at TEXT NOT NULL,
                    updated_at TEXT NOT NULL,
                    source TEXT NOT NULL,
                    resume_ready INTEGER NOT NULL DEFAULT 0,
                    packet_json TEXT NOT NULL
                );
                """
            )

            var statement: OpaquePointer?
            let sql = """
                INSERT INTO context_handoffs(
                    id, created_at, updated_at, source, resume_ready, packet_json
                ) VALUES (?, ?, ?, ?, ?, ?)
                """
            guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
                  let statement else {
                throw SQLiteFixtureError.failure(String(cString: sqlite3_errmsg(database)))
            }
            defer { sqlite3_finalize(statement) }
            bindSQLiteFixture(statement, index: 1, value: legacyPacket.id)
            bindSQLiteFixture(statement, index: 2, value: legacyPacket.createdAt)
            bindSQLiteFixture(statement, index: 3, value: legacyPacket.updatedAt)
            bindSQLiteFixture(statement, index: 4, value: legacyPacket.source.rawValue)
            sqlite3_bind_int(statement, 5, 1)
            bindSQLiteFixture(statement, index: 6, value: legacyJSON)
            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw SQLiteFixtureError.failure(String(cString: sqlite3_errmsg(database)))
            }
        }

        let app = try ForgeApp.bootstrap(home: tempHome)
        defer { app.shutdown() }
        let restored = try app.continuity.get(id: legacyPacket.id)
        XCTAssertEqual(restored["found"] as? Bool, true)
        let restoredPacket = try XCTUnwrap(restored["packet"] as? [String: Any])
        let restoredTask = try XCTUnwrap(restoredPacket["task"] as? [String: Any])
        XCTAssertEqual(restoredTask["goal"] as? String, "Recover legacy continuity state")

        let current = try app.tools.call(
            name: "session_handoff",
            arguments: ["goal": "State written after migration"],
            clientID: ClientID("migration-writer")
        )
        let currentID = try XCTUnwrap(current.payload["handoff_id"] as? String)
        XCTAssertEqual(try app.store.handoffLatest()?.id, currentID)
        XCTAssertEqual(try app.store.handoffList(limit: 10).map(\.id), [currentID, legacyPacket.id])
    }

    func testConcurrentVersionThreeMigrationIsIdempotent() throws {
        let databaseURL = tempHome.appendingPathComponent("store.sqlite")
        try withSQLiteFixture(at: databaseURL) { database in
            try executeSQLiteFixture(
                database,
                sql: """
                CREATE TABLE schema_version (version INTEGER NOT NULL);
                INSERT INTO schema_version(version) VALUES (3);
                CREATE TABLE context_handoffs (
                    id TEXT PRIMARY KEY,
                    created_at TEXT NOT NULL,
                    updated_at TEXT NOT NULL,
                    source TEXT NOT NULL,
                    resume_ready INTEGER NOT NULL DEFAULT 0,
                    packet_json TEXT NOT NULL
                );
                """
            )
        }

        let failures = LockedFailureMessages()
        DispatchQueue.concurrentPerform(iterations: 2) { index in
            do {
                let store = try SQLiteStore(path: databaseURL)
                store.close()
            } catch {
                failures.append("migration \(index): \(error)")
            }
        }
        XCTAssertEqual(failures.snapshot, [])

        let store = try SQLiteStore(path: databaseURL)
        defer { store.close() }
        let packet = HandoffPacket(id: "post-concurrent-migration", goal: "Migration complete")
        try store.handoffUpsert(packet)
        XCTAssertEqual(try store.handoffLatest()?.id, packet.id)
        XCTAssertEqual(try store.memoryGet(key: "continuity/latest"), packet.id)
    }

    func testConcurrentPrimaryAndFallbackWritesKeepProjectionsConsistent() throws {
        let primary = try ForgeApp.bootstrap(home: tempHome)
        let fallback = try ForgeApp.bootstrap(home: tempHome)
        defer {
            primary.shutdown()
            fallback.shutdown()
        }

        let failures = LockedFailureMessages()
        DispatchQueue.concurrentPerform(iterations: 24) { index in
            let app = index.isMultiple(of: 2) ? primary : fallback
            do {
                _ = try app.continuity.handoff(
                    arguments: ["goal": "Concurrent handoff \(index)"],
                    clientID: ClientID("concurrent-\(index)")
                )
            } catch {
                failures.append("write \(index): \(error)")
            }
        }
        XCTAssertEqual(failures.snapshot, [])

        let packets = try primary.store.handoffList(limit: 100)
        XCTAssertEqual(packets.count, 24)
        XCTAssertEqual(Set(packets.map(\.id)).count, 24)
        for packet in packets {
            let projection = primary.paths.memoryHandoffsDir.appendingPathComponent("\(packet.id).json")
            XCTAssertTrue(FileManager.default.fileExists(atPath: projection.path), packet.id)
        }

        let authoritativeLatest = try XCTUnwrap(primary.store.handoffLatest())
        let projectedLatest = try String(
            contentsOf: primary.paths.memoryHandoffsDir.appendingPathComponent("LATEST"),
            encoding: .utf8
        )
        XCTAssertEqual(projectedLatest, authoritativeLatest.id)
        let currentTask = try String(contentsOf: primary.paths.memoryCurrentTask, encoding: .utf8)
        XCTAssertTrue(currentTask.contains(authoritativeLatest.id), currentTask)
        XCTAssertTrue(currentTask.contains(authoritativeLatest.goal), currentTask)
    }

    func testPrimaryAndFallbackMCPProcessesShareContinuitySafely() throws {
        let binary = try XCTUnwrap(
            locateContinuityCLIBinary(),
            "The current test build must provide an adjacent forge-conductor CLI"
        )
        let processHome = tempHome.appendingPathComponent("process-home", isDirectory: true)
        try FileManager.default.createDirectory(at: processHome, withIntermediateDirectories: true)
        let primary = try launchMCPFixture(binary: binary, home: processHome, role: "primary")
        let fallback = try launchMCPFixture(binary: binary, home: processHome, role: "fallback")

        try sendMCPHandoff(primary, id: 2, goal: "Primary process handoff")
        try sendMCPHandoff(fallback, id: 2, goal: "Fallback process handoff")
        let primaryOutput = try waitForMCPFixture(primary, timeout: 10)
        let fallbackOutput = try waitForMCPFixture(fallback, timeout: 10)

        for output in [primaryOutput, fallbackOutput] {
            let response = output.first { ($0["id"] as? Int) == 2 }
            let result = try XCTUnwrap(response?["result"] as? [String: Any])
            XCTAssertEqual(result["isError"] as? Bool, false)
            let structured = try XCTUnwrap(result["structuredContent"] as? [String: Any])
            XCTAssertEqual(structured["ok"] as? Bool, true)
            XCTAssertEqual(structured["projection_ok"] as? Bool, true)
        }

        // Read raw storage without ForgeApp bootstrap so projection repair cannot
        // hide an ordering mismatch produced by the two serve processes.
        let store = try SQLiteStore(path: processHome.appendingPathComponent("store.sqlite"))
        let packets = try store.handoffList(limit: 10)
        let latest = try XCTUnwrap(store.handoffLatest())
        store.close()
        XCTAssertEqual(packets.count, 2)
        XCTAssertEqual(
            Set(packets.map(\.goal)),
            Set(["Primary process handoff", "Fallback process handoff"])
        )

        let paths = AppPaths(home: processHome)
        let pointer = try String(
            contentsOf: paths.memoryHandoffsDir.appendingPathComponent("LATEST"),
            encoding: .utf8
        )
        XCTAssertEqual(pointer, latest.id)
        let markdown = try String(contentsOf: paths.memoryCurrentTask, encoding: .utf8)
        XCTAssertTrue(markdown.contains(latest.id), markdown)
        XCTAssertTrue(markdown.contains(latest.goal), markdown)
    }

    func testConcurrentUpdatesToSamePacketPreserveDisjointFields() throws {
        let primary = try ForgeApp.bootstrap(home: tempHome)
        let fallback = try ForgeApp.bootstrap(home: tempHome)
        defer {
            primary.shutdown()
            fallback.shutdown()
        }
        let client = ClientID("shared-packet-owner")
        let initial = try primary.continuity.checkpoint(
            arguments: ["goal": "Merge concurrent packet updates"],
            clientID: client
        )
        let handoffID = try XCTUnwrap(initial["handoff_id"] as? String)
        let failures = LockedFailureMessages()

        DispatchQueue.concurrentPerform(iterations: 2) { index in
            do {
                if index == 0 {
                    _ = try primary.continuity.checkpoint(
                        arguments: [
                            "handoff_id": handoffID,
                            "blockers": ["Primary blocker"],
                        ],
                        clientID: client
                    )
                } else {
                    _ = try fallback.continuity.checkpoint(
                        arguments: [
                            "handoff_id": handoffID,
                            "decisions": ["Fallback decision"],
                        ],
                        clientID: client
                    )
                }
            } catch {
                failures.append("update \(index): \(error)")
            }
        }
        XCTAssertEqual(failures.snapshot, [])

        let merged = try XCTUnwrap(primary.store.handoffGet(id: handoffID))
        XCTAssertEqual(merged.goal, "Merge concurrent packet updates")
        XCTAssertEqual(merged.blockers, ["Primary blocker"])
        XCTAssertEqual(merged.decisions, ["Fallback decision"])
    }

    func testNarrativeOnlyCheckpointReplacesCurrentTaskProjection() throws {
        let app = try ForgeApp.bootstrap(home: tempHome)
        defer { app.shutdown() }
        _ = try app.continuity.checkpoint(
            arguments: ["goal": "Old projected goal"],
            clientID: ClientID("old-projection")
        )
        let latest = try app.continuity.checkpoint(
            arguments: ["narrative": "Narrative-only latest state"],
            clientID: ClientID("new-projection")
        )
        let latestID = try XCTUnwrap(latest["handoff_id"] as? String)

        let markdown = try String(contentsOf: app.paths.memoryCurrentTask, encoding: .utf8)
        XCTAssertTrue(markdown.contains(latestID), markdown)
        XCTAssertTrue(markdown.contains("Narrative-only latest state"), markdown)
        XCTAssertFalse(markdown.contains("Old projected goal"), markdown)
    }

    func testContinuityToolsListed() throws {
        let app = try ForgeApp.bootstrap(home: tempHome)
        defer { app.shutdown() }
        let names = Set(app.tools.toolNames)
        for need in ["session_checkpoint", "session_handoff", "context_get", "context_list"] {
            XCTAssertTrue(names.contains(need), "missing \(need)")
        }

        let server = MCPServer(app: app, clientID: ClientID("continuity-schema"))
        let response = server.handle([
            "jsonrpc": "2.0",
            "id": 1,
            "method": "tools/list",
        ])
        let result = response?["result"] as? [String: Any]
        let descriptors = result?["tools"] as? [[String: Any]] ?? []
        let byName = Dictionary(uniqueKeysWithValues: descriptors.compactMap { descriptor in
            (descriptor["name"] as? String).map { ($0, descriptor) }
        })
        XCTAssertTrue(MCPServeVerifier.requiredContinuityTools.isSubset(of: Set(byName.keys)))

        let checkpointSchema = byName["session_checkpoint"]?["inputSchema"] as? [String: Any]
        let checkpointProperties = checkpointSchema?["properties"] as? [String: Any]
        XCTAssertNotNil(checkpointProperties?["summary"], "summary alias must be advertised to MCP hosts")
        let contextSchema = byName["context_get"]?["inputSchema"] as? [String: Any]
        let contextProperties = contextSchema?["properties"] as? [String: Any]
        XCTAssertNotNil(contextProperties?["handoff_id"])
        XCTAssertNotNil(contextProperties?["resume_ready"])
    }

    func testBudgetLoopEventuallyRequiresHandoff() throws {
        let app = try ForgeApp.bootstrap(home: tempHome)
        defer { app.shutdown() }
        let client = ClientID("loop")
        let path = tempHome.appendingPathComponent("loop.txt").path
        _ = try app.tools.call(
            name: "fs_write",
            arguments: ["path": path, "content": "x"],
            clientID: client
        )
        // Same read repeatedly — soft budget annotates, hard budget blocks.
        var sawHandoffRequired = false
        var sawHardBlock = false
        for _ in 0..<12 {
            let r = try app.tools.call(
                name: "fs_read",
                arguments: ["path": path],
                clientID: client
            )
            if r.payload["handoff_required"] as? Bool == true {
                sawHandoffRequired = true
            }
            if r.payload["code"] as? String == "identical_call_loop" {
                sawHardBlock = true
                break
            }
        }
        XCTAssertTrue(sawHandoffRequired || sawHardBlock, "expected budget continuity signal")
        let latest = try app.continuity.get(preferResumeReady: true)
        // Soft/hard budget writes resume-ready packet
        if sawHandoffRequired || sawHardBlock {
            XCTAssertEqual(latest["found"] as? Bool, true)
        }
    }

    func testBudgetLoopSignalsExactlyAtSoftAndHardThresholds() throws {
        let app = try ForgeApp.bootstrap(home: tempHome)
        defer { app.shutdown() }
        let client = ClientID("exact-loop-thresholds")
        let path = tempHome.appendingPathComponent("exact-loop.txt").path
        _ = try app.tools.call(
            name: "fs_write",
            arguments: ["path": path, "content": "threshold"],
            clientID: client
        )

        var softHandoffID: String?
        for count in 1...9 {
            let result = try app.tools.call(
                name: "fs_read",
                arguments: ["path": path],
                clientID: client
            )
            switch count {
            case 1...3:
                XCTAssertTrue(result.ok, "call \(count)")
                XCTAssertNil(result.payload["handoff_required"], "call \(count)")
            case 4:
                XCTAssertTrue(result.ok)
                XCTAssertEqual(result.payload["handoff_required"] as? Bool, true)
                softHandoffID = result.payload["handoff_id"] as? String
                XCTAssertNotNil(softHandoffID)
            case 5...8:
                XCTAssertTrue(result.ok, "call \(count)")
                XCTAssertNil(result.payload["code"], "call \(count)")
            case 9:
                XCTAssertFalse(result.ok)
                XCTAssertTrue(result.isError)
                XCTAssertEqual(result.payload["code"] as? String, "identical_call_loop")
                XCTAssertEqual(result.payload["handoff_required"] as? Bool, true)
                XCTAssertEqual(result.payload["handoff_id"] as? String, softHandoffID)
            default:
                XCTFail("unexpected count")
            }
        }
    }

    func testAuthorizationDeniedLoopSignalsExactlyAtSoftAndHardThresholds() throws {
        let app = try ForgeApp.bootstrap(home: tempHome)
        defer { app.shutdown() }
        let client = ClientID("denied-exact-loop-thresholds")
        let outside = tempHome.deletingLastPathComponent()
            .appendingPathComponent("forge-denied-loop-\(UUID().uuidString).txt")

        var softHandoffID: String?
        for count in 1...9 {
            let result = try app.tools.call(
                name: "fs_write",
                arguments: ["path": outside.path, "content": "must remain denied"],
                clientID: client
            )

            switch count {
            case 1...3, 5...8:
                XCTAssertFalse(result.ok, "call \(count)")
                XCTAssertTrue(result.isError, "call \(count)")
                XCTAssertEqual(result.payload["code"] as? String, "path_outside_allowed_roots")
                XCTAssertNil(result.payload["handoff_required"], "call \(count)")
            case 4:
                XCTAssertFalse(result.ok)
                XCTAssertTrue(result.isError)
                XCTAssertEqual(result.payload["code"] as? String, "path_outside_allowed_roots")
                XCTAssertEqual(result.payload["handoff_required"] as? Bool, true)
                softHandoffID = result.payload["handoff_id"] as? String
                XCTAssertNotNil(softHandoffID)
                XCTAssertFalse((result.payload["resume_seed"] as? String ?? "").isEmpty)
            case 9:
                XCTAssertFalse(result.ok)
                XCTAssertTrue(result.isError)
                XCTAssertEqual(result.payload["code"] as? String, "identical_call_loop")
                XCTAssertEqual(result.payload["blocked_call_code"] as? String, "path_outside_allowed_roots")
                XCTAssertEqual(result.payload["handoff_required"] as? Bool, true)
                XCTAssertEqual(result.payload["handoff_id"] as? String, softHandoffID)
                XCTAssertFalse((result.payload["resume_seed"] as? String ?? "").isEmpty)
            default:
                XCTFail("unexpected count")
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: outside.path), "call \(count) dispatched")
        }

        let handoffID = try XCTUnwrap(softHandoffID)
        let packet = try XCTUnwrap(app.store.handoffGet(id: handoffID))
        XCTAssertEqual(packet.source, .budget)
        XCTAssertTrue(packet.resumeReady)
        XCTAssertFalse(packet.resumeSeed.isEmpty)
        XCTAssertTrue(packet.narrative.contains("identical_call_loop tool=fs_write count=9"), packet.narrative)
        XCTAssertTrue(packet.narrative.contains("authorization_denial=path_outside_allowed_roots"), packet.narrative)

        let audits = try app.audit.recent(limit: 20).filter {
            $0.tool == "fs_write" && $0.clientID == client.rawValue
        }
        XCTAssertEqual(audits.filter { $0.status == "denied" }.count, 8)
        XCTAssertEqual(audits.filter { $0.status == "error" }.count, 1)
    }

    func testAuthorizationDeniedHardBudgetFailsClosedWhenPersistenceFails() throws {
        let app = try ForgeApp.bootstrap(home: tempHome)
        defer { app.shutdown() }
        let client = ClientID("denied-failed-loop-persistence")
        let outside = tempHome.deletingLastPathComponent()
            .appendingPathComponent("forge-denied-failed-loop-\(UUID().uuidString).txt")
        try withSQLiteFixture(at: app.paths.storeSQLite) { database in
            try executeSQLiteFixture(
                database,
                sql: """
                CREATE TRIGGER fail_denied_loop_handoff
                BEFORE INSERT ON context_handoffs
                BEGIN
                    SELECT RAISE(ABORT, 'forced denied loop handoff failure');
                END;
                """
            )
        }

        for count in 1...9 {
            let result = try app.tools.call(
                name: "fs_write",
                arguments: ["path": outside.path, "content": "must remain denied"],
                clientID: client
            )
            if count < 9 {
                XCTAssertFalse(result.ok, "call \(count)")
                XCTAssertEqual(result.payload["code"] as? String, "path_outside_allowed_roots")
                XCTAssertNil(result.payload["handoff_required"], "call \(count)")
            } else {
                XCTAssertFalse(result.ok)
                XCTAssertTrue(result.isError)
                XCTAssertEqual(result.payload["code"] as? String, "continuity_persistence_failed")
                XCTAssertEqual(result.payload["loop_code"] as? String, "identical_call_loop")
                XCTAssertEqual(result.payload["blocked_call_code"] as? String, "path_outside_allowed_roots")
                XCTAssertEqual(result.payload["handoff_required"] as? Bool, true)
                XCTAssertEqual(result.payload["handoff_persisted"] as? Bool, false)
                XCTAssertNil(result.payload["handoff_id"])
                XCTAssertNil(result.payload["resume_seed"])
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: outside.path), "call \(count) dispatched")
        }

        XCTAssertEqual(try app.store.handoffList(limit: 10), [])
        let audits = try app.audit.recent(limit: 20).filter {
            $0.tool == "fs_write" && $0.clientID == client.rawValue
        }
        XCTAssertEqual(audits.filter { $0.status == "denied" }.count, 8)
        XCTAssertEqual(audits.filter { $0.status == "error" }.count, 1)
    }

    func testDispatchFailuresRetainTheirErrorsAtSoftThreshold() throws {
        let app = try ForgeApp.bootstrap(home: tempHome)
        defer { app.shutdown() }

        let unknownClient = ClientID("unknown-tool-soft-threshold")
        var unknownHandoffID: String?
        for count in 1...4 {
            let result = try app.tools.call(
                name: "missing_test_tool",
                arguments: ["probe": "same"],
                clientID: unknownClient
            )
            XCTAssertFalse(result.ok)
            XCTAssertTrue(result.isError)
            XCTAssertEqual(result.payload["code"] as? String, "unknown_tool")
            if count < 4 {
                XCTAssertNil(result.payload["handoff_required"], "call \(count)")
            } else {
                XCTAssertEqual(result.payload["handoff_required"] as? Bool, true)
                unknownHandoffID = result.payload["handoff_id"] as? String
                XCTAssertNotNil(unknownHandoffID)
            }
        }

        let throwingRouter = ToolRouter(app: app, packs: [ThrowingLoopToolPack()])
        let throwingClient = ClientID("throwing-tool-soft-threshold")
        var throwingHandoffID: String?
        for count in 1...4 {
            let result = try throwingRouter.call(
                name: "throwing_test_tool",
                arguments: ["probe": "same"],
                clientID: throwingClient
            )
            XCTAssertFalse(result.ok)
            XCTAssertTrue(result.isError)
            XCTAssertEqual(result.payload["code"] as? String, "tool_exception")
            if count < 4 {
                XCTAssertNil(result.payload["handoff_required"], "call \(count)")
            } else {
                XCTAssertEqual(result.payload["handoff_required"] as? Bool, true)
                throwingHandoffID = result.payload["handoff_id"] as? String
                XCTAssertNotNil(throwingHandoffID)
            }
        }

        for handoffID in [unknownHandoffID, throwingHandoffID].compactMap({ $0 }) {
            let packet = try XCTUnwrap(app.store.handoffGet(id: handoffID))
            XCTAssertEqual(packet.source, .budget)
            XCTAssertTrue(packet.resumeReady)
            XCTAssertFalse(packet.resumeSeed.isEmpty)
        }
    }

    func testHardBudgetBlocksWhenContinuityPersistenceFails() throws {
        let app = try ForgeApp.bootstrap(home: tempHome)
        defer { app.shutdown() }
        let client = ClientID("failed-loop-persistence")
        let path = tempHome.appendingPathComponent("failed-loop.txt").path
        _ = try app.tools.call(
            name: "fs_write",
            arguments: ["path": path, "content": "threshold"],
            clientID: client
        )
        try withSQLiteFixture(at: app.paths.storeSQLite) { database in
            try executeSQLiteFixture(
                database,
                sql: """
                CREATE TRIGGER fail_loop_handoff
                BEFORE INSERT ON context_handoffs
                BEGIN
                    SELECT RAISE(ABORT, 'forced loop handoff failure');
                END;
                """
            )
        }

        for count in 1...9 {
            let result = try app.tools.call(
                name: "fs_read",
                arguments: ["path": path],
                clientID: client
            )
            if count < 9 {
                XCTAssertTrue(result.ok, "call \(count)")
                continue
            }

            XCTAssertFalse(result.ok)
            XCTAssertTrue(result.isError)
            XCTAssertEqual(result.payload["code"] as? String, "continuity_persistence_failed")
            XCTAssertEqual(result.payload["loop_code"] as? String, "identical_call_loop")
            XCTAssertEqual(result.payload["handoff_required"] as? Bool, true)
            XCTAssertEqual(result.payload["handoff_persisted"] as? Bool, false)
            XCTAssertNil(result.payload["handoff_id"])
        }
        XCTAssertEqual(try app.store.handoffList(limit: 10), [])
    }

    func testBudgetFingerprintDistinguishesFractionalArguments() throws {
        let app = try ForgeApp.bootstrap(home: tempHome)
        defer { app.shutdown() }
        let client = ClientID("fractional-loop")
        let path = tempHome.appendingPathComponent("fractional.txt").path
        _ = try app.tools.call(
            name: "fs_write",
            arguments: ["path": path, "content": "value"],
            clientID: client
        )

        for index in 0..<12 {
            let probe = index.isMultiple(of: 2) ? 1.1 : 1.9
            let result = try app.tools.call(
                name: "fs_read",
                arguments: ["path": path, "probe": probe],
                clientID: client
            )
            XCTAssertTrue(result.ok, "different fractional arguments must not form an identical-call loop")
            XCTAssertNil(result.payload["handoff_required"])
        }

        let latest = try app.continuity.get()
        XCTAssertEqual(latest["found"] as? Bool, false)
    }
}

private enum SQLiteFixtureError: Error {
    case failure(String)
}

private enum ThrowingLoopToolPackError: Error {
    case forced
}

private struct ThrowingLoopToolPack: ToolPackHandling {
    let toolNames = ["throwing_test_tool"]

    func handle(
        name: String,
        arguments: [String: Any],
        clientID: ClientID,
        app: ForgeApp
    ) throws -> ToolResult? {
        guard name == "throwing_test_tool" else { return nil }
        throw ThrowingLoopToolPackError.forced
    }
}

private func withSQLiteFixture(
    at url: URL,
    _ body: (OpaquePointer) throws -> Void
) throws {
    var database: OpaquePointer?
    guard sqlite3_open(url.path, &database) == SQLITE_OK, let database else {
        let message = database.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown SQLite open error"
        if let database { sqlite3_close(database) }
        throw SQLiteFixtureError.failure(message)
    }
    defer { sqlite3_close(database) }
    try body(database)
}

private func executeSQLiteFixture(_ database: OpaquePointer, sql: String) throws {
    var errorMessage: UnsafeMutablePointer<CChar>?
    guard sqlite3_exec(database, sql, nil, nil, &errorMessage) == SQLITE_OK else {
        let message = errorMessage.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(database))
        sqlite3_free(errorMessage)
        throw SQLiteFixtureError.failure(message)
    }
}

private func bindSQLiteFixture(_ statement: OpaquePointer, index: Int32, value: String) {
    let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    value.withCString { pointer in
        _ = sqlite3_bind_text(statement, index, pointer, -1, transient)
    }
}

private final class LockedFailureMessages: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []

    func append(_ value: String) {
        lock.lock()
        defer { lock.unlock() }
        values.append(value)
    }

    var snapshot: [String] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }
}

private struct MCPProcessFixture {
    var process: Process
    var input: Pipe
    var output: Pipe
    var error: Pipe
}

private enum MCPProcessFixtureError: Error {
    case timeout(String)
    case failed(String)
}

private func locateContinuityCLIBinary() -> URL? {
    let products = Bundle(for: ContinuityTests.self).bundleURL.deletingLastPathComponent()
    let adjacent = products.appendingPathComponent("forge-conductor")
    if FileManager.default.isExecutableFile(atPath: adjacent.path) {
        return adjacent
    }
    return nil
}

private func launchMCPFixture(binary: URL, home: URL, role: String) throws -> MCPProcessFixture {
    let process = Process()
    process.executableURL = binary
    process.arguments = ["serve"]
    var environment = ProcessInfo.processInfo.environment
    environment["FORGE_CONDUCTOR_HOME"] = home.path
    environment["FORGE_MCP_ROLE"] = role
    environment["FORGE_DEPLOYMENT_ID"] = "continuity-process-test"
    process.environment = environment
    let input = Pipe()
    let output = Pipe()
    let error = Pipe()
    process.standardInput = input
    process.standardOutput = output
    process.standardError = error
    try process.run()
    return MCPProcessFixture(process: process, input: input, output: output, error: error)
}

private func sendMCPHandoff(_ fixture: MCPProcessFixture, id: Int, goal: String) throws {
    let initialize: [String: Any] = [
        "jsonrpc": "2.0",
        "id": 1,
        "method": "initialize",
        "params": [
            "protocolVersion": "2025-11-25",
            "capabilities": [:] as [String: Any],
            "clientInfo": ["name": "continuity-process-test", "version": "1"],
        ] as [String: Any],
    ]
    let handoff: [String: Any] = [
        "jsonrpc": "2.0",
        "id": id,
        "method": "tools/call",
        "params": [
            "name": "session_handoff",
            "arguments": ["goal": goal],
        ] as [String: Any],
    ]
    let payload = try JSONSupport.string(from: initialize) + "\n"
        + JSONSupport.string(from: handoff) + "\n"
    fixture.input.fileHandleForWriting.write(Data(payload.utf8))
    try fixture.input.fileHandleForWriting.close()
}

private func waitForMCPFixture(
    _ fixture: MCPProcessFixture,
    timeout: TimeInterval
) throws -> [[String: Any]] {
    let deadline = Date().addingTimeInterval(timeout)
    while fixture.process.isRunning, Date() < deadline {
        Thread.sleep(forTimeInterval: 0.02)
    }
    guard !fixture.process.isRunning else {
        fixture.process.terminate()
        throw MCPProcessFixtureError.timeout("MCP process did not exit after stdin closed")
    }
    let outputData = fixture.output.fileHandleForReading.readDataToEndOfFile()
    let errorData = fixture.error.fileHandleForReading.readDataToEndOfFile()
    guard fixture.process.terminationStatus == 0 else {
        let stderr = String(data: errorData, encoding: .utf8) ?? ""
        throw MCPProcessFixtureError.failed(stderr)
    }
    return try outputData.split(separator: 0x0A, omittingEmptySubsequences: true).map { line in
        try JSONSupport.object(from: Data(line))
    }
}
