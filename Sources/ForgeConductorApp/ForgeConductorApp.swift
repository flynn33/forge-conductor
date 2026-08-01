// ForgeConductorApp.swift
// What: Defines the process and scene entry points for the native macOS product.
// How: Command-line modes are routed before SwiftUI starts; GUI mode then
// creates scenes, injects AppModel, and activates a regular foreground app.
// Why: One binary can safely serve GUI, manager, and MCP roles without parallel bootstraps.

import SwiftUI
import AppKit
import Combine
import ForgeConductorCore

/// Process entry: the app binary already receives argv from LaunchAgent and must
/// also accept `serve` from LM Studio. Route non-GUI modes before SwiftUI starts.
@main
enum ForgeConductorMain {
    static func main() {
        // LaunchAgent:  …/Forge Conductor manager run --home …
        // LM Studio:    …/Forge Conductor serve   (+ FORGE_MCP_ROLE)
        // Double-click: no subcommand → GUI
        ForgeProcessEntry.runNonGUIIfNeeded()
        ForgeConductorGUIApp.main()
    }
}

struct ForgeConductorGUIApp: App {
    @NSApplicationDelegateAdaptor(ForgeApplicationDelegate.self) private var appDelegate
    private var model: AppModel { appDelegate.model }

    var body: some Scene {
        Settings {
            ManagerSettingsView()
                .environmentObject(model)
                .frame(width: 480, height: 360)
        }
        .restorationBehavior(.disabled)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("Navigation") {
                Button(model.isNavigationVisible ? "Hide Navigation" : "Show Navigation") {
                    model.toggleNavigation()
                }
                .keyboardShortcut("s", modifiers: [.command, .control])
            }
            CommandMenu("Telemetry") {
                Button("Refresh Now") { model.refresh(force: true) }
                    .keyboardShortcut("r", modifiers: [.command])
                Toggle(
                    "Auto-refresh",
                    isOn: Binding(
                        get: { model.autoRefresh },
                        set: { model.autoRefresh = $0 }
                    )
                )
            }
        }
    }
}

@MainActor
final class ForgeApplicationDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    let model = AppModel()

    private var modelObservation: AnyCancellable?
    private var mainWindowController: ForgeMainWindowController?

    override init() {
        super.init()
        modelObservation = model.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        presentMainWindow()
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        presentMainWindow()
        return false
    }

    private func presentMainWindow() {
        if let controller = mainWindowController {
            controller.showWindow(nil)
            controller.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let controller = ForgeMainWindowController(model: model)
        mainWindowController = controller
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

@MainActor
private final class ForgeMainWindowController: NSWindowController {
    init(model: AppModel) {
        let content = ContentView()
            .environmentObject(model)
            .frame(minWidth: 1100, minHeight: 720)
        let hostingController = NSHostingController(rootView: content)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1440, height: 900),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Forge Conductor"
        window.identifier = NSUserInterfaceItemIdentifier("forge-main-window")
        window.minSize = NSSize(width: 1100, height: 720)
        window.tabbingMode = .disallowed
        window.contentViewController = hostingController
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }
}
