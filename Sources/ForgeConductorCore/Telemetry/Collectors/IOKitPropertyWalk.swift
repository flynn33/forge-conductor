// IOKitPropertyWalk.swift
// What: Provides safe recursive lookup and numeric coercion for IOKit property trees.
// How: It walks nested dictionaries/arrays with bounded recursion and recognizes the
// numeric representations returned by different drivers.
// Why: Collectors share one compatibility layer instead of duplicating fragile casts.

import Foundation
import IOKit

/// Shared **IOKit / IORegistry** helpers.
///
/// - `IOServiceMatching` + `IOServiceGetMatchingServices` — locate services
/// - `IORegistryEntryCreateCFProperties` — read the IORegistry property plane
///
/// NSDictionary-safe: Swift `[String: Any]` casts often fail on nested CF types.
enum IOKitPropertyWalk {
    /// `IORegistryEntryCreateCFProperties` for a live `io_object_t` service.
    static func props(for service: io_object_t) -> NSDictionary? {
        var ref: Unmanaged<CFMutableDictionary>?
        let kr = IORegistryEntryCreateCFProperties(service, &ref, kCFAllocatorDefault, 0)
        guard kr == KERN_SUCCESS, let dict = ref?.takeRetainedValue() as NSDictionary? else { return nil }
        return dict
    }

    static func double(_ dict: NSDictionary, keys: [String]) -> Double? {
        for k in keys {
            if let v = dict[k] as? Double { return v }
            if let v = dict[k] as? NSNumber { return v.doubleValue }
            if let v = dict[k] as? Int { return Double(v) }
            if let v = dict[k] as? String, let d = Double(v) { return d }
        }
        return nil
    }

    static func u64(_ dict: NSDictionary, keys: [String]) -> UInt64? {
        for k in keys {
            if let v = dict[k] as? UInt64 { return v }
            if let v = dict[k] as? NSNumber { return v.uint64Value }
            if let v = dict[k] as? Int { return UInt64(v) }
            if let v = dict[k] as? Double { return UInt64(v) }
        }
        return nil
    }

    static func string(_ dict: NSDictionary, keys: [String]) -> String? {
        for k in keys {
            if let v = dict[k] as? String { return v }
            if let v = dict[k] as? NSString { return v as String }
            if let v = dict[k] as? Data, let s = String(data: v, encoding: .utf8) { return s }
        }
        return nil
    }

    static func int(_ dict: NSDictionary, keys: [String]) -> Int? {
        for k in keys {
            if let v = dict[k] as? Int { return v }
            if let v = dict[k] as? NSNumber { return v.intValue }
        }
        return nil
    }

    static func childDict(_ dict: NSDictionary, keys: [String]) -> NSDictionary? {
        for k in keys {
            if let d = dict[k] as? NSDictionary { return d }
            if let d = dict[k] as? [String: Any] { return d as NSDictionary }
        }
        return nil
    }

    /// Iterate all services of a class.
    static func forEachService(className: String, body: (io_object_t, NSDictionary) -> Void) {
        let matching = IOServiceMatching(className)
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else { return }
        defer { IOObjectRelease(iterator) }
        var service = IOIteratorNext(iterator)
        while service != 0 {
            defer {
                IOObjectRelease(service)
                service = IOIteratorNext(iterator)
            }
            if let p = props(for: service) {
                body(service, p)
            }
        }
    }
}
