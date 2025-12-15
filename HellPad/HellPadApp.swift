import SwiftUI
import Combine

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

    // Loadout menu management
    private var loadoutMenuItems: [NSMenuItem] = []
    private var loadoutSeparatorBefore: NSMenuItem?
    private var loadoutSeparatorAfter: NSMenuItem?
    private var loadoutCancellables = Set<AnyCancellable>()

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

        // Save Loadout item
        menu.addItem(NSMenuItem(title: "Save Loadout...", action: #selector(showSaveLoadoutDialog), keyEquivalent: ""))

        // Separators and placeholder for loadout items (will be populated dynamically)
        loadoutSeparatorBefore = NSMenuItem.separator()
        menu.addItem(loadoutSeparatorBefore!)
        // Dynamic loadout items will be inserted here
        loadoutSeparatorAfter = NSMenuItem.separator()
        menu.addItem(loadoutSeparatorAfter!)

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
            self.setupLoadoutMenuObservers()
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
        alert.messageText = "HellPad v1.1.2"
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

    // MARK: - Loadout Menu Management

    private func setupLoadoutMenuObservers() {
        guard let manager = stratagemManager else { return }

        // Observe loadouts and activeLoadoutId changes
        manager.$loadouts
            .combineLatest(manager.$activeLoadoutId)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _, _ in
                self?.rebuildLoadoutMenuItems()
            }
            .store(in: &loadoutCancellables)

        // Initial build
        rebuildLoadoutMenuItems()
    }

    private func rebuildLoadoutMenuItems() {
        guard let menu = statusItem?.menu,
              let manager = stratagemManager,
              let separatorBefore = loadoutSeparatorBefore,
              let separatorAfter = loadoutSeparatorAfter else { return }

        // Find indices
        guard let beforeIndex = menu.items.firstIndex(of: separatorBefore),
              let _ = menu.items.firstIndex(of: separatorAfter) else { return }

        // Remove existing loadout items (between the separators)
        for item in loadoutMenuItems {
            menu.removeItem(item)
        }
        loadoutMenuItems.removeAll()

        // Hide separators if no loadouts
        separatorBefore.isHidden = manager.loadouts.isEmpty
        separatorAfter.isHidden = manager.loadouts.isEmpty

        // Add loadout items with numbers (1-9 for keyboard shortcuts)
        var insertIndex = beforeIndex + 1
        for (index, loadout) in manager.loadouts.enumerated() {
            // Show number prefix for first 9 loadouts (keyboard shortcuts)
            let numberPrefix = index < 9 ? "\(index + 1)  " : ""
            let item = NSMenuItem(title: "\(numberPrefix)\(loadout.name)", action: #selector(loadoutMenuItemClicked(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = loadout.id
            item.state = (manager.activeLoadoutId == loadout.id) ? .on : .off

            menu.insertItem(item, at: insertIndex)
            loadoutMenuItems.append(item)
            insertIndex += 1
        }
    }

    @objc func loadoutMenuItemClicked(_ sender: NSMenuItem) {
        guard let loadoutId = sender.representedObject as? UUID,
              let manager = stratagemManager else { return }
        manager.loadLoadout(id: loadoutId)
    }

    @objc func showSaveLoadoutDialog() {
        guard let manager = stratagemManager else { return }

        let alert = NSAlert()
        alert.messageText = "Save Loadout"
        alert.informativeText = "Enter a name for a new loadout, or select an existing one to overwrite."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

        // Create accessory view
        let hasExistingLoadouts = !manager.loadouts.isEmpty
        let viewHeight: CGFloat = hasExistingLoadouts ? 58 : 24

        let accessoryView = NSView(frame: NSRect(x: 0, y: 0, width: 280, height: viewHeight))

        // Name text field
        let textField = NSTextField(frame: NSRect(x: 0, y: viewHeight - 24, width: 280, height: 22))
        textField.placeholderString = generateUniqueLoadoutName(manager: manager)
        accessoryView.addSubview(textField)

        // Overwrite dropdown (only if loadouts exist)
        var dropdown: NSPopUpButton?
        if hasExistingLoadouts {
            dropdown = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 280, height: 26))
            dropdown!.addItem(withTitle: "Create New")
            dropdown!.menu?.addItem(NSMenuItem.separator())
            for loadout in manager.loadouts {
                dropdown!.addItem(withTitle: "Overwrite: \(loadout.name)")
            }
            accessoryView.addSubview(dropdown!)
        }

        alert.accessoryView = accessoryView

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            let defaultName = generateUniqueLoadoutName(manager: manager)
            let enteredName = textField.stringValue.trimmingCharacters(in: .whitespaces)
            let userTypedName = !enteredName.isEmpty

            if let dropdown = dropdown {
                let selectedIndex = dropdown.indexOfSelectedItem
                if selectedIndex <= 1 {  // "Create New" or separator
                    let name = userTypedName ? enteredName : defaultName

                    // Check for duplicate name (defaultName is already unique, but user input might not be)
                    if userTypedName && manager.loadouts.contains(where: { $0.name == name }) {
                        showDuplicateNameError(name: name)
                        return
                    }
                    manager.saveLoadout(name: name)
                } else {
                    // Overwriting existing loadout
                    let loadoutIndex = selectedIndex - 2
                    let loadoutToOverwrite = manager.loadouts[loadoutIndex]

                    // Use original name unless user typed a name
                    let name = userTypedName ? enteredName : loadoutToOverwrite.name

                    // Check for duplicate name (but allow keeping same name on overwrite)
                    if name != loadoutToOverwrite.name && manager.loadouts.contains(where: { $0.name == name }) {
                        showDuplicateNameError(name: name)
                        return
                    }
                    manager.saveLoadout(name: name, overwriteId: loadoutToOverwrite.id)
                }
            } else {
                let name = userTypedName ? enteredName : defaultName

                // Check for duplicate name (defaultName is already unique, but user input might not be)
                if userTypedName && manager.loadouts.contains(where: { $0.name == name }) {
                    showDuplicateNameError(name: name)
                    return
                }
                manager.saveLoadout(name: name)
            }
        }
    }

    private func showDuplicateNameError(name: String) {
        let alert = NSAlert()
        alert.messageText = "Duplicate Name"
        alert.informativeText = "A loadout named \"\(name)\" already exists. Please choose a different name."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func generateUniqueLoadoutName(manager: StratagemManager) -> String {
        var counter = manager.loadouts.count + 1
        var name = "Loadout \(counter)"
        while manager.loadouts.contains(where: { $0.name == name }) {
            counter += 1
            name = "Loadout \(counter)"
        }
        return name
    }
}
