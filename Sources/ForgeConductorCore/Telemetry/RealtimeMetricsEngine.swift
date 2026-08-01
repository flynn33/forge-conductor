// RealtimeMetricsEngine.swift
// What: Owns the continuous high-frequency host sampling loop and history buffer.
// How: One serial timer samples SystemMetricsCollecting, measures actual cadence,
// maintains bounded history, and publishes synchronized latest values under a lock.
// Why: Every consumer must share one clock instead of launching duplicate collectors.

import Foundation
import Darwin

/// Continuous native host metrics engine.
///
/// **Source of truth for host load is Mach**, not snapshots or shell:
/// - CPU: `host_processor_info` / `host_statistics` (delta ticks → %)
/// - RAM: `host_statistics64` `HOST_VM_INFO64`
/// - Processes: `proc_pidinfo` `PROC_PIDTASKINFO` (task CPU/RSS; Mach task times)
/// - Disk I/O / GPU: IOKit counters (delta rates between engine ticks)
///
/// Samples at a target Hz with **tiered** collectors so heavy walks never block
/// the Mach CPU/RAM path:
/// - every tick: CPU + RAM (Mach realtime gauges)
/// - every 3rd tick: disk I/O + GPU
/// - every 10th tick: processes + disk volumes
public final class RealtimeMetricsEngine: RealtimeMetricsStreaming, @unchecked Sendable {
    public static let defaultTargetHz: Double = 30

    private let systemCollector: any SystemMetricsCollecting
    private let tieredCollector: SystemCollector?
    private let queue: DispatchQueue
    private let lock = NSLock()

    private var timer: DispatchSourceTimer?
    private var _latest: SystemMetrics
    private var _targetHz: Double = RealtimeMetricsEngine.defaultTargetHz
    private var _running = false
    private var listeners: [UUID: (SystemMetrics) -> Void] = [:]
    private var tick: UInt64 = 0

    // Measured Hz over a 1s window
    private var sampleCountWindow = 0
    private var windowStarted = Date()
    private var _measuredHz: Double = 0

    public init(systemCollector: any SystemMetricsCollecting = SystemCollector()) {
        self.systemCollector = systemCollector
        self.tieredCollector = systemCollector as? SystemCollector
        self.queue = DispatchQueue(label: "forge.telemetry.realtime.engine", qos: .userInitiated)
        // The first public frame must be structurally complete even when the
        // continuous timer is intentionally idle (tests, CLI doctor, startup).
        self._latest = systemCollector.collectMetrics()
    }

    public var latestSystem: SystemMetrics {
        lock.lock(); defer { lock.unlock() }
        return _latest
    }

    public var targetSampleHz: Double {
        lock.lock(); defer { lock.unlock() }
        return _targetHz
    }

    public var measuredSampleHz: Double {
        lock.lock(); defer { lock.unlock() }
        return _measuredHz
    }

    public var isRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        return _running
    }

    public func start(targetHz: Double = RealtimeMetricsEngine.defaultTargetHz) {
        stop()
        let hz = min(max(targetHz, 5), 60)
        let periodMs = max(16, Int((1000.0 / hz).rounded()))
        lock.lock()
        _targetHz = hz
        _running = true
        sampleCountWindow = 0
        windowStarted = Date()
        tick = 0
        lock.unlock()

        // Warm full sample so heavy fields are not empty on first paint.
        sampleOnce(forceFull: true)

        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(
            deadline: .now() + .milliseconds(periodMs),
            repeating: .milliseconds(periodMs),
            leeway: .milliseconds(max(2, periodMs / 10))
        )
        t.setEventHandler { [weak self] in
            self?.sampleOnce(forceFull: false)
        }
        t.resume()
        lock.lock()
        timer = t
        lock.unlock()
    }

    public func stop() {
        lock.lock()
        timer?.cancel()
        timer = nil
        _running = false
        lock.unlock()
    }

    @discardableResult
    public func addListener(_ block: @escaping (SystemMetrics) -> Void) -> UUID {
        let id = UUID()
        lock.lock()
        listeners[id] = block
        lock.unlock()
        return id
    }

    public func removeListener(_ id: UUID) {
        lock.lock()
        listeners[id] = nil
        lock.unlock()
    }

    private func sampleOnce(forceFull: Bool) {
        lock.lock()
        tick &+= 1
        let n = tick
        lock.unlock()

        let tier: SystemCollector.SampleTier
        if forceFull || n % 10 == 0 {
            tier = .full
        } else if n % 3 == 0 {
            tier = .medium
        } else {
            tier = .realtime
        }

        let metrics = tieredCollector?.collectMetrics(tier: tier)
            ?? systemCollector.collectMetrics()
        lock.lock()
        _latest = metrics
        sampleCountWindow += 1
        let elapsed = Date().timeIntervalSince(windowStarted)
        if elapsed >= 1.0 {
            _measuredHz = Double(sampleCountWindow) / elapsed
            sampleCountWindow = 0
            windowStarted = Date()
        }
        let cbs = Array(listeners.values)
        lock.unlock()
        for cb in cbs {
            cb(metrics)
        }
    }
}
