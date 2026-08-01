// ProcessMetricsCollector.swift
// What: Samples resource usage for relevant local processes.
// How: libproc enumerates identities and Mach task/thread counters provide CPU, memory,
// and thread measurements with filtering and hard result limits.
// Why: Native bounded collection is faster and safer than repeatedly invoking ps.

import Foundation
import Darwin

/// Hot-process metrics via **libproc** (never `/bin/ps`).
///
/// Primary path:
/// - `proc_listpids` — enumerate PIDs
/// - `proc_pidpath` — identity filter
/// - `proc_pid_rusage(..., RUSAGE_INFO_V3)` — user/system time, RSS, phys footprint
///
/// Fallback:
/// - `proc_pidinfo(..., PROC_PIDTASKINFO)` — `proc_taskinfo` (Mach task times/RSS)
///
/// Thread count:
/// - `proc_pidinfo(..., PROC_PIDLISTTHREADS)` when available
/// - self-process: Mach `task_threads` + `thread_info` (THREAD_BASIC_INFO)
///
/// CPU% = Δ(`ri_user_time`+`ri_system_time`) / Δwall — first sample 0 until next realtime tick.
public final class ProcessMetricsCollector: ProcessMetricsCollecting, @unchecked Sendable {
    private let lock = NSLock()
    private var previousCPU: [Int32: (user: UInt64, system: UInt64, at: Date)] = [:]

    private static let interestKeys = [
        "llama", "lm studio", "lmstudio", "lms", "forge-conductor", "forge conductor",
        "mlx", "ollama", "ggml", "metal", "lm studio.app",
    ]

    public init() {}

    public func collect() -> [ProcessMetrics] {
        let pids = listPIDs()
        var rows: [ProcessMetrics] = []
        rows.reserveCapacity(16)
        let now = Date()
        let selfPID = ProcessInfo.processInfo.processIdentifier

        lock.lock()
        var nextPrev: [Int32: (user: UInt64, system: UInt64, at: Date)] = [:]
        defer {
            previousCPU = nextPrev
            lock.unlock()
        }

        for pid in pids {
            guard pid > 0 else { continue }
            guard let path = pidPath(pid) else { continue }
            let leaf = (path as NSString).lastPathComponent
            let lower = (path + " " + leaf).lowercased()
            guard Self.interestKeys.contains(where: { lower.contains($0) }) else { continue }
            if lower.contains("claude") || lower.contains("ccdt") { continue }

            guard let sample = sampleProcess(pid) else { continue }
            let cpu = cpuPercent(
                pid: pid,
                user: sample.userNS,
                system: sample.systemNS,
                now: now,
                previous: &nextPrev
            )
            let threads: Int?
            if pid == selfPID {
                threads = MachTaskThreadSampler.currentProcessThreadCount()
            } else {
                threads = threadCount(pid)
            }

            rows.append(ProcessMetrics(
                pid: Int(pid),
                name: String(leaf.prefix(48)),
                cpuPercent: (cpu * 10).rounded() / 10,
                rssGB: (sample.rssBytes / 1_073_741_824.0 * 100).rounded() / 100,
                footprintGB: sample.footprintBytes.map { ($0 / 1_073_741_824.0 * 100).rounded() / 100 },
                threadCount: threads,
                source: sample.source
            ))
        }

        rows.sort {
            $0.cpuPercent == $1.cpuPercent ? $0.rssGB > $1.rssGB : $0.cpuPercent > $1.cpuPercent
        }
        return Array(rows.prefix(16))
    }

    // MARK: - Sample (rusage → taskinfo)

    private struct ProcSample {
        var userNS: UInt64
        var systemNS: UInt64
        var rssBytes: Double
        var footprintBytes: Double?
        var source: String
    }

    private func sampleProcess(_ pid: Int32) -> ProcSample? {
        if let r = rusageV3(pid) {
            return ProcSample(
                userNS: r.ri_user_time,
                systemNS: r.ri_system_time,
                rssBytes: Double(r.ri_resident_size),
                footprintBytes: Double(r.ri_phys_footprint),
                source: "proc_pid_rusage"
            )
        }
        if let t = taskInfo(pid) {
            return ProcSample(
                userNS: t.pti_total_user,
                systemNS: t.pti_total_system,
                rssBytes: Double(t.pti_resident_size),
                footprintBytes: nil,
                source: "proc_pidinfo"
            )
        }
        return nil
    }

    private func cpuPercent(
        pid: Int32,
        user: UInt64,
        system: UInt64,
        now: Date,
        previous: inout [Int32: (user: UInt64, system: UInt64, at: Date)]
    ) -> Double {
        let cpu: Double
        if let prev = previousCPU[pid] {
            let du = user &- prev.user
            let ds = system &- prev.system
            let dt = now.timeIntervalSince(prev.at)
            if dt > 0.01 {
                let cpuSec = Double(du &+ ds) / 1_000_000_000.0
                cpu = max(0, min(800, 100.0 * cpuSec / dt))
            } else {
                cpu = 0
            }
        } else {
            cpu = 0
        }
        previous[pid] = (user, system, now)
        return cpu
    }

    // MARK: - libproc

    private func listPIDs() -> [Int32] {
        let type = UInt32(PROC_ALL_PIDS)
        let bufSize = proc_listpids(type, 0, nil, 0)
        guard bufSize > 0 else { return [] }
        let count = Int(bufSize) / MemoryLayout<Int32>.stride
        var pids = [Int32](repeating: 0, count: max(count, 1))
        let got = proc_listpids(type, 0, &pids, Int32(pids.count * MemoryLayout<Int32>.stride))
        guard got > 0 else { return [] }
        let n = Int(got) / MemoryLayout<Int32>.stride
        return Array(pids.prefix(n)).filter { $0 > 0 }
    }

    private func pidPath(_ pid: Int32) -> String? {
        var buf = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        let n = proc_pidpath(pid, &buf, UInt32(buf.count))
        guard n > 0 else { return nil }
        let end = buf.firstIndex(of: 0) ?? min(Int(n), buf.count)
        return String(
            decoding: buf[..<end].map { UInt8(bitPattern: $0) },
            as: UTF8.self
        )
    }

    /// `proc_pid_rusage(pid, RUSAGE_INFO_V3, …)`
    private func rusageV3(_ pid: Int32) -> rusage_info_v3? {
        var info = rusage_info_v3()
        let ret = withUnsafeMutablePointer(to: &info) { ptr -> Int32 in
            ptr.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { rebound in
                proc_pid_rusage(pid, RUSAGE_INFO_V3, rebound)
            }
        }
        guard ret == 0 else { return nil }
        return info
    }

    /// `proc_pidinfo(pid, PROC_PIDTASKINFO, …)`
    private func taskInfo(_ pid: Int32) -> proc_taskinfo? {
        var info = proc_taskinfo()
        let sz = Int32(MemoryLayout<proc_taskinfo>.stride)
        let ret = proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, sz)
        guard ret == sz else { return nil }
        return info
    }

    /// `proc_pidinfo(pid, PROC_PIDLISTTHREADS, …)` → thread id count
    private func threadCount(_ pid: Int32) -> Int? {
        // Buffer for up to 256 thread IDs (uint64_t each per Darwin).
        var buf = [UInt64](repeating: 0, count: 256)
        let bytes = Int32(buf.count * MemoryLayout<UInt64>.stride)
        let ret = proc_pidinfo(pid, PROC_PIDLISTTHREADS, 0, &buf, bytes)
        guard ret > 0 else { return nil }
        return Int(ret) / MemoryLayout<UInt64>.stride
    }
}

// MARK: - Mach task/thread (self process)

/// Mach Task / Thread APIs for the **current** process (no `task_for_pid` privilege needed).
enum MachTaskThreadSampler {
    /// `task_threads(mach_task_self_)` then release ports.
    static func currentProcessThreadCount() -> Int? {
        var threadList: thread_act_array_t?
        var threadCount: mach_msg_type_number_t = 0
        let kr = task_threads(mach_task_self_, &threadList, &threadCount)
        guard kr == KERN_SUCCESS, let list = threadList else { return nil }
        defer {
            let size = vm_size_t(threadCount) * vm_size_t(MemoryLayout<thread_t>.stride)
            // Deallocate thread ports then the array.
            for i in 0..<Int(threadCount) {
                mach_port_deallocate(mach_task_self_, list[i])
            }
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: list), size)
        }
        return Int(threadCount)
    }

    /// `task_info(mach_task_self_, TASK_BASIC_INFO, …)` resident size of this process.
    static func currentTaskRSSBytes() -> UInt64? {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info_data_t>.stride / MemoryLayout<natural_t>.stride)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return nil }
        return UInt64(info.resident_size)
    }
}
