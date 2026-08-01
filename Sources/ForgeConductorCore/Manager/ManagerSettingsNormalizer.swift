// ManagerSettingsNormalizer.swift
// What: Validates and canonicalizes incoming manager configuration patches.
// How: It clamps numeric ranges, normalizes host/boolean values, and emits a typed patch.
// Why: Every settings entry path must enforce the same safe operating limits.

import Foundation

/// Pure settings-patch normalization (no process state).
public enum ManagerSettingsNormalizer {
    public static func normalize(_ patch: [String: Any]) -> [String: Any] {
        var normalized: [String: Any] = [:]
        if let dash = patch["dashboard"] as? [String: Any] {
            var d: [String: Any] = [:]
            if let host = dash["host"] as? String {
                let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
                if DashboardRequestPolicy.isConfiguredLoopbackHost(trimmed) {
                    d["host"] = trimmed
                }
            }
            if let port = intValue(dash["port"]), (1...65_535).contains(port) {
                d["port"] = port
            }
            // Dashboard HTML refresh only — host telemetry is continuous via RealtimeMetricsEngine.
            if let refresh = intValue(dash["refresh_interval_sec"]) {
                d["refresh_interval_sec"] = min(max(refresh, 2), 300)
            }
            if !d.isEmpty { normalized["dashboard"] = d }
        }
        if let mgr = patch["manager"] as? [String: Any] {
            var m: [String: Any] = [:]
            if let v = mgr["auto_restart"] as? Bool { m["auto_restart"] = v }
            if let v = mgr["open_browser_on_start"] as? Bool { m["open_browser_on_start"] = v }
            if let v = intValue(mgr["watchdog_interval_sec"]) {
                m["watchdog_interval_sec"] = min(max(v, 1), 60)
            }
            if !m.isEmpty { normalized["manager"] = m }
        }
        if let sessions = patch["sessions"] as? [String: Any] {
            var s: [String: Any] = [:]
            if let ttl = intValue(sessions["idle_ttl_sec"]), ttl >= 60 {
                s["idle_ttl_sec"] = ttl
            }
            if !s.isEmpty { normalized["sessions"] = s }
        }
        if let shell = patch["shell"] as? [String: Any] {
            var s: [String: Any] = [:]
            if let t = intValue(shell["default_timeout_sec"]) {
                s["default_timeout_sec"] = min(max(t, 1), 600)
            }
            if !s.isEmpty { normalized["shell"] = s }
        }
        if let level = patch["log_level"] as? String {
            normalized["log_level"] = level
        }
        return normalized
    }

    public static func intValue(_ any: Any?) -> Int? {
        if let i = any as? Int { return i }
        if let d = any as? Double { return Int(d) }
        if let s = any as? String { return Int(s) }
        if let n = any as? NSNumber { return n.intValue }
        return nil
    }
}
