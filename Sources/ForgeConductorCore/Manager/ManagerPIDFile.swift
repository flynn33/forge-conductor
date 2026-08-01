// ManagerPIDFile.swift
// What: Reads, validates, and removes the persistent manager PID marker.
// How: Small static helpers parse a positive process identifier and perform atomic writes.
// Why: PID-file semantics stay consistent across installer, manager, CLI, and tests.

import Foundation

/// Owns the manager PID-file format and its liveness/termination operations.
///
/// Centralizing this behavior prevents the CLI, installer, and runtime from applying
/// different parsing rules or accidentally signalling an invalid process identifier.
public enum ManagerPIDFile {
    public static func write(paths: AppPaths) throws {
        try paths.ensureLayout()
        let pid = ProcessInfo.processInfo.processIdentifier
        try "\(pid)\n".write(to: paths.managerPid, atomically: true, encoding: .utf8)
    }

    public static func remove(paths: AppPaths) {
        try? FileManager.default.removeItem(at: paths.managerPid)
    }

    public static func read(paths: AppPaths) -> Int32? {
        guard let text = try? String(contentsOf: paths.managerPid, encoding: .utf8) else { return nil }
        return Int32(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    public static func isProcessAlive(pid: Int32) -> Bool {
        if pid <= 0 { return false }
        return kill(pid, 0) == 0
    }

    public static func runningPID(paths: AppPaths) -> Int32? {
        guard let pid = read(paths: paths), isProcessAlive(pid: pid) else { return nil }
        return pid
    }

    @discardableResult
    public static func signalStop(paths: AppPaths) -> Bool {
        guard let pid = runningPID(paths: paths) else { return false }
        kill(pid, SIGTERM)
        return true
    }
}
