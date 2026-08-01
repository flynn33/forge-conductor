// ForgeProcessEntry.swift
// What: Routes a shared executable into GUI, MCP-server, or manager process modes.
// How: It parses argv before UI startup, resolves the configured home, and transfers
// control to the corresponding Core service with one well-defined exit path.
// Why: A unified binary remains safe only when mutually exclusive roles are explicit.

import Foundation
import Darwin

/// Shared process entry for the **app binary** and any host that spawns it with argv.
///
/// Evidence already in-tree:
/// - LaunchAgent ProgramArguments: `Forge Conductor.app/.../Forge Conductor manager run --home …`
///   (`ManagerInstaller.installLoginAgent`)
/// - LM Studio mcp.json / mcpBridge should spawn: `…/Forge Conductor serve` (stdio MCP)
///
/// Until this router runs, the SwiftUI `@main` ignored argv and never spoke MCP.
public enum ForgeProcessEntry {
    public enum Mode: Equatable {
        case gui
        case serve
        case managerRun(openBrowser: Bool)
        case managerOther // start/stop/restart/status — delegated if needed
    }

    public static func parseMode(arguments: [String] = CommandLine.arguments) -> Mode {
        let args = Array(arguments.dropFirst())
        guard let head = args.first else { return .gui }
        switch head {
        case "serve", "mcp-serve", "mcp":
            // `mcp` alone or `mcp serve` → stdio MCP
            return .serve
        case "manager":
            let sub = args.dropFirst().first ?? "run"
            if sub == "run" || sub.hasPrefix("-") {
                let open = args.contains("--open")
                return .managerRun(openBrowser: open)
            }
            // Other manager subcommands still run headless via Core (no full CLI surface).
            return .managerOther
        default:
            return .gui
        }
    }

    public static func homeOverride(from arguments: [String] = CommandLine.arguments) -> URL? {
        let args = Array(arguments.dropFirst())
        if let idx = args.firstIndex(of: "--home"), args.index(after: idx) < args.endIndex {
            let raw = args[args.index(after: idx)] as NSString
            return URL(fileURLWithPath: raw.expandingTildeInPath, isDirectory: true)
        }
        return nil
    }

    /// Run stdio MCP until stdin closes. Does not return on success (process exits 0).
    public static func runServe(home: URL? = nil) -> Never {
        do {
            let app = try ForgeApp.bootstrap(home: home ?? homeOverride())
            defer { app.shutdown() }
            // MCP owns stdout. Normal lifecycle diagnostics are persisted by
            // DiagnosticLog; keep stderr quiet unless startup actually fails.
            try MCPServer(app: app).run()
            exit(0)
        } catch {
            fputs("forge-conductor serve error: \(error)\n", stderr)
            exit(1)
        }
    }

    /// Foreground manager (LaunchAgent path). Blocks until stop.
    public static func runManager(home: URL? = nil, openBrowser: Bool = false) -> Never {
        do {
            let app = try ForgeApp.bootstrap(home: home ?? homeOverride())
            let node = ManagerNode(app: app)
            try node.run(openBrowser: openBrowser)
            exit(0)
        } catch {
            fputs("forge-conductor manager error: \(error)\n", stderr)
            exit(1)
        }
    }

    /// Handle non-GUI modes. Returns only when mode is `.gui` (caller should start SwiftUI).
    public static func runNonGUIIfNeeded(arguments: [String] = CommandLine.arguments) {
        switch parseMode(arguments: arguments) {
        case .gui:
            return
        case .serve:
            runServe(home: homeOverride(from: arguments))
        case .managerRun(let open):
            runManager(home: homeOverride(from: arguments), openBrowser: open)
        case .managerOther:
            // Minimal support: only `run` is required for LaunchAgent. Other subcommands
            // remain on the CLI target (`forge-conductor manager …`).
            fputs("forge-conductor: use CLI for manager subcommands other than run, or launch without args for GUI\n", stderr)
            exit(2)
        }
    }
}
