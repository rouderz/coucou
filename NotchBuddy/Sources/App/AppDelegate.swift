import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem?
    private(set) var islandController: IslandWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Ignore SIGPIPE — prevents crash when nb-hook closes socket before we write response
        signal(SIGPIPE, SIG_IGN)
        // Unit tests run inside the app: don't start the island, the socket or the pollers.
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil { return }
        _ = AppLanguage.atLaunch  // remember the language this run started with
        // Warm up Keychain cache on main thread BEFORE any poller or view touches it
        _ = Secrets.store
        NSApp.setActivationPolicy(.accessory)
        setupMenuBarItem()
        setupIsland()
    }

    // MARK: - Menu bar

    private func setupMenuBarItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        guard let button = statusItem?.button else { return }
        button.image = NSImage(named: "MenuBarIcon") ?? NSImage(systemSymbolName: "circle.fill", accessibilityDescription: "Coucou")
        button.image?.size = NSSize(width: 24, height: 18)
        button.image?.accessibilityDescription = "Coucou"
        button.image?.isTemplate = true

        let menu = NSMenu()
        menu.addItem(withTitle: "Open Coucou", action: #selector(openIsland), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        statusItem?.menu = menu
    }

    // MARK: - Actions

    @objc private func openIsland() {
        islandController?.expand(to: .overview)
    }

    private var settingsWindow: NSWindow?

    @objc private func openSettings() {
        // The island floats above every window; fold it away so it can't cover Settings.
        if AppState.shared.mode == .expanded { islandController?.collapse() }

        if let w = settingsWindow, w.isVisible {
            placeBelowIsland(w)
            w.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return
        }
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 680),
                           styleMask: [.titled, .closable, .miniaturizable, .resizable],
                           backing: .buffered, defer: false)
        win.title = "Settings — Coucou"
        win.contentView = NSHostingView(rootView: SettingsView())
        win.contentMinSize = NSSize(width: 480, height: 360)
        win.isReleasedWhenClosed = false
        placeBelowIsland(win)
        settingsWindow = win
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Centres the window on the notch screen (the island is folded away while Settings is
    /// open), keeping it under the island's compact pill and shrinking it to fit small screens.
    private func placeBelowIsland(_ win: NSWindow) {
        let screen = IslandWindowController.notchScreen() ?? NSScreen.main ?? win.screen
        guard let screen else { win.center(); return }
        let visible = screen.visibleFrame
        let top = min(visible.maxY, screen.frame.maxY - 60)   // clear of the compact pill
        var frame = win.frame
        frame.size.height = min(frame.height, top - visible.minY - 24)
        frame.size.width = min(frame.width, visible.width - 48)
        frame.origin.x = visible.midX - frame.width / 2
        frame.origin.y = min(top - frame.height, visible.midY - frame.height / 2)
        frame.origin.y = max(visible.minY + 12, frame.origin.y)
        win.setFrame(frame, display: true)
    }

    // MARK: - Island setup

    private func setupIsland() {
        islandController = IslandWindowController()
        islandController?.showWindow(nil)
        islandController?.fsm.launch()
        PollGate.shared.start()
        DoNotDisturb.shared.start()
        HookServer.shared.start()
        for source in Integrations.all { source.start() }
        InboxStore.shared.start()
        WakeWord.shared.start()
        Updates.shared.start()
        NotificationCenter.default.addObserver(self, selector: #selector(openSettings),
                                               name: .openFullSettings, object: nil)
        Task { await ClaudeCodeChat.locate() }
    }
}
