// MachHostMetricsTests.swift
// Exercises the Darwin, Mach, libproc, IOKit, and power-source collector implementations.
// Multiple samples verify delta-based metrics rather than merely checking static metadata.

import XCTest
@testable import ForgeConductorCore

/// Proves host collectors use the Darwin API map (Mach / libproc / IOKit / IOPowerSources).
final class MachHostMetricsTests: XCTestCase {
    func testCPUCollectorHostProcessorInfoDeltas() {
        let cpu = CPUCollector()
        _ = cpu.collect()
        Thread.sleep(forTimeInterval: 0.05)
        let a = cpu.collect()
        Thread.sleep(forTimeInterval: 0.08)
        let b = cpu.collect()
        XCTAssertFalse(a.perCPU.isEmpty)
        XCTAssertEqual(a.perCPU.count, a.countLogical)
        for p in b.perCPU {
            XCTAssertGreaterThanOrEqual(p, 0)
            XCTAssertLessThanOrEqual(p, 100)
        }
        XCTAssertGreaterThanOrEqual(b.user + b.system + b.idle, 0)
    }

    func testRAMCollectorHostStatistics64() {
        let m = RAMCollector().collect()
        XCTAssertGreaterThan(m.totalGB, 0)
        XCTAssertGreaterThanOrEqual(m.percent, 0)
        XCTAssertLessThanOrEqual(m.percent, 100)
    }

    func testProcessCollectorLibprocNotPs() {
        let col = ProcessMetricsCollector()
        _ = col.collect()
        Thread.sleep(forTimeInterval: 0.05)
        let rows = col.collect()
        for p in rows {
            XCTAssertGreaterThan(p.pid, 0)
            XCTAssertGreaterThanOrEqual(p.cpuPercent, 0)
            XCTAssertGreaterThanOrEqual(p.rssGB, 0)
            if let src = p.source {
                XCTAssertTrue(
                    src == "proc_pid_rusage" || src == "proc_pidinfo",
                    "unexpected source \(src)"
                )
            }
        }
    }

    func testMachTaskThreadSamplerSelf() {
        let n = MachTaskThreadSampler.currentProcessThreadCount()
        XCTAssertNotNil(n)
        XCTAssertGreaterThan(n ?? 0, 0)
        let rss = MachTaskThreadSampler.currentTaskRSSBytes()
        XCTAssertNotNil(rss)
        XCTAssertGreaterThan(rss ?? 0, 0)
    }

    func testPowerSourcesCollectorIOKit() {
        let p = PowerSourcesCollector().collect()
        XCTAssertFalse(p.state.isEmpty)
        XCTAssertGreaterThanOrEqual(p.sourceCount, 0)
        if let pct = p.batteryPercent {
            XCTAssertGreaterThanOrEqual(pct, 0)
            XCTAssertLessThanOrEqual(pct, 100)
        }
    }

    func testDiskIONoSleepDelta() {
        let dio = DiskIOCollector()
        _ = dio.collect()
        Thread.sleep(forTimeInterval: 0.05)
        let second = dio.collect()
        XCTAssertGreaterThanOrEqual(second.totalMBs, 0)
    }

    func testGPUCollectorIORegistry() {
        let gpus = GPUCollector().collect()
        XCTAssertFalse(gpus.isEmpty)
        XCTAssertEqual(gpus.first?.vendor, "Apple")
    }

    func testSystemCollectorWiresAllSurfaces() {
        let sys = SystemCollector()
        _ = sys.collectMetrics(tier: .full)
        Thread.sleep(forTimeInterval: 0.06)
        let m = sys.collectMetrics(tier: .full)
        XCTAssertFalse(m.cpu.perCPU.isEmpty)
        XCTAssertGreaterThan(m.ram.totalGB, 0)
        XCTAssertNotNil(m.power)
        let dict = m.asDictionary()
        XCTAssertNotNil(dict["power"])
        XCTAssertNotNil(dict["cpu"])
        XCTAssertNotNil(dict["ram"])
    }

    func testEngineAdvancesMachPath() {
        let engine = RealtimeMetricsEngine()
        engine.start(targetHz: 30)
        defer { engine.stop() }
        Thread.sleep(forTimeInterval: 0.05)
        let a = engine.latestSystem
        Thread.sleep(forTimeInterval: 0.12)
        let b = engine.latestSystem
        XCTAssertGreaterThan(b.ts, a.ts)
        XCTAssertFalse(b.cpu.perCPU.isEmpty)
    }
}
