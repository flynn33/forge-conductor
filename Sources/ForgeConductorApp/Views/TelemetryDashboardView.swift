// TelemetryDashboardView.swift
// What: Presents the typed system-telemetry overview outside the dense rig layout.
// How: It derives native cards and charts from AppModel's latest composed frame.
// Why: A separate module supports focused inspection while reusing the same data owner.

import SwiftUI
import ForgeConductorCore

/// Presents the general-purpose telemetry dashboard from typed, observable metrics.
///
/// It composes reusable cards and Metal charts but does not collect data itself;
/// `AppModel` owns sampling and publishes a coherent frame for the entire view.
struct TelemetryDashboardView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                metricsStrip
                MultiSeriesLoadChart(
                    cpu: model.historyCPU,
                    ram: model.historyRAM,
                    gpu: model.historyGPU
                )
                    .frame(height: 160)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(Color.cyan.opacity(0.35), lineWidth: 1)
                    )
                orchestrationSection
                HStack(alignment: .top, spacing: 14) {
                    processPanel
                    storagePanel
                }
            }
            .padding(20)
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("TELEMETRY")
                    .font(.system(.title2, design: .rounded).weight(.bold))
                    .foregroundStyle(Color.cyan)
                Text(model.hostName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 16)
            statusPill(
                text: model.orchestration?.healthLabel ?? "—",
                tone: TelemetryHealth.tone(for: model.orchestration?.health)
            )
        }
    }

    private var metricsStrip: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 14)], spacing: 14) {
            metricCard("CPU", value: model.cpuPercent, unit: "%", tint: .cyan)
            metricCard("RAM", value: model.ramPercent, unit: "%", tint: .orange)
            metricCard("GPU", value: model.gpuPercent, unit: "%", tint: .green)
            metricCard("MCP", value: Double(model.mcpServerCards.count), unit: "", tint: .purple, asInt: true)
            metricCard(
                "AGENTS",
                value: Double(model.agentCards.filter(\.live).count),
                unit: "live",
                tint: .mint,
                asInt: true
            )
        }
    }

    private func metricCard(
        _ title: String,
        value: Double?,
        unit: String,
        tint: Color,
        asInt: Bool = false
    ) -> some View {
        let resolvedValue = value ?? 0
        let displayValue = value.map {
            asInt ? "\(Int($0))" : String(format: "%.1f", $0)
        } ?? "—"
        let displayTint: Color = value == nil ? .gray : tint
        return VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(displayValue)
                    .font(.system(.title, design: .monospaced).weight(.bold))
                    .foregroundStyle(displayTint)
                Text(value == nil ? "" : unit)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.08))
                    Capsule()
                        .fill(displayTint.opacity(0.85))
                        .frame(
                            width: geo.size.width
                                * CGFloat(min(max(resolvedValue / 100.0, 0), 1))
                        )
                }
            }
            .frame(height: 6)
            .opacity(asInt ? 0 : (value == nil ? 0.35 : 1))
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(tint.opacity(0.25), lineWidth: 1)
        )
    }

    private var orchestrationSection: some View {
        let o = model.orchestration
        return VStack(alignment: .leading, spacing: 12) {
            Text("ORCHESTRATION")
                .font(.headline)
            HStack(spacing: 12) {
                orchCard("MODE", o?.mode ?? "—")
                orchCard("MANAGER", o?.managerAlive == true ? "UP" : "DOWN")
                orchCard("MCP PROCS", "\(o?.mcpExternalCount ?? 0)")
                orchCard("SERVE", "\(o?.serveCount ?? 0)")
                orchCard("HEALTH", o?.healthLabel ?? "—")
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor)))
    }

    private func orchCard(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.system(.body, design: .monospaced).weight(.semibold))
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.1)))
    }

    private var processPanel: some View {
        let procs = model.hotProcesses
        return VStack(alignment: .leading, spacing: 10) {
            Text("HOT PROCESSES").font(.headline)
            if procs.isEmpty {
                Text("No matching processes").foregroundStyle(.secondary).font(.caption)
            } else {
                ForEach(Array(procs.prefix(8).enumerated()), id: \.offset) { _, p in
                    HStack(spacing: 10) {
                        Text("\(p.pid)")
                            .font(.system(.caption, design: .monospaced))
                            .frame(width: 56, alignment: .leading)
                        Text(p.name)
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        Text(String(format: "%.1f%%", p.cpuPercent))
                            .font(.system(.caption, design: .monospaced))
                        Text(String(format: "%.2f GB", p.rssGB))
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor)))
    }

    private var storagePanel: some View {
        let disks = model.diskVolumes
        let io = model.diskIO
        return VStack(alignment: .leading, spacing: 10) {
            Text("STORAGE").font(.headline)
            Text(String(format: "IO %.1f MB/s (R %.1f / W %.1f)", io.totalMBs, io.readMBs, io.writeMBs))
                .font(.caption)
                .foregroundStyle(.secondary)
            ForEach(Array(disks.prefix(4).enumerated()), id: \.offset) { _, d in
                HStack(spacing: 10) {
                    Text(d.mount)
                        .font(.system(.caption, design: .monospaced))
                    Spacer(minLength: 8)
                    Text(String(format: "%.0f%%", d.percent))
                        .font(.system(.caption, design: .monospaced))
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor)))
    }

    private func statusPill(text: String, tone: TelemetryStatusTone) -> some View {
        Text(text)
            .font(.caption.weight(.bold))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Capsule().fill(tone.color.opacity(0.2)))
            .foregroundStyle(tone.color)
            .accessibilityValue(tone.rawValue)
    }
}
