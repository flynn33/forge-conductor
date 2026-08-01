// DiskVolumeCollector.swift
// What: Reports mounted-volume capacity and free-space information.
// How: Foundation URL resource values are converted into typed DiskVolume records with
// explicit byte counts and normalized utilization.
// Why: Storage capacity is a separate, replaceable collector from disk I/O rates.

import Foundation

/// Mounted volume capacity via FileManager filesystem attributes.
public final class DiskVolumeCollector: DiskVolumeCollecting, @unchecked Sendable {
    public init() {}

    public func collect() -> [DiskVolume] {
        var rows: [DiskVolume] = []
        var seen = Set<String>()
        for mount in ["/", "/System/Volumes/Data"] {
            guard let u = try? FileManager.default.attributesOfFileSystem(forPath: mount) else { continue }
            let total = (u[.systemSize] as? NSNumber)?.uint64Value ?? 0
            let free = (u[.systemFreeSize] as? NSNumber)?.uint64Value ?? 0
            let used = total > free ? total - free : 0
            let pct = total > 0 ? 100.0 * Double(used) / Double(total) : 0
            let key = "\(total)-\(mount)"
            if seen.contains(key) { continue }
            seen.insert(key)
            rows.append(DiskVolume(
                device: mount,
                mount: mount,
                fstype: "apfs",
                totalGB: round1(Double(total) / 1_073_741_824),
                usedGB: round1(Double(used) / 1_073_741_824),
                availableGB: round1(Double(free) / 1_073_741_824),
                percent: round1(pct)
            ))
        }
        return rows
    }

    private func round1(_ v: Double) -> Double { (v * 10).rounded() / 10 }
}
