// TelemetryModels.swift
// What: Defines the typed contract for hardware samples, history, and composed frames.
// How: Sendable value types retain native units and provide explicit dictionary
// projections only at transport boundaries.
// Why: Strong models keep collectors, engines, UI, SSE, and tests in schema agreement.

import Foundation

// MARK: - Health (shared UI vocabulary — evidence: old app.js healthBadge)

/// Shared severity vocabulary used by collectors, composed frames, and native badges.
public enum TelemetryHealth: String, Sendable, Codable, CaseIterable {
    case ok, warn, error, down, config

    public var label: String {
        switch self {
        case .ok: "READY"
        case .warn: "WARN"
        case .error: "ERROR"
        case .down: "DOWN"
        case .config: "CONFIG"
        }
    }

    public var tone: TelemetryStatusTone {
        switch self {
        case .ok: .healthy
        case .warn: .caution
        case .error, .down: .failure
        case .config: .informational
        }
    }

    /// Converts legacy/raw health strings at the presentation boundary without
    /// treating an unknown or loading state as a failure.
    public static func tone(for rawValue: String?) -> TelemetryStatusTone {
        guard let rawValue, let health = Self(rawValue: rawValue) else {
            return .unavailable
        }
        return health.tone
    }
}

/// Presentation-neutral severity. Core owns the state semantics while each UI
/// module remains free to choose platform-appropriate colors and symbols.
public enum TelemetryStatusTone: String, Sendable, Codable, CaseIterable, Hashable {
    case healthy
    case caution
    case failure
    case informational
    case unavailable

    /// Aggregates independent component states without allowing a healthy or
    /// configured peer to hide a verified warning/failure.
    public static func mostSevere<S: Sequence>(_ tones: S) -> TelemetryStatusTone
    where S.Element == TelemetryStatusTone {
        let priority: [TelemetryStatusTone: Int] = [
            .unavailable: 0,
            .informational: 1,
            .healthy: 2,
            .caution: 3,
            .failure: 4,
        ]
        return tones.max {
            priority[$0, default: 0] < priority[$1, default: 0]
        } ?? .unavailable
    }
}

// MARK: - System metrics (contract keys from TelemetryContract.systemKeys)

public struct SystemMetrics: Sendable {
    public var ts: TimeInterval
    public var host: String
    public var platform: String
    public var arch: String
    public var cpu: CPUMetrics
    public var ram: RAMMetrics
    public var disk: [DiskVolume]
    public var diskIO: DiskIOMetrics
    public var gpu: [GPUMetrics]
    public var processes: [ProcessMetrics]
    /// AC/battery from IOKit IOPowerSources (`IOPSCopyPowerSourcesInfo`).
    public var power: PowerMetrics

    public init(
        ts: TimeInterval,
        host: String,
        platform: String,
        arch: String,
        cpu: CPUMetrics,
        ram: RAMMetrics,
        disk: [DiskVolume],
        diskIO: DiskIOMetrics,
        gpu: [GPUMetrics],
        processes: [ProcessMetrics],
        power: PowerMetrics = .unknown
    ) {
        self.ts = ts
        self.host = host
        self.platform = platform
        self.arch = arch
        self.cpu = cpu
        self.ram = ram
        self.disk = disk
        self.diskIO = diskIO
        self.gpu = gpu
        self.processes = processes
        self.power = power
    }

    public func asDictionary() -> [String: Any] {
        [
            "ts": ts,
            "host": host,
            "platform": platform,
            "arch": arch,
            "cpu": cpu.asDictionary(),
            "ram": ram.asDictionary(),
            "disk": disk.map { $0.asDictionary() },
            "disk_io": diskIO.asDictionary(),
            "gpu": gpu.map { $0.asDictionary() },
            "processes": processes.map { $0.asDictionary() },
            "power": power.asDictionary(),
        ]
    }
}

/// System power path via IOKit **IOPowerSources** (not a shell/sysctl snapshot).
public struct PowerMetrics: Sendable, Equatable {
    public var onAC: Bool
    public var state: String
    public var batteryPercent: Double?
    public var isCharging: Bool?
    public var isCharged: Bool?
    public var timeToEmptyMin: Int?
    public var timeToFullMin: Int?
    public var sourceCount: Int
    public var providingName: String?

    public init(
        onAC: Bool,
        state: String,
        batteryPercent: Double?,
        isCharging: Bool?,
        isCharged: Bool?,
        timeToEmptyMin: Int?,
        timeToFullMin: Int?,
        sourceCount: Int,
        providingName: String?
    ) {
        self.onAC = onAC
        self.state = state
        self.batteryPercent = batteryPercent
        self.isCharging = isCharging
        self.isCharged = isCharged
        self.timeToEmptyMin = timeToEmptyMin
        self.timeToFullMin = timeToFullMin
        self.sourceCount = sourceCount
        self.providingName = providingName
    }

    public static let unknown = PowerMetrics(
        onAC: true,
        state: "Unknown",
        batteryPercent: nil,
        isCharging: nil,
        isCharged: nil,
        timeToEmptyMin: nil,
        timeToFullMin: nil,
        sourceCount: 0,
        providingName: nil
    )

    public func asDictionary() -> [String: Any] {
        [
            "on_ac": onAC,
            "state": state,
            "battery_percent": batteryPercent as Any,
            "is_charging": isCharging as Any,
            "is_charged": isCharged as Any,
            "time_to_empty_min": timeToEmptyMin as Any,
            "time_to_full_min": timeToFullMin as Any,
            "source_count": sourceCount,
            "providing": providingName as Any,
        ]
    }
}

public struct CPUMetrics: Sendable {
    public var percent: Double
    public var perCPU: [Double]
    public var countLogical: Int
    public var countPhysical: Int
    public var freqMHz: Int?
    public var freqPerCoreMHz: [Int]?
    public var loadAvg: (m1: Double, m5: Double, m15: Double)
    public var brand: String
    public var user: Double
    public var system: Double
    public var idle: Double

    public init(
        percent: Double,
        perCPU: [Double],
        countLogical: Int,
        countPhysical: Int,
        freqMHz: Int?,
        freqPerCoreMHz: [Int]?,
        loadAvg: (m1: Double, m5: Double, m15: Double),
        brand: String,
        user: Double,
        system: Double,
        idle: Double
    ) {
        self.percent = percent
        self.perCPU = perCPU
        self.countLogical = countLogical
        self.countPhysical = countPhysical
        self.freqMHz = freqMHz
        self.freqPerCoreMHz = freqPerCoreMHz
        self.loadAvg = loadAvg
        self.brand = brand
        self.user = user
        self.system = system
        self.idle = idle
    }

    public func asDictionary() -> [String: Any] {
        [
            "percent": percent,
            "per_cpu": perCPU,
            "count_logical": countLogical,
            "count_physical": countPhysical,
            "freq_mhz": freqMHz as Any,
            "freq_per_core_mhz": freqPerCoreMHz as Any,
            "load_avg": ["m1": loadAvg.m1, "m5": loadAvg.m5, "m15": loadAvg.m15],
            "brand": brand,
            "user": user,
            "system": system,
            "idle": idle,
        ]
    }
}

public struct RAMMetrics: Sendable {
    public var totalGB: Double
    public var usedGB: Double
    public var availableGB: Double
    public var percent: Double
    public var pressurePercent: Double
    public var activeGB: Double
    public var wiredGB: Double
    public var compressedGB: Double

    public init(
        totalGB: Double,
        usedGB: Double,
        availableGB: Double,
        percent: Double,
        pressurePercent: Double,
        activeGB: Double,
        wiredGB: Double,
        compressedGB: Double
    ) {
        self.totalGB = totalGB
        self.usedGB = usedGB
        self.availableGB = availableGB
        self.percent = percent
        self.pressurePercent = pressurePercent
        self.activeGB = activeGB
        self.wiredGB = wiredGB
        self.compressedGB = compressedGB
    }

    public func asDictionary() -> [String: Any] {
        [
            "total_gb": totalGB,
            "used_gb": usedGB,
            "available_gb": availableGB,
            "percent": percent,
            "pressure_percent": pressurePercent,
            "active_gb": activeGB,
            "wired_gb": wiredGB,
            "compressed_gb": compressedGB,
            "swap_total_gb": 0,
            "swap_used_gb": 0,
            "swap_percent": 0,
        ]
    }
}

public struct DiskVolume: Sendable {
    public var device: String
    public var mount: String
    public var fstype: String
    public var totalGB: Double
    public var usedGB: Double
    public var availableGB: Double
    public var percent: Double

    public init(
        device: String,
        mount: String,
        fstype: String,
        totalGB: Double,
        usedGB: Double,
        availableGB: Double,
        percent: Double
    ) {
        self.device = device
        self.mount = mount
        self.fstype = fstype
        self.totalGB = totalGB
        self.usedGB = usedGB
        self.availableGB = availableGB
        self.percent = percent
    }

    public func asDictionary() -> [String: Any] {
        [
            "device": device,
            "mount": mount,
            "fstype": fstype,
            "total_gb": totalGB,
            "used_gb": usedGB,
            "available_gb": availableGB,
            "percent": percent,
        ]
    }
}

public struct DiskIOMetrics: Sendable {
    public var readMBs: Double
    public var writeMBs: Double
    public var totalMBs: Double
    public var readIOPS: Double
    public var writeIOPS: Double
    public var totalIOPS: Double

    public init(
        readMBs: Double,
        writeMBs: Double,
        totalMBs: Double,
        readIOPS: Double,
        writeIOPS: Double,
        totalIOPS: Double
    ) {
        self.readMBs = readMBs
        self.writeMBs = writeMBs
        self.totalMBs = totalMBs
        self.readIOPS = readIOPS
        self.writeIOPS = writeIOPS
        self.totalIOPS = totalIOPS
    }

    public func asDictionary() -> [String: Any] {
        [
            "read_mb_s": readMBs,
            "write_mb_s": writeMBs,
            "total_mb_s": totalMBs,
            "read_iops": readIOPS,
            "write_iops": writeIOPS,
            "total_iops": totalIOPS,
            "read_bytes_total": 0,
            "write_bytes_total": 0,
            "read_ops_total": 0,
            "write_ops_total": 0,
        ]
    }
}

public struct GPUMetrics: Sendable {
    public var vendor: String
    public var name: String
    public var utilGPU: Double?
    public var utilRenderer: Double?
    public var utilTiler: Double?
    public var memUsedMiB: Int?
    public var memTotalMiB: Int
    public var cores: Int?
    public var metal: Bool

    public init(
        vendor: String,
        name: String,
        utilGPU: Double?,
        utilRenderer: Double?,
        utilTiler: Double?,
        memUsedMiB: Int?,
        memTotalMiB: Int,
        cores: Int?,
        metal: Bool
    ) {
        self.vendor = vendor
        self.name = name
        self.utilGPU = utilGPU
        self.utilRenderer = utilRenderer
        self.utilTiler = utilTiler
        self.memUsedMiB = memUsedMiB
        self.memTotalMiB = memTotalMiB
        self.cores = cores
        self.metal = metal
    }

    public func asDictionary() -> [String: Any] {
        [
            "vendor": vendor,
            "name": name,
            "util_gpu": utilGPU as Any,
            "util_mem": NSNull(),
            "util_renderer": utilRenderer as Any,
            "util_tiler": utilTiler as Any,
            "mem_used_mib": memUsedMiB as Any,
            "mem_total_mib": memTotalMiB,
            "mem_alloc_mib": memUsedMiB as Any,
            "mem_free_mib": memUsedMiB.map { max(0, memTotalMiB - $0) } as Any,
            "temp_c": NSNull(),
            "power_w": NSNull(),
            "power_limit_w": NSNull(),
            "clock_sm_mhz": NSNull(),
            "clock_sm_max_mhz": NSNull(),
            "clock_mem_mhz": NSNull(),
            "cores": cores as Any,
            "shared_memory": true,
            "metal": metal,
            "processes": [] as [Any],
        ]
    }
}

public struct ProcessMetrics: Sendable {
    public var pid: Int
    public var name: String
    public var cpuPercent: Double
    public var rssGB: Double
    /// Physical footprint from `proc_pid_rusage` (`ri_phys_footprint`) when available.
    public var footprintGB: Double?
    /// Thread count from `proc_pidinfo(PROC_PIDLISTTHREADS)` / Mach `task_threads`.
    public var threadCount: Int?
    /// Source API used for the sample (`proc_pid_rusage` | `proc_pidinfo` | `task_info`).
    public var source: String?

    public init(
        pid: Int,
        name: String,
        cpuPercent: Double,
        rssGB: Double,
        footprintGB: Double? = nil,
        threadCount: Int? = nil,
        source: String? = nil
    ) {
        self.pid = pid
        self.name = name
        self.cpuPercent = cpuPercent
        self.rssGB = rssGB
        self.footprintGB = footprintGB
        self.threadCount = threadCount
        self.source = source
    }

    public func asDictionary() -> [String: Any] {
        [
            "pid": pid,
            "name": name,
            "cpu_percent": cpuPercent,
            "rss_gb": rssGB,
            "footprint_gb": footprintGB as Any,
            "thread_count": threadCount as Any,
            "source": source as Any,
        ]
    }
}

// MARK: - History point (load trace multi-series)

public struct HistoryPoint: Sendable {
    public var ts: TimeInterval
    public var cpu: Double
    public var ram: Double
    public var gpu: Double?
    public var diskIO: Double
    public var mcp: Int
    public var orch: String

    public init(
        ts: TimeInterval,
        cpu: Double,
        ram: Double,
        gpu: Double?,
        diskIO: Double,
        mcp: Int,
        orch: String
    ) {
        self.ts = ts
        self.cpu = cpu
        self.ram = ram
        self.gpu = gpu
        self.diskIO = diskIO
        self.mcp = mcp
        self.orch = orch
    }

    public func asDictionary() -> [String: Any] {
        [
            "ts": ts,
            "cpu": cpu,
            "ram": ram,
            "gpu": gpu.map { $0 as Any } ?? NSNull(),
            "disk_io": diskIO,
            "mcp": mcp,
            "orch": orch,
        ]
    }
}

// MARK: - Live telemetry frame

/// One composed live frame (host sample + last forge composition).
/// Product delivery is the continuous stream; this type is the frame payload.
public struct TelemetrySnapshot: Sendable {
    public var system: SystemMetrics
    public var forge: ForgeSnapshot
    public var updated: TimeInterval
    public var history: [HistoryPoint]
    public var runtime: String

    public init(
        system: SystemMetrics,
        forge: ForgeSnapshot,
        updated: TimeInterval,
        history: [HistoryPoint],
        runtime: String
    ) {
        self.system = system
        self.forge = forge
        self.updated = updated
        self.history = history
        self.runtime = runtime
    }

    /// Serialization boundary only (HTTP / JSON / SSE / tests).
    public func asDictionary() -> [String: Any] {
        [
            "system": system.asDictionary(),
            "forge": forge.asDictionary(),
            "updated": updated,
            "history": history.map { $0.asDictionary() },
            "runtime": runtime,
        ]
    }
}

/// Preferred name for the continuous stream frame payload.
public typealias LiveTelemetryFrame = TelemetrySnapshot

// MARK: - UI strip models (parity with old sys-strip)

public struct SysStripModel: Sendable, Equatable {
    public var cpuPercent: Double
    public var freqMHz: Int?
    public var ramPercent: Double
    public var gpuPercent: Double?
    public var diskReadMBs: Double
    public var diskWriteMBs: Double
    public var diskTotalMBs: Double
    public var cpuBrand: String
    public var loadM1: Double

    public init(from system: SystemMetrics) {
        cpuPercent = system.cpu.percent
        freqMHz = system.cpu.freqMHz
        ramPercent = system.ram.percent
        gpuPercent = system.gpu.first?.utilGPU
        diskReadMBs = system.diskIO.readMBs
        diskWriteMBs = system.diskIO.writeMBs
        diskTotalMBs = system.diskIO.totalMBs
        cpuBrand = system.cpu.brand
        loadM1 = system.cpu.loadAvg.m1
    }
}
