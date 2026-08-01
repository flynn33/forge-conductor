// ProcessRunner.swift
// What: Provides the bounded native subprocess adapter used by connector modules.
// How: Foundation.Process is wrapped with explicit environment, working directory,
// timeout, termination, and capped stdout/stderr collection behavior.
// Why: Every module must share the same resource and failure semantics for child processes.

import Foundation
import Darwin

/// Describes a completed subprocess, including timeout and output-cap evidence.
///
/// Truncation flags let callers distinguish complete diagnostics from output that was
/// intentionally bounded to protect the long-running host process.
public struct ProcessResult: Sendable {
    public var exitCode: Int32
    public var stdout: String
    public var stderr: String
    public var timedOut: Bool
    public var stdoutTruncated: Bool
    public var stderrTruncated: Bool
}

/// Failures that are specific to subprocess lifecycle management.
public enum ProcessRunnerError: Error, Equatable, Sendable, LocalizedError {
    /// TERM and KILL were requested, but process termination was not observed before
    /// the final bounded wait expired. No termination status is available in this state.
    case terminationUnconfirmed(processIdentifier: Int32, signalError: Int32?)

    public var errorDescription: String? {
        switch self {
        case let .terminationUnconfirmed(pid, signalError):
            if let signalError {
                return "process \(pid) did not confirm termination; SIGKILL failed with errno \(signalError)"
            }
            return "process \(pid) did not confirm termination after SIGKILL"
        }
    }
}

/// Runs allowlisted processes with timeout (no shell injection — argv array).
///
/// Reads stdout/stderr concurrently so large or chatty children cannot deadlock
/// on full pipe buffers (common with Node diagnostics on stderr).
public final class ProcessRunner: @unchecked Sendable {
    private let terminationGraceSec: TimeInterval
    private let forcedTerminationGraceSec: TimeInterval

    public init() {
        terminationGraceSec = 0.5
        forcedTerminationGraceSec = 1.0
    }

    /// Internal timing seam keeps timeout-path tests fast without changing production bounds.
    init(terminationGraceSec: TimeInterval, forcedTerminationGraceSec: TimeInterval) {
        self.terminationGraceSec = max(0, terminationGraceSec)
        self.forcedTerminationGraceSec = max(0, forcedTerminationGraceSec)
    }

    public func run(
        executable: String,
        arguments: [String] = [],
        currentDirectory: String? = nil,
        environment: [String: String]? = nil,
        timeoutSec: TimeInterval = 30,
        maximumOutputBytes: Int = 1_048_576
    ) throws -> ProcessResult {
        let process = Process()
        let exeURL: URL
        if executable.hasPrefix("/") {
            exeURL = URL(fileURLWithPath: executable)
        } else if let path = ProcessRunner.which(executable) {
            exeURL = URL(fileURLWithPath: path)
        } else {
            throw NSError(
                domain: "ProcessRunner",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "executable not found: \(executable)"]
            )
        }
        process.executableURL = exeURL
        process.arguments = arguments
        if let currentDirectory {
            process.currentDirectoryURL = URL(fileURLWithPath: currentDirectory)
        }
        if let environment {
            var env = ProcessInfo.processInfo.environment
            for (k, v) in environment { env[k] = v }
            process.environment = env
        }

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.standardInput = FileHandle.nullDevice

        final class BufferBox: @unchecked Sendable {
            let condition = NSCondition()
            var data = Data()
            var truncated = false
            let limit: Int
            var acceptsCallbacks = true
            var activeCallbacks = 0

            init(limit: Int) {
                self.limit = max(0, limit)
            }

            func append(_ chunk: Data) {
                condition.lock()
                defer { condition.unlock() }
                appendLocked(chunk)
            }

            func consumeAvailableData(from handle: FileHandle) {
                condition.lock()
                guard acceptsCallbacks else {
                    condition.unlock()
                    return
                }
                activeCallbacks += 1
                condition.unlock()

                let chunk = handle.availableData

                condition.lock()
                if !chunk.isEmpty {
                    appendLocked(chunk)
                }
                activeCallbacks -= 1
                if activeCallbacks == 0 {
                    condition.broadcast()
                }
                condition.unlock()
            }

            /// Prevents new callbacks and waits for an already-running callback to finish.
            /// This must happen before a native nonblocking remainder drain.
            func stopCallbacks(on handle: FileHandle) {
                condition.lock()
                let shouldClearHandler = acceptsCallbacks
                acceptsCallbacks = false
                condition.unlock()

                if shouldClearHandler {
                    handle.readabilityHandler = nil
                }

                condition.lock()
                while activeCallbacks > 0 {
                    condition.wait()
                }
                condition.unlock()
            }

            func take() -> (data: Data, truncated: Bool) {
                condition.lock()
                defer { condition.unlock() }
                return (data, truncated)
            }

            /// Drains bytes that are already readable without waiting for every inherited
            /// writer to close. A descendant can retain a pipe after the direct child exits,
            /// so an EOF-based read would make the caller's timeout unbounded.
            func drainCurrentlyAvailableData(from handle: FileHandle) {
                let descriptor = handle.fileDescriptor
                let originalFlags = fcntl(descriptor, F_GETFL)
                guard originalFlags >= 0 else {
                    markTruncated()
                    return
                }

                let changedFlags = originalFlags & O_NONBLOCK == 0
                if changedFlags, fcntl(descriptor, F_SETFL, originalFlags | O_NONBLOCK) < 0 {
                    markTruncated()
                    return
                }
                defer {
                    if changedFlags {
                        _ = fcntl(descriptor, F_SETFL, originalFlags)
                    }
                }

                var buffer = [UInt8](repeating: 0, count: 16_384)
                var interruptedReads = 0
                while shouldContinueNativeDrain() {
                    let count = buffer.withUnsafeMutableBytes { bytes in
                        Darwin.read(descriptor, bytes.baseAddress, bytes.count)
                    }
                    if count > 0 {
                        interruptedReads = 0
                        append(Data(buffer.prefix(count)))
                        continue
                    }
                    if count == 0 {
                        return
                    }

                    let readError = errno
                    if readError == EINTR {
                        interruptedReads += 1
                        if interruptedReads < 8 {
                            continue
                        }
                        markTruncated()
                    } else if readError != EAGAIN && readError != EWOULDBLOCK {
                        markTruncated()
                    }
                    return
                }
            }

            private func appendLocked(_ chunk: Data) {
                let remaining = max(0, limit - data.count)
                if remaining > 0 { data.append(chunk.prefix(remaining)) }
                if chunk.count > remaining { truncated = true }
            }

            private func shouldContinueNativeDrain() -> Bool {
                condition.lock()
                defer { condition.unlock() }
                return !truncated
            }

            private func markTruncated() {
                condition.lock()
                truncated = true
                condition.unlock()
            }
        }

        final class TerminationBox: @unchecked Sendable {
            private let lock = NSLock()
            private var completed = false
            private var status: Int32?

            /// Records the first terminal outcome. The return value identifies the
            /// caller responsible for balancing the termination dispatch group.
            func complete(status: Int32?) -> Bool {
                lock.lock()
                defer { lock.unlock() }
                guard !completed else { return false }
                completed = true
                self.status = status
                return true
            }

            func load() -> Int32? {
                lock.lock()
                defer { lock.unlock() }
                return status
            }
        }
        let outBox = BufferBox(limit: maximumOutputBytes)
        let errBox = BufferBox(limit: maximumOutputBytes)
        let outHandle = outPipe.fileHandleForReading
        let errHandle = errPipe.fileHandleForReading

        outHandle.readabilityHandler = { handle in
            outBox.consumeAvailableData(from: handle)
        }
        errHandle.readabilityHandler = { handle in
            errBox.consumeAvailableData(from: handle)
        }
        defer {
            outBox.stopCallbacks(on: outHandle)
            errBox.stopCallbacks(on: errHandle)
        }

        let terminationGroup = DispatchGroup()
        let terminationBox = TerminationBox()
        var timedOut = false
        terminationGroup.enter()
        process.terminationHandler = { terminatedProcess in
            if terminationBox.complete(status: terminatedProcess.terminationStatus) {
                terminationGroup.leave()
            }
        }
        do {
            try process.run()
        } catch {
            process.terminationHandler = nil
            if terminationBox.complete(status: nil) {
                terminationGroup.leave()
            }
            throw error
        }
        let processIdentifier = process.processIdentifier

        func confirmedStatus(waiting seconds: TimeInterval) -> Int32? {
            if seconds == .infinity {
                terminationGroup.wait()
                return terminationBox.load()
            }
            let boundedSeconds = seconds.isFinite ? max(0, seconds) : 0
            guard terminationGroup.wait(timeout: .now() + boundedSeconds) == .success else {
                return nil
            }
            return terminationBox.load()
        }

        let exitCode: Int32
        if let status = confirmedStatus(waiting: timeoutSec) {
            exitCode = status
        } else {
            timedOut = true
            process.terminate()
            if let status = confirmedStatus(waiting: terminationGraceSec) {
                exitCode = status
            } else {
                // Some system tools ignore SIGTERM (e.g. systemextensionsctl).
                let killResult = kill(processIdentifier, SIGKILL)
                let signalError: Int32? = killResult == 0 || errno == ESRCH ? nil : errno
                guard let status = confirmedStatus(waiting: forcedTerminationGraceSec) else {
                    // Do not synchronously drain pipes while the child may still own their
                    // write ends. Closing our readers keeps the failure path bounded.
                    outBox.stopCallbacks(on: outHandle)
                    errBox.stopCallbacks(on: errHandle)
                    try? outHandle.close()
                    try? errHandle.close()
                    throw ProcessRunnerError.terminationUnconfirmed(
                        processIdentifier: processIdentifier,
                        signalError: signalError
                    )
                }
                exitCode = status
            }
        }

        // Termination is confirmed. Stop callbacks before draining bytes that are
        // immediately available so no two readers race on the same file descriptor.
        // Do not wait for EOF: a descendant can retain an inherited write end.
        outBox.stopCallbacks(on: outHandle)
        errBox.stopCallbacks(on: errHandle)
        outBox.drainCurrentlyAvailableData(from: outHandle)
        errBox.drainCurrentlyAvailableData(from: errHandle)
        try? outHandle.close()
        try? errHandle.close()

        let capturedOut = outBox.take()
        let capturedError = errBox.take()
        return ProcessResult(
            exitCode: exitCode,
            stdout: String(decoding: capturedOut.data, as: UTF8.self),
            stderr: String(decoding: capturedError.data, as: UTF8.self),
            timedOut: timedOut,
            stdoutTruncated: capturedOut.truncated,
            stderrTruncated: capturedError.truncated
        )
    }

    public static func which(_ name: String) -> String? {
        let path = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        for dir in path.split(separator: ":") {
            let candidate = URL(fileURLWithPath: String(dir)).appendingPathComponent(name).path
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }
}
