// RigDashboardView.swift
// What: Builds the real-time host and orchestration instrument panel.
// How: A display-cadence TimelineView projects AppModel telemetry into modular Metal
// gauges, charts, process panels, MCP cards, and event summaries.
// Why: The rig provides one coherent operational view without slowing Core sampling.

import SwiftUI
import ForgeConductorCore

/// Single-screen FORGE RIG board — full panel parity; **all gauges are Metal**.
/// Display updates continuously from the realtime metrics engine (not a 2s snapshot).
struct RigDashboardView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        // TimelineView drives UI at animation/display cadence against the continuous engine.
        TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: !model.autoRefresh)) { _ in
            rigContent
        }
    }

    private var rigContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                headerPills
                sysStrip
                MultiSeriesLoadChart(
                    cpu: model.historyCPU,
                    ram: model.historyRAM,
                    gpu: model.historyGPU
                )
                .frame(height: 168)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.cyan.opacity(0.35), lineWidth: 1))
                .overlay(alignment: .topLeading) {
                    Text("LOAD TRACE  ·  Metal  ·  REAL-TIME  ·  \(model.telemetryModeLabel)")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.cyan.opacity(0.8))
                        .padding(10)
                }

                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 260), spacing: 14, alignment: .top)],
                    alignment: .leading,
                    spacing: 14
                ) {
                    coreBarsPanel
                    gpuCoresPanel
                    storagePanel
                }
                .frame(minHeight: 190)

                orchestrationPanel

                HStack(alignment: .top, spacing: 14) {
                    mcpServersPanel
                    mcpToolsPanel
                }
                .frame(minHeight: 220)

                HStack(alignment: .top, spacing: 14) {
                    agentsPanel
                    processesPanel
                }
                .frame(minHeight: 200)

                liveFeedPanel
            }
            .padding(18)
        }
        .background(Color(red: 0.008, green: 0.016, blue: 0.04))
    }

    // MARK: Header

    private var headerPills: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("FORGE RIG // LM STUDIO")
                    .font(.system(.title3, design: .rounded).weight(.bold))
                    .foregroundStyle(Color.cyan)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                    .accessibilityIdentifier("detail-rig")
                Text("LOCAL MODELS · GPU · DISK · LM STUDIO MCP · LIVE FEED · METAL")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .layoutPriority(1)

            // Fixed-width chip strip: 4×80 + 3×6 spacing = 338pt — never grows with MTKView.
            HStack(spacing: 6) {
                MetalStatusPill(
                    text: "LINK",
                    tone: model.lastError == nil ? .healthy : .failure,
                    fraction: 1
                )
                MetalStatusPill(
                    text: "ORCH \(model.orchestration?.healthLabel ?? "—")",
                    tone: TelemetryHealth.tone(for: model.orchestration?.health),
                    fraction: model.orchestration?.health == "ok" ? 1 : 0.25
                )
                MetalStatusPill(
                    text: "MCP \(model.mcpServerCards.filter(\.live).count)/\(model.mcpServerCards.count)",
                    tone: mcpHeaderTone,
                    fraction: model.mcpServerCards.isEmpty ? 0 : Double(model.mcpServerCards.filter(\.live).count) / Double(model.mcpServerCards.count)
                )
                MetalStatusPill(
                    text: String(format: "LOAD %.0f", model.cpuPercent),
                    tone: model.cpuPercent < 90 ? .healthy : .caution,
                    fraction: min(model.cpuPercent / 100, 1)
                )
            }
            .fixedSize(horizontal: true, vertical: true)
            .layoutPriority(0)
        }
    }

    // MARK: Sys strip — Metal bars only

    private var sysStrip: some View {
        let s = model.sysStrip
        let gpuValue = s.gpuPercent.map { String(format: "%.1f%%", $0) } ?? "—"
        let gpuFraction = s.gpuPercent.map { $0 / 100 } ?? 0
        let gpuMetadata = s.gpuPercent == nil ? "telemetry unavailable" : "Metal IOKit"
        let gpuTint: Color = s.gpuPercent == nil ? .gray : .green
        return LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: 12)], spacing: 12) {
            sysCard("CPU", value: String(format: "%.1f%%", s.cpuPercent), meta: s.cpuBrand, frac: s.cpuPercent / 100, tint: .cyan)
            sysCard("FREQ", value: s.freqMHz.map { "\($0)" } ?? "—", meta: "MHz · load \(String(format: "%.2f", s.loadM1))", frac: min((Double(s.freqMHz ?? 0) / 4000), 1), tint: .mint)
            sysCard("RAM", value: String(format: "%.1f%%", s.ramPercent), meta: "pressure", frac: s.ramPercent / 100, tint: .orange)
            sysCard(
                "GPU",
                value: gpuValue,
                meta: gpuMetadata,
                frac: gpuFraction,
                tint: gpuTint
            )
            sysCard(
                "DISK I/O",
                value: String(format: "%.1f", s.diskTotalMBs),
                meta: String(format: "R %.1f · W %.1f MB/s", s.diskReadMBs, s.diskWriteMBs),
                frac: min(s.diskTotalMBs / 200, 1),
                tint: .purple
            )
        }
    }

    private func sysCard(_ title: String, value: String, meta: String, frac: Double, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(.title2, design: .monospaced).weight(.bold))
                .foregroundStyle(tint)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            MetalBarGauge(fraction: frac, tint: tint)
                .frame(height: 14)
                .clipShape(Capsule())
            Text(meta)
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.04)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(tint.opacity(0.25), lineWidth: 1))
    }

    // MARK: CPU cores — Metal

    private var coreBarsPanel: some View {
        let cores = model.perCPU
        return panel("CPU CORES", meta: "\(cores.count) logical · Metal") {
            if cores.isEmpty {
                Text("NO PER-CORE DATA").font(.caption).foregroundStyle(.secondary)
            } else {
                MetalCoreBarsView(cores: cores)
                    .frame(height: 100)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
        }
    }

    private var gpuCoresPanel: some View {
        let gpu = model.system?.gpu.first
        let coreCount = max(gpu?.cores ?? 0, 0)
        return panel(
            "GPU CORES",
            meta: coreCount > 0 ? "\(coreCount) cores · aggregate engines" : "count unavailable"
        ) {
            if let gpu {
                if coreCount > 0 {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 24), spacing: 5)],
                        alignment: .leading,
                        spacing: 5
                    ) {
                        ForEach(0..<coreCount, id: \.self) { index in
                            Text("\(index + 1)")
                                .font(.system(size: 8, weight: .semibold, design: .monospaced))
                                .foregroundStyle(Color.purple.opacity(0.9))
                                .frame(maxWidth: .infinity, minHeight: 18)
                                .background(
                                    RoundedRectangle(cornerRadius: 3)
                                        .fill(Color.purple.opacity(0.08))
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 3)
                                        .stroke(Color.purple.opacity(0.35), lineWidth: 1)
                                )
                        }
                    }
                    .accessibilityLabel("\(coreCount) GPU cores")
                }

                HStack(spacing: 10) {
                    gpuEngineStat("DEVICE", gpu.utilGPU)
                    gpuEngineStat("RENDER", gpu.utilRenderer)
                    gpuEngineStat("TILER", gpu.utilTiler)
                }
                .padding(.top, coreCount > 0 ? 6 : 0)

                Text("Core tiles show topology; macOS exposes aggregate engine load, not per-core utilization.")
                    .font(.system(size: 8, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("NO GPU DATA")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func gpuEngineStat(_ label: String, _ percent: Double?) -> some View {
        let measured = percent != nil
        let value = percent ?? 0
        return VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 8, design: .monospaced))
                .foregroundStyle(.secondary)
            Text(measured ? String(format: "%.0f%%", value) : "—")
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(measured ? Color.purple : Color.secondary)
            MetalBarGauge(
                fraction: measured ? min(max(value / 100, 0), 1) : 0,
                tint: measured ? .purple : .secondary
            )
            .frame(height: 6)
            .clipShape(Capsule())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Storage — Metal meters

    private var storagePanel: some View {
        let disks = model.diskVolumes
        let io = model.diskIO
        return panel("STORAGE", meta: String(format: "%.1f MB/s total", io.totalMBs)) {
            HStack(spacing: 14) {
                ioStat("READ", io.readMBs, io.readIOPS, frac: min(io.readMBs / 100, 1), tint: .cyan)
                ioStat("WRITE", io.writeMBs, io.writeIOPS, frac: min(io.writeMBs / 100, 1), tint: .orange)
                ioStat("TOTAL", io.totalMBs, io.totalIOPS, frac: min(io.totalMBs / 200, 1), tint: .purple)
            }
            .padding(.bottom, 10)
            if disks.isEmpty {
                Text("NO VOLUME DATA").font(.caption).foregroundStyle(.secondary)
            } else {
                VStack(spacing: 8) {
                    ForEach(Array(disks.prefix(4).enumerated()), id: \.offset) { _, d in
                        VStack(alignment: .leading, spacing: 5) {
                            HStack(spacing: 8) {
                                Text(d.mount).font(.system(size: 11, design: .monospaced))
                                Spacer(minLength: 8)
                                Text(String(format: "%.0f/%.0f GB · %.0f%%", d.usedGB, d.totalGB, d.percent))
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(.secondary)
                            }
                            MetalBarGauge(fraction: d.percent / 100, tint: .cyan)
                                .frame(height: 10)
                                .clipShape(Capsule())
                        }
                    }
                }
            }
        }
    }

    private func ioStat(_ title: String, _ mbs: Double, _ iops: Double, frac: Double, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary)
            Text(String(format: "%.1f MB/s", mbs)).font(.system(size: 11, weight: .bold, design: .monospaced)).foregroundStyle(tint)
            MetalBarGauge(fraction: frac, tint: tint).frame(height: 8).clipShape(Capsule())
            Text(String(format: "%.0f IOPS", iops)).font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Orchestration

    private var orchestrationPanel: some View {
        let o = model.orchestration
        let mode = o?.mode ?? "—"
        let cards: [OrchestrationCardState] = {
            if mode == "swift-manager" || o?.managerAlive == true {
                let mcpN = Double(o?.mcpExternalCount ?? 0)
                let alive = o?.managerAlive == true
                return [
                    OrchestrationCardState(
                        title: "MANAGER",
                        state: alive ? "UP" : "DOWN",
                        detail: "swift",
                        fraction: alive ? 1 : 0,
                        tone: alive ? .healthy : .failure
                    ),
                    OrchestrationCardState(
                        title: "HTTP",
                        state: model.serviceActive ? "UP" : (alive ? "CHECK" : "DOWN"),
                        detail: model.serviceState,
                        fraction: model.serviceActive ? 1 : 0.35,
                        tone: model.serviceActive ? .healthy : (alive ? .caution : .failure)
                    ),
                    OrchestrationCardState(
                        title: "MCP PROCS",
                        state: mcpN > 0 ? "ACTIVE" : "IDLE",
                        detail: mcpN > 0 ? "\(Int(mcpN)) local" : "LM Studio starts on demand",
                        fraction: min(mcpN / 2, 1),
                        tone: mcpN > 0 ? .healthy : .informational
                    ),
                    OrchestrationCardState(
                        title: "SERVE",
                        state: (o?.serveCount ?? 0) > 0 ? "ACTIVE" : "IDLE",
                        detail: (o?.serveCount ?? 0) > 0
                            ? "\(o?.serveCount ?? 0) stdio role(s)"
                            : "waiting for LM Studio",
                        fraction: min(Double(o?.serveCount ?? 0) / 2, 1),
                        tone: (o?.serveCount ?? 0) > 0 ? .healthy : .informational
                    ),
                    OrchestrationCardState(
                        title: "STATUS",
                        state: o?.healthLabel ?? "—",
                        detail: mode,
                        fraction: o?.health == "ok" ? 1 : 0.2,
                        tone: TelemetryHealth.tone(for: o?.health)
                    ),
                ]
            }
            return [
                OrchestrationCardState(
                    title: "STATUS",
                    state: o?.healthLabel ?? "—",
                    detail: mode,
                    fraction: o?.health == "ok" ? 1 : 0.2,
                    tone: TelemetryHealth.tone(for: o?.health)
                ),
            ]
        }()

        return panel("ORCHESTRATION", meta: "\(o?.healthLabel ?? "—") · \(mode)") {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 10)], spacing: 10) {
                ForEach(Array(cards.enumerated()), id: \.offset) { _, c in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 6) {
                            Text(c.title).font(.system(size: 10, weight: .bold, design: .monospaced))
                            Spacer(minLength: 6)
                            Text(c.state)
                                .font(.system(size: 9, weight: .bold, design: .monospaced))
                                .foregroundStyle(c.tone.color)
                        }
                        MetalBarGauge(fraction: c.fraction, tint: c.tone.color)
                            .frame(height: 8)
                            .clipShape(Capsule())
                        Text(c.detail)
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    .padding(10)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(c.tone.color.opacity(0.4), lineWidth: 1)
                    )
                    .accessibilityElement(children: .combine)
                    .accessibilityValue(c.tone.rawValue)
                }
            }
        }
    }

    // MARK: MCP servers — Metal rings

    private var mcpServersPanel: some View {
        let cards = model.mcpServerCards
        return panel("MCP SERVERS", meta: "\(cards.count) cards · Metal rings") {
            if cards.isEmpty {
                Text("NO MCP PRESENCE — WAITING FOR HEARTBEAT / PROCESS SCAN")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 10)], spacing: 10) {
                    ForEach(Array(cards.prefix(12).enumerated()), id: \.offset) { _, s in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 8) {
                                Text(s.label)
                                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                    .lineLimit(1)
                                Spacer(minLength: 8)
                                Text(s.healthLabel)
                                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                                    .foregroundStyle(healthColor(s.health))
                            }
                            HStack(alignment: .top, spacing: 12) {
                                MetalRingGaugeLabeled(
                                    fraction: s.activity / 100,
                                    tint: healthColor(s.health),
                                    centerText: "\(Int(s.activity))"
                                )
                                .frame(width: 56, height: 56)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("\(s.role) · \(s.status)\(s.live ? " · LINK" : "")")
                                        .font(.system(size: 9, design: .monospaced))
                                    Text(String(format: "%.1f evt/min · %d/5m · err %.2f", s.eventsPerMin, s.eventCount5m, s.errorRate))
                                        .font(.system(size: 8, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                    Text("pid \(s.pid.map(String.init) ?? "—") · \(s.source)")
                                        .font(.system(size: 8, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                    if !s.topTools.isEmpty {
                                        Text(s.topTools.joined(separator: " · "))
                                            .font(.system(size: 8, design: .monospaced))
                                            .foregroundStyle(.cyan.opacity(0.8))
                                            .lineLimit(1)
                                    }
                                    if !s.healthReason.isEmpty {
                                        Text(s.healthReason)
                                            .font(.system(size: 8, design: .monospaced))
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                }
                            }
                            MetalBarGauge(fraction: s.activity / 100, tint: healthColor(s.health))
                                .frame(height: 5)
                                .clipShape(Capsule())
                        }
                        .padding(10)
                        .background(RoundedRectangle(cornerRadius: 6).stroke(healthColor(s.health).opacity(0.35)))
                    }
                }
            }
        }
    }

    // MARK: MCP tools — Metal load tiles

    private var mcpToolsPanel: some View {
        let tools = model.toolCards
        let packs = model.toolPacks
        return panel("MCP TOOLS", meta: "\(tools.count) tools · Metal load tiers") {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Array(packs.prefix(12).enumerated()), id: \.offset) { _, p in
                        let active = Double(p.activeCount)
                        let total = max(Double(p.toolCount), 1)
                        VStack(spacing: 4) {
                            Text(p.pack)
                                .font(.system(size: 9, design: .monospaced))
                            MetalBarGauge(fraction: active / total, tint: .cyan)
                                .frame(width: 64, height: 6)
                                .clipShape(Capsule())
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(Capsule().stroke(Color.cyan.opacity(0.35)))
                    }
                }
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 60), spacing: 8)], spacing: 8) {
                ForEach(Array(tools.prefix(48).enumerated()), id: \.offset) { _, t in
                    MetalToolLoadTile(
                        shortLabel: String(t.shortLabel.prefix(6)),
                        activity: t.activity,
                        health: t.health,
                        loadTier: t.loadTier
                    )
                    .help("\(t.name) · \(t.pack) · \(t.healthLabel) · \(t.events1h)/1h · load \(t.loadTier)/3")
                }
            }
        }
    }

    // MARK: Agents — Metal rings

    private var agentsPanel: some View {
        let agents = model.agentCards
        return panel("SUB-AGENTS", meta: "\(agents.count) · Metal") {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 10)], spacing: 10) {
                ForEach(Array(agents.prefix(12).enumerated()), id: \.offset) { _, a in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) {
                            Text(a.agentID)
                                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                .lineLimit(1)
                            Spacer(minLength: 8)
                            Text(a.healthLabel)
                                .font(.system(size: 9, weight: .bold, design: .monospaced))
                                .foregroundStyle(healthColor(a.health))
                        }
                        HStack(alignment: .top, spacing: 10) {
                            MetalRingGaugeLabeled(
                                fraction: a.activity / 100,
                                tint: healthColor(a.health),
                                centerText: a.live ? "ON" : "SB"
                            )
                            .frame(width: 48, height: 48)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(a.status)
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                if let last = a.lastSessionStatus {
                                    Text("last \(last)")
                                        .font(.system(size: 8, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                }
                                if let sum = a.summary, !sum.isEmpty {
                                    Text(sum).font(.system(size: 8, design: .monospaced))
                                        .foregroundStyle(.secondary).lineLimit(2)
                                }
                            }
                        }
                        MetalBarGauge(fraction: a.activity / 100, tint: healthColor(a.health))
                            .frame(height: 6)
                            .clipShape(Capsule())
                    }
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 6).stroke(healthColor(a.health).opacity(0.35)))
                }
            }
        }
    }

    // MARK: Processes

    private var processesPanel: some View {
        panel("HOT PROCESSES", meta: "LM Studio · Forge · llama") {
            if model.hotProcesses.isEmpty {
                Text("NO MATCHING PROCESSES").font(.caption).foregroundStyle(.secondary)
            } else {
                VStack(spacing: 6) {
                    HStack(spacing: 10) {
                        Text("PID").frame(width: 52, alignment: .leading)
                        Text("NAME").frame(maxWidth: .infinity, alignment: .leading)
                        Text("CPU").frame(width: 100, alignment: .leading)
                        Text("RSS").frame(width: 48, alignment: .trailing)
                    }
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(.secondary)
                    ForEach(Array(model.hotProcesses.prefix(12).enumerated()), id: \.offset) { _, p in
                        HStack(spacing: 10) {
                            Text("\(p.pid)").frame(width: 52, alignment: .leading)
                            Text(p.name).frame(maxWidth: .infinity, alignment: .leading).lineLimit(1)
                            MetalBarGauge(fraction: min(p.cpuPercent / 100, 1), tint: p.cpuPercent > 50 ? .orange : .cyan)
                                .frame(width: 100, height: 8)
                                .clipShape(Capsule())
                            Text(String(format: "%.2fG", p.rssGB)).frame(width: 48, alignment: .trailing)
                        }
                        .font(.system(size: 10, design: .monospaced))
                    }
                }
            }
        }
    }

    // MARK: Live feed

    private var liveFeedPanel: some View {
        // Column budget (pt): ts 56 + status 36 + gap×3(24) + bar 40 + ms 44 = 200 fixed.
        // Tool name takes remaining width and truncates — never pushes past the panel.
        panel("LIVE STREAM ▮ TOOLS · AGENTS · DIAGNOSTICS", meta: "\(model.liveFeedEvents.count)") {
            VStack(alignment: .leading, spacing: 5) {
                ForEach(Array(model.liveFeedEvents.prefix(24).enumerated()), id: \.offset) { _, e in
                    HStack(spacing: 8) {
                        Text(String(e.timestamp.suffix(8)))
                            .foregroundStyle(.secondary)
                            .frame(width: 56, alignment: .leading)
                        Text(e.status)
                            .foregroundStyle(auditStatusColor(e.status))
                            .frame(width: 36, alignment: .leading)
                        Text(e.tool)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if let ms = e.durationMs {
                            MetalBarGauge(fraction: min(Double(ms) / 2000, 1), tint: .mint)
                                .frame(width: 40, height: 5)
                                .clipShape(Capsule())
                                .allowsHitTesting(false)
                            Text("\(ms)ms")
                                .foregroundStyle(.secondary)
                                .frame(width: 44, alignment: .trailing)
                        } else {
                            Color.clear.frame(width: 40 + 8 + 44, height: 5)
                        }
                    }
                    .font(.system(size: 10, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: 220, alignment: .topLeading)
            .clipped()
        }
    }

    // MARK: Helpers

    private struct OrchestrationCardState {
        var title: String
        var state: String
        var detail: String
        var fraction: Double
        var tone: TelemetryStatusTone
    }

    private var mcpHeaderTone: TelemetryStatusTone {
        TelemetryStatusTone.mostSevere(
            model.mcpServerCards.map { TelemetryHealth.tone(for: $0.health) }
        )
    }

    private func panel<Content: View>(_ title: String, meta: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Text("▸ \(title)")
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundStyle(Color.cyan)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                Spacer(minLength: 12)
                Text(meta)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .layoutPriority(1)
            }
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .clipped()
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.035)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.cyan.opacity(0.15), lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func healthColor(_ h: String) -> Color {
        TelemetryHealth.tone(for: h).color
    }

    private func auditStatusColor(_ status: String) -> Color {
        switch AuditOutcome(status: status) {
        case .success:
            return .green
        case .operationalError:
            return .red
        case .policyDenied:
            return .orange
        case .maintenanceWarning:
            return .yellow
        case .other:
            return .secondary
        }
    }
}
