// ManagerTests.swift
// Verifies manager start, stop, status, settings, and PID-file lifecycle behavior.
// Each test uses an isolated home to avoid signalling or reconfiguring an installed manager.

import XCTest
import Security
import Darwin
@testable import ForgeConductorCore

private enum ManagerArtifactFixtureError: Error {
    case forcedCopyFailure
    case forcedSigningFailure
    case forcedVerificationFailure
    case forcedCommitFailure
}

private final class TestManagerArtifactValidator: ManagerArtifactValidating {
    enum Operation: Equatable {
        case sign(ManagerArtifactKind)
        case verify(ManagerArtifactKind)
    }

    let failingOperation: Operation?
    private(set) var operations: [Operation] = []

    init(failingOperation: Operation? = nil) {
        self.failingOperation = failingOperation
    }

    func prepareAndSign(_ url: URL, kind: ManagerArtifactKind) throws {
        _ = url
        let operation = Operation.sign(kind)
        operations.append(operation)
        if operation == failingOperation {
            throw ManagerArtifactFixtureError.forcedSigningFailure
        }
    }

    func verify(_ url: URL, kind: ManagerArtifactKind) throws {
        _ = url
        let operation = Operation.verify(kind)
        operations.append(operation)
        if operation == failingOperation {
            throw ManagerArtifactFixtureError.forcedVerificationFailure
        }
    }
}

private final class TestManagerArtifactCopier: ManagerArtifactCopying {
    let failingCopy: Int?
    private(set) var copyCount = 0

    init(failingCopy: Int? = nil) {
        self.failingCopy = failingCopy
    }

    func copyItem(at source: URL, to destination: URL) throws {
        copyCount += 1
        if copyCount == failingCopy {
            throw ManagerArtifactFixtureError.forcedCopyFailure
        }
        try FileManager.default.copyItem(at: source, to: destination)
    }
}

private final class TestManagerArtifactReplacer: ManagerArtifactReplacing {
    let failingReplacement: Int?
    private(set) var replacementCount = 0

    init(failingReplacement: Int? = nil) {
        self.failingReplacement = failingReplacement
    }

    func applyReplacement(
        target: URL,
        staged: URL?,
        backup: URL,
        hadOriginal: Bool
    ) throws {
        replacementCount += 1
        let failAfterReplacement = replacementCount == failingReplacement
        let fm = FileManager.default
        if let staged {
            if hadOriginal {
                if (try? fm.destinationOfSymbolicLink(atPath: target.path)) != nil {
                    try fm.moveItem(at: target, to: backup)
                    try fm.moveItem(at: staged, to: target)
                } else {
                    _ = try fm.replaceItemAt(
                        target,
                        withItemAt: staged,
                        backupItemName: backup.lastPathComponent,
                        options: [.usingNewMetadataOnly, .withoutDeletingBackupItem]
                    )
                }
            } else {
                try fm.moveItem(at: staged, to: target)
            }
        } else if hadOriginal {
            try fm.moveItem(at: target, to: backup)
        }
        if failAfterReplacement {
            throw ManagerArtifactFixtureError.forcedCommitFailure
        }
    }
}

private struct TestManagerCodeSignatureInspector: ManagerCodeSignatureInspecting {
    let inspection: ManagerArtifactSignatureInspection

    func inspect(
        _ url: URL,
        kind: ManagerArtifactKind
    ) throws -> ManagerArtifactSignatureInspection {
        _ = url
        _ = kind
        return inspection
    }
}

final class ManagerTests: XCTestCase {
    private var home: URL!

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("forge-mgr-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
    }

    func testManagerStartStopService() throws {
        let app = try ForgeApp.bootstrap(home: home)
        try app.config.update([
            "dashboard": ["port": Int.random(in: 19_000...28_000)] as [String: Any],
        ], save: true)

        let node = ManagerNode(app: app)
        let started = try node.startService()
        XCTAssertEqual(started.state, .running)
        XCTAssertEqual(started.serviceActive, true)
        XCTAssertTrue(node.isServiceActive())

        let port = app.config.int("dashboard", "port", default: 7788)
        let statusURL = URL(string: "http://127.0.0.1:\(port)/api/manager/status")!
        Thread.sleep(forTimeInterval: 0.2)
        let live = try HTTPTestHelpers.fetchJSON(statusURL)
        XCTAssertEqual(live["ok"] as? Bool, true)
        XCTAssertEqual(live["state"] as? String, "running")

        let stopped = try node.stopService()
        XCTAssertEqual(stopped.state, .stopped)
        XCTAssertEqual(stopped.serviceActive, false)
        XCTAssertFalse(node.isServiceActive())

        let mgr = try HTTPTestHelpers.fetchJSON(statusURL)
        XCTAssertEqual(mgr["state"] as? String, "stopped")

        let sessionsURL = URL(string: "http://127.0.0.1:\(port)/api/sessions")!
        let code = try HTTPTestHelpers.fetchStatusCode(sessionsURL)
        XCTAssertEqual(code, 503)

        let again = try node.startService()
        XCTAssertEqual(again.serviceActive, true)
        Thread.sleep(forTimeInterval: 0.15)
        let sessionsOK = try HTTPTestHelpers.fetchJSON(sessionsURL)
        XCTAssertEqual(sessionsOK["ok"] as? Bool, true)
        _ = node
    }

    func testManagerRuntimeThrottlesPresenceMaintenance() {
        let runtime = ManagerRuntime()
        let start = Date(timeIntervalSince1970: 1_000)

        XCTAssertTrue(runtime.claimPresencePrune(now: start, minimumInterval: 60))
        XCTAssertFalse(
            runtime.claimPresencePrune(
                now: start.addingTimeInterval(59),
                minimumInterval: 60
            )
        )
        XCTAssertTrue(
            runtime.claimPresencePrune(
                now: start.addingTimeInterval(60),
                minimumInterval: 60
            )
        )
    }

    func testManagerStartPrunesDeadStalePresence() throws {
        let clock = FixedClock(Date(timeIntervalSince1970: 1_000))
        let app = try ForgeApp.bootstrap(home: home, clock: clock)
        try app.store.presenceUpsert(
            clientID: "stale-client",
            hostKind: "lm-studio-mcp",
            pid: Int32.max,
            cwd: home.path
        )
        clock.date = clock.date.addingTimeInterval(121)
        try app.config.update([
            "dashboard": ["port": Int.random(in: 19_000...28_000)] as [String: Any],
        ], save: true)

        let node = ManagerNode(app: app)
        _ = try node.startService()

        XCTAssertTrue(try app.store.presenceRecords().isEmpty)
    }

    func testManagerSettingsPersist() throws {
        let app = try ForgeApp.bootstrap(home: home)
        let port = Int.random(in: 19_000...28_000)
        try app.config.update(["dashboard": ["port": port] as [String: Any]], save: true)
        let node = ManagerNode(app: app)
        _ = try node.startService()

        let result = try node.updateSettings([
            "dashboard": [
                "refresh_interval_sec": 12,
            ] as [String: Any],
            "manager": [
                "auto_restart": false,
                "watchdog_interval_sec": 5,
            ] as [String: Any],
        ], apply: true)

        XCTAssertEqual(result["ok"] as? Bool, true)
        let mgr = result["manager"] as? [String: Any]
        XCTAssertEqual(mgr?["auto_restart"] as? Bool, false)
        XCTAssertEqual(mgr?["watchdog_interval_sec"] as? Int, 5)
        let dash = result["dashboard"] as? [String: Any]
        XCTAssertEqual(dash?["refresh_interval_sec"] as? Int, 12)

        app.config.reload()
        XCTAssertEqual(app.config.bool("manager", "auto_restart", default: true), false)
        XCTAssertEqual(app.config.int("dashboard", "refresh_interval_sec", default: 8), 12)
    }

    func testManagerRestartAPI() throws {
        let app = try ForgeApp.bootstrap(home: home)
        let port = Int.random(in: 19_000...28_000)
        try app.config.update(["dashboard": ["port": port] as [String: Any]], save: true)
        let node = ManagerNode(app: app)
        _ = try node.startService()
        Thread.sleep(forTimeInterval: 0.15)

        let restarted = try node.restartService()
        XCTAssertEqual(restarted.state, .running)
        XCTAssertGreaterThanOrEqual(restarted.restartCount, 1)

        Thread.sleep(forTimeInterval: 0.2)
        let url = URL(string: "http://127.0.0.1:\(port)/api/manager/status")!
        let live = try HTTPTestHelpers.fetchJSON(url)
        XCTAssertEqual(live["service_active"] as? Bool, true)
    }

    func testDashboardClientAttachesToExistingManager() async throws {
        let app = try ForgeApp.bootstrap(home: home)
        let port = Int.random(in: 29_000...39_000)
        try app.config.update(["dashboard": ["port": port] as [String: Any]], save: true)
        let node = ManagerNode(app: app)
        _ = try node.startService()
        try await Task.sleep(for: .milliseconds(150))

        let client = ManagerDashboardClient(host: "127.0.0.1", port: port)
        let status = try await client.status()
        XCTAssertTrue(status.ok)
        XCTAssertTrue(status.serviceActive)
        XCTAssertEqual(status.pid, ProcessInfo.processInfo.processIdentifier)
        XCTAssertEqual(status.dashboardPort, port)

        let settings = try await client.settings()
        XCTAssertEqual(settings.dashboardPort, port)
        XCTAssertEqual(settings.dashboardHost, "127.0.0.1")
    }

    func testPIDFileHelpers() throws {
        let paths = AppPaths(home: home)
        try paths.ensureLayout()
        try ManagerPIDFile.write(paths: paths)
        let pid = ManagerPIDFile.read(paths: paths)
        XCTAssertEqual(pid, ProcessInfo.processInfo.processIdentifier)
        XCTAssertEqual(ManagerPIDFile.runningPID(paths: paths), pid)
        ManagerPIDFile.remove(paths: paths)
        XCTAssertNil(ManagerPIDFile.runningPID(paths: paths))
    }

    func testNormalizeSettingsPatch() {
        let patch = ManagerNode.normalizeSettingsPatch([
            "dashboard": [
                "host": " 127.0.0.1 ",
                "port": "8899",
                "refresh_interval_sec": 1,
            ] as [String: Any],
            "manager": ["watchdog_interval_sec": 100] as [String: Any],
        ])
        let dash = patch["dashboard"] as? [String: Any]
        XCTAssertEqual(dash?["host"] as? String, "127.0.0.1")
        XCTAssertEqual(dash?["port"] as? Int, 8899)
        XCTAssertEqual(dash?["refresh_interval_sec"] as? Int, 2)
        let mgr = patch["manager"] as? [String: Any]
        XCTAssertEqual(mgr?["watchdog_interval_sec"] as? Int, 60)

        let rejected = ManagerNode.normalizeSettingsPatch([
            "dashboard": ["host": "0.0.0.0"] as [String: Any],
        ])
        XCTAssertNil((rejected["dashboard"] as? [String: Any])?["host"])
    }

    func testDashboardHTMLHasManagerControls() throws {
        XCTAssertTrue(DashboardHTML.index.contains("/api/manager/start"))
        XCTAssertTrue(DashboardHTML.index.contains("/api/manager/stop"))
        XCTAssertTrue(DashboardHTML.index.contains("/api/manager/restart"))
        XCTAssertTrue(DashboardHTML.index.contains("/api/manager/settings"))
        XCTAssertTrue(DashboardHTML.index.contains("Shutdown manager"))
    }

    func testInstallerBinaryPathAndAllowlist() throws {
        let app = try ForgeApp.bootstrap(home: home)
        let installer = ManagerInstaller(app: app)
        XCTAssertTrue(
            installer.installedBinaryURL.path.contains(".forge-conductor")
                || installer.installedBinaryURL.path.contains(home.lastPathComponent)
        )
        let report = installer.endpointProtectionReport()
        XCTAssertEqual(report["ok"] as? Bool, true)
        let allow = report["allowlist"] as? [String: Any]
        XCTAssertNotNil(allow?["crowdstrike_falcon"])
        XCTAssertNotNil(allow?["jamf_protect"])
        XCTAssertNotNil(allow?["macos_login_items"])
    }

    func testManagerArtifactStagingReplacesStaleBinaryFrameworkAndAppBundle() throws {
        let validator = TestManagerArtifactValidator()
        let fixture = try makeArtifactFixture(validator: validator)

        let stagedBinary = try fixture.installer.stageInstalledArtifacts(
            from: fixture.sourceExecutable
        )

        try assertCurrentArtifacts(fixture)
        XCTAssertEqual(stagedBinary, fixture.installer.installedBinaryURL)
        XCTAssertEqual(
            validator.operations,
            [
                .sign(.executable), .verify(.executable),
                .sign(.framework), .verify(.framework),
                .sign(.framework), .verify(.framework),
                .sign(.applicationBundle), .verify(.applicationBundle),
            ]
        )
        try assertNoTransactionArtifactsRemain()
    }

    func testManagerArtifactCopyFailurePreservesExistingInstallation() throws {
        let copier = TestManagerArtifactCopier(failingCopy: 4)
        let fixture = try makeArtifactFixture(
            validator: TestManagerArtifactValidator(),
            copier: copier
        )

        XCTAssertThrowsError(
            try fixture.installer.stageInstalledArtifacts(from: fixture.sourceExecutable)
        ) { error in
            XCTAssertTrue(error is ManagerArtifactFixtureError)
        }

        XCTAssertEqual(copier.copyCount, 4)
        try assertStaleArtifacts(fixture)
        try assertNoTransactionArtifactsRemain()
    }

    func testManagerArtifactSigningFailurePreservesExistingInstallation() throws {
        let validator = TestManagerArtifactValidator(failingOperation: .sign(.framework))
        let fixture = try makeArtifactFixture(validator: validator)

        XCTAssertThrowsError(
            try fixture.installer.stageInstalledArtifacts(from: fixture.sourceExecutable)
        ) { error in
            XCTAssertTrue(error is ManagerArtifactFixtureError)
        }

        XCTAssertEqual(
            validator.operations,
            [.sign(.executable), .verify(.executable), .sign(.framework)]
        )
        try assertStaleArtifacts(fixture)
        try assertNoTransactionArtifactsRemain()
    }

    func testManagerArtifactAppVerificationFailurePreservesExistingInstallation() throws {
        let validator = TestManagerArtifactValidator(
            failingOperation: .verify(.applicationBundle)
        )
        let fixture = try makeArtifactFixture(validator: validator)

        XCTAssertThrowsError(
            try fixture.installer.stageInstalledArtifacts(from: fixture.sourceExecutable)
        ) { error in
            XCTAssertTrue(error is ManagerArtifactFixtureError)
        }

        XCTAssertEqual(validator.operations.last, .verify(.applicationBundle))
        try assertStaleArtifacts(fixture)
        try assertNoTransactionArtifactsRemain()
    }

    func testManagerArtifactCommitFailureRollsBackEarlierReplacements() throws {
        let replacer = TestManagerArtifactReplacer(failingReplacement: 4)
        let fixture = try makeArtifactFixture(
            validator: TestManagerArtifactValidator(),
            replacer: replacer
        )

        XCTAssertThrowsError(
            try fixture.installer.stageInstalledArtifacts(from: fixture.sourceExecutable)
        ) { error in
            XCTAssertTrue(error is ManagerArtifactFixtureError)
        }

        XCTAssertEqual(replacer.replacementCount, 4)
        try assertStaleArtifacts(fixture)
        try assertNoTransactionArtifactsRemain()
    }

    func testManagerArtifactTransactionCommitsCommandLinkWithArtifacts() throws {
        let replacer = TestManagerArtifactReplacer()
        let fixture = try makeArtifactFixture(
            validator: TestManagerArtifactValidator(),
            replacer: replacer
        )
        let commandLink = home
            .appendingPathComponent(".local/bin", isDirectory: true)
            .appendingPathComponent("forge-conductor-swift")
        let priorTarget = home.appendingPathComponent("prior-success-target")
        try FileManager.default.createDirectory(
            at: commandLink.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "prior".write(to: priorTarget, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(
            at: commandLink,
            withDestinationURL: priorTarget
        )

        _ = try fixture.installer.stageInstalledArtifacts(
            from: fixture.sourceExecutable,
            commandLink: commandLink
        )

        XCTAssertEqual(replacer.replacementCount, 5)
        try assertCurrentArtifacts(fixture)
        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(atPath: commandLink.path),
            fixture.installer.installedBinaryURL.path
        )
        try assertNoTransactionArtifactsRemain()
    }

    func testManagerCommandLinkCommitFailureRollsBackEntireArtifactTransaction() throws {
        let replacer = TestManagerArtifactReplacer(failingReplacement: 5)
        let fixture = try makeArtifactFixture(
            validator: TestManagerArtifactValidator(),
            replacer: replacer
        )
        let commandDirectory = home.appendingPathComponent(".local/bin", isDirectory: true)
        let commandLink = commandDirectory.appendingPathComponent("forge-conductor-swift")
        let priorTarget = home.appendingPathComponent("prior-forge-conductor")
        try FileManager.default.createDirectory(
            at: commandDirectory,
            withIntermediateDirectories: true
        )
        try "prior".write(to: priorTarget, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(
            at: commandLink,
            withDestinationURL: priorTarget
        )

        XCTAssertThrowsError(
            try fixture.installer.stageInstalledArtifacts(
                from: fixture.sourceExecutable,
                commandLink: commandLink
            )
        ) { error in
            XCTAssertTrue(
                error is ManagerArtifactFixtureError,
                "unexpected link-commit error: \(error)"
            )
        }

        XCTAssertEqual(replacer.replacementCount, 5)
        try assertStaleArtifacts(fixture)
        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(atPath: commandLink.path),
            priorTarget.path
        )
        try assertNoTransactionArtifactsRemain()
    }

    func testProductionSignatureValidatorPreservesValidMachOAndAppMetadata() throws {
        let validator = CodesignManagerArtifactValidator()
        let executable = try makeAdHocMachOFixture(
            name: "valid-tool-\(UUID().uuidString)",
            identifier: "com.forge-conductor.tests.valid-tool"
        )
        let appFixture = try makeAdHocAppFixture(
            name: "ValidFixture-\(UUID().uuidString)",
            identifier: "com.forge-conductor.tests.valid-app"
        )
        let frameworkFixture = try makeAdHocFrameworkFixture(
            name: "ValidFramework-\(UUID().uuidString)",
            identifier: "com.forge-conductor.tests.valid-framework"
        )

        let executableBytes = try Data(contentsOf: executable)
        let executableBefore = try signatureMetadata(at: executable)
        let appBefore = try signatureMetadata(at: appFixture.bundle)
        let nestedBefore = try signatureMetadata(at: appFixture.nestedExecutable)
        let frameworkBefore = try signatureMetadata(at: frameworkFixture.bundle)
        let frameworkBinaryBefore = try signatureMetadata(at: frameworkFixture.executable)

        try validator.prepareAndSign(executable, kind: .executable)
        try validator.verify(executable, kind: .executable)
        try validator.prepareAndSign(appFixture.bundle, kind: .applicationBundle)
        try validator.verify(appFixture.bundle, kind: .applicationBundle)
        try validator.prepareAndSign(frameworkFixture.bundle, kind: .framework)
        try validator.verify(frameworkFixture.bundle, kind: .framework)

        XCTAssertEqual(try Data(contentsOf: executable), executableBytes)
        XCTAssertEqual(try signatureMetadata(at: executable), executableBefore)
        XCTAssertEqual(try signatureMetadata(at: appFixture.bundle), appBefore)
        XCTAssertEqual(
            try signatureMetadata(at: appFixture.nestedExecutable),
            nestedBefore
        )
        XCTAssertEqual(try signatureMetadata(at: frameworkFixture.bundle), frameworkBefore)
        XCTAssertEqual(
            try signatureMetadata(at: frameworkFixture.executable),
            frameworkBinaryBefore
        )
        XCTAssertTrue(executableBefore.flags.contains(.runtime))
        XCTAssertTrue(appBefore.flags.contains(.runtime))
        XCTAssertTrue(frameworkBefore.flags.contains(.runtime))
    }

    func testProductionSignatureValidatorRepairsUnsignedMachOWithStableRuntimeIdentity() throws {
        let validator = CodesignManagerArtifactValidator()
        let first = try makeUnsignedMachOFixture(name: ".unsigned-stage-\(UUID().uuidString)")
        let second = try makeUnsignedMachOFixture(name: ".unsigned-stage-\(UUID().uuidString)")

        try validator.prepareAndSign(first, kind: .executable)
        try validator.verify(first, kind: .executable)
        try validator.prepareAndSign(second, kind: .executable)
        try validator.verify(second, kind: .executable)

        let firstMetadata = try signatureMetadata(at: first)
        let secondMetadata = try signatureMetadata(at: second)
        XCTAssertEqual(firstMetadata.identifier, "com.forge-conductor.cli")
        XCTAssertEqual(secondMetadata.identifier, firstMetadata.identifier)
        XCTAssertTrue(firstMetadata.flags.contains(.adhoc))
        XCTAssertTrue(firstMetadata.flags.contains(.runtime))
        XCTAssertTrue(secondMetadata.flags.contains(.adhoc))
        XCTAssertTrue(secondMetadata.flags.contains(.runtime))
    }

    func testProductionSignatureValidatorRepairsInvalidAdHocAppWithoutChangingNestedIdentity() throws {
        let validator = CodesignManagerArtifactValidator()
        let entitlements = try makeTestEntitlements()
        let fixture = try makeAdHocAppFixture(
            name: "RepairFixture-\(UUID().uuidString)",
            identifier: "com.forge-conductor.tests.repair-app",
            entitlements: entitlements
        )
        let appBefore = try signatureMetadata(at: fixture.bundle)
        let nestedBefore = try signatureMetadata(at: fixture.nestedExecutable)
        try "changed after signing".write(
            to: fixture.resource,
            atomically: true,
            encoding: .utf8
        )

        let invalid = try SecurityManagerCodeSignatureInspector().inspect(
            fixture.bundle,
            kind: .applicationBundle
        )
        XCTAssertEqual(invalid.state, .invalidAdHoc)

        try validator.prepareAndSign(fixture.bundle, kind: .applicationBundle)
        try validator.verify(fixture.bundle, kind: .applicationBundle)

        let appAfter = try signatureMetadata(at: fixture.bundle)
        XCTAssertEqual(appAfter.identifier, appBefore.identifier)
        XCTAssertEqual(appAfter.entitlementsJSON, appBefore.entitlementsJSON)
        XCTAssertTrue(appAfter.flags.contains(.adhoc))
        XCTAssertTrue(appAfter.flags.contains(.runtime))
        XCTAssertEqual(
            try signatureMetadata(at: fixture.nestedExecutable),
            nestedBefore
        )
    }

    func testProductionSignatureValidatorRejectsInvalidCMSWithoutMutation() throws {
        let fixture = home.appendingPathComponent("invalid-cms-\(UUID().uuidString)")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: fixture)
        try invalidateMachOSlices(at: fixture)
        let before = try Data(contentsOf: fixture)
        let quarantine = Data("0081;fixture;ForgeConductorTests;".utf8)
        try setExtendedAttribute(
            named: "com.apple.quarantine",
            value: quarantine,
            at: fixture
        )
        XCTAssertEqual(
            try extendedAttribute(named: "com.apple.quarantine", at: fixture),
            quarantine
        )
        let inspection = try SecurityManagerCodeSignatureInspector().inspect(
            fixture,
            kind: .executable
        )
        XCTAssertEqual(inspection.state, .invalidCMS)

        XCTAssertThrowsError(
            try CodesignManagerArtifactValidator().prepareAndSign(
                fixture,
                kind: .executable
            )
        ) { error in
            XCTAssertTrue(error.localizedDescription.contains("invalid CMS/team signature"))
        }

        XCTAssertEqual(try Data(contentsOf: fixture), before)
        XCTAssertEqual(
            try extendedAttribute(named: "com.apple.quarantine", at: fixture),
            quarantine
        )
        XCTAssertEqual(
            try SecurityManagerCodeSignatureInspector()
                .inspect(fixture, kind: .executable).state,
            .invalidCMS
        )
    }

    func testSignatureInspectionErrorsAndAmbiguousMetadataFailClosed() throws {
        let fixture = try makeUnsignedMachOFixture(name: "fail-closed-\(UUID().uuidString)")
        let before = try Data(contentsOf: fixture)
        let ambiguous = TestManagerCodeSignatureInspector(
            inspection: ManagerArtifactSignatureInspection(
                state: .indeterminate,
                identifier: nil,
                validationStatus: errSecCSBadObjectFormat
            )
        )
        let validator = CodesignManagerArtifactValidator(signatureInspector: ambiguous)

        XCTAssertThrowsError(
            try validator.prepareAndSign(fixture, kind: .executable)
        ) { error in
            XCTAssertTrue(error.localizedDescription.contains("indeterminate signature metadata"))
        }
        XCTAssertEqual(try Data(contentsOf: fixture), before)
    }

    func testProductionSignatureValidatorPreservesValidTeamSignedAppWhenAvailable() throws {
        guard let source = try validTeamSignedAppFixture() else {
            throw XCTSkip("No valid local team-signed Forge app fixture is available")
        }
        let destination = home.appendingPathComponent("TeamFixture-\(UUID().uuidString).app")
        try FileManager.default.copyItem(at: source, to: destination)
        let before = try signatureMetadata(at: destination)
        guard let teamIdentifier = before.teamIdentifier, !teamIdentifier.isEmpty else {
            throw XCTSkip("The valid app fixture has no TeamIdentifier")
        }

        let validator = CodesignManagerArtifactValidator()
        try validator.prepareAndSign(destination, kind: .applicationBundle)
        try validator.verify(destination, kind: .applicationBundle)
        let after = try signatureMetadata(at: destination)

        XCTAssertEqual(after, before)
        XCTAssertEqual(after.teamIdentifier, teamIdentifier)
    }

    func testLaunchAgentLogRotationRetainsOnlyBoundedTailsInForgeHome() throws {
        let fm = FileManager.default
        let paths = AppPaths(home: home)
        try paths.ensureLayout()
        let installer = ManagerInstaller(paths: paths, config: ConfigStore(paths: paths))
        let output = installer.launchAgentStandardOutputURL
        let error = installer.launchAgentStandardErrorURL
        let output1 = URL(fileURLWithPath: "\(output.path).1")
        let output2 = URL(fileURLWithPath: "\(output.path).2")
        let error1 = URL(fileURLWithPath: "\(error.path).1")

        try "0123456789ABCDEFGHIJ".write(to: output, atomically: true, encoding: .utf8)
        try "error-current".write(to: error, atomically: true, encoding: .utf8)
        try "previous-output".write(to: output1, atomically: true, encoding: .utf8)
        try "discarded-oldest".write(to: output2, atomically: true, encoding: .utf8)

        try installer.rotateLaunchAgentLogs(maxBytesPerFile: 8, retainedGenerations: 2)

        XCTAssertFalse(fm.fileExists(atPath: output.path))
        XCTAssertFalse(fm.fileExists(atPath: error.path))
        XCTAssertEqual(try String(contentsOf: output1, encoding: .utf8), "CDEFGHIJ")
        XCTAssertEqual(try String(contentsOf: output2, encoding: .utf8), "s-output")
        XCTAssertEqual(try String(contentsOf: error1, encoding: .utf8), "-current")
        XCTAssertLessThanOrEqual(try Data(contentsOf: output1).count, 8)
        XCTAssertLessThanOrEqual(try Data(contentsOf: output2).count, 8)
        XCTAssertLessThanOrEqual(try Data(contentsOf: error1).count, 8)
    }

    func testLaunchAgentLogRotationBoundsAndPrunesArchivesWithoutCurrentContent() throws {
        let fm = FileManager.default
        let paths = AppPaths(home: home)
        try paths.ensureLayout()
        let installer = ManagerInstaller(paths: paths, config: ConfigStore(paths: paths))
        let output = installer.launchAgentStandardOutputURL
        let error = installer.launchAgentStandardErrorURL
        let output1 = URL(fileURLWithPath: "\(output.path).1")
        let output2 = URL(fileURLWithPath: "\(output.path).2")
        let output3 = URL(fileURLWithPath: "\(output.path).3")
        let output7 = URL(fileURLWithPath: "\(output.path).7")
        let error1 = URL(fileURLWithPath: "\(error.path).1")
        let error3 = URL(fileURLWithPath: "\(error.path).3")
        let previousOutput1 = "0123456789ABC"
        let previousOutput2 = "ABCDEFGHIJKL"
        let previousError1 = "error-archive-long"

        try previousOutput1.write(to: output1, atomically: true, encoding: .utf8)
        try previousOutput2.write(to: output2, atomically: true, encoding: .utf8)
        try "prune-three".write(to: output3, atomically: true, encoding: .utf8)
        try "prune-seven".write(to: output7, atomically: true, encoding: .utf8)
        try Data().write(to: error, options: .atomic)
        try previousError1.write(to: error1, atomically: true, encoding: .utf8)
        try "prune-error".write(to: error3, atomically: true, encoding: .utf8)

        try installer.rotateLaunchAgentLogs(maxBytesPerFile: 8, retainedGenerations: 2)

        XCTAssertFalse(fm.fileExists(atPath: output.path))
        XCTAssertFalse(fm.fileExists(atPath: error.path))
        XCTAssertEqual(
            try String(contentsOf: output1, encoding: .utf8),
            String(previousOutput1.suffix(8))
        )
        XCTAssertEqual(
            try String(contentsOf: output2, encoding: .utf8),
            String(previousOutput2.suffix(8))
        )
        XCTAssertEqual(
            try String(contentsOf: error1, encoding: .utf8),
            String(previousError1.suffix(8))
        )
        XCTAssertFalse(fm.fileExists(atPath: output3.path))
        XCTAssertFalse(fm.fileExists(atPath: output7.path))
        XCTAssertFalse(fm.fileExists(atPath: error3.path))
    }

    private struct SignatureMetadata: Equatable {
        var identifier: String?
        var teamIdentifier: String?
        var flags: SecCodeSignatureFlags
        var uniqueHash: Data?
        var entitlementsJSON: Data?
    }

    private struct AppSignatureFixture {
        var bundle: URL
        var executable: URL
        var nestedExecutable: URL
        var resource: URL
    }

    private struct FrameworkSignatureFixture {
        var bundle: URL
        var executable: URL
    }

    private func makeAdHocMachOFixture(name: String, identifier: String) throws -> URL {
        let destination = home.appendingPathComponent(name)
        try FileManager.default.copyItem(at: testHostExecutable(), to: destination)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: destination.path
        )
        try clearExtendedAttributes(at: destination)
        try signAdHoc(destination, identifier: identifier)
        return destination
    }

    private func makeUnsignedMachOFixture(name: String) throws -> URL {
        let destination = home.appendingPathComponent(name)
        try FileManager.default.copyItem(at: testHostExecutable(), to: destination)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: destination.path
        )
        try runRequired(
            executable: "/usr/bin/codesign",
            arguments: ["--remove-signature", destination.path]
        )
        let inspection = try SecurityManagerCodeSignatureInspector().inspect(
            destination,
            kind: .executable
        )
        XCTAssertEqual(inspection.state, .unsigned)
        return destination
    }

    private func makeAdHocAppFixture(
        name: String,
        identifier: String,
        entitlements: URL? = nil
    ) throws -> AppSignatureFixture {
        let bundle = home.appendingPathComponent("\(name).app", isDirectory: true)
        let contents = bundle.appendingPathComponent("Contents", isDirectory: true)
        let macOS = contents.appendingPathComponent("MacOS", isDirectory: true)
        let helpers = contents.appendingPathComponent("Helpers", isDirectory: true)
        let resources = contents.appendingPathComponent("Resources", isDirectory: true)
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: helpers, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)

        let executableName = "FixtureExecutable"
        let executable = macOS.appendingPathComponent(executableName)
        try FileManager.default.copyItem(at: testHostExecutable(), to: executable)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executable.path
        )
        try clearExtendedAttributes(at: executable)
        try signAdHoc(executable, identifier: "\(identifier).executable")
        let nestedExecutable = helpers.appendingPathComponent("FixtureHelper")
        try FileManager.default.copyItem(at: testHostExecutable(), to: nestedExecutable)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: nestedExecutable.path
        )
        try clearExtendedAttributes(at: nestedExecutable)
        try signAdHoc(nestedExecutable, identifier: "\(identifier).helper")

        let info: [String: Any] = [
            "CFBundleExecutable": executableName,
            "CFBundleIdentifier": identifier,
            "CFBundleInfoDictionaryVersion": "6.0",
            "CFBundleName": name,
            "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": "1.0",
            "CFBundleVersion": "1",
        ]
        let infoData = try PropertyListSerialization.data(
            fromPropertyList: info,
            format: .xml,
            options: 0
        )
        try infoData.write(to: contents.appendingPathComponent("Info.plist"), options: .atomic)
        let resource = resources.appendingPathComponent("payload.txt")
        try "original".write(to: resource, atomically: true, encoding: .utf8)

        try clearExtendedAttributes(at: bundle)
        try signAdHoc(bundle, identifier: identifier, entitlements: entitlements)
        return AppSignatureFixture(
            bundle: bundle,
            executable: executable,
            nestedExecutable: nestedExecutable,
            resource: resource
        )
    }

    private func makeAdHocFrameworkFixture(
        name: String,
        identifier: String
    ) throws -> FrameworkSignatureFixture {
        let frameworkName = name.replacingOccurrences(of: ".framework", with: "")
        let bundle = home.appendingPathComponent("\(frameworkName).framework", isDirectory: true)
        let versions = bundle.appendingPathComponent("Versions", isDirectory: true)
        let versionA = versions.appendingPathComponent("A", isDirectory: true)
        let resources = versionA.appendingPathComponent("Resources", isDirectory: true)
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)

        let executable = versionA.appendingPathComponent(frameworkName)
        try FileManager.default.copyItem(at: testHostExecutable(), to: executable)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executable.path
        )
        try clearExtendedAttributes(at: executable)
        try signAdHoc(executable, identifier: "\(identifier).binary")

        let info: [String: Any] = [
            "CFBundleExecutable": frameworkName,
            "CFBundleIdentifier": identifier,
            "CFBundleInfoDictionaryVersion": "6.0",
            "CFBundleName": frameworkName,
            "CFBundlePackageType": "FMWK",
            "CFBundleShortVersionString": "1.0",
            "CFBundleVersion": "1",
        ]
        let infoData = try PropertyListSerialization.data(
            fromPropertyList: info,
            format: .xml,
            options: 0
        )
        try infoData.write(to: resources.appendingPathComponent("Info.plist"), options: .atomic)
        try FileManager.default.createSymbolicLink(
            atPath: versions.appendingPathComponent("Current").path,
            withDestinationPath: "A"
        )
        try FileManager.default.createSymbolicLink(
            atPath: bundle.appendingPathComponent(frameworkName).path,
            withDestinationPath: "Versions/Current/\(frameworkName)"
        )
        try FileManager.default.createSymbolicLink(
            atPath: bundle.appendingPathComponent("Resources").path,
            withDestinationPath: "Versions/Current/Resources"
        )

        try clearExtendedAttributes(at: bundle)
        try signAdHoc(bundle, identifier: identifier)
        return FrameworkSignatureFixture(bundle: bundle, executable: executable)
    }

    private func makeTestEntitlements() throws -> URL {
        let url = home.appendingPathComponent("fixture-entitlements-\(UUID().uuidString).plist")
        let data = try PropertyListSerialization.data(
            fromPropertyList: ["com.apple.security.get-task-allow": true],
            format: .xml,
            options: 0
        )
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path
        )
        return url
    }

    private func signAdHoc(
        _ url: URL,
        identifier: String,
        entitlements: URL? = nil
    ) throws {
        var arguments = [
            "--force",
            "--sign", "-",
            "--timestamp=none",
            "--options", "runtime",
            "--identifier", identifier,
        ]
        if let entitlements {
            arguments.append(contentsOf: ["--entitlements", entitlements.path])
        }
        arguments.append(url.path)
        try runRequired(executable: "/usr/bin/codesign", arguments: arguments)
    }

    private func clearExtendedAttributes(at url: URL) throws {
        try runRequired(
            executable: "/usr/bin/xattr",
            arguments: ["-cr", url.path]
        )
    }

    private func setExtendedAttribute(
        named name: String,
        value: Data,
        at url: URL
    ) throws {
        let result = value.withUnsafeBytes { bytes in
            setxattr(
                url.path,
                name,
                bytes.baseAddress,
                bytes.count,
                0,
                0
            )
        }
        guard result == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    private func extendedAttribute(named name: String, at url: URL) throws -> Data? {
        errno = 0
        let size = getxattr(url.path, name, nil, 0, 0, 0)
        if size < 0 {
            if errno == ENOATTR {
                return nil
            }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }

        var value = Data(count: size)
        let bytesRead = value.withUnsafeMutableBytes { bytes in
            getxattr(
                url.path,
                name,
                bytes.baseAddress,
                bytes.count,
                0,
                0
            )
        }
        guard bytesRead == size else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return value
    }

    private func runRequired(executable: String, arguments: [String]) throws {
        let result: ProcessResult
        do {
            result = try ProcessRunner().run(
                executable: executable,
                arguments: arguments,
                timeoutSec: 60
            )
        } catch {
            throw NSError(
                domain: "ManagerTests",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey:
                    "\(executable) \(arguments.joined(separator: " ")) threw: \(error)"]
            )
        }
        guard result.exitCode == 0, !result.timedOut else {
            throw NSError(
                domain: "ManagerTests",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey:
                    "\(executable) \(arguments.joined(separator: " ")) failed "
                    + "(exit \(result.exitCode)): \(result.stderr)"]
            )
        }
    }

    private func testHostExecutable() throws -> URL {
        let url = URL(fileURLWithPath: "/usr/bin/true").resolvingSymlinksInPath()
        guard FileManager.default.isExecutableFile(atPath: url.path) else {
            throw NSError(
                domain: "ManagerTests",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey:
                    "Mach-O fixture source is not executable: \(url.path)"]
            )
        }
        return url
    }

    private func signatureMetadata(at url: URL) throws -> SignatureMetadata {
        var staticCode: SecStaticCode?
        let createStatus = SecStaticCodeCreateWithPath(url.standardizedFileURL as CFURL, [], &staticCode)
        guard createStatus == errSecSuccess, let staticCode else {
            throw NSError(
                domain: "ManagerTests",
                code: Int(createStatus),
                userInfo: [NSLocalizedDescriptionKey:
                    "SecStaticCodeCreateWithPath failed for \(url.path): \(createStatus)"]
            )
        }

        var rawInformation: CFDictionary?
        let infoStatus = SecCodeCopySigningInformation(
            staticCode,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &rawInformation
        )
        guard infoStatus == errSecSuccess,
              let information = rawInformation as? [CFString: Any],
              let flagsNumber = information[kSecCodeInfoFlags] as? NSNumber else {
            throw NSError(
                domain: "ManagerTests",
                code: Int(infoStatus),
                userInfo: [NSLocalizedDescriptionKey:
                    "SecCodeCopySigningInformation failed for \(url.path): \(infoStatus)"]
            )
        }

        let entitlementsJSON: Data?
        if let entitlements = information[kSecCodeInfoEntitlementsDict] as? [String: Any],
           JSONSerialization.isValidJSONObject(entitlements) {
            entitlementsJSON = try JSONSerialization.data(
                withJSONObject: entitlements,
                options: [.sortedKeys]
            )
        } else {
            entitlementsJSON = nil
        }

        return SignatureMetadata(
            identifier: information[kSecCodeInfoIdentifier] as? String,
            teamIdentifier: information[kSecCodeInfoTeamIdentifier] as? String,
            flags: SecCodeSignatureFlags(rawValue: flagsNumber.uint32Value),
            uniqueHash: information[kSecCodeInfoUnique] as? Data,
            entitlementsJSON: entitlementsJSON
        )
    }

    private func invalidateMachOSlices(at url: URL) throws {
        var data = try Data(contentsOf: url)

        func bigEndianUInt32(at offset: Int) throws -> UInt32 {
            guard offset >= 0, offset + 4 <= data.count else {
                throw NSError(
                    domain: "ManagerTests",
                    code: 3,
                    userInfo: [NSLocalizedDescriptionKey: "Malformed Mach-O fixture"]
                )
            }
            return data[offset..<(offset + 4)].reduce(UInt32(0)) {
                ($0 << 8) | UInt32($1)
            }
        }

        let magic = try bigEndianUInt32(at: 0)
        var sliceOffsets: [Int] = []
        switch magic {
        case 0xCAFEBABE:
            let count = Int(try bigEndianUInt32(at: 4))
            for index in 0..<count {
                let entry = 8 + index * 20
                sliceOffsets.append(Int(try bigEndianUInt32(at: entry + 8)))
            }
        case 0xCAFEBABF:
            let count = Int(try bigEndianUInt32(at: 4))
            for index in 0..<count {
                let entry = 8 + index * 32
                let high = UInt64(try bigEndianUInt32(at: entry + 8))
                let low = UInt64(try bigEndianUInt32(at: entry + 12))
                sliceOffsets.append(Int((high << 32) | low))
            }
        default:
            sliceOffsets = [0]
        }

        for sliceOffset in sliceOffsets {
            let mutationOffset = sliceOffset + 1_024
            guard mutationOffset < data.count else {
                throw NSError(
                    domain: "ManagerTests",
                    code: 4,
                    userInfo: [NSLocalizedDescriptionKey:
                        "Mach-O fixture is too small to invalidate safely"]
                )
            }
            data[mutationOffset] ^= 0x01
        }
        try data.write(to: url)
    }

    private func validTeamSignedAppFixture() throws -> URL? {
        var candidates: [URL] = []
        if let configured = ProcessInfo.processInfo.environment["FORGE_TEST_TEAM_SIGNED_APP"],
           !configured.isEmpty {
            candidates.append(URL(fileURLWithPath: configured, isDirectory: true))
        }
        candidates.append(
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent(
                    ".build/xcode/Build/Products/Debug/Forge Conductor.app",
                    isDirectory: true
                )
        )
        candidates.append(
            URL(fileURLWithPath: "/Applications/Forge Conductor.app", isDirectory: true)
        )

        let inspector = SecurityManagerCodeSignatureInspector()
        for candidate in candidates where FileManager.default.fileExists(atPath: candidate.path) {
            guard let metadata = try? signatureMetadata(at: candidate),
                  let teamIdentifier = metadata.teamIdentifier,
                  !teamIdentifier.isEmpty,
                  let inspection = try? inspector.inspect(candidate, kind: .applicationBundle),
                  inspection.state == .valid else {
                continue
            }
            return candidate
        }
        return nil
    }

    private struct ArtifactFixture {
        let installer: ManagerInstaller
        let sourceExecutable: URL
        let installedFramework: URL
        let mirroredFramework: URL
    }

    private func makeArtifactFixture(
        validator: any ManagerArtifactValidating,
        copier: any ManagerArtifactCopying = TestManagerArtifactCopier(),
        replacer: any ManagerArtifactReplacing = TestManagerArtifactReplacer()
    ) throws -> ArtifactFixture {
        let fm = FileManager.default
        let paths = AppPaths(home: home)
        try paths.ensureLayout()
        let installer = ManagerInstaller(
            paths: paths,
            config: ConfigStore(paths: paths),
            artifactValidator: validator,
            artifactCopier: copier,
            artifactReplacer: replacer
        )

        let sourceBundle = home
            .appendingPathComponent("current", isDirectory: true)
            .appendingPathComponent("\(ManagerInstaller.appDisplayName).app", isDirectory: true)
        let sourceContents = sourceBundle.appendingPathComponent("Contents", isDirectory: true)
        let sourceMacOS = sourceContents.appendingPathComponent("MacOS", isDirectory: true)
        let sourceResources = sourceContents.appendingPathComponent("Resources", isDirectory: true)
        let sourceFramework = sourceContents
            .appendingPathComponent("Frameworks", isDirectory: true)
            .appendingPathComponent("ForgeConductorCore.framework", isDirectory: true)
        try fm.createDirectory(at: sourceMacOS, withIntermediateDirectories: true)
        try fm.createDirectory(at: sourceResources, withIntermediateDirectories: true)
        try fm.createDirectory(at: sourceFramework, withIntermediateDirectories: true)

        let sourceExecutable = sourceMacOS.appendingPathComponent(ManagerInstaller.appDisplayName)
        try "#!/bin/sh\necho current\n".write(
            to: sourceExecutable,
            atomically: true,
            encoding: .utf8
        )
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: sourceExecutable.path)
        try "current-framework".write(
            to: sourceFramework.appendingPathComponent("revision.txt"),
            atomically: true,
            encoding: .utf8
        )
        try "current-resource".write(
            to: sourceResources.appendingPathComponent("revision.txt"),
            atomically: true,
            encoding: .utf8
        )
        try "<plist version=\"1.0\"><dict/></plist>".write(
            to: sourceContents.appendingPathComponent("Info.plist"),
            atomically: true,
            encoding: .utf8
        )

        let installedFramework = installer.installedBinaryURL.deletingLastPathComponent()
            .appendingPathComponent("ForgeConductorCore.framework", isDirectory: true)
        let mirroredFramework = home
            .appendingPathComponent("lib", isDirectory: true)
            .appendingPathComponent("ForgeConductorCore.framework", isDirectory: true)
        let staleAppMacOS = installer.appBundleURL
            .appendingPathComponent("Contents/MacOS", isDirectory: true)
        let staleAppResources = installer.appBundleURL
            .appendingPathComponent("Contents/Resources", isDirectory: true)
        try fm.createDirectory(
            at: installer.installedBinaryURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try fm.createDirectory(at: installedFramework, withIntermediateDirectories: true)
        try fm.createDirectory(at: mirroredFramework, withIntermediateDirectories: true)
        try fm.createDirectory(at: staleAppMacOS, withIntermediateDirectories: true)
        try fm.createDirectory(at: staleAppResources, withIntermediateDirectories: true)
        try "stale-binary".write(
            to: installer.installedBinaryURL,
            atomically: true,
            encoding: .utf8
        )
        try "stale-framework".write(
            to: installedFramework.appendingPathComponent("stale.txt"),
            atomically: true,
            encoding: .utf8
        )
        try "stale-framework".write(
            to: mirroredFramework.appendingPathComponent("stale.txt"),
            atomically: true,
            encoding: .utf8
        )
        try "stale-app".write(
            to: staleAppMacOS.appendingPathComponent(ManagerInstaller.appDisplayName),
            atomically: true,
            encoding: .utf8
        )
        try "stale-resource".write(
            to: staleAppResources.appendingPathComponent("stale.txt"),
            atomically: true,
            encoding: .utf8
        )

        return ArtifactFixture(
            installer: installer,
            sourceExecutable: sourceExecutable,
            installedFramework: installedFramework,
            mirroredFramework: mirroredFramework
        )
    }

    private func assertCurrentArtifacts(
        _ fixture: ArtifactFixture,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let fm = FileManager.default
        XCTAssertEqual(
            try String(contentsOf: fixture.installer.installedBinaryURL, encoding: .utf8),
            "#!/bin/sh\necho current\n",
            file: file,
            line: line
        )
        XCTAssertEqual(
            try String(
                contentsOf: fixture.installedFramework.appendingPathComponent("revision.txt"),
                encoding: .utf8
            ),
            "current-framework",
            file: file,
            line: line
        )
        XCTAssertEqual(
            try String(
                contentsOf: fixture.mirroredFramework.appendingPathComponent("revision.txt"),
                encoding: .utf8
            ),
            "current-framework",
            file: file,
            line: line
        )
        XCTAssertEqual(
            try String(contentsOf: fixture.installer.appExecutableURL, encoding: .utf8),
            "#!/bin/sh\necho current\n",
            file: file,
            line: line
        )
        XCTAssertEqual(
            try String(
                contentsOf: fixture.installer.appBundleURL
                    .appendingPathComponent("Contents/Frameworks/ForgeConductorCore.framework/revision.txt"),
                encoding: .utf8
            ),
            "current-framework",
            file: file,
            line: line
        )
        XCTAssertEqual(
            try String(
                contentsOf: fixture.installer.appBundleURL
                    .appendingPathComponent("Contents/Resources/revision.txt"),
                encoding: .utf8
            ),
            "current-resource",
            file: file,
            line: line
        )
        XCTAssertFalse(
            fm.fileExists(atPath: fixture.installedFramework.appendingPathComponent("stale.txt").path),
            file: file,
            line: line
        )
        XCTAssertFalse(
            fm.fileExists(atPath: fixture.mirroredFramework.appendingPathComponent("stale.txt").path),
            file: file,
            line: line
        )
    }

    private func assertStaleArtifacts(
        _ fixture: ArtifactFixture,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        XCTAssertEqual(
            try String(contentsOf: fixture.installer.installedBinaryURL, encoding: .utf8),
            "stale-binary",
            file: file,
            line: line
        )
        XCTAssertEqual(
            try String(
                contentsOf: fixture.installedFramework.appendingPathComponent("stale.txt"),
                encoding: .utf8
            ),
            "stale-framework",
            file: file,
            line: line
        )
        XCTAssertEqual(
            try String(
                contentsOf: fixture.mirroredFramework.appendingPathComponent("stale.txt"),
                encoding: .utf8
            ),
            "stale-framework",
            file: file,
            line: line
        )
        XCTAssertEqual(
            try String(contentsOf: fixture.installer.appExecutableURL, encoding: .utf8),
            "stale-app",
            file: file,
            line: line
        )
        XCTAssertEqual(
            try String(
                contentsOf: fixture.installer.appBundleURL
                    .appendingPathComponent("Contents/Resources/stale.txt"),
                encoding: .utf8
            ),
            "stale-resource",
            file: file,
            line: line
        )
    }

    private func assertNoTransactionArtifactsRemain(
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let fm = FileManager.default
        let enumerator = fm.enumerator(
            at: home,
            includingPropertiesForKeys: nil,
            options: []
        )
        let leftovers = (enumerator?.allObjects as? [URL] ?? []).filter {
            $0.lastPathComponent.contains(".stage-")
                || $0.lastPathComponent.contains(".backup-")
        }
        XCTAssertTrue(
            leftovers.isEmpty,
            "transaction artifacts remain: \(leftovers.map(\.path))",
            file: file,
            line: line
        )
    }
}
