// CPUCollector.swift
// What: Measures aggregate and per-core CPU utilization with native Mach APIs.
// How: Successive host_processor_info counters are differenced under a lock and converted
// into normalized busy fractions while releasing kernel-allocated buffers correctly.
// Why: Accurate telemetry should not depend on parsing command-line utility output.

import Foundation
import Darwin

/// Real-time per-core and aggregate CPU via Mach host APIs.
///
/// - `host_processor_info(..., PROCESSOR_CPU_LOAD_INFO)` — per-core tick counters
/// - `host_statistics(..., HOST_CPU_LOAD_INFO)` — host-wide tick counters (fallback)
///
/// Utilization is always a **delta between samples** stored on this collector.
/// Never blocks the realtime queue with `Thread.sleep` (that is a snapshot anti-pattern).
public final class CPUCollector: CPUMetricsCollecting, @unchecked Sendable {
    private let lock = NSLock()
    private var previousCores: [CoreTicks]?
    private var previousHost: CoreTicks?

    private struct CoreTicks {
        var user: UInt32
        var system: UInt32
        var idle: UInt32
        var nice: UInt32
    }

    public init() {}

    public func collect() -> CPUMetrics {
        let logical = ProcessInfo.processInfo.processorCount
        let physical = sysctlInt("hw.physicalcpu") ?? logical
        var loads = [Double](repeating: 0, count: 3)
        _ = getloadavg(&loads, 3)
        let brand = sysctlString("machdep.cpu.brand_string")
            ?? sysctlString("hw.model")
            ?? "CPU"

        let (per, breakdown) = sampleRealtime()
        let percent: Double
        if !per.isEmpty {
            percent = per.reduce(0, +) / Double(per.count)
        } else {
            percent = breakdown.user + breakdown.system
        }
        let filled = per.isEmpty
            ? Array(repeating: round1(min(100, percent)), count: max(logical, 1))
            : per

        let freq = CPUFrequencyEstimator.estimate(
            brand: brand,
            model: sysctlString("hw.model"),
            perCoreUtilization: filled
        )

        return CPUMetrics(
            percent: round1(min(100, percent)),
            perCPU: filled.map { round1($0) },
            countLogical: logical,
            countPhysical: physical,
            freqMHz: freq.averageMHz,
            freqPerCoreMHz: freq.perCoreMHz,
            loadAvg: (round2(loads[0]), round2(loads[1]), round2(loads[2])),
            brand: brand,
            user: breakdown.user,
            system: breakdown.system,
            idle: breakdown.idle
        )
    }

    // MARK: - Real-time sample (no sleep)

    private func sampleRealtime() -> (perCore: [Double], breakdown: (user: Double, system: Double, idle: Double)) {
        if let cores = readPerCoreTicks() {
            lock.lock()
            let prev = previousCores
            previousCores = cores
            // Keep host fallback warm with sum of core ticks.
            previousHost = sumTicks(cores)
            lock.unlock()

            guard let prev, prev.count == cores.count else {
                // First sample: counters established; next engine tick yields true deltas.
                return (Array(repeating: 0, count: cores.count), (0, 0, 100))
            }
            let per = zip(prev, cores).map { utilization(from: $0, to: $1) }
            let br = breakdown(from: sumTicks(prev), to: sumTicks(cores))
            return (per, br)
        }

        // Fallback: host-wide HOST_CPU_LOAD_INFO (still Mach, still delta-only).
        guard let host = readHostTicks() else {
            return ([], (0, 0, 100))
        }
        lock.lock()
        let prev = previousHost
        previousHost = host
        lock.unlock()
        guard let prev else {
            return ([], (0, 0, 100))
        }
        let br = breakdown(from: prev, to: host)
        let pct = br.user + br.system
        let logical = max(ProcessInfo.processInfo.processorCount, 1)
        return (Array(repeating: pct, count: logical), br)
    }

    private func sumTicks(_ cores: [CoreTicks]) -> CoreTicks {
        cores.reduce(CoreTicks(user: 0, system: 0, idle: 0, nice: 0)) { acc, c in
            CoreTicks(
                user: acc.user &+ c.user,
                system: acc.system &+ c.system,
                idle: acc.idle &+ c.idle,
                nice: acc.nice &+ c.nice
            )
        }
    }

    private func breakdown(from a: CoreTicks, to b: CoreTicks) -> (user: Double, system: Double, idle: Double) {
        let du = Double(b.user &- a.user)
        let ds = Double(b.system &- a.system)
        let di = Double(b.idle &- a.idle)
        let dn = Double(b.nice &- a.nice)
        let total = du + ds + di + dn
        guard total > 0 else { return (0, 0, 100) }
        return (
            round1(100 * du / total),
            round1(100 * ds / total),
            round1(100 * di / total)
        )
    }

    /// Mach: `host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, …)`
    private func readPerCoreTicks() -> [CoreTicks]? {
        var cpuCount: natural_t = 0
        var cpuInfoArray: processor_info_array_t?
        var cpuInfoCount: mach_msg_type_number_t = 0
        let kr = host_processor_info(
            mach_host_self(),
            PROCESSOR_CPU_LOAD_INFO,
            &cpuCount,
            &cpuInfoArray,
            &cpuInfoCount
        )
        guard kr == KERN_SUCCESS, let info = cpuInfoArray, cpuCount > 0 else { return nil }
        defer {
            let size = vm_size_t(cpuInfoCount) * vm_size_t(MemoryLayout<integer_t>.size)
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info), size)
        }

        var cores: [CoreTicks] = []
        cores.reserveCapacity(Int(cpuCount))
        // PROCESSOR_CPU_LOAD_INFO: CPU_STATE_MAX integer_t ticks per logical CPU
        let stride = Int(CPU_STATE_MAX)
        for i in 0..<Int(cpuCount) {
            let base = i * stride
            guard base + 3 < Int(cpuInfoCount) else { break }
            cores.append(CoreTicks(
                user: UInt32(bitPattern: info[base + Int(CPU_STATE_USER)]),
                system: UInt32(bitPattern: info[base + Int(CPU_STATE_SYSTEM)]),
                idle: UInt32(bitPattern: info[base + Int(CPU_STATE_IDLE)]),
                nice: UInt32(bitPattern: info[base + Int(CPU_STATE_NICE)])
            ))
        }
        return cores
    }

    private func utilization(from a: CoreTicks, to b: CoreTicks) -> Double {
        let du = Double(b.user &- a.user)
        let ds = Double(b.system &- a.system)
        let di = Double(b.idle &- a.idle)
        let dn = Double(b.nice &- a.nice)
        let total = du + ds + di + dn
        guard total > 0 else { return 0 }
        return max(0, min(100, 100 * (1 - di / total)))
    }

    /// Mach: `host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, …)`
    private func readHostTicks() -> CoreTicks? {
        var load = host_cpu_load_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size
        )
        let kr = withUnsafeMutablePointer(to: &load) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return nil }
        return CoreTicks(
            user: load.cpu_ticks.0,
            system: load.cpu_ticks.1,
            idle: load.cpu_ticks.2,
            nice: load.cpu_ticks.3
        )
    }

    // MARK: - sysctl (static identity only — not the utilization clock)

    private func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 1 else { return nil }
        var buf = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buf, &size, nil, 0) == 0 else { return nil }
        return String(decoding: buf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
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
