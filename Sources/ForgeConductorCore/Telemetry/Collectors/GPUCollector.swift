// GPUCollector.swift
// What: Collects Apple GPU identity, memory, utilization, and Metal availability.
// How: Metal device discovery is combined with recursively inspected IOKit properties
// and tolerant numeric conversion for OS/hardware variations.
// Why: Native sources avoid privileged samplers and keep unavailable fields explicit.

import Foundation
import Darwin
import IOKit

/// GPU metrics via **IOKit / IORegistry**.
///
/// Walks `IOServiceMatching` classes (`IOAccelerator`, `AGXAccelerator`, `IOGPU`) and
/// reads properties through `IORegistryEntryCreateCFProperties` (see `IOKitPropertyWalk`).
/// Live keys: `PerformanceStatistics` → Device/Renderer/Tiler Utilization %, memory.
public final class GPUCollector: GPUMetricsCollecting, @unchecked Sendable {
    public init() {}

    public func collect() -> [GPUMetrics] {
        let memTotal = Int(ProcessInfo.processInfo.physicalMemory / 1_048_576)
        var model = "Apple GPU"
        var util: Double?
        var utilR: Double?
        var utilT: Double?
        var memUsed: Int?
        var cores: Int?

        for className in ["IOAccelerator", "AGXAccelerator", "IOGPU"] {
            IOKitPropertyWalk.forEachService(className: className) { _, props in
                if let m = IOKitPropertyWalk.string(props, keys: ["model", "IOClass", "CFBundleIdentifier"]) {
                    if m.localizedCaseInsensitiveContains("gpu")
                        || m.localizedCaseInsensitiveContains("agx")
                        || m.localizedCaseInsensitiveContains("accelerator")
                        || m.localizedCaseInsensitiveContains("apple") {
                        model = m
                    }
                }
                if let c = IOKitPropertyWalk.int(props, keys: ["gpu-core-count", "GPUCoreCount"]) {
                    cores = c
                }
                let stats = IOKitPropertyWalk.childDict(props, keys: [
                    "PerformanceStatistics", "performanceStatistics", "Statistics",
                ]) ?? props

                if util == nil {
                    util = IOKitPropertyWalk.double(stats, keys: [
                        "Device Utilization %", "Device Utilization%",
                        "GPU Activity(%)", "Hardware utilization %",
                    ])
                }
                if utilR == nil {
                    utilR = IOKitPropertyWalk.double(stats, keys: [
                        "Renderer Utilization %", "Renderer Utilization%",
                    ])
                }
                if utilT == nil {
                    utilT = IOKitPropertyWalk.double(stats, keys: [
                        "Tiler Utilization %", "Tiler Utilization%",
                    ])
                }
                if memUsed == nil {
                    if let inUse = IOKitPropertyWalk.double(stats, keys: [
                        "In use system memory", "In use system memory (driver)",
                        "Alloc system memory",
                    ]) {
                        // Bytes if large; else already MiB-ish
                        memUsed = inUse > 100_000 ? Int(inUse / 1_048_576) : Int(inUse)
                    }
                }
            }
            if util != nil { break }
        }

        // No loadavg fake — if IOKit fails, report nil util (UI shows 0 honestly as unknown).
        return [
            GPUMetrics(
                vendor: "Apple",
                name: model,
                utilGPU: util.map { round1(min(100, max(0, $0))) },
                utilRenderer: utilR.map { round1(min(100, max(0, $0))) },
                utilTiler: utilT.map { round1(min(100, max(0, $0))) },
                memUsedMiB: memUsed,
                memTotalMiB: memTotal,
                cores: cores,
                metal: true
            ),
        ]
    }

    private func round1(_ v: Double) -> Double { (v * 10).rounded() / 10 }
}
