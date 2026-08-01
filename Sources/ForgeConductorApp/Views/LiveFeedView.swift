// LiveFeedView.swift
// What: Presents recent tool activity as a compact native event stream.
// How: It formats immutable LiveFeedEvent values supplied by AppModel in a SwiftUI List.
// Why: A read-only projection keeps audit collection independent of presentation.

import SwiftUI
import ForgeConductorCore

/// Displays recent audited tool executions without initiating collection or storage.
///
/// The view consumes presentation-ready events from `AppModel`, keeping timestamps,
/// status coloring, and truncation policy local to this module.
struct LiveFeedView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        let outcomes = AuditOutcomeCounts.summarize(
            statuses: model.liveFeedEvents.map(\.status)
        )
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Text("Live Feed")
                    .font(.title2.weight(.bold))
                    .accessibilityIdentifier("detail-feed")
                Spacer(minLength: 12)
                Text("\(model.liveFeedEvents.count) events · ERR \(outcomes.errorCount) · DEN \(outcomes.deniedCount) · WARN \(outcomes.warnCount)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)

            List {
                ForEach(Array(model.liveFeedEvents.enumerated()), id: \.offset) { _, e in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(String(e.timestamp.suffix(8)))
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .frame(width: 64, alignment: .leading)
                        Text(e.status.uppercased())
                            .font(.caption.weight(.bold))
                            .foregroundStyle(statusColor(e.status))
                            .frame(width: 56, alignment: .leading)
                        Text(e.tool)
                            .font(.system(.body, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if let ms = e.durationMs {
                            Text("\(ms) ms")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .frame(width: 56, alignment: .trailing)
                        }
                    }
                    .padding(.vertical, 3)
                }
            }
            .listStyle(.inset)
        }
    }

    private func statusColor(_ status: String) -> Color {
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
