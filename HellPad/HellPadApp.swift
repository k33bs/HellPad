import SwiftUI

@main
struct HellPadApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var statusItem: NSStatusItem?
    var mainWindow: NSWindow?
    var settingsWindow: NSWindow?
    var alwaysOnTopMenuItem: NSMenuItem?
    var stratagemManager: StratagemManager?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Hide from dock
        NSApp.setActivationPolicy(.accessory)

        // Create menu bar item
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem?.button {
            // Use AppIcon for menu bar (will use the appropriate size automatically)
            if let icon = NSImage(named: "AppIcon") {
                icon.size = NSSize(width: 18, height: 18)
                button.image = icon
            }
            button.action = #selector(togglePopover)
        }

        // Create menu
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Configure Apps...", action: #selector(showAppSettings), keyEquivalent: ""))

        // Add "Always on top" toggle - default ON
        alwaysOnTopMenuItem = NSMenuItem(title: "Always on top", action: #selector(toggleAlwaysOnTop), keyEquivalent: "")
        alwaysOnTopMenuItem?.state = .on  // Default to ON
        menu.addItem(alwaysOnTopMenuItem!)

        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Show Window", action: #selector(showWindow), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "About HellPad", action: #selector(showAbout), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem?.menu = menu

        // Check accessibility permissions
        AccessibilityManager.shared.ensureAccessibilityPermission {
            self.createFloatingWindow()
        }
    }

    @objc func togglePopover() {
        if let window = mainWindow, window.isVisible {
            window.orderOut(nil)
        } else {
            showWindow()
        }
    }

    @objc func showWindow() {
        if mainWindow == nil {
            createFloatingWindow()
        }
        mainWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func toggleAlwaysOnTop() {
        guard let menuItem = alwaysOnTopMenuItem, let window = mainWindow else { return }

        // Toggle state
        if menuItem.state == .off {
            menuItem.state = .on
            window.level = .floating  // Always on top
        } else {
            menuItem.state = .off
            window.level = .normal  // Normal window behavior
        }
    }

    @objc func showAbout() {
        let alert = NSAlert()
        alert.messageText = "HellPad v1.0.3"
        alert.informativeText = """
        A native macOS application for executing HELLDIVERS™ 2 stratagems via customizable hotkeys.

        • Global hotkeys with combo mode
        • Smart app detection
        • Thread-safe execution

        Inspired by HellBuddy (Windows) by chris-codes1
        Stratagem icons by Nicolas Vigneux

        © 2025 HellPad
        Licensed under GPL v3

        Not affiliated with Arrowhead Game Studios or Sony Interactive Entertainment.
        """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Help")
        alert.addButton(withTitle: "GitHub")
        alert.addButton(withTitle: "OK")

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            // Help - opens README
            NSWorkspace.shared.open(URL(string: "https://github.com/k33bs/HellPad#usage")!)
        } else if response == .alertSecondButtonReturn {
            // GitHub - opens repo
            NSWorkspace.shared.open(URL(string: "https://github.com/k33bs/HellPad")!)
        }
    }

    @objc func showAppSettings() {
        guard let manager = stratagemManager else {
            print("StratagemManager not initialized yet")
            return
        }

        if settingsWindow == nil {
            let settingsView = AppSettingsView(stratagemManager: manager)
            settingsWindow = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            settingsWindow?.title = "App Settings"
            settingsWindow?.contentView = NSHostingView(rootView: settingsView)
            settingsWindow?.isReleasedWhenClosed = false
            settingsWindow?.center()
        }

        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func createFloatingWindow() {
        // Create StratagemManager if needed
        if stratagemManager == nil {
            stratagemManager = StratagemManager()
        }

        let contentView = ContentView(stratagemManager: stratagemManager!)
            .padding(EdgeInsets(top: 0, leading: 1, bottom: 1, trailing: 1))
            .background(Color.black)  // Ensure padding area is black
            .frame(width: 186, height: 475)

        mainWindow = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 186, height: 475),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        mainWindow?.title = "HellPad"
        mainWindow?.contentView = NSHostingView(rootView: contentView)
        mainWindow?.level = .floating  // Default to always on top
        mainWindow?.isOpaque = true
        mainWindow?.backgroundColor = NSColor.black
        mainWindow?.hasShadow = true
        mainWindow?.isRestorable = false
        mainWindow?.delegate = self
        mainWindow?.center()  // Center on screen
        mainWindow?.makeKeyAndOrderFront(nil)
    }

    // Handle window close button - quit the app
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        NSApplication.shared.terminate(nil)
        return false
    }
}
