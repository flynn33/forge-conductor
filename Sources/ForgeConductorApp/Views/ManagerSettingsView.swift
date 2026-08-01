// ManagerSettingsView.swift
// What: Provides native controls for the persistent manager and its configuration.
// How: Form fields bind to staged AppModel values, while commands call typed manager
// operations and render returned health/doctor information.
// Why: A single settings module replaces ad-hoc process and configuration mutations.

import SwiftUI
import ForgeConductorCore

/// Full management console parity with classic `/control` surface.
struct ManagerSettingsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var doctorJSON = ""
    @State private var doctorOK: Bool?

    var body: some View {
        Form {
            Section {
                LabeledContent("State", value: model.serviceState)
                LabeledContent("Active", value: model.serviceActive ? "yes" : "no")
                if let msg = model.managerMessage {
                    Text(msg).font(.caption).foregroundStyle(.secondary)
                }
                HStack(spacing: 10) {
                    Button("Start") { model.managerStart() }
                        .buttonStyle(.borderedProminent)
                        .tint(.green)
                    Button("Stop") { model.managerStop() }
                        .buttonStyle(.bordered)
                        .tint(.red)
                    Button("Restart") { model.managerRestart() }
                        .buttonStyle(.bordered)
                }
                .padding(.vertical, 2)
            } header: {
                Text("Service")
                    .accessibilityIdentifier("detail-manager")
            }

            Section("Runtime") {
                LabeledContent("App version", value: model.version)
                LabeledContent("Manager version", value: model.managerRuntimeVersion)
                if let notice = model.managerVersionNotice {
                    Label(notice, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .accessibilityIdentifier("manager-version-mismatch")
                }
                LabeledContent("Home", value: model.homePath)
                LabeledContent("Product", value: ForgeApp.productName)
                if let updated = model.updated {
                    LabeledContent("Host telemetry", value: model.telemetryModeLabel)
                    LabeledContent("Last host sample", value: updated.formatted())
                    LabeledContent("Dashboard HTML poll", value: "\(model.setRefresh)s (not host telemetry)")
                }
            }

            Section("Settings") {
                TextField("Dashboard host", text: $model.setHost)
                TextField("Dashboard port", value: $model.setPort, format: .number)
                TextField("UI refresh (sec)", value: $model.setRefresh, format: .number)
                TextField("Watchdog (sec)", value: $model.setWatchdog, format: .number)
                TextField("Session idle TTL (sec)", value: $model.setIdleTTL, format: .number)
                TextField("Shell timeout (sec)", value: $model.setShellTimeout, format: .number)
                Toggle("Auto-restart HTTP if it drops", isOn: $model.setAutoRestart)
                HStack(spacing: 10) {
                    Button("Reload from disk") { model.loadSettingsFromConfig() }
                    Button("Save settings") { model.saveSettings() }
                        .buttonStyle(.borderedProminent)
                }
                .padding(.vertical, 2)
            }

            Section("Maintenance") {
                Toggle("Auto-refresh telemetry", isOn: $model.autoRefresh)
                Button("Refresh telemetry now") { model.refresh(force: true) }
                Button("Prune stale presence") { model.prunePresence() }
                Button("Prune idle sessions") { model.pruneSessions() }
                Button("Run doctor") {
                    if let d = model.runDoctor() {
                        doctorOK = d.ok
                        let lines = d.checks.map { c in
                            "\(c.ok ? "OK" : "FAIL")  \(c.name): \(c.detail)"
                        }
                        doctorJSON = ([
                            "ok=\(d.ok)  version=\(d.version)",
                            "home=\(d.home)",
                            "binary=\(d.binaryInstalled ? "yes" : "no")  \(d.binaryPath)",
                            "telemetry=\(d.telemetry.runtime)",
                            "",
                        ] + lines).joined(separator: "\n")
                    } else {
                        doctorJSON = "doctor failed"
                        doctorOK = false
                    }
                }
            }

            if !doctorJSON.isEmpty {
                Section("Doctor \(doctorOK == true ? "OK" : "ISSUES")") {
                    ScrollView {
                        Text(doctorJSON)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(minHeight: 160)
                }
            }

            Section("Notes") {
                Text("Start/Stop toggles operational service_active. Restart rebinds the HTTP control plane. Product path: Deploy to LM Studio on the LM Studio MCP tab; configuration, host reload, and both connection checks are automatic. Telemetry is a continuous native stream (~30 Hz host sampling + SSE /api/stream), not multi-second snapshots. Diagnostics export is on the Diagnostics tab.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding(16)
        .onAppear { model.loadSettingsFromConfig() }
    }
}
