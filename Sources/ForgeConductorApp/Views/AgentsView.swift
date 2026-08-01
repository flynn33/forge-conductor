// AgentsView.swift
// What: Displays the available agent playbooks and their live session health.
// How: It projects AgentCard values from AppModel into an adaptive native grid
// and routes maintenance actions back through the presentation model.
// Why: The view remains a declarative module with no direct storage dependencies.

import SwiftUI
import ForgeConductorCore

/// Renders the agent catalog and current agent-session health as adaptive cards.
///
/// All mutations are delegated to `AppModel`; this view only selects, formats, and
/// presents the state needed by the Agents feature module.
struct AgentsView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Text("Agents")
                    .font(.title2.weight(.bold))
                    .accessibilityIdentifier("detail-agents")
                Spacer(minLength: 12)
                Text("\(model.agentCards.count) catalog")
                    .foregroundStyle(.secondary)
                Button("Prune idle sessions") { model.pruneSessions() }
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)

            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 14)], spacing: 14) {
                    ForEach(model.agentCards) { a in
                        agentCard(a)
                    }
                }
                .padding(16)
            }
        }
    }

    private func agentCard(_ a: AgentCard) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(a.name)
                    .font(.headline)
                Spacer(minLength: 8)
                Text(a.healthLabel)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(a.live ? Color.green : Color.secondary)
            }
            Text(a.description.isEmpty ? a.agentID : a.description)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(3)
            if !a.tools.isEmpty {
                Text(a.tools.prefix(4).joined(separator: " · "))
                    .font(.caption2)
                    .foregroundStyle(.cyan)
                    .lineLimit(1)
            }
            Text(a.status)
                .font(.system(.caption, design: .monospaced))
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(a.live ? Color.green.opacity(0.4) : Color.primary.opacity(0.08), lineWidth: 1)
        )
    }
}
