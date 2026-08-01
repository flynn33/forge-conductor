// CPUFrequencyEstimator.swift
// What: Estimates effective CPU frequency for Apple silicon performance clusters.
// How: It combines IOKit frequency properties, active-core distribution, and optional
// utilization weights into stable per-cluster and overall values.
// Why: macOS does not expose one universally reliable current-frequency API.

import Foundation
import Darwin

/// Live-ish CPU frequency for Apple Silicon and Intel.
///
/// Public sysctl `hw.cpufrequency` is typically unavailable on Apple Silicon.
/// Private IOReport DVFS channels exist but are unstable/entitlement-sensitive across OS builds.
///
/// Strategy (EP-safe, no subprocess, no private IOReport):
/// 1. Prefer live sysctl when present (Intel / rare AS builds).
/// 2. Else compute **effective frequency** from per-core utilization weighted by
///    P/E cluster peak clocks (`hw.perflevel*`) and chip nominal peaks.
/// 3. Idle cores use cluster floor clocks so FREQ is never a static peak sticker.
public enum CPUFrequencyEstimator {
    public struct Estimate: Sendable, Equatable {
        public var averageMHz: Int
        public var perCoreMHz: [Int]
        public var source: String
        public var peakPMHz: Int
        public var peakEMHz: Int
        public var pCoreCount: Int
        public var eCoreCount: Int
    }

    public static func estimate(
        brand: String,
        model: String?,
        perCoreUtilization: [Double]
    ) -> Estimate {
        // Prefer the utilization sample length (matches host_processor_info core list).
        let logical = perCoreUtilization.isEmpty
            ? ProcessInfo.processInfo.processorCount
            : perCoreUtilization.count
        var pCount = sysctlInt("hw.perflevel0.physicalcpu")
            ?? sysctlInt("hw.perflevel0.logicalcpu")
            ?? logical
        var eCount = sysctlInt("hw.perflevel1.physicalcpu")
            ?? sysctlInt("hw.perflevel1.logicalcpu")
            ?? max(0, logical - pCount)
        // Clamp cluster counts to the sample width under test / partial lists.
        if pCount + eCount != logical {
            if pCount >= logical {
                pCount = logical
                eCount = 0
            } else {
                eCount = max(0, logical - pCount)
            }
        }

        let peaks = peakClocks(brand: brand, model: model ?? sysctlString("hw.model"))
        let pPeak = peaks.p
        let ePeak = peaks.e
        // Floor clocks ~ DVFS idle (approx; better than reporting peak when idle)
        let pFloor = max(600, pPeak / 3)
        let eFloor = max(400, ePeak / 3)

        if let live = liveSysctlMHz() {
            let per = Array(repeating: live, count: max(logical, 1))
            return Estimate(
                averageMHz: live,
                perCoreMHz: per,
                source: "sysctl",
                peakPMHz: pPeak,
                peakEMHz: ePeak,
                pCoreCount: pCount,
                eCoreCount: eCount
            )
        }

        var per = [Int]()
        per.reserveCapacity(max(logical, 1))
        var weighted = 0.0
        var weight = 0.0

        for i in 0..<max(logical, 1) {
            let util = i < perCoreUtilization.count
                ? min(max(perCoreUtilization[i] / 100.0, 0), 1)
                : 0
            // Apple lists Performance cores first in host_processor_info on AS.
            let isP = i < pCount
            let peak = isP ? pPeak : ePeak
            let floor = isP ? pFloor : eFloor
            // Effective clock for this core between floor and peak by utilization.
            let mhz = Int((Double(floor) + Double(peak - floor) * util).rounded())
            per.append(mhz)
            // Weight busier cores more for the strip average (matches "how hard is the chip working").
            let w = 0.15 + util
            weighted += Double(mhz) * w
            weight += w
        }

        let avg = weight > 0 ? Int((weighted / weight).rounded()) : pPeak
        return Estimate(
            averageMHz: avg,
            perCoreMHz: per,
            source: "cluster-util-effective",
            peakPMHz: pPeak,
            peakEMHz: ePeak,
            pCoreCount: pCount,
            eCoreCount: eCount
        )
    }

    // MARK: - Peaks

    private static func peakClocks(brand: String, model: String?) -> (p: Int, e: Int) {
        let b = brand.lowercased()
        let m = (model ?? "").lowercased()
        let table: [(String, Int, Int)] = [
            // (match, P-peak MHz, E-peak MHz)
            ("m4 max", 4500, 2600),
            ("m4 pro", 4500, 2600),
            ("m4", 4400, 2500),
            ("m3 max", 4050, 2750),
            ("m3 pro", 4050, 2750),
            ("m3", 4050, 2750),
            ("m2 ultra", 3500, 2400),
            ("m2 max", 3670, 2400),
            ("m2 pro", 3500, 2400),
            ("m2", 3500, 2400),
            ("m1 ultra", 3200, 2100),
            ("m1 max", 3200, 2100),
            ("m1 pro", 3220, 2100),
            ("m1", 3200, 2100),
        ]
        for (key, p, e) in table {
            if b.contains(key) || m.contains(key.replacingOccurrences(of: " ", with: "")) {
                return (p, e)
            }
        }
        if m.hasPrefix("mac16") || m.hasPrefix("mac17") { return (4500, 2600) }
        if m.hasPrefix("mac15") { return (4050, 2750) }
        if m.hasPrefix("mac14") { return (3500, 2400) }
        if m.hasPrefix("mac13") || m.contains("macbookpro18") || m.contains("macbookair10") {
            return (3200, 2100)
        }
        #if arch(arm64)
        return (3200, 2100)
        #else
        if let live = liveSysctlMHz() { return (live, live) }
        return (3000, 3000)
        #endif
    }

    private static func liveSysctlMHz() -> Int? {
        if let hz = sysctlUInt64("hw.cpufrequency"), hz > 100_000_000 {
            return Int(hz / 1_000_000)
        }
        if let hz = sysctlUInt64("hw.cpufrequency_max"), hz > 100_000_000 {
            return Int(hz / 1_000_000)
        }
        if let mhz = sysctlInt("hw.cpufrequency_max"), mhz > 1000 {
            // Some systems store already in Hz-scale int
            return mhz > 100_000 ? mhz / 1_000_000 : mhz
        }
        return nil
    }

    // MARK: - sysctl

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 1 else { return nil }
        var buf = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buf, &size, nil, 0) == 0 else { return nil }
        return String(decoding: buf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    private static func sysctlInt(_ name: String) -> Int? {
        var v: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname(name, &v, &size, nil, 0) == 0 else { return nil }
        return Int(v)
    }

    private static func sysctlUInt64(_ name: String) -> UInt64? {
        var v: UInt64 = 0
        var size = MemoryLayout<UInt64>.size
        guard sysctlbyname(name, &v, &size, nil, 0) == 0 else { return nil }
        return v
    }
}
