// ProcessRunnerTests.swift
// Verifies bounded subprocess completion, timeout escalation, and output capture.

import Darwin
import XCTest
@testable import ForgeConductorCore

final class ProcessRunnerTests: XCTestCase {
    private func fastRunner() -> ProcessRunner {
        ProcessRunner(terminationGraceSec: 0.05, forcedTerminationGraceSec: 0.5)
    }

    func testNormalAndNonzeroExitStatuses() throws {
        let runner = fastRunner()

        let success = try runner.run(executable: "/usr/bin/true", timeoutSec: 1)
        XCTAssertEqual(success.exitCode, 0)
        XCTAssertFalse(success.timedOut)

        let failure = try runner.run(executable: "/usr/bin/false", timeoutSec: 1)
        XCTAssertEqual(failure.exitCode, 1)
        XCTAssertFalse(failure.timedOut)
    }

    func testLaunchFailureDoesNotPoisonTheNextRun() throws {
        let runner = fastRunner()

        XCTAssertThrowsError(
            try runner.run(executable: "/forge-conductor-tests/missing-executable")
        )

        let recovery = try runner.run(executable: "/usr/bin/true", timeoutSec: 1)
        XCTAssertEqual(recovery.exitCode, 0)
        XCTAssertFalse(recovery.timedOut)
    }

    func testTimeoutTerminatesChildAndReturnsConfirmedStatus() throws {
        let started = ContinuousClock.now
        let result = try fastRunner().run(
            executable: "/bin/sleep",
            arguments: ["5"],
            timeoutSec: 0.02
        )

        XCTAssertTrue(result.timedOut)
        XCTAssertNotEqual(result.exitCode, 0)
        XCTAssertLessThan(started.duration(to: .now), .seconds(1))
    }

    func testTermIgnoringChildRequiresSIGKILL() throws {
        let result = try fastRunner().run(
            executable: "/bin/sh",
            arguments: ["-c", "trap '' TERM; printf 'ready\\n'; while :; do :; done"],
            timeoutSec: 0.25
        )

        XCTAssertTrue(result.timedOut)
        XCTAssertEqual(result.exitCode, SIGKILL)
        XCTAssertEqual(result.stdout, "ready\n")
    }

    func testOutputIsCapturedConcurrentlyAndTruncatedPerStream() throws {
        let result = try fastRunner().run(
            executable: "/bin/sh",
            arguments: [
                "-c",
                "printf '%010240d' 0; printf '%010240d' 0 >&2",
            ],
            timeoutSec: 2,
            maximumOutputBytes: 256
        )

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertFalse(result.timedOut)
        XCTAssertEqual(result.stdout.utf8.count, 256)
        XCTAssertEqual(result.stderr.utf8.count, 256)
        XCTAssertTrue(result.stdoutTruncated)
        XCTAssertTrue(result.stderrTruncated)
    }

    func testDirectChildExitDoesNotWaitForDescendantPipeEOF() throws {
        let started = ContinuousClock.now
        let result = try fastRunner().run(
            executable: "/bin/sh",
            arguments: ["-c", "/bin/sleep 3 & printf '%d\\n' $!"],
            timeoutSec: 1
        )
        let elapsed = started.duration(to: .now)

        if elapsed < .seconds(2),
           let descendantPID = Int32(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) {
            _ = kill(descendantPID, SIGKILL)
        }

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertFalse(result.timedOut)
        XCTAssertLessThan(elapsed, .seconds(1))
        XCTAssertNotNil(Int32(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)))
    }

    func testMalformedAndCapSplitUTF8PreserveReadableOutput() throws {
        let malformed = try fastRunner().run(
            executable: "/usr/bin/printf",
            arguments: ["valid-prefix\\377suffix"],
            timeoutSec: 1
        )
        XCTAssertEqual(malformed.stdout, "valid-prefix\u{FFFD}suffix")
        XCTAssertFalse(malformed.stdoutTruncated)

        let capSplit = try fastRunner().run(
            executable: "/usr/bin/printf",
            arguments: ["A\\342\\202\\254"],
            timeoutSec: 1,
            maximumOutputBytes: 3
        )
        XCTAssertEqual(capSplit.stdout, "A\u{FFFD}")
        XCTAssertTrue(capSplit.stdoutTruncated)
    }

    func testParallelRunsRemainBoundedAndIndependent() {
        let runner = fastRunner()
        let failures = FailureBox()

        DispatchQueue.concurrentPerform(iterations: 12) { index in
            do {
                if index.isMultiple(of: 2) {
                    let result = try runner.run(executable: "/usr/bin/true", timeoutSec: 1)
                    if result.exitCode != 0 || result.timedOut {
                        failures.append("normal \(index): \(result.exitCode), timeout=\(result.timedOut)")
                    }
                } else {
                    let result = try runner.run(
                        executable: "/bin/sleep",
                        arguments: ["2"],
                        timeoutSec: 0.02
                    )
                    if !result.timedOut || result.exitCode == 0 {
                        failures.append("timeout \(index): \(result.exitCode), timeout=\(result.timedOut)")
                    }
                }
            } catch {
                failures.append("run \(index) threw \(error)")
            }
        }

        XCTAssertEqual(failures.values, [])
    }

    func testRapidExitNotificationsAreNotLostUnderLoad() {
        let runner = fastRunner()
        let failures = FailureBox()
        let started = ContinuousClock.now

        DispatchQueue.concurrentPerform(iterations: 48) { index in
            do {
                let result = try runner.run(executable: "/usr/bin/true", timeoutSec: 1)
                if result.exitCode != 0 || result.timedOut {
                    failures.append(
                        "rapid \(index): \(result.exitCode), timeout=\(result.timedOut)"
                    )
                }
            } catch {
                failures.append("rapid \(index) threw \(error)")
            }
        }

        XCTAssertEqual(failures.values, [])
        XCTAssertLessThan(started.duration(to: .now), .seconds(5))
    }
}

private final class FailureBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    var values: [String] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func append(_ value: String) {
        lock.lock()
        storage.append(value)
        lock.unlock()
    }
}
