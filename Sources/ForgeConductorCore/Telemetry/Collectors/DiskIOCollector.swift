// DiskIOCollector.swift
// What: Measures host disk read/write throughput from native IOKit counters.
// How: It walks block-storage statistics, stores the prior byte totals/timestamp, and
// derives finite per-second deltas on subsequent samples.
// Why: Delta sampling yields live rates without spawning or parsing external tools.

import Foundation
import Darwin
import IOKit

/// Disk I/O rates via **IOKit / IORegistry** on `IOBlockStorageDriver`.
///
/// Uses `IORegistryEntryCreateCFProperties` for cumulative `Statistics`
/// (`Bytes (Read/Write)`, `Operations (Read/Write)`). Rates are **deltas**
/// between realtime samples — no `Thread.sleep`.
public final class DiskIOCollector: DiskIOMetricsCollecting, @unchecked Sendable {
    private let lock = NSLock()
    private var previous: Sample?

    private struct Sample {
        var at: Date
        var bytesRead: UInt64
        var bytesWritten: UInt64
        var opsRead: UInt64
        var opsWritten: UInt64
    }

    public init() {}

    public func collect() -> DiskIOMetrics {
        guard let sample = readSample() else {
            return .zero
        }
        lock.lock()
        let prev = previous
        previous = sample
        lock.unlock()

        guard let prev else {
            return .zero
        }
        return rates(from: prev, to: sample)
    }

    private func rates(from prev: Sample, to sample: Sample) -> DiskIOMetrics {
        let dt = max(sample.at.timeIntervalSince(prev.at), 0.001)
        let rB = sample.bytesRead >= prev.bytesRead ? sample.bytesRead - prev.bytesRead : 0
        let wB = sample.bytesWritten >= prev.bytesWritten ? sample.bytesWritten - prev.bytesWritten : 0
        let rO = sample.opsRead >= prev.opsRead ? sample.opsRead - prev.opsRead : 0
        let wO = sample.opsWritten >= prev.opsWritten ? sample.opsWritten - prev.opsWritten : 0
        let rMB = Double(rB) / 1_048_576 / dt
        let wMB = Double(wB) / 1_048_576 / dt
        return DiskIOMetrics(
            readMBs: round2(rMB),
            writeMBs: round2(wMB),
            totalMBs: round2(rMB + wMB),
            readIOPS: round1(Double(rO) / dt),
            writeIOPS: round1(Double(wO) / dt),
            totalIOPS: round1(Double(rO + wO) / dt)
        )
    }

    private func readSample() -> Sample? {
        var bytesRead: UInt64 = 0
        var bytesWritten: UInt64 = 0
        var opsRead: UInt64 = 0
        var opsWritten: UInt64 = 0
        var found = false

        IOKitPropertyWalk.forEachService(className: "IOBlockStorageDriver") { _, props in
            let stats = IOKitPropertyWalk.childDict(props, keys: ["Statistics", "statistics"]) ?? props
            if let br = IOKitPropertyWalk.u64(stats, keys: ["Bytes (Read)", "BytesRead", "bytes_read"]) {
                bytesRead &+= br
                found = true
            }
            if let bw = IOKitPropertyWalk.u64(stats, keys: ["Bytes (Write)", "BytesWritten", "bytes_written"]) {
                bytesWritten &+= bw
                found = true
            }
            if let or = IOKitPropertyWalk.u64(stats, keys: ["Operations (Read)", "OperationsRead", "reads"]) {
                opsRead &+= or
            }
            if let ow = IOKitPropertyWalk.u64(stats, keys: ["Operations (Write)", "OperationsWritten", "writes"]) {
                opsWritten &+= ow
            }
        }
        guard found else { return nil }
        return Sample(
            at: Date(),
            bytesRead: bytesRead,
            bytesWritten: bytesWritten,
            opsRead: opsRead,
            opsWritten: opsWritten
        )
    }

    private func round1(_ v: Double) -> Double { (v * 10).rounded() / 10 }
    private func round2(_ v: Double) -> Double { (v * 100).rounded() / 100 }
}

private extension DiskIOMetrics {
    static var zero: DiskIOMetrics {
        DiskIOMetrics(readMBs: 0, writeMBs: 0, totalMBs: 0, readIOPS: 0, writeIOPS: 0, totalIOPS: 0)
    }
}
