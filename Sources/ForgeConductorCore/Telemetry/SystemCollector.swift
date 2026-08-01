// SystemCollector.swift
// What: Composes all native hardware collectors into one SystemMetrics sample.
// How: Injected CPU, RAM, disk, GPU, process, power, and frequency modules are sampled
// and normalized with host/platform metadata at a shared timestamp.
// Why: The engine depends on one replaceable system port rather than concrete collectors.

import Foundation
import Darwin

/// Composes modular host collectors into `SystemMetrics`.
///
/// | Field | API surface |
/// |-------|-------------|
/// | CPU | Mach `host_processor_info` / `host_statistics` |
/// | RAM | Mach `host_statistics64` `HOST_VM_INFO64` |
/// | Processes | libproc `proc_pid_rusage` / `proc_pidinfo`; self: Mach `task_threads` |
/// | Disk I/O | IOKit + **IORegistry** (`IORegistryEntryCreateCFProperties` on IOBlockStorageDriver) |
/// | GPU | IOKit + **IORegistry** (IOAccelerator / AGX / IOGPU PerformanceStatistics) |
/// | Power | IOKit **IOPowerSources** (`IOPSCopyPowerSourcesInfo` …) |
/// | Volumes | FileManager filesystem attributes |
///
/// Tiered sampling keeps Mach CPU/RAM at ~30 Hz without waiting on heavier walks.
public final class SystemCollector: SystemMetricsCollecting, @unchecked Sendable {
    public enum SampleTier: Sendable {
        /// CPU + RAM only (Mach realtime gauges).
        case realtime
        /// + disk I/O + GPU (IOKit/IORegistry).
        case medium
        /// Full: processes (libproc), volumes, power (IOPowerSources).
        case full
    }

    private let cpu: any CPUMetricsCollecting
    private let ram: any RAMMetricsCollecting
    private let disk: any DiskVolumeCollecting
    private let gpu: any GPUMetricsCollecting
    private let diskIO: any DiskIOMetricsCollecting
    private let processes: any ProcessMetricsCollecting
    private let power: any PowerMetricsCollecting

    private let lock = NSLock()
    private var lastDisk: [DiskVolume] = []
    private var lastDiskIO = DiskIOMetrics(
        readMBs: 0, writeMBs: 0, totalMBs: 0, readIOPS: 0, writeIOPS: 0, totalIOPS: 0
    )
    private var lastGPU: [GPUMetrics] = []
    private var lastProcesses: [ProcessMetrics] = []
    private var lastPower: PowerMetrics = .unknown
    private let hostName: String
    private let arch: String

    public init(
        cpu: any CPUMetricsCollecting = CPUCollector(),
        ram: any RAMMetricsCollecting = RAMCollector(),
        disk: any DiskVolumeCollecting = DiskVolumeCollector(),
        gpu: any GPUMetricsCollecting = GPUCollector(),
        diskIO: any DiskIOMetricsCollecting = DiskIOCollector(),
        processes: any ProcessMetricsCollecting = ProcessMetricsCollector(),
        power: any PowerMetricsCollecting = PowerSourcesCollector()
    ) {
        self.cpu = cpu
        self.ram = ram
        self.disk = disk
        self.gpu = gpu
        self.diskIO = diskIO
        self.processes = processes
        self.power = power
        self.hostName = Host.current().localizedName ?? ProcessInfo.processInfo.hostName
        #if arch(arm64)
        self.arch = "arm64"
        #else
        self.arch = "x86_64"
        #endif
    }

    public func collectMetrics() -> SystemMetrics {
        collectMetrics(tier: .full)
    }

    public func collectMetrics(tier: SampleTier) -> SystemMetrics {
        // Mach path — every tick.
        let cpuM = cpu.collect()
        let ramM = ram.collect()

        lock.lock()
        switch tier {
        case .realtime:
            break
        case .medium:
            lastDiskIO = diskIO.collect()
            lastGPU = gpu.collect()
            lastPower = power.collect()
        case .full:
            lastDiskIO = diskIO.collect()
            lastGPU = gpu.collect()
            lastPower = power.collect()
            lastDisk = disk.collect()
            lastProcesses = processes.collect()
        }
        let d = lastDisk
        let dio = lastDiskIO
        let g = lastGPU
        let p = lastProcesses
        let pow = lastPower
        lock.unlock()

        return SystemMetrics(
            ts: Date().timeIntervalSince1970,
            host: hostName,
            platform: "darwin",
            arch: arch,
            cpu: cpuM,
            ram: ramM,
            disk: d,
            diskIO: dio,
            gpu: g,
            processes: p,
            power: pow
        )
    }

    public func collect() -> [String: Any] {
        collectMetrics().asDictionary()
    }
}
