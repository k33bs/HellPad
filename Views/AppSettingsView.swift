import SwiftUI
import AppKit

struct AppSettingsView: View {
    @ObservedObject var stratagemManager: StratagemManager
    @State private var runningApps: [RunningApp] = []
    @State private var selectedTab = 0

    var body: some View {
        VStack(spacing: 0) {
            // Tab bar
            HStack(spacing: 0) {
                TabButton(title: "Apps", isSelected: selectedTab == 0) {
                    selectedTab = 0
                }
                TabButton(title: "Controls", isSelected: selectedTab == 1) {
                    selectedTab = 1
                }
                TabButton(title: "Loadouts", isSelected: selectedTab == 2) {
                    selectedTab = 2
                }
                Spacer()
            }
            .padding(.horizontal)
            .padding(.top, 8)

            Divider()
                .padding(.top, 8)

            // Tab content - use ZStack to prevent layout shifts
            ZStack(alignment: .topLeading) {
                AppsTabView(stratagemManager: stratagemManager, runningApps: $runningApps)
                    .opacity(selectedTab == 0 ? 1 : 0)

                ControlsTabView(stratagemManager: stratagemManager)
                    .opacity(selectedTab == 1 ? 1 : 0)

                LoadoutsTabView(stratagemManager: stratagemManager)
                    .opacity(selectedTab == 2 ? 1 : 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(width: 500, height: 460)
        .onAppear {
            loadRunningApps()
        }
    }

    private func loadRunningApps() {
        let workspace = NSWorkspace.shared
        runningApps = workspace.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { app in
                guard let name = app.localizedName else { return nil }
                return RunningApp(name: name, icon: app.icon)
            }
            .sorted { $0.name < $1.name }
    }
}

// MARK: - Tab Button

struct TabButton: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                .foregroundColor(isSelected ? .primary : .secondary)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
        }
        .buttonStyle(PlainButtonStyle())
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? Color.accentColor.opacity(0.15) : Color.clear)
        )
    }
}

// MARK: - Apps Tab

struct AppsTabView: View {
    @ObservedObject var stratagemManager: StratagemManager
    @Binding var runningApps: [RunningApp]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Hotkeys will only work when these apps are active:")
                .font(.caption)
                .foregroundColor(.secondary)

            HStack(spacing: 16) {
                // Left side: Currently allowed apps
                VStack(alignment: .leading, spacing: 8) {
                    Text("Allowed Apps")
                        .font(.subheadline)
                        .fontWeight(.medium)

                    List {
                        ForEach(stratagemManager.allowedApps, id: \.self) { appName in
                            HStack {
                                Text(appName)
                                Spacer()
                                Button(action: {
                                    stratagemManager.allowedApps.removeAll { $0 == appName }
                                    stratagemManager.saveAllSettings()
                                }) {
                                    Image(systemName: "minus.circle.fill")
                                        .foregroundColor(.red)
                                }
                                .buttonStyle(PlainButtonStyle())
                            }
                        }
                    }
                }

                Divider()

                // Right side: Running apps selector
                VStack(alignment: .leading, spacing: 8) {
                    Text("Running Apps")
                        .font(.subheadline)
                        .fontWeight(.medium)

                    List {
                        ForEach(runningApps, id: \.name) { app in
                            HStack {
                                if let icon = app.icon {
                                    Image(nsImage: icon)
                                        .resizable()
                                        .frame(width: 16, height: 16)
                                }
                                Text(app.name)
                                Spacer()
                                Button(action: {
                                    if !stratagemManager.allowedApps.contains(app.name) {
                                        stratagemManager.allowedApps.append(app.name)
                                        stratagemManager.saveAllSettings()
                                    }
                                }) {
                                    Image(systemName: "plus.circle.fill")
                                        .foregroundColor(.green)
                                }
                                .buttonStyle(PlainButtonStyle())
                                .disabled(stratagemManager.allowedApps.contains(app.name))
                            }
                        }
                    }

                    Button("Refresh") {
                        let workspace = NSWorkspace.shared
                        runningApps = workspace.runningApplications
                            .filter { $0.activationPolicy == .regular }
                            .compactMap { app in
                                guard let name = app.localizedName else { return nil }
                                return RunningApp(name: name, icon: app.icon)
                            }
                            .sorted { $0.name < $1.name }
                    }
                }
            }
        }
        .padding()
    }
}

// MARK: - Controls Tab

struct ControlsTabView: View {
    @ObservedObject var stratagemManager: StratagemManager
    @State private var listeningFor: KeybindTarget? = nil
    @State private var keyEventMonitor: Any? = nil
    @State private var flagsEventMonitor: Any? = nil

    enum KeybindTarget: Equatable {
        case superKey
        case comboKey
        case directional(String)  // "up", "down", "left", "right"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Stratagem Menu Key
                VStack(alignment: .leading, spacing: 8) {
                Text("Stratagem Menu Key")
                    .font(.subheadline)
                    .fontWeight(.medium)

                HStack {
                    KeybindButton(
                        label: getKeyLabel(for: .superKey),
                        isListening: listeningFor == .superKey
                    ) {
                        startListening(for: .superKey)
                    }

                    Text("The key that opens the stratagem menu in-game")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            Divider()

            // Combo Queue Key
            VStack(alignment: .leading, spacing: 8) {
                Text("Combo Queue Key")
                    .font(.subheadline)
                    .fontWeight(.medium)

                HStack {
                    KeybindButton(
                        label: getKeyLabel(for: .comboKey),
                        isListening: listeningFor == .comboKey
                    ) {
                        startListening(for: .comboKey)
                    }

                    Text("Hold this key + hotkeys to queue multiple stratagems")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            Divider()

            // Activation Mode
            VStack(alignment: .leading, spacing: 8) {
                Text("Activation Mode")
                    .font(.subheadline)
                    .fontWeight(.medium)

                Picker("", selection: Binding(
                    get: { stratagemManager.activationMode },
                    set: { stratagemManager.updateActivationMode($0) }
                )) {
                    Text("Hold").tag(ActivationMode.hold)
                    Text("Toggle").tag(ActivationMode.toggle)
                }
                .pickerStyle(SegmentedPickerStyle())
                .frame(width: 200)

                Text(stratagemManager.activationMode == .hold
                    ? "Hold the menu key while pressing directions"
                    : "Press menu key once, then press directions")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Divider()

            // Directional Keys
            VStack(alignment: .leading, spacing: 8) {
                Text("Directional Keys")
                    .font(.subheadline)
                    .fontWeight(.medium)

                HStack(spacing: 40) {
                    // Cross pattern for directional keys
                    VStack(spacing: 4) {
                        KeybindButton(
                            label: getKeyLabel(for: .directional("up")),
                            isListening: listeningFor == .directional("up")
                        ) {
                            startListening(for: .directional("up"))
                        }

                        HStack(spacing: 4) {
                            KeybindButton(
                                label: getKeyLabel(for: .directional("left")),
                                isListening: listeningFor == .directional("left")
                            ) {
                                startListening(for: .directional("left"))
                            }

                            KeybindButton(
                                label: getKeyLabel(for: .directional("down")),
                                isListening: listeningFor == .directional("down")
                            ) {
                                startListening(for: .directional("down"))
                            }

                            KeybindButton(
                                label: getKeyLabel(for: .directional("right")),
                                isListening: listeningFor == .directional("right")
                            ) {
                                startListening(for: .directional("right"))
                            }
                        }
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Click a key to rebind")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text("Press ESC to cancel")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }

            Divider()

            // Hover Preview
            VStack(alignment: .leading, spacing: 8) {
                Toggle(isOn: Binding(
                    get: { stratagemManager.hoverPreviewEnabled },
                    set: {
                        stratagemManager.hoverPreviewEnabled = $0
                        stratagemManager.saveAllSettings()
                    }
                )) {
                    Text("Hover Preview")
                        .font(.subheadline)
                        .fontWeight(.medium)
                }
                .toggleStyle(.switch)

                Text("Show magnified icon when hovering in stratagem picker")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding()
        }
        .onDisappear {
            stopListening()
        }
    }

    private func getKeyLabel(for target: KeybindTarget) -> String {
        if listeningFor == target {
            return "..."
        }

        switch target {
        case .superKey:
            return stratagemManager.superKey.letter
        case .comboKey:
            return stratagemManager.comboKey.letter
        case .directional(let direction):
            switch direction {
            case "up": return stratagemManager.directionalKeys.up.letter
            case "down": return stratagemManager.directionalKeys.down.letter
            case "left": return stratagemManager.directionalKeys.left.letter
            case "right": return stratagemManager.directionalKeys.right.letter
            default: return "?"
            }
        }
    }

    private func startListening(for target: KeybindTarget) {
        listeningFor = target
        setupKeyMonitor()
    }

    private func stopListening() {
        listeningFor = nil
        if let monitor = keyEventMonitor {
            NSEvent.removeMonitor(monitor)
            keyEventMonitor = nil
        }
        if let monitor = flagsEventMonitor {
            NSEvent.removeMonitor(monitor)
            flagsEventMonitor = nil
        }
    }

    private func setupKeyMonitor() {
        // Remove existing monitors
        if let monitor = keyEventMonitor {
            NSEvent.removeMonitor(monitor)
            keyEventMonitor = nil
        }
        if let monitor = flagsEventMonitor {
            NSEvent.removeMonitor(monitor)
            flagsEventMonitor = nil
        }

        // Monitor for regular key presses
        keyEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard let target = listeningFor else { return event }

            // ESC cancels
            if event.keyCode == 0x35 {  // ESC
                stopListening()
                return nil
            }

            let keyCode = event.keyCode
            let keyCodeHex = String(format: "0x%02X", keyCode)

            // Get display string for the key
            let keyString = getKeyDisplayString(event: event, keyCode: keyCode)

            // Apply the keybind
            applyKeybind(target: target, keyCode: keyCodeHex, letter: keyString)
            stopListening()
            return nil
        }

        // Monitor for modifier keys (Control, Option, Command, Shift)
        flagsEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
            guard let target = listeningFor else { return event }

            let flags = event.modifierFlags
            var keyCode: UInt16? = nil
            var keyString: String? = nil

            // Detect which modifier was pressed (check the key that changed)
            if flags.contains(.control) && event.keyCode == 0x3B {
                keyCode = 0x3B
                keyString = "⌃"
            } else if flags.contains(.option) && event.keyCode == 0x3A {
                keyCode = 0x3A
                keyString = "⌥"
            } else if flags.contains(.command) && event.keyCode == 0x37 {
                keyCode = 0x37
                keyString = "⌘"
            } else if flags.contains(.shift) && event.keyCode == 0x38 {
                keyCode = 0x38
                keyString = "⇧"
            }
            // Right-side modifiers
            else if flags.contains(.control) && event.keyCode == 0x3E {
                keyCode = 0x3E
                keyString = "⌃"
            } else if flags.contains(.option) && event.keyCode == 0x3D {
                keyCode = 0x3D
                keyString = "⌥"
            } else if flags.contains(.command) && event.keyCode == 0x36 {
                keyCode = 0x36
                keyString = "⌘"
            } else if flags.contains(.shift) && event.keyCode == 0x3C {
                keyCode = 0x3C
                keyString = "⇧"
            }

            if let keyCode = keyCode, let keyString = keyString {
                let keyCodeHex = String(format: "0x%02X", keyCode)
                applyKeybind(target: target, keyCode: keyCodeHex, letter: keyString)
                stopListening()
            }

            return event
        }
    }

    private func applyKeybind(target: KeybindTarget, keyCode: String, letter: String) {
        switch target {
        case .superKey:
            stratagemManager.updateSuperKey(keyCode: keyCode, letter: letter)
        case .comboKey:
            stratagemManager.updateComboKey(keyCode: keyCode, letter: letter)
        case .directional(let direction):
            stratagemManager.updateDirectionalKey(direction, keyCode: keyCode, letter: letter)
        }
    }

    private func getKeyDisplayString(event: NSEvent, keyCode: UInt16) -> String {
        // Handle special keys
        switch keyCode {
        case 0x7E: return "↑"
        case 0x7D: return "↓"
        case 0x7B: return "←"
        case 0x7C: return "→"
        case 0x31: return "Space"
        case 0x24: return "↵"
        case 0x30: return "Tab"
        case 0x33: return "⌫"
        case 0x35: return "ESC"
        case 0x3B: return "⌃"  // Control
        case 0x3A: return "⌥"  // Option
        case 0x37: return "⌘"  // Command
        case 0x38: return "⇧"  // Shift
        default:
            return event.charactersIgnoringModifiers?.uppercased() ?? "?"
        }
    }
}

// MARK: - Loadouts Tab

struct LoadoutsTabView: View {
    @ObservedObject var stratagemManager: StratagemManager
    @State private var loadoutToDelete: Loadout? = nil
    @State private var showDeleteConfirmation = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Manage your saved stratagem loadouts. Click a loadout in the menu bar to switch.")
                .font(.caption)
                .foregroundColor(.secondary)

            if stratagemManager.loadouts.isEmpty {
                VStack(spacing: 8) {
                    Spacer()
                    Image(systemName: "tray")
                        .font(.system(size: 40))
                        .foregroundColor(.secondary)
                    Text("No loadouts saved")
                        .font(.headline)
                        .foregroundColor(.secondary)
                    Text("Use \"Save Loadout...\" from the menu bar to create one.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(stratagemManager.loadouts) { loadout in
                        HStack(spacing: 12) {
                            // Active indicator
                            if stratagemManager.activeLoadoutId == loadout.id {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(.green)
                                    .frame(width: 20)
                            } else {
                                Color.clear
                                    .frame(width: 20, height: 20)
                            }

                            VStack(alignment: .leading, spacing: 2) {
                                Text(loadout.name)
                                    .fontWeight(.medium)
                                Text(loadout.equippedStratagems.prefix(4).joined(separator: ", "))
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                            }

                            Spacer()

                            // Load button
                            Button("Load") {
                                stratagemManager.loadLoadout(id: loadout.id)
                            }
                            .disabled(stratagemManager.activeLoadoutId == loadout.id)

                            // Delete button
                            Button(action: {
                                loadoutToDelete = loadout
                                showDeleteConfirmation = true
                            }) {
                                Image(systemName: "trash")
                                    .foregroundColor(.red)
                            }
                            .buttonStyle(PlainButtonStyle())
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
        }
        .padding()
        .alert("Delete Loadout?", isPresented: $showDeleteConfirmation, presenting: loadoutToDelete) { loadout in
            Button("Cancel", role: .cancel) { }
            Button("Delete", role: .destructive) {
                stratagemManager.deleteLoadout(id: loadout.id)
            }
        } message: { loadout in
            Text("Are you sure you want to delete \"\(loadout.name)\"? This cannot be undone.")
        }
    }
}

// MARK: - Keybind Button

struct KeybindButton: View {
    let label: String
    let isListening: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 14, weight: .medium, design: .monospaced))
                .frame(width: 44, height: 32)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(isListening ? Color.accentColor.opacity(0.3) : Color(NSColor.controlBackgroundColor))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(isListening ? Color.accentColor : Color.gray.opacity(0.3), lineWidth: 1)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
    }
}

struct RunningApp {
    let name: String
    let icon: NSImage?
}
