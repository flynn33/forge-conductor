// RAMCollector.swift
// What: Measures physical memory pressure and page-class usage.
// How: host_statistics64 page counts are converted with the host page size into typed
// used, available, wired, compressed, and cached byte totals.
// Why: Direct Mach counters provide consistent native memory telemetry.

import Foundation
import Darwin

/// Real-time RAM via Mach `host_statistics64(mach_host_self(), HOST_VM_INFO64, …)`.
/// Instant counters (free/active/inactive/wired/compressor) — no poll interval, no sleep.
public final class RAMCollector: RAMMetricsCollecting, @unchecked Sendable {
    public init() {}

    public func collect() -> RAMMetrics {
        let page = UInt64(sysctlInt("hw.pagesize") ?? 16384)
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        let kr = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        let total = ProcessInfo.processInfo.physicalMemory
        var free: UInt64 = 0, active: UInt64 = 0, inactive: UInt64 = 0, wired: UInt64 = 0, compressed: UInt64 = 0
        if kr == KERN_SUCCESS {
            free = UInt64(stats.free_count) * page
            active = UInt64(stats.active_count) * page
            inactive = UInt64(stats.inactive_count) * page
            wired = UInt64(stats.wire_count) * page
            compressed = UInt64(stats.compressor_page_count) * page
        }
        let available = free + inactive
        let used = total > available ? total - available : 0
        let pressure = total > 0 ? 100.0 * Double(total - available) / Double(total) : 0
        let usedPct = total > 0 ? 100.0 * Double(used) / Double(total) : 0
        return RAMMetrics(
            totalGB: round2(Double(total) / 1_073_741_824),
            usedGB: round2(Double(used) / 1_073_741_824),
            availableGB: round2(Double(available) / 1_073_741_824),
            percent: round1(usedPct),
            pressurePercent: round1(pressure),
            activeGB: round2(Double(active) / 1_073_741_824),
            wiredGB: round2(Double(wired) / 1_073_741_824),
            compressedGB: round2(Double(compressed) / 1_073_741_824)
        )
    }

    private func sysctlInt(_ name: String) -> Int? {
        var v: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname(name, &v, &size, nil, 0) == 0 else { return nil }
        return Int(v)
    }

    private func round1(_ v: Double) -> Double { (v * 10).rounded() / 10 }
    private func round2(_ v: Double) -> Double { (v * 100).rounded() / 100 }
}
