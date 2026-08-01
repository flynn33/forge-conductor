// PowerSourcesCollector.swift
// What: Reports battery, power-source, charging, and thermal-pressure state.
// How: IOPowerSources and ProcessInfo values are normalized into a typed PowerMetrics record.
// Why: Power context explains performance changes without tying consumers to IOKit.

import Foundation
import IOKit
import IOKit.ps

/// System power path via IOKit **IOPowerSources**.
///
/// - `IOPSCopyPowerSourcesInfo`
/// - `IOPSCopyPowerSourcesList`
/// - `IOPSGetPowerSourceDescription`
/// - `IOPSCopyExternalPowerAdapterDetails` (AC adapter watts when present)
///
/// Read-only, non-blocking — safe on the realtime medium/full sample tier.
public final class PowerSourcesCollector: PowerMetricsCollecting, @unchecked Sendable {
    public init() {}

    public func collect() -> PowerMetrics {
        guard let blobRef = IOPSCopyPowerSourcesInfo() else {
            return .unknown
        }
        let blob = blobRef.takeRetainedValue()

        guard let listRef = IOPSCopyPowerSourcesList(blob) else {
            return .unknown
        }
        let list = listRef.takeRetainedValue() as [CFTypeRef]
        var onAC = false
        var state = "Unknown"
        var batteryPercent: Double?
        var isCharging: Bool?
        var isCharged: Bool?
        var timeToEmpty: Int?
        var timeToFull: Int?
        var providing: String?

        for ps in list {
            guard let descRef = IOPSGetPowerSourceDescription(blob, ps) else { continue }
            let desc = descRef.takeUnretainedValue() as NSDictionary

            let present = (desc[kIOPSIsPresentKey] as? Bool) ?? true
            guard present else { continue }

            if let name = desc[kIOPSNameKey] as? String {
                providing = providing ?? name
            }
            if let st = desc[kIOPSPowerSourceStateKey] as? String {
                state = st
                if st == kIOPSACPowerValue {
                    onAC = true
                }
                if st == kIOPSBatteryPowerValue {
                    onAC = false
                }
            }
            // Capacity
            if let cur = number(desc[kIOPSCurrentCapacityKey]),
               let maxCap = number(desc[kIOPSMaxCapacityKey]), maxCap > 0 {
                batteryPercent = Swift.min(100, Swift.max(0, 100.0 * cur / maxCap))
            } else if let cur = number(desc[kIOPSCurrentCapacityKey]), cur <= 100 {
                batteryPercent = cur
            }
            if let v = desc[kIOPSIsChargingKey] as? Bool {
                isCharging = v
                if v { onAC = true }
            }
            if let v = desc[kIOPSIsChargedKey] as? Bool {
                isCharged = v
            }
            if let t = number(desc[kIOPSTimeToEmptyKey]), t > 0, t < 1_000_000 {
                timeToEmpty = Int(t)
            }
            if let t = number(desc[kIOPSTimeToFullChargeKey]), t > 0, t < 1_000_000 {
                timeToFull = Int(t)
            }
        }

        // External adapter presence strengthens onAC.
        if let adapterRef = IOPSCopyExternalPowerAdapterDetails() {
            let adapter = adapterRef.takeRetainedValue() as NSDictionary
            if !adapter.allKeys.isEmpty {
                onAC = true
                if providing == nil {
                    providing = "External AC Adapter"
                }
                if let watts = number(adapter[kIOPSPowerAdapterWattsKey]) {
                    providing = "AC Adapter \(Int(watts))W"
                }
            }
        }

        // Unlimited remaining on AC is common desktops — treat as on AC.
        let remaining = IOPSGetTimeRemainingEstimate()
        if remaining == kIOPSTimeRemainingUnlimited {
            onAC = true
            if state == "Unknown" { state = kIOPSACPowerValue }
        }

        return PowerMetrics(
            onAC: onAC,
            state: state,
            batteryPercent: batteryPercent.map { ($0 * 10).rounded() / 10 },
            isCharging: isCharging,
            isCharged: isCharged,
            timeToEmptyMin: timeToEmpty,
            timeToFullMin: timeToFull,
            sourceCount: list.count,
            providingName: providing
        )
    }

    private func number(_ any: Any?) -> Double? {
        if let d = any as? Double { return d }
        if let n = any as? NSNumber { return n.doubleValue }
        if let i = any as? Int { return Double(i) }
        if let i = any as? Int64 { return Double(i) }
        return nil
    }
}
