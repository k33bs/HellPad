import Foundation
import Combine
import Carbon
import SwiftUI
import os.log

private let logger = Logger(subsystem: "com.hellpad.app", category: "stratagem")

class StratagemManager: ObservableObject {
    @Published var allStratagems: [Stratagem] = []
    @Published var equippedStratagems: [String] = Array(repeating: "Resupply", count: 8)
    @Published var keybinds: [Keybind] = []
    @Published var flashingSlotIndex: Int? = nil
    @Published var allowedApps: [String] = ["HELLDIVERS 2"]
    @Published var isPaused: Bool = false
    @Published var comboQueue: [Int] = []
    @Published var isExecutingCombo: Bool = false
    @Published var isExecutingStratagem: Bool = false  // Block input during single stratagem execution
    private var comboExecutionSemaphore: DispatchSemaphore?
    private let stratagemExecutionQueue = DispatchQueue(label: "com.hellpad.stratagem-execution", qos: .userInitiated)
    private let keyCodeLock = NSLock()
    private let pauseStateLock = NSLock()
    private let comboStateLock = NSLock()
    private let eventTapManager = EventTapManager()
    private let keySimulator = KeyPressSimulator()
    private var stratagemLookup: [String: Stratagem] = [:]
    private var helldiversKeybinds: HelldiversKeybinds?
    private var userDataURL: URL?
    private var keyCodeToSlotIndex: [CGKeyCode: Int] = [:]

    init() {
        setupUserDataDirectory()
        loadStratagems()
        loadUserData()
        loadHelldiversKeybinds()
        setupHotkeys()
    }

    private func setupUserDataDirectory() {
        guard let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            logger.error("Failed to get Application Support directory")
            return
        }

        let hellPadDir = appSupport.appendingPathComponent("HellPad", isDirectory: true)

        // Create directory if it doesn't exist
        if !FileManager.default.fileExists(atPath: hellPadDir.path) {
            try? FileManager.default.createDirectory(at: hellPadDir, withIntermediateDirectories: true)
        }

        userDataURL = hellPadDir.appendingPathComponent("user_data.json")

        // Copy default user_data.json from bundle if it doesn't exist in Application Support
        if let bundleURL = Bundle.main.url(forResource: "user_data", withExtension: "json"),
           let userURL = userDataURL,
           !FileManager.default.fileExists(atPath: userURL.path) {
            logger.debug("Copying default user_data.json from bundle to: \(userURL.path)")
            try? FileManager.default.copyItem(at: bundleURL, to: userURL)
        }
    }

    private func loadStratagems() {
        guard let url = Bundle.main.url(forResource: "stratagems", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let stratagems = try? JSONDecoder().decode([Stratagem].self, from: data) else {
            logger.error("Failed to load stratagems.json - FATAL")
            showFatalError(message: "Critical Error: stratagems.json is missing or corrupt.\n\nPlease reinstall the application.")
            return
        }

        allStratagems = stratagems
        for stratagem in stratagems {
            stratagemLookup[stratagem.name] = stratagem
        }
    }

    private func loadUserData() {
        // Load from Application Support, not bundle
        guard let url = userDataURL,
              FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let userData = try? JSONDecoder().decode(UserData.self, from: data) else {
            logger.error("Failed to load user_data.json from Application Support")
            setDefaultUserData()
            return
        }

        equippedStratagems = userData.equippedStratagems
        keybinds = userData.keybinds
        allowedApps = userData.allowedApps ?? ["HELLDIVERS 2"]  // Use default if not in file
    }

    private func loadHelldiversKeybinds() {
        guard let url = Bundle.main.url(forResource: "helldivers_keybinds_mac", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let keybinds = try? JSONDecoder().decode(HelldiversKeybinds.self, from: data) else {
            logger.error("Failed to load helldivers_keybinds_mac.json - FATAL")
            showFatalError(message: "Critical Error: helldivers_keybinds_mac.json is missing or corrupt.\n\nPlease reinstall the application.")
            return
        }

        helldiversKeybinds = keybinds
    }

    private func showFatalError(message: String) {
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "Fatal Error"
            alert.informativeText = message
            alert.alertStyle = .critical
            alert.addButton(withTitle: "Quit")
            alert.runModal()
            NSApplication.shared.terminate(nil)
        }
    }

    private func setDefaultUserData() {
        equippedStratagems = [
            "Resupply", "Reinforce", "Eagle Airstrike", "Eagle 500kg Bomb",
            "Orbital Precision Strike", "Orbital Railcannon Strike",
            "Hellbomb", "SEAF Artillery"
        ]

        keybinds = [
            Keybind(keyCode: "0x11", letter: "T"),
            Keybind(keyCode: "0x10", letter: "Y"),
            Keybind(keyCode: "0x04", letter: "H"),
            Keybind(keyCode: "0x2D", letter: "N"),
            Keybind(keyCode: "0x20", letter: "U"),
            Keybind(keyCode: "0x26", letter: "J"),
            Keybind(keyCode: "0x2E", letter: "M"),
            Keybind(keyCode: "0x28", letter: "K")
        ]
    }

    func setupHotkeys() {
        // Map key codes to their slot positions
        keyCodeLock.lock()
        keyCodeToSlotIndex.removeAll()
        for (index, keybind) in keybinds.enumerated() {
            if let keyCode = keySimulator.hexStringToKeyCode(keybind.keyCode) {
                keyCodeToSlotIndex[keyCode] = index
            }
        }
        keyCodeLock.unlock()

        // Listen for keypresses globally
        eventTapManager.onKeyPressed = { [weak self] (keyCode: CGKeyCode, isShiftHeld: Bool, isCtrlHeld: Bool) -> Bool in
            guard let self = self else { return false }

            // Shift+ESC cancels any active combo
            if keyCode == HBConstants.KeyCode.escape && isShiftHeld {
                if self.keySimulator.isAllowedAppActive(allowedApps: self.allowedApps) {
                    self.comboStateLock.lock()
                    let isExecuting = self.isExecutingCombo
                    self.comboStateLock.unlock()

                    // Check and clear combo queue on main thread
                    DispatchQueue.main.async {
                        if !self.comboQueue.isEmpty || isExecuting {
                            logger.debug("Combo cancelled")
                            self.comboQueue.removeAll()

                            // Stop the combo if it's running
                            if isExecuting {
                                self.comboStateLock.lock()
                                self.isExecutingCombo = false
                                self.comboStateLock.unlock()
                                self.comboExecutionSemaphore?.signal()
                            }
                        }
                    }
                    return true
                }
            }

            // Ctrl+P toggles pause state - only in allowed apps
            if keyCode == HBConstants.KeyCode.pause && isCtrlHeld {
                if self.keySimulator.isAllowedAppActive(allowedApps: self.allowedApps) {
                    DispatchQueue.main.async {
                        self.pauseStateLock.lock()
                        self.isPaused.toggle()
                        let newState = self.isPaused
                        self.pauseStateLock.unlock()
                        logger.info("HellPad \(newState ? "PAUSED" : "ACTIVE")")
                    }
                    return true
                }
            }

            // When paused, let all keys through normally
            self.pauseStateLock.lock()
            let currentlyPaused = self.isPaused
            self.pauseStateLock.unlock()
            if currentlyPaused {
                return false
            }

            // Check if this is one of our assigned hotkeys
            self.keyCodeLock.lock()
            let slotIndex = self.keyCodeToSlotIndex[keyCode]
            self.keyCodeLock.unlock()

            guard let slotIndex = slotIndex else {
                return false  // Not our key, pass it through
            }

            // Block hotkeys while stratagem is executing
            if self.isExecutingStratagem {
                return true  // Consume but ignore
            }

            // Only consume the key if an allowed app is active
            if self.keySimulator.isAllowedAppActive(allowedApps: self.allowedApps) {
                // Ctrl+key passes through (used by game for stratagem menu)
                if isCtrlHeld {
                    return false
                }

                if isShiftHeld {
                    // Shift+key adds to combo queue (main thread for @Published property)
                    DispatchQueue.main.async {
                        if !self.comboQueue.contains(slotIndex) {
                            self.comboQueue.append(slotIndex)
                            logger.debug("Added slot \(slotIndex) to combo")
                        } else {
                            logger.debug("Slot \(slotIndex) already in combo")
                        }
                    }
                } else {
                    // Plain keypress triggers the stratagem immediately
                    self.handleHotkeyPressed(slotIndex: slotIndex)
                }
                return true
            } else {
                return false
            }
        }

        // When Shift is released, execute the queued combo
        eventTapManager.onShiftReleased = { [weak self] in
            guard let self = self else { return }

            self.comboStateLock.lock()
            let isExecuting = self.isExecutingCombo
            self.comboStateLock.unlock()

            if isExecuting { return }

            // Access comboQueue on main thread
            DispatchQueue.main.async {
                if !self.comboQueue.isEmpty {
                    logger.info("Starting combo with \(self.comboQueue.count) stratagems")
                    let queuedSlots = self.comboQueue
                    self.comboQueue.removeAll()

                    self.comboStateLock.lock()
                    self.isExecutingCombo = true
                    self.comboStateLock.unlock()

                    // Short delay lets Ctrl key fully release before we start
                    DispatchQueue.main.asyncAfter(deadline: .now() + HBConstants.Timing.ctrlReleaseDelay) {
                        self.executeCombo(slots: queuedSlots)
                    }
                }
            }
        }

        // Listen for mouse clicks while combo is running
        eventTapManager.onMouseClicked = { [weak self] in
            guard let self = self else { return }
            // Player clicked, continue to next stratagem
            self.comboExecutionSemaphore?.signal()
        }

        eventTapManager.setupEventTap()
    }

    private func executeCombo(slots: [Int]) {
        logger.info("Executing combo sequence")

        comboExecutionSemaphore = DispatchSemaphore(value: 0)

        // Execute all stratagems in sequence on serial queue
        stratagemExecutionQueue.async {
            for (index, slotIndex) in slots.enumerated() {
                // Check if combo was cancelled (thread-safe read)
                self.comboStateLock.lock()
                let isExecuting = self.isExecutingCombo
                self.comboStateLock.unlock()

                if !isExecuting {
                    logger.info("Combo execution cancelled")
                    break
                }

                self.executeStratagemAtSlot(slotIndex: slotIndex)

                // Wait for player to throw this stratagem before continuing
                if index < slots.count - 1 {
                    logger.debug("Waiting for click to throw...")
                    // Give player 3 seconds to click
                    let result = self.comboExecutionSemaphore?.wait(timeout: .now() + HBConstants.Timing.comboWaitTimeout)

                    // Check again if cancelled during wait (thread-safe read)
                    self.comboStateLock.lock()
                    let stillExecuting = self.isExecutingCombo
                    self.comboStateLock.unlock()

                    if !stillExecuting {
                        logger.info("Combo cancelled")
                        break
                    }

                    if result == .timedOut {
                        logger.info("Combo timed out, stopping")
                        break
                    }
                    logger.debug("Click detected, continuing combo")
                    usleep(HBConstants.Timing.afterMouseClick)
                }
            }

            // Clean up on main thread with lock
            DispatchQueue.main.async {
                self.comboStateLock.lock()
                self.isExecutingCombo = false
                self.comboStateLock.unlock()
            }
            self.comboExecutionSemaphore = nil
        }
    }

    private func handleHotkeyPressed(slotIndex: Int) {
        logger.debug("Activating slot \(slotIndex)")

        guard slotIndex < equippedStratagems.count else { return }

        // Trigger flash INSTANTLY on main thread
        DispatchQueue.main.async {
            self.flashingSlotIndex = slotIndex
            self.isExecutingStratagem = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + HBConstants.Timing.flashDuration) {
            self.flashingSlotIndex = nil
        }

        // Execute on serial queue to prevent interleaving
        stratagemExecutionQueue.async {
            self.executeStratagemAtSlot(slotIndex: slotIndex)

            // Clear executing flag when done
            DispatchQueue.main.async {
                self.isExecutingStratagem = false
            }
        }
    }

    private func executeStratagemAtSlot(slotIndex: Int) {
        guard slotIndex < equippedStratagems.count else { return }

        let stratagemName = equippedStratagems[slotIndex]
        guard let stratagem = stratagemLookup[stratagemName],
              let helldiversKeybinds = helldiversKeybinds,
              let menuKeyCode = keySimulator.hexStringToKeyCode(helldiversKeybinds.stratagemMenu) else {
            return
        }

        logger.info("Executing stratagem: \(stratagemName)")
        keySimulator.executeStratagem(sequence: stratagem.sequence,
                                      stratagemMenuKeyCode: menuKeyCode)
    }

    func updateEquippedStratagem(at index: Int, with stratagemName: String) {
        guard index < equippedStratagems.count else { return }
        equippedStratagems[index] = stratagemName
        saveUserData()
    }

    func startListeningForKeybind(at index: Int) {
        guard index < keybinds.count else { return }
        // Temporarily disable event tap while listening to avoid conflicts
        eventTapManager.disable()
        logger.debug("Listening for new key on slot \(index)")
    }

    func updateKeybind(at index: Int, keyCode: String, letter: String) {
        guard index < keybinds.count else { return }

        // Update keybind
        keybinds[index] = Keybind(keyCode: keyCode, letter: letter)

        // Re-setup event tap with new keybinds
        setupHotkeys()
        logger.info("Slot \(index) rebound to '\(letter)'")

        saveUserData()
    }

    func cancelKeybindListening() {
        // Re-enable event tap after cancel
        setupHotkeys()
        logger.debug("Rebind cancelled")
    }

    func saveAllSettings() {
        saveUserData()
    }

    private func saveUserData() {
        // Save to Application Support, not bundle
        let userData = UserData(equippedStratagems: equippedStratagems, keybinds: keybinds, allowedApps: allowedApps)
        guard let data = try? JSONEncoder().encode(userData),
              let url = userDataURL else {
            logger.error("Failed to save user_data.json - no valid URL")
            return
        }

        do {
            try data.write(to: url, options: .atomic)
            logger.debug("User data saved to: \(url.path)")
        } catch {
            logger.error("Failed to write user_data.json: \(error.localizedDescription)")
        }
    }
}
