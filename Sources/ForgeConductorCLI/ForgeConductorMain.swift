// ForgeConductorMain.swift
// What: Implements the command-line executable and its operator-facing commands.
// How: The entry point parses arguments, bootstraps ForgeApp once, and delegates
// serve, manager, install, diagnostics, and status operations to typed services.
// Why: A thin CLI preserves the same Core behavior used by the native application.

import Foundation
import ForgeConductorCore

/// Native command-line entry point for administration, MCP serving, and diagnostics.
///
/// Command parsing is deliberately thin: each branch constructs or invokes a Core
/// service so the executable remains an adapter rather than a second application layer.
@main
enum ForgeConductorMain {
    static func main() {
        let args = Array(CommandLine.arguments.dropFirst())
        let command = args.first ?? "help"
        let rest = Array(args.dropFirst())

        do {
            switch command {
            case "help", "-h", "--help":
                printHelp()
            case "version", "--version":
                print(ForgeApp.version)
            case "install":
                try cmdInstall(rest)
            case "install-lmstudio-plugin":
                try cmdInstallLMStudioPlugin(rest)
            case "doctor":
                try cmdDoctor(rest)
            case "status":
                try cmdStatus(rest)
            case "serve":
                try cmdServe(rest)
            case "dashboard":
                try cmdDashboard(rest)
            case "manager":
                try cmdManager(rest)
            case "agents":
                try cmdAgents(rest)
            default:
                fputs("Unknown command: \(command)\n\n", stderr)
                printHelp()
                exit(2)
            }
        } catch {
            fputs("error: \(error)\n", stderr)
            exit(1)
        }
    }

    static func printHelp() {
        print("""
        Forge-Conductor \(ForgeApp.version) — native Swift MCP orchestrator

        Usage:
          forge-conductor <command> [options]

        Commands:
          install              Layout + install Swift binary to ~/.forge-conductor/bin
          install-lmstudio-plugin [--binary PATH]  Deploy to LM Studio (primary+failover mcpBridge + mcp.json)
          doctor               Validate install, port conflicts, endpoint protection
          status               Print runtime status JSON
          serve                Run MCP server on stdio (for LM Studio)
          dashboard            Start standalone control surface (no supervisor)
          manager              Supervised dashboard node (keeps UI up)
            run [--open]         Foreground manager
            start [--open]       Background manager
            stop                 Stop manager
            restart [--open]     Restart manager
            status               Manager status
            install-login        App bundle + LaunchAgent (shows as Forge Conductor)
            uninstall-login      Remove LaunchAgent
            cleanup-stale        Remove legacy com.forge.* agents (bash/python3 in Login Items)
            allowlist            Print EP / firewall allowlist guidance
          agents               List specialist agent ids
          version              Print version
          help                 Show this help

        Environment:
          FORGE_CONDUCTOR_HOME  Override data directory (default ~/.forge-conductor)

        Managed Mac note:
          Falcon / Jamf Protect / Cortex may block ad-hoc binaries and loopback HTTP.
          Run: forge-conductor manager allowlist
          Then: System Settings → General → Login Items & Extensions

        Examples:
          forge-conductor install
          forge-conductor manager install-login
          forge-conductor manager status
          open -a "Google Chrome" http://127.0.0.1:7788/
        """)
    }

    static func homeOverride(_ args: [String]) -> URL? {
        if let idx = args.firstIndex(of: "--home"), args.index(after: idx) < args.endIndex {
            return URL(fileURLWithPath: (args[args.index(after: idx)] as NSString).expandingTildeInPath, isDirectory: true)
        }
        return nil
    }

    static func cmdInstall(_ args: [String]) throws {
        let app = try ForgeApp.bootstrap(home: homeOverride(args))
        let installer = ManagerInstaller(app: app)
        // Prefer release build path if present when reinstalling from source tree.
        var source: URL?
        if let idx = args.firstIndex(of: "--from"), args.index(after: idx) < args.endIndex {
            source = URL(fileURLWithPath: args[args.index(after: idx)])
        }
        let dest = try installer.installBinary(from: source)
        _ = try? app.store.presencePrune(maxAgeSec: 60)
        let fw = installer.tryAllowFirewall()
        print("Installed Forge-Conductor at \(app.paths.home.path)")
        print("  CLI binary: \(dest.path)")
        print("  App:        \(installer.appExecutableURL.path)")
        print("  link:   ~/.local/bin/forge-conductor-swift → \(dest.path)")
        print("  store:  \(app.paths.storeSQLite.path)")
        print("  config: \(app.paths.configJSON.path)")
        print("  agents: \(app.catalog.all().count) loaded")
        print("  firewall: \(fw["ok"] as? Bool == true ? "ok/permitted" : "may need admin — see manager allowlist")")
        print("")
        print("LM Studio is NOT modified by install. Product path:")
        print("  1) Open Forge Conductor GUI → LM Studio MCP → Deploy to LM Studio")
        print("  2) Or: \(dest.path) install-lmstudio-plugin")
        print("  Deploy writes LM Studio configuration, activates both roles, and verifies hosted tools automatically.")
        print("")
        print("App argv:  serve | manager run [--home PATH] | (none = GUI)")
    }

    static func cmdInstallLMStudioPlugin(_ args: [String]) throws {
        let app = try ForgeApp.bootstrap(home: homeOverride(args))
        defer { app.shutdown() }
        var preferred: URL? = nil
        if let idx = args.firstIndex(of: "--binary"), args.index(after: idx) < args.endIndex {
            preferred = URL(fileURLWithPath: (args[args.index(after: idx)] as NSString).expandingTildeInPath)
        }
        let result = try app.lmStudioDeploy.deploy(preferredBinary: preferred)
        print(result.message)
        print("  binary:  \(result.binaryPath)")
        print("  args:    serve")
        print("  plugins: \(result.pluginsWritten.joined(separator: ", "))")
        print("  mcp.json: \(result.mcpConfigPath)")
        print("  revision: \(result.deploymentID)")
        print("  host:    configuration synchronized; no manual file editing or restart required")
        let st = app.lmStudioDeploy.status(preferredBinary: preferred)
        print("  status:  \(st.detail)")
        if !result.ok { exit(1) }
    }

    static func cmdDoctor(_ args: [String]) throws {
        let app = try ForgeApp.bootstrap(home: homeOverride(args))
        let result = try app.doctor()
        print(try JSONSupport.string(from: result))
        if result["ok"] as? Bool != true { exit(1) }
    }

    static func cmdStatus(_ args: [String]) throws {
        let app = try ForgeApp.bootstrap(home: homeOverride(args))
        var snap = try app.statusSnapshot()
        if let pid = ManagerPIDFile.runningPID(paths: app.paths) {
            snap["manager_pid"] = Int(pid)
            snap["manager_running"] = true
            if let data = try? Data(contentsOf: app.paths.managerState),
               let state = try? JSONSupport.object(from: data) {
                snap["manager_state"] = state
            }
        } else {
            snap["manager_running"] = false
        }
        print(try JSONSupport.string(from: snap))
    }

    static func cmdAgents(_ args: [String]) throws {
        let app = try ForgeApp.bootstrap(home: homeOverride(args))
        for a in app.catalog.all() {
            print("\(a.id)\t\(a.displayName)\t\(a.source)")
        }
    }

    static func cmdServe(_ args: [String]) throws {
        let app = try ForgeApp.bootstrap(home: homeOverride(args))
        let server = MCPServer(app: app)
        try server.run()
    }

    static func cmdDashboard(_ args: [String]) throws {
        let app = try ForgeApp.bootstrap(home: homeOverride(args))
        var host: String? = nil
        var port: UInt16? = nil
        var i = 0
        while i < args.count {
            let a = args[i]
            if a == "--host", i + 1 < args.count {
                host = args[i + 1]; i += 2; continue
            }
            if a == "--port", i + 1 < args.count {
                port = UInt16(args[i + 1]); i += 2; continue
            }
            if a == "--open" {
                i += 1
                continue
            }
            i += 1
        }
        let server = DashboardServer(app: app, host: host, port: port)
        let openBrowser = args.contains("--open")
        try server.start()
        fputs("Dashboard listening at \(server.baseURL.absoluteString) (standalone — no manager)\n", stderr)
        fputs("Prefer: forge-conductor manager run --open\n", stderr)
        if openBrowser {
            let runner = ProcessRunner()
            _ = try? runner.run(
                executable: "/usr/bin/open",
                arguments: [server.baseURL.absoluteString],
                timeoutSec: 5
            )
        }
        let sem = DispatchSemaphore(value: 0)
        signal(SIGINT, SIG_IGN)
        signal(SIGTERM, SIG_IGN)
        let sigInt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
        let sigTerm = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global())
        sigInt.setEventHandler { sem.signal() }
        sigTerm.setEventHandler { sem.signal() }
        sigInt.resume()
        sigTerm.resume()
        sem.wait()
        server.stop()
    }

    // MARK: - Manager

    static func cmdManager(_ args: [String]) throws {
        let sub = args.first ?? "run"
        let rest = Array(args.dropFirst())
        switch sub {
        case "run":
            try managerRun(rest, open: rest.contains("--open"))
        case "start":
            try managerStartBackground(rest)
        case "stop":
            try managerStop(rest)
        case "restart":
            try managerRestart(rest)
        case "status":
            try managerStatus(rest)
        case "install-login":
            try managerInstallLogin(rest)
        case "uninstall-login":
            try managerUninstallLogin(rest)
        case "cleanup-stale":
            try managerCleanupStale(rest)
        case "allowlist":
            try managerAllowlist(rest)
        case "help", "-h", "--help":
            print("""
            forge-conductor manager <subcommand>

              run [--open] [--home PATH]    Foreground supervised dashboard
              start [--open] [--home PATH]  Background daemon
              stop [--home PATH]            SIGTERM running manager
              restart [--open]              stop + start
              status [--home PATH]          JSON status
              cleanup-stale                 Remove legacy com.forge.* (bash/python3) login agents
              install-login [--open]        Install Forge Conductor.app + LaunchAgent
              uninstall-login               Remove LaunchAgent
              allowlist                     Endpoint protection + firewall guidance
            """)
        default:
            // bare `manager --open` → run
            if sub.hasPrefix("-") {
                try managerRun(args, open: args.contains("--open"))
            } else {
                fputs("Unknown manager subcommand: \(sub)\n", stderr)
                exit(2)
            }
        }
    }

    static func managerInstallLogin(_ args: [String]) throws {
        let app = try ForgeApp.bootstrap(home: homeOverride(args))
        let installer = ManagerInstaller(app: app)

        // Always clear stale agents first so Login Items is not cluttered with bash/python3.
        if !args.contains("--keep-stale") {
            let cleaned = try installer.cleanupStaleLaunchAgents()
            print("Cleaned stale LaunchAgents:")
            for row in cleaned {
                print("  - \(row["label"] as? String ?? "?") removed=\(row["removed"] as? Bool ?? false)")
            }
        }

        let plist = try installer.installLoginAgent(openBrowser: args.contains("--open"))
        let appBundle = installer.appBundleURL
        _ = installer.tryAllowFirewall()

        print("")
        print("Forge Conductor login item installed")
        print("  display name: \(ManagerInstaller.appDisplayName)")
        print("  app bundle:   \(appBundle.path)")
        print("  label:        \(ManagerInstaller.launchAgentLabel)")
        print("  plist:        \(plist.path)")
        print("  binary:       \(installer.installedBinaryURL.path)")
        print("  dashboard:    http://\(app.config.string("dashboard", "host", default: "127.0.0.1")):\(app.config.int("dashboard", "port", default: 7788))/")
        print("")
        print("Where to look in System Settings:")
        print("  General → Login Items & Extensions → Allow in the Background")
        print("  → \"\(ManagerInstaller.appDisplayName)\"  (NOT bash / python3)")
        print("")
        print("If it still does not appear:")
        print("  1. Log out and back in (BTM refresh)")
        print("  2. Or reboot once")
        print("  3. Check: launchctl print gui/$(id -u)/\(ManagerInstaller.launchAgentLabel)")
        Thread.sleep(forTimeInterval: 1.0)
        try managerStatus(args)
    }

    static func managerCleanupStale(_ args: [String]) throws {
        let app = try ForgeApp.bootstrap(home: homeOverride(args))
        let installer = ManagerInstaller(app: app)
        print("Before:")
        for row in installer.listForgeLaunchAgents() {
            print("  \(row["label"] as? String ?? "?") exists=\(row["plist_exists"] as? Bool ?? false) loaded=\(row["loaded"] as? Bool ?? false) stale=\(row["stale"] as? Bool ?? false)")
        }
        let cleaned = try installer.cleanupStaleLaunchAgents()
        print("")
        print("Cleanup results:")
        for row in cleaned {
            print("  \(row["label"] as? String ?? "?") removed=\(row["removed"] as? Bool ?? false) archived=\(row["archived_to"] as? String ?? "—")")
        }
        print("")
        print("After:")
        for row in installer.listForgeLaunchAgents() {
            print("  \(row["label"] as? String ?? "?") exists=\(row["plist_exists"] as? Bool ?? false) loaded=\(row["loaded"] as? Bool ?? false)")
        }
        print("")
        print("Legacy plists archived under ~/.forge-conductor/legacy-launchagents/")
        print("Note: Login Items UI may still show ghost entries until log out/in.")
        print("Next: forge-conductor manager install-login")
    }

    static func managerUninstallLogin(_ args: [String]) throws {
        let app = try ForgeApp.bootstrap(home: homeOverride(args))
        let installer = ManagerInstaller(app: app)
        // Stop process first
        _ = ManagerPIDFile.signalStop(paths: app.paths)
        let removed = try installer.uninstallLoginAgent()
        print(removed ? "Login agent removed" : "Login agent was not installed")
    }

    static func managerAllowlist(_ args: [String]) throws {
        let app = try ForgeApp.bootstrap(home: homeOverride(args))
        let installer = ManagerInstaller(app: app)
        let report = installer.endpointProtectionReport()
        print(try JSONSupport.string(from: report))
        print("")
        // Human summary
        print("=== Quick allowlist checklist (managed Mac) ===")
        print("1. Binary path to allow: \(installer.installedBinaryURL.path)")
        print("2. Loopback listen: 127.0.0.1:\(app.config.int("dashboard", "port", default: 7788))")
        print("3. System Settings → General → Login Items & Extensions")
        print("   - Background: allow forge-conductor / \(ManagerInstaller.launchAgentLabel)")
        print("   - Endpoint Security Extensions: Falcon, Jamf Protect, Cortex (IT — leave on)")
        print("   - Network Extensions: GlobalProtect / Cortex (if localhost blocked, ticket IT)")
        print("4. macOS Firewall: allow incoming for the binary above")
        print("5. Open dashboard with Chrome (not Safari):")
        print("   open -a \"Google Chrome\" http://127.0.0.1:\(app.config.int("dashboard", "port", default: 7788))/")
        print("6. Avoid old path ~/.local/bin/forge-conductor if it points at Python venv")
        if let bin = report["binary"] as? [String: Any],
           let w = bin["legacy_warning"] as? String, !w.isEmpty {
            print("")
            print("WARNING: \(w)")
        }
    }

    static func managerRun(_ args: [String], open: Bool) throws {
        let app = try ForgeApp.bootstrap(home: homeOverride(args))
        let node = ManagerNode(app: app)
        try node.run(openBrowser: open)
    }

    static func managerStartBackground(_ args: [String]) throws {
        let app = try ForgeApp.bootstrap(home: homeOverride(args))
        if let pid = ManagerPIDFile.runningPID(paths: app.paths) {
            print("Manager already running (pid \(pid))")
            print("  url: http://\(app.config.string("dashboard", "host", default: "127.0.0.1")):\(app.config.int("dashboard", "port", default: 7788))/")
            return
        }

        // Prefer installed stable binary so EP allowlists target a fixed path.
        let installer = ManagerInstaller(app: app)
        let exe: String
        if FileManager.default.isExecutableFile(atPath: installer.installedBinaryURL.path) {
            exe = installer.installedBinaryURL.path
        } else {
            exe = try SelfExecutable.path()
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: exe)
        var childArgs = ["manager", "run"]
        if let home = homeOverride(args) {
            childArgs += ["--home", home.path]
        }
        if args.contains("--open") {
            childArgs.append("--open")
        }
        process.arguments = childArgs

        try app.paths.ensureLayout()
        if !FileManager.default.fileExists(atPath: app.paths.managerLog.path) {
            FileManager.default.createFile(atPath: app.paths.managerLog.path, contents: nil)
        }
        let log = try FileHandle(forWritingTo: app.paths.managerLog)
        try log.seekToEnd()
        let banner = Data("\n--- manager start \(ISO8601.string(from: Date())) ---\n".utf8)
        try log.write(contentsOf: banner)
        process.standardOutput = log
        process.standardError = log
        process.standardInput = FileHandle.nullDevice

        try process.run()
        // Wait for pid file / listener
        var launched: Int32?
        for _ in 0..<30 {
            Thread.sleep(forTimeInterval: 0.1)
            if let pid = ManagerPIDFile.runningPID(paths: app.paths) {
                launched = pid
                break
            }
        }
        let host = app.config.string("dashboard", "host", default: "127.0.0.1")
        let port = app.config.int("dashboard", "port", default: 7788)
        if let launched {
            print("Manager started (pid \(launched))")
            print("  dashboard: http://\(host):\(port)/")
            print("  log: \(app.paths.managerLog.path)")
        } else {
            fputs("Manager process launched but pid file not seen yet. Check \(app.paths.managerLog.path)\n", stderr)
            exit(1)
        }
    }

    static func managerStop(_ args: [String]) throws {
        let paths = AppPaths(home: homeOverride(args))
        try paths.ensureLayout()
        guard let pid = ManagerPIDFile.runningPID(paths: paths) else {
            print("Manager is not running")
            // clean stale pid
            ManagerPIDFile.remove(paths: paths)
            return
        }
        if ManagerPIDFile.signalStop(paths: paths) {
            for _ in 0..<50 {
                if ManagerPIDFile.runningPID(paths: paths) == nil { break }
                Thread.sleep(forTimeInterval: 0.1)
            }
            if ManagerPIDFile.runningPID(paths: paths) == nil {
                print("Manager stopped (was pid \(pid))")
            } else {
                fputs("Sent SIGTERM to \(pid); process still alive\n", stderr)
                exit(1)
            }
        } else {
            fputs("Failed to signal manager\n", stderr)
            exit(1)
        }
    }

    static func managerRestart(_ args: [String]) throws {
        let paths = AppPaths(home: homeOverride(args))
        if ManagerPIDFile.runningPID(paths: paths) != nil {
            try managerStop(args)
            Thread.sleep(forTimeInterval: 0.3)
        }
        try managerStartBackground(args)
    }

    static func managerStatus(_ args: [String]) throws {
        let app = try ForgeApp.bootstrap(home: homeOverride(args))
        let pid = ManagerPIDFile.runningPID(paths: app.paths)
        var out: [String: Any] = [
            "ok": true,
            "manager_running": pid != nil,
            "pid": pid.map { Int($0) } as Any,
            "home": app.paths.home.path,
            "dashboard": [
                "host": app.config.string("dashboard", "host", default: "127.0.0.1"),
                "port": app.config.int("dashboard", "port", default: 7788),
            ] as [String: Any],
        ]
        if let data = try? Data(contentsOf: app.paths.managerState),
           let state = try? JSONSupport.object(from: data) {
            out["state"] = state
        }
        // Live probe if up
        if pid != nil {
            let host = app.config.string("dashboard", "host", default: "127.0.0.1")
            let port = app.config.int("dashboard", "port", default: 7788)
            if let url = URL(string: "http://\(host):\(port)/api/manager/status"),
               let live = try? liveJSON(url: url) {
                out["live"] = live
            }
        }
        print(try JSONSupport.string(from: out.compactNSNull()))
    }

    static func liveJSON(url: URL) throws -> [String: Any] {
        // Thread-safe box avoids Swift 6 Sendable warnings on URLSession callbacks.
        final class ResponseBox: @unchecked Sendable {
            let lock = NSLock()
            var data: Data?
            var error: Error?
            func set(data: Data?, error: Error?) {
                lock.lock()
                self.data = data
                self.error = error
                lock.unlock()
            }
            func take() -> (Data?, Error?) {
                lock.lock()
                defer { lock.unlock() }
                return (data, error)
            }
        }
        let box = ResponseBox()
        let sem = DispatchSemaphore(value: 0)
        let task = URLSession.shared.dataTask(with: url) { data, _, error in
            box.set(data: data, error: error)
            sem.signal()
        }
        task.resume()
        guard sem.wait(timeout: .now() + 2) == .success else {
            throw NSError(
                domain: "ForgeConductorCLI",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Timed out fetching \(url.absoluteString)"]
            )
        }
        let (data, error) = box.take()
        if let error { throw error }
        guard let data else { return [:] }
        return try JSONSupport.object(from: data)
    }
}
