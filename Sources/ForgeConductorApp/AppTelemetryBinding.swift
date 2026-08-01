// AppTelemetryBinding.swift
// What: Bridges the continuously sampled Core telemetry stream into SwiftUI.
// How: It subscribes once, coalesces frames on the main actor, and publishes a
// composed snapshot only after every related field has been updated together.
// Why: A single binding avoids inconsistent partial frames and duplicate listeners.

import Foundation
import Combine
import ForgeConductorCore

/// Binds the continuous realtime telemetry stream to UI state.
/// Host metrics come from `RealtimeMetricsEngine` samples — never a multi-second snapshot poll.
@MainActor
public final class AppTelemetryBinding: ObservableObject {
    public private(set) var system: SystemMetrics?
    public private(set) var forge: ForgeSnapshot?
    public private(set) var history: [HistoryPoint] = []
    public private(set) var updated: Date?
    public private(set) var lastTyped: TelemetrySnapshot?
    public private(set) var measuredHz: Double = 0
    public private(set) var lastError: String?
    public private(set) var isLoading = false
    @Published public var autoRefresh = true

    private weak var app: ForgeApp?
    private var frameListenerID: UUID?
    private let updateSubject = PassthroughSubject<Void, Never>()

    /// Emits after a complete telemetry frame has been applied. Consumers that
    /// mirror this state receive one coherent update instead of one per field.
    public var updates: AnyPublisher<Void, Never> {
        updateSubject.eraseToAnyPublisher()
    }

    public init() {}

    public func attach(app: ForgeApp) {
        detach()
        self.app = app

        // Always run continuous host sampling for the GUI.
        if !app.telemetry.realtimeEngine.isRunning {
            app.telemetry.startBackgroundRefresh(intervalSec: 0.5)
        }

        // TelemetryService publishes one composed frame for every host sample.
        frameListenerID = app.telemetry.addListener { [weak self] frame in
            Task { @MainActor in
                guard let self, self.autoRefresh else { return }
                self.measuredHz = app.telemetry.realtimeEngine.measuredSampleHz
                self.apply(frame)
            }
        }

        // One forge seed so MCP/agent cards appear immediately; host already streaming.
        seedForgeOnce()
    }

    public func detach() {
        if let id = frameListenerID, let app {
            app.telemetry.removeListener(id)
        }
        frameListenerID = nil
    }

    /// Manual recompose of forge cards only (does not replace the continuous host stream).
    public func refresh(force: Bool) {
        guard let app else { return }
        if isLoading && !force { return }
        objectWillChange.send()
        isLoading = true
        updateSubject.send()
        Task { [weak self] in
            do {
                let frame = try await Task.detached {
                    try app.telemetry.snapshotTyped(force: true)
                }.value
                await MainActor.run {
                    self?.measuredHz = app.telemetry.realtimeEngine.measuredSampleHz
                    self?.apply(frame)
                }
            } catch {
                await MainActor.run {
                    self?.objectWillChange.send()
                    self?.lastError = "\(error)"
                    self?.isLoading = false
                    self?.updateSubject.send()
                    app.diagnostics.warn("telemetry_refresh_failed", [
                        "error": "\(error)",
                    ], category: .telemetry)
                }
            }
        }
    }

    public var modeLabel: String {
        let target = app?.telemetry.realtimeEngine.targetSampleHz ?? RealtimeMetricsEngine.defaultTargetHz
        if measuredHz > 0.5 {
            return String(format: "Real-time native · %.0f Hz target · %.1f Hz measured", target, measuredHz)
        }
        return String(format: "Real-time native · %.0f Hz continuous stream", target)
    }

    private func seedForgeOnce() {
        guard let app else { return }
        let frame = app.telemetry.currentFrame()
        measuredHz = app.telemetry.realtimeEngine.measuredSampleHz
        apply(frame)
    }

    private func apply(_ typed: TelemetrySnapshot) {
        objectWillChange.send()
        lastTyped = typed
        system = typed.system
        forge = typed.forge
        history = typed.history
        updated = Date(timeIntervalSince1970: typed.updated)
        lastError = nil
        isLoading = false
        updateSubject.send()
    }
}
