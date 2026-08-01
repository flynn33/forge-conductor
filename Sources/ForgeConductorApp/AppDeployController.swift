// AppDeployController.swift
// What: Presents Core's LM Studio deployment workflow as UI-friendly state.
// How: It owns the deployment task, publishes progress, and delegates every
// installation or verification side effect to the injected ForgeApp services.
// Why: Keeping orchestration out of SwiftUI views preserves a testable module boundary.

import Foundation
import ForgeConductorCore

/// GUI-facing deploy controller (keeps AppModel thin).
@MainActor
public final class AppDeployController {
    private let app: ForgeApp

    public init(app: ForgeApp) {
        self.app = app
    }

    public var preferredServeBinary: URL {
        app.lmStudioDeploy.resolveServeBinary(preferred: Bundle.main.executableURL)
    }

    public func status() -> LMStudioMCPPluginInstaller.PluginStatus {
        app.lmStudioDeploy.status(preferredBinary: preferredServeBinary)
    }

    public func deploy() throws -> LMStudioMCPPluginInstaller.InstallResult {
        try app.lmStudioDeploy.deploy(preferredBinary: preferredServeBinary)
    }
}
