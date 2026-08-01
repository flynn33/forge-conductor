// MCPServersView.swift
// What: Shows MCP connector health and exposes the complete LM Studio deploy action.
// How: Typed server cards and installer status come from AppModel; buttons invoke
// model methods that own transactional configuration, reload, and verification.
// Why: Connection side effects stay behind Core protocols instead of leaking into UI.

import SwiftUI
import ForgeConductorCore

/// Presents MCP server health and the transactional LM Studio deployment workflow.
///
/// The view reports installer and verification states while `AppModel` performs all
/// filesystem, process, reload, and connector work through Core abstractions.
struct MCPServersView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Text("LM Studio · MCP")
                    .font(.title2.weight(.bold))
                    .accessibilityIdentifier("detail-mcp")
                Spacer(minLength: 12)
                Text("\(model.mcpServerCards.filter(\.live).count) live · \(model.mcpServerCards.count) total")
                    .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    Button("Deploy to LM Studio") {
                        model.deployToLMStudio()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.isInstallingPlugin)
                    .help("Transactionally configure primary + failover, reload LM Studio, and verify both hosted connections")
                    .accessibilityIdentifier("mcp-deploy-lmstudio")

                    Button("Refresh") {
                        model.refreshLMStudioPluginStatus()
                        model.refresh(force: true)
                    }
                    Button("Prune presence") { model.prunePresence() }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)

            productFlowBanner
                .padding(.horizontal, 16)

            pluginStatusBanner
                .padding(.horizontal, 16)

            if model.mcpServerCards.isEmpty {
                ContentUnavailableView(
                    "No LM Studio MCP activity yet",
                    systemImage: "server.rack",
                    description: Text(
                        "Click Deploy to LM Studio. Forge writes and validates all required configuration, reloads LM Studio, and verifies both hosted connections automatically."
                    )
                )
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 240), spacing: 14)], spacing: 14) {
                        ForEach(model.mcpServerCards) { s in
                            serverCard(s)
                        }
                    }
                    .padding(16)
                }
            }
        }
        .onAppear {
            model.refreshLMStudioPluginStatus()
        }
    }

    private var productFlowBanner: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Product flow")
                .font(.caption.weight(.semibold))
            Text("Install LM Studio → Install Forge Conductor → Deploy to LM Studio (this button) → Use tools / agents.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("Deploy owns the complete operation: it writes main + failover configuration, triggers hot reload (or relaunches LM Studio), verifies LM Studio synchronized the exact revision, and independently checks both tool servers.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.accentColor.opacity(0.08))
        )
    }

    @ViewBuilder
    private var pluginStatusBanner: some View {
        let st = model.lmStudioPluginStatus
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: st?.isFullyInstalled == true ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(st?.isFullyInstalled == true ? Color.green : Color.orange)
                Text(st?.isFullyInstalled == true ? "LM Studio connection deployed" : "Not fully deployed to LM Studio")
                    .font(.headline)
                Spacer(minLength: 8)
                if model.isInstallingPlugin {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            Text(st?.detail ?? "Checking deploy status…")
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            if let msg = model.lmStudioPluginMessage, !msg.isEmpty {
                Text(msg)
                    .font(.caption)
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
            }
            HStack(spacing: 16) {
                labeledBit("main (primary)", st?.primaryPluginInstalled == true)
                labeledBit("failover", st?.fallbackPluginInstalled == true)
                labeledBit("mcp.json", st?.mcpJSONRegistered == true)
                labeledBit("serve binary", st?.binaryExecutable == true)
            }
            .font(.caption2)
            if let path = st?.binaryPath {
                Text("Serve binary: \(path)")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(2)
            }
            Text("No manual file editing or LM Studio restart is required. A deployment may relaunch LM Studio when hot reload cannot replace a stale plugin process; plugin selection remains a per-chat LM Studio choice.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(
                    (st?.isFullyInstalled == true ? Color.green : Color.orange).opacity(0.35),
                    lineWidth: 1
                )
        )
    }

    private func labeledBit(_ title: String, _ ok: Bool) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(ok ? Color.green : Color.red.opacity(0.7))
                .frame(width: 7, height: 7)
            Text(title)
                .foregroundStyle(.secondary)
        }
    }

    private func serverCard(_ s: MCPServerCard) -> some View {
        let tone = TelemetryHealth.tone(for: s.health)
        let color = tone.color

        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(serverDisplayName(s))
                    .font(.headline)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(s.healthLabel)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(color)
            }
            Text("\(s.hostKind) · \(s.status)")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Text("pid \(s.pid.map(String.init) ?? "—")")
                    .font(.system(.caption, design: .monospaced))
                Spacer(minLength: 8)
                Text(s.source)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if !s.healthReason.isEmpty {
                Text(s.healthReason)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            HStack(spacing: 5) {
                Circle()
                    .fill(color)
                    .frame(width: 8, height: 8)
                Text(s.live ? "live process" : (s.health == "config" ? "configured · starts on demand" : "not running"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(color.opacity(0.35), lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
        .accessibilityValue(tone.rawValue)
    }

    private func serverDisplayName(_ server: MCPServerCard) -> String {
        guard server.label.lowercased().contains("forge-conductor") else {
            return server.label
        }
        switch server.role {
        case "fallback": return "Forge Conductor · Failover"
        case "primary": return "Forge Conductor · Primary"
        default: return server.label
        }
    }
}
