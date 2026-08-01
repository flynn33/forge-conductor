// ManagerRuntime.swift
// What: Stores the mutable objects owned by one ManagerNode instance.
// How: A lock protects service state, dashboard reference, last errors, and timestamps
// while exposing narrow mutation/snapshot operations.
// Why: Separating synchronization state keeps ManagerNode orchestration readable.

import Foundation

/// Mutable runtime state for the manager process (thread-safe via owner lock).
/// Extracted so `ManagerNode` is orchestration-only, not a god object of fields + timers.
public final class ManagerRuntime: @unchecked Sendable {
    public var dashboard: DashboardServer?
    public var state: ManagerServiceState = .stopped
    public var desiredRunning = true
    public var lastError: String?
    public var startedAt: Date?
    public var restartCount = 0
    public var watchdog: DispatchSourceTimer?
    public var lastPresencePruneAt: Date?
    public var shutdownRequested = false
    public var signalSources: [Any] = []
    public let runLock = DispatchSemaphore(value: 0)
    public let queue = DispatchQueue(label: "forge.manager", qos: .userInitiated)

    public init() {}

    public var isHTTPUp: Bool {
        dashboard?.isRunning == true
    }

    public var isServiceActive: Bool {
        state == .running && isHTTPUp
    }

    public func markRunning(now: Date = Date()) {
        state = .running
        if startedAt == nil { startedAt = now }
        lastError = nil
    }

    public func markFailed(_ error: Error) {
        state = .failed
        lastError = "\(error)"
    }

    public func markStopped() {
        state = .stopped
        lastError = nil
    }

    public func beginRestart() -> Int {
        state = .restarting
        desiredRunning = true
        restartCount += 1
        return restartCount
    }

    public func requestShutdown() {
        shutdownRequested = true
        desiredRunning = false
    }

    /// Called while the owning ManagerNode lock is held.
    public func claimPresencePrune(now: Date, minimumInterval: TimeInterval) -> Bool {
        if let lastPresencePruneAt,
           now.timeIntervalSince(lastPresencePruneAt) < minimumInterval {
            return false
        }
        lastPresencePruneAt = now
        return true
    }
}
