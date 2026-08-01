// AppSidebarView.swift
// What: Provides persistent navigation between independently composed app modules.
// How: Explicit buttons mutate the single AppModel.AppTab state and expose stable
// accessibility identifiers without introducing a second navigation state machine.
// Why: Deterministic navigation prevents blank-detail and lost-selection regressions.

import SwiftUI

/// Persistent application navigation. This intentionally uses explicit
/// buttons instead of `List(selection:)`: tab choice is application state,
/// not a second navigation-stack state machine.
struct AppSidebarView: View {
    let selectedTab: AppModel.AppTab
    let version: String
    let lastError: String?
    let onSelect: (AppModel.AppTab) -> Void

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(AppModel.AppTab.allCases) { tab in
                        tabButton(tab)
                    }
                }
                .padding(10)
            }

            Divider()
            VStack(alignment: .leading, spacing: 6) {
                Text("Forge Conductor")
                    .font(.headline)
                    .accessibilityIdentifier("app-title")
                Text(version)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("app-version")
                if let lastError {
                    Text(lastError)
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .lineLimit(3)
                        .accessibilityIdentifier("app-error")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
        }
        .frame(width: 224)
        .background(Color(nsColor: .windowBackgroundColor))
        .accessibilityIdentifier("sidebar")
    }

    private func tabButton(_ tab: AppModel.AppTab) -> some View {
        let selected = selectedTab == tab
        return Button {
            onSelect(tab)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: tab.systemImage)
                    .frame(width: 18)
                Text(tab.rawValue)
                    .lineLimit(1)
                Spacer(minLength: 8)
            }
            .foregroundStyle(selected ? Color.white : Color.primary)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(selected ? Color.accentColor : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("tab-\(tab.accessibilityID)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private extension AppModel.AppTab {
    var systemImage: String {
        switch self {
        case .rig: "gauge.with.dots.needle.67percent"
        case .mcp: "server.rack"
        case .agents: "person.3"
        case .tools: "wrench.and.screwdriver"
        case .feed: "waveform.path.ecg"
        case .diagnostics: "doc.text.magnifyingglass"
        case .manager: "gearshape.2"
        }
    }
}
