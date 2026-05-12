import SwiftUI
import Combine

@main
struct HellPadApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // app protocol requires a scene; real ui is built by AppDelegate.
        // we still need the placeholder Settings scene, but we drop its "Settings…" / cmd+,
        // menu entry so users don't get an empty preferences window
        Settings {
            EmptyView()
        }
        .commands {
            CommandGroup(replacing: .appSettings) {}
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var statusItem: NSStatusItem?
    var mainWindow: NSWindow?
    var settingsWindow: NSWindow?
    var alwaysOnTopMenuItem: NSMenuItem?
    var stratagemManager: StratagemManager?

    // loadout menu management has been extracted into LoadoutMenuController.
    // we still hold the separator references so we can hand them to the controller
    // once stratagemManager exists (after the accessibility permission flow finishes)
    private var loadoutSeparatorBefore: NSMenuItem?
    private var loadoutSeparatorAfter: NSMenuItem?
    private var loadoutMenuController: LoadoutMenuController?

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

        // Save Loadout item — target stays on AppDelegate because the controller is created later;
        // the @objc func showSaveLoadoutDialog below forwards to the controller
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
            self.setupLoadoutMenuController()
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
        alert.messageText = "HellPad v1.1.7"
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
        // use shared appName constant so window title matches keyWindow checks
        mainWindow?.title = HBConstants.appName
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

    // MARK: - Loadout Menu

    private func setupLoadoutMenuController() {
        // build the controller once stratagemManager exists; from here on it owns rebuilding
        // and click handling for loadout items between the two separators
        guard let manager = stratagemManager,
              let menu = statusItem?.menu,
              let before = loadoutSeparatorBefore,
              let after = loadoutSeparatorAfter else { return }
        loadoutMenuController = LoadoutMenuController(
            menu: menu,
            manager: manager,
            separatorBefore: before,
            separatorAfter: after
        )
    }

    @objc func showSaveLoadoutDialog() {
        // thin shim — the menu item was created at startup with target=self because the controller
        // doesn't exist yet at that point. once it does, we just forward.
        loadoutMenuController?.showSaveLoadoutDialog()
    }
}

// MARK: - LoadoutMenuController

/// owns the dynamic loadout entries between two separators in the status item menu,
/// plus the "Save Loadout…" dialog and helpers. extracted from AppDelegate to keep
/// the application-lifecycle code focused on application-lifecycle concerns.
final class LoadoutMenuController: NSObject {
    private weak var menu: NSMenu?
    private let manager: StratagemManager
    private let separatorBefore: NSMenuItem
    private let separatorAfter: NSMenuItem
    private var loadoutMenuItems: [NSMenuItem] = []
    private var cancellables = Set<AnyCancellable>()

    init(menu: NSMenu,
         manager: StratagemManager,
         separatorBefore: NSMenuItem,
         separatorAfter: NSMenuItem) {
        self.menu = menu
        self.manager = manager
        self.separatorBefore = separatorBefore
        self.separatorAfter = separatorAfter
        super.init()

        // observe loadouts and active id changes and rebuild the menu on the main thread
        manager.$loadouts
            .combineLatest(manager.$activeLoadoutId)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _, _ in
                self?.rebuild()
            }
            .store(in: &cancellables)

        rebuild()
    }

    private func rebuild() {
        guard let menu = menu else { return }
        // find indices — NSMenuItem doesn't override Equatable so firstIndex(of:) here matches by
        // object identity, which works because we hold the same NSMenuItem references stored above
        guard let beforeIndex = menu.items.firstIndex(of: separatorBefore),
              menu.items.firstIndex(of: separatorAfter) != nil else { return }

        // remove existing loadout items between the separators
        for item in loadoutMenuItems {
            menu.removeItem(item)
        }
        loadoutMenuItems.removeAll()

        // hide both separators if there are no loadouts
        separatorBefore.isHidden = manager.loadouts.isEmpty
        separatorAfter.isHidden = manager.loadouts.isEmpty

        // add loadout items with numbers (1-9 for keyboard shortcuts)
        var insertIndex = beforeIndex + 1
        for (index, loadout) in manager.loadouts.enumerated() {
            // show number prefix for first 9 loadouts (keyboard shortcuts)
            let numberPrefix = index < 9 ? "\(index + 1)  " : ""
            let item = NSMenuItem(
                title: "\(numberPrefix)\(loadout.name)",
                action: #selector(loadoutClicked(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = loadout.id
            item.state = (manager.activeLoadoutId == loadout.id) ? .on : .off

            menu.insertItem(item, at: insertIndex)
            loadoutMenuItems.append(item)
            insertIndex += 1
        }
    }

    @objc private func loadoutClicked(_ sender: NSMenuItem) {
        guard let loadoutId = sender.representedObject as? UUID else { return }
        manager.loadLoadout(id: loadoutId)
    }

    func showSaveLoadoutDialog() {
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
        textField.placeholderString = generateUniqueLoadoutName()
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
            let defaultName = generateUniqueLoadoutName()
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

    private func generateUniqueLoadoutName() -> String {
        var counter = manager.loadouts.count + 1
        var name = "Loadout \(counter)"
        while manager.loadouts.contains(where: { $0.name == name }) {
            counter += 1
            name = "Loadout \(counter)"
        }
        return name
    }
}
