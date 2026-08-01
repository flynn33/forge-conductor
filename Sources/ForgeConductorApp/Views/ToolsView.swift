// ToolsView.swift
// What: Lists registered tool modules, activity state, and health.
// How: It filters ToolCard projections locally and renders them with native List rows.
// Why: Discovery stays UI-only while authorization and execution remain in Core.

import SwiftUI
import ForgeConductorCore

/// Lists the registered tool surface and supports local name/category filtering.
///
/// Search state belongs to this view because it is transient presentation state;
/// authoritative tool metadata continues to come from `AppModel`.
struct ToolsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var filter = ""

    private var filtered: [ToolCard] {
        let all = model.toolCards
        guard !filter.isEmpty else { return all }
        return all.filter {
            $0.name.localizedCaseInsensitiveContains(filter)
                || $0.pack.localizedCaseInsensitiveContains(filter)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Text("Tools")
                    .font(.title2.weight(.bold))
                    .accessibilityIdentifier("detail-tools")
                Spacer(minLength: 12)
                TextField("Filter tools", text: $filter)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 240)
                Text("\(filtered.count)")
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 28, alignment: .trailing)
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)

            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "info.circle")
                    .foregroundStyle(.cyan)
                Text("READY means the tool is registered. IDLE is normal until a model invokes it. ERR is an execution failure, DEN is an authorization-policy outcome, and WARN is a maintenance advisory. DEN and WARN do not raise the operational error rate.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 16)

            List {
                ForEach(filtered) { t in
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(t.name)
                                .font(.system(.body, design: .monospaced))
                            Text(t.pack)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 12)
                        HStack(spacing: 4) {
                            outcomeBadges(t.outcomes1h)
                        }
                        .fixedSize(horizontal: true, vertical: false)
                        Text(t.status)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(statusColor(t.status))
                        Text(t.healthLabel)
                            .font(.caption2)
                            .foregroundStyle(TelemetryHealth.tone(for: t.health).color)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(
                                Capsule()
                                    .fill(TelemetryHealth.tone(for: t.health).color.opacity(0.1))
                            )
                        Text("\(t.events5m)/5m · \(t.events1h)/1h")
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                    .help(toolHelp(t))
                }
            }
            .listStyle(.inset)
        }
    }

    private func statusColor(_ s: String) -> Color {
        switch s {
        case "active": return .green
        case "warm": return .orange
        default: return .secondary
        }
    }

    private func toolHelp(_ tool: ToolCard) -> String {
        let healthDetail: String
        switch TelemetryHealth.tone(for: tool.health) {
        case .healthy:
            healthDetail = "Operational error rate is below the alert threshold."
        case .caution:
            healthDetail = "Recent operational errors exceed the warning threshold."
        case .failure:
            healthDetail = "Recent operational errors exceed the failure threshold."
        case .informational:
            healthDetail = "Configured and available on demand."
        case .unavailable:
            healthDetail = "Health evidence is unavailable."
        }
        let outcomes = tool.outcomes1h
        return "\(tool.name) · \(tool.pack) · \(tool.events5m) calls/5m · \(tool.events1h) calls/1h · \(outcomes.errorCount) operational errors · \(outcomes.deniedCount) policy denials · \(outcomes.warnCount) maintenance warnings. \(healthDetail)"
    }

    @ViewBuilder
    private func outcomeBadges(_ outcomes: AuditOutcomeCounts) -> some View {
        if outcomes.errorCount > 0 {
            outcomeBadge("ERR \(outcomes.errorCount)", color: .red)
        }
        if outcomes.deniedCount > 0 {
            outcomeBadge("DEN \(outcomes.deniedCount)", color: .orange)
        }
        if outcomes.warnCount > 0 {
            outcomeBadge("WARN \(outcomes.warnCount)", color: .yellow)
        }
    }

    private func outcomeBadge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .semibold, design: .monospaced))
            .foregroundStyle(color)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.12)))
    }
}
