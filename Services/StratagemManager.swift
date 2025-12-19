import AppKit
import Carbon
import Combine
import Foundation
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

    @Published var recentStratagemNames: [String] = []

    // Configurable game keybinds
    @Published var superKey: Keybind = Keybind(keyCode: "0x3B", letter: "⌃")  // Default: Control
    @Published var activationMode: ActivationMode = .hold
    @Published var directionalKeys: DirectionalKeybinds = .defaultWASD
    @Published var comboKey: Keybind = Keybind(keyCode: "0x37", letter: "⌘")  // Default: Left Command
    @Published var loadoutKey: Keybind = Keybind(keyCode: "0x3A", letter: "⌥")  // Default: Left Option
    @Published var loadouts: [Loadout] = []
    @Published var activeLoadoutId: UUID? = nil  // nil = dirty/no loadout active
    @Published var hoverPreviewEnabled: Bool = true
    @Published var voiceFeedbackEnabled: Bool = false
    @Published var selectedVoice: String? = nil  // nil = system default
    @Published var voiceVolume: Float = 0.5  // 0.0 to 1.0
    private let speechSynthesizer = NSSpeechSynthesizer()

    // Available voices for TTS (computed once to avoid repeated I/O)
    let availableVoices: [(identifier: String, name: String)] = {
        NSSpeechSynthesizer.availableVoices.compactMap { voiceId in
            let attrs = NSSpeechSynthesizer.attributes(forVoice: voiceId)
            guard let name = attrs[.name] as? String else { return nil }
            return (identifier: voiceId.rawValue, name: name)
        }.sorted { $0.name < $1.name }
    }()
    private var comboExecutionSemaphore: DispatchSemaphore?
    private let stratagemExecutionQueue = DispatchQueue(
        label: "com.hellpad.stratagem-execution", qos: .userInitiated)
    private let keyCodeLock = NSLock()
    private let pauseStateLock = NSLock()
    private let comboStateLock = NSLock()
    private let executingLock = NSLock()
    private var _isExecutingFlag = false  // Thread-safe flag for immediate checking
    private let appActiveLock = NSLock()
    private var _isAllowedAppActive = false  // Cached app state to avoid IPC in event tap
    private var appObserver: NSObjectProtocol?
    private let eventTapManager = EventTapManager()
    private let keySimulator = KeyPressSimulator()
    private var stratagemLookup: [String: Stratagem] = [:]
    private var userDataURL: URL?
    private var keyCodeToSlotIndex: [CGKeyCode: Int] = [:]

    private lazy var loadoutGridReader: LoadoutGridReader = {
        LoadoutGridReader(canonicalStratagemNames: self.allStratagems.map { $0.name })
    }()
    private let loadoutGridReaderQueue = DispatchQueue(
        label: "com.hellpad.loadout-grid-reader", qos: .userInitiated)
    private let loadoutGridReaderLock = NSLock()
    private var isLoadoutGridReaderRunning = false

    #if DEBUG
        private let loadoutGridDebugWindowController = LoadoutGridDebugWindowController()
    #endif

    init() {
        setupUserDataDirectory()
        loadStratagems()
        loadUserData()
        setupAppObserver()
        setupHotkeys()
    }

    deinit {
        if let appObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(appObserver)
        }
    }

    func recordRecentStratagem(name: String) {
        if recentStratagemNames.first == name {
            return
        }
        recentStratagemNames.removeAll { $0 == name }
        recentStratagemNames.insert(name, at: 0)
        if recentStratagemNames.count > 6 {
            recentStratagemNames = Array(recentStratagemNames.prefix(6))
        }
    }

    private func isHellPadFrontmost() -> Bool {
        let frontmost = NSWorkspace.shared.frontmostApplication
        if let bundleId = Bundle.main.bundleIdentifier, !bundleId.isEmpty {
            return frontmost?.bundleIdentifier == bundleId
        }
        return frontmost?.localizedName == "HellPad"
    }

    private func setupAppObserver() {
        // Cache active app state to avoid IPC calls in event tap callback
        let updateAppState = { [weak self] in
            guard let self = self else { return }
            let isActive = self.keySimulator.isAllowedAppActive(allowedApps: self.allowedApps)
            self.appActiveLock.lock()
            self._isAllowedAppActive = isActive
            self.appActiveLock.unlock()
        }

        // Initial check
        updateAppState()

        // Observe app activation changes
        appObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { _ in updateAppState() }
    }

    private func updateCachedAppState() {
        let isActive = keySimulator.isAllowedAppActive(allowedApps: allowedApps)
        appActiveLock.lock()
        _isAllowedAppActive = isActive
        appActiveLock.unlock()
    }

    private func setupUserDataDirectory() {
        guard
            let appSupport = FileManager.default.urls(
                for: .applicationSupportDirectory, in: .userDomainMask
            ).first
        else {
            logger.error("Failed to get Application Support directory")
            return
        }

        let hellPadDir = appSupport.appendingPathComponent("HellPad", isDirectory: true)

        // Create directory if it doesn't exist
        if !FileManager.default.fileExists(atPath: hellPadDir.path) {
            try? FileManager.default.createDirectory(
                at: hellPadDir, withIntermediateDirectories: true)
        }

        userDataURL = hellPadDir.appendingPathComponent("user_data.json")

        // Copy default user_data.json from bundle if it doesn't exist in Application Support
        if let bundleURL = Bundle.main.url(forResource: "user_data", withExtension: "json"),
            let userURL = userDataURL,
            !FileManager.default.fileExists(atPath: userURL.path)
        {
            logger.debug("Copying default user_data.json from bundle to: \(userURL.path)")
            try? FileManager.default.copyItem(at: bundleURL, to: userURL)
        }
    }

    private func loadStratagems() {
        guard let url = Bundle.main.url(forResource: "stratagems", withExtension: "json"),
            let data = try? Data(contentsOf: url),
            let stratagems = try? JSONDecoder().decode([Stratagem].self, from: data)
        else {
            logger.error("Failed to load stratagems.json - FATAL")
            showFatalError(
                message:
                    "Critical Error: stratagems.json is missing or corrupt.\n\nPlease reinstall the application."
            )
            return
        }

        // Sort by category order (Common, Objectives, Offensive, Supply, Defense)
        allStratagems = stratagems.sorted { $0.categorySortIndex < $1.categorySortIndex }
        for stratagem in stratagems {
            stratagemLookup[stratagem.name] = stratagem
        }
    }

    private func loadUserData() {
        // Load from Application Support, not bundle
        guard let url = userDataURL,
            FileManager.default.fileExists(atPath: url.path),
            let data = try? Data(contentsOf: url),
            let userData = try? JSONDecoder().decode(UserData.self, from: data)
        else {
            logger.error("Failed to load user_data.json from Application Support")
            setDefaultUserData()
            return
        }

        equippedStratagems = userData.equippedStratagems
        keybinds = userData.keybinds
        allowedApps = userData.allowedApps ?? ["HELLDIVERS 2"]

        // Load new configurable keybind settings (with defaults for backwards compatibility)
        superKey = userData.superKey ?? Keybind(keyCode: "0x3B", letter: "⌃")
        activationMode = userData.activationMode ?? .hold
        directionalKeys = userData.directionalKeys ?? .defaultWASD
        comboKey = userData.comboKey ?? Keybind(keyCode: "0x37", letter: "⌘")
        loadoutKey = userData.loadoutKey ?? Keybind(keyCode: "0x3A", letter: "⌥")

        // Load loadouts (optional for backwards compatibility)
        loadouts = userData.loadouts ?? []
        activeLoadoutId = userData.activeLoadoutId.flatMap { UUID(uuidString: $0) }
        hoverPreviewEnabled = userData.hoverPreviewEnabled ?? true
        voiceFeedbackEnabled = userData.voiceFeedbackEnabled ?? false
        selectedVoice = userData.selectedVoice
        voiceVolume = userData.voiceVolume ?? 0.5
        recentStratagemNames = Array((userData.recentStratagemNames ?? []).prefix(6))
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
            "Hellbomb", "SEAF Artillery",
        ]

        keybinds = [
            Keybind(keyCode: "0x11", letter: "T"),
            Keybind(keyCode: "0x10", letter: "Y"),
            Keybind(keyCode: "0x04", letter: "H"),
            Keybind(keyCode: "0x2D", letter: "N"),
            Keybind(keyCode: "0x20", letter: "U"),
            Keybind(keyCode: "0x26", letter: "J"),
            Keybind(keyCode: "0x2E", letter: "M"),
            Keybind(keyCode: "0x28", letter: "K"),
        ]

        recentStratagemNames = []
    }

    func setupHotkeys() {
        // Map key codes to their slot positions
        do {
            keyCodeLock.lock()
            defer { keyCodeLock.unlock() }
            keyCodeToSlotIndex.removeAll()
            for (index, keybind) in keybinds.enumerated() {
                if let keyCode = keySimulator.hexStringToKeyCode(keybind.keyCode) {
                    keyCodeToSlotIndex[keyCode] = index
                }
            }
        }

        // Set the configurable combo key code
        if let comboKeyCode = keySimulator.hexStringToKeyCode(comboKey.keyCode) {
            eventTapManager.comboKeyCode = comboKeyCode
        }

        // Listen for keypresses globally
        eventTapManager.onKeyPressed = {
            [weak self] (keyCode: CGKeyCode, isComboKeyHeld: Bool, isCtrlHeld: Bool) -> Bool in
            guard let self = self else { return false }

            // ComboKey+ESC cancels any active combo
            if keyCode == HBConstants.KeyCode.escape && isComboKeyHeld {
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

            // Loadout key + number (1-9) switches loadouts
            if let loadoutKeyCode = self.keySimulator.hexStringToKeyCode(self.loadoutKey.keyCode),
                CGEventSource.keyState(.hidSystemState, key: loadoutKeyCode)
            {
                if keyCode == HBConstants.KeyCode.zero {
                    if self.keySimulator.isAllowedAppActive(allowedApps: self.allowedApps)
                        || self.isHellPadFrontmost()
                    {
                        self.triggerLoadoutGridRead()
                        return true
                    }
                }

                if let loadoutIndex = HBConstants.KeyCode.loadoutIndex(for: keyCode) {
                    if self.keySimulator.isAllowedAppActive(allowedApps: self.allowedApps)
                        || self.isHellPadFrontmost()
                    {
                        DispatchQueue.main.async {
                            if loadoutIndex < self.loadouts.count {
                                let loadout = self.loadouts[loadoutIndex]
                                self.loadLoadout(id: loadout.id)
                                logger.info(
                                    "Switched to loadout \(loadoutIndex + 1): \(loadout.name)")
                            } else {
                                logger.debug("No loadout at index \(loadoutIndex + 1)")
                            }
                        }
                        return true
                    }
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

            // Check if this is the combo key itself being pressed
            let comboKeyCode = self.keySimulator.hexStringToKeyCode(self.comboKey.keyCode)
            let isComboKey = (comboKeyCode != nil && keyCode == comboKeyCode!)

            guard let slotIndex = slotIndex else {
                // Not our hotkey - but if it's the combo key in an allowed app, consume it
                if isComboKey && self.keySimulator.isAllowedAppActive(allowedApps: self.allowedApps)
                {
                    return true  // Consume combo key press to prevent typing
                }
                return false  // Not our key, pass it through
            }

            // Block hotkeys while stratagem is executing (use lock-protected flag)
            self.executingLock.lock()
            let isExecuting = self._isExecutingFlag
            self.executingLock.unlock()
            if isExecuting {
                return true  // Consume but ignore
            }

            // Only consume the key if an allowed app is active
            if self.keySimulator.isAllowedAppActive(allowedApps: self.allowedApps) {
                // Check if the configured Super Key is PHYSICALLY held (manual menu interaction)
                // Use .hidSystemState to ignore virtual key state from our simulated events
                if let superKeyCode = self.keySimulator.hexStringToKeyCode(self.superKey.keyCode) {
                    let isSuperKeyHeld = CGEventSource.keyState(.hidSystemState, key: superKeyCode)
                    if isSuperKeyHeld {
                        return false
                    }
                }

                if isComboKeyHeld {
                    // ComboKey+key adds to combo queue (main thread for @Published property)
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

        // When combo key is released, execute the queued combo
        eventTapManager.onComboKeyReleased = { [weak self] in
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
                    DispatchQueue.main.asyncAfter(
                        deadline: .now() + HBConstants.Timing.ctrlReleaseDelay
                    ) {
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

    private func triggerLoadoutGridRead() {
        loadoutGridReaderQueue.async {
            self.loadoutGridReaderLock.lock()
            if self.isLoadoutGridReaderRunning {
                self.loadoutGridReaderLock.unlock()
                return
            }
            self.isLoadoutGridReaderRunning = true
            self.loadoutGridReaderLock.unlock()

            defer {
                self.loadoutGridReaderLock.lock()
                self.isLoadoutGridReaderRunning = false
                self.loadoutGridReaderLock.unlock()
            }

            #if DEBUG
                DispatchQueue.main.async {
                    self.loadoutGridDebugWindowController.loadoutGridReader = self.loadoutGridReader
                    self.loadoutGridDebugWindowController.show()
                }
                let debugSnapshot = self.loadoutGridReader.readMissionStratagemDebug()
                if let debugSnapshot {
                    DispatchQueue.main.async {
                        self.loadoutGridDebugWindowController.setSnapshot(debugSnapshot)
                    }
                }
                let names = debugSnapshot?.names
            #else
                let names = self.loadoutGridReader.readMissionStratagemNames()
            #endif

            guard let names, names.count >= 4 else { return }

            DispatchQueue.main.async {
                var detectedNames: [String] = []
                for i in 0..<4 {
                    let name = names[i]
                    if !name.isEmpty {
                        self.updateEquippedStratagem(at: 2 + i, with: name)
                        detectedNames.append(name)
                    }
                }
                logger.info("Loadout grid read applied to slots 2-5")

                // Voice feedback for detected stratagems
                if self.voiceFeedbackEnabled && !detectedNames.isEmpty {
                    let voiceTexts = detectedNames.compactMap { name -> String? in
                        self.stratagemLookup[name]?.voiceText
                    }
                    if !voiceTexts.isEmpty {
                        let announcement = "loadout: " + voiceTexts.joined(separator: ", ")
                        if let voice = self.selectedVoice {
                            self.speechSynthesizer.setVoice(NSSpeechSynthesizer.VoiceName(rawValue: voice))
                        } else {
                            self.speechSynthesizer.setVoice(nil)
                        }
                        self.speechSynthesizer.volume = self.voiceVolume
                        self.speechSynthesizer.startSpeaking(announcement)
                    }
                }
            }
        }
    }

    private func executeCombo(slots: [Int]) {
        logger.info("Executing combo sequence")

        // Capture configuration on main thread to avoid race conditions
        let capturedStratagems = self.equippedStratagems
        let capturedSuperKey = self.superKey
        let capturedDirectionalKeys = self.directionalKeys
        let capturedActivationMode = self.activationMode
        let capturedStratagemLookup = self.stratagemLookup

        comboExecutionSemaphore = DispatchSemaphore(value: 0)

        // Block hotkey input during combo execution (lock-protected flag)
        executingLock.lock()
        _isExecutingFlag = true
        executingLock.unlock()

        // Update UI
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

                self.executeStratagemAtSlotWithConfig(
                    slotIndex: slotIndex,
                    equippedStratagems: capturedStratagems,
                    stratagemLookup: capturedStratagemLookup,
                    superKey: capturedSuperKey,
                    directionalKeys: capturedDirectionalKeys,
                    activationMode: capturedActivationMode
                )

                // Wait for player to throw this stratagem before continuing
                if index < slots.count - 1 {
                    // Drain any clicks that happened during stratagem execution
                    while self.comboExecutionSemaphore?.wait(timeout: .now()) == .success {}

                    logger.debug("Waiting for click to throw...")
                    // Give player 3 seconds to click
                    let result = self.comboExecutionSemaphore?.wait(
                        timeout: .now() + HBConstants.Timing.comboWaitTimeout)

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

            // Clear lock-protected flag immediately (no queue dependency)
            self.executingLock.lock()
            self._isExecutingFlag = false
            self.executingLock.unlock()

            // Update UI on main thread
            DispatchQueue.main.async {
                self.comboStateLock.lock()
                self.isExecutingCombo = false
                self.comboStateLock.unlock()
            }
            self.comboExecutionSemaphore = nil
        }
    }

    // Thread-safe version that uses captured config values
    private func executeStratagemAtSlotWithConfig(
        slotIndex: Int,
        equippedStratagems: [String],
        stratagemLookup: [String: Stratagem],
        superKey: Keybind,
        directionalKeys: DirectionalKeybinds,
        activationMode: ActivationMode
    ) {
        guard slotIndex < equippedStratagems.count else { return }

        let stratagemName = equippedStratagems[slotIndex]
        guard let stratagem = stratagemLookup[stratagemName],
            let superKeyCode = keySimulator.hexStringToKeyCode(superKey.keyCode)
        else {
            return
        }

        logger.info("Executing stratagem: \(stratagemName)")
        keySimulator.executeStratagem(
            sequence: stratagem.sequence,
            superKeyCode: superKeyCode,
            directionalKeys: directionalKeys,
            activationMode: activationMode
        )
    }

    private func handleHotkeyPressed(slotIndex: Int) {
        logger.debug("Activating slot \(slotIndex)")

        guard slotIndex < equippedStratagems.count else { return }

        // Block immediately with lock-protected flag (thread-safe, no queue dependency)
        executingLock.lock()
        _isExecutingFlag = true
        executingLock.unlock()
        flashingSlotIndex = slotIndex

        DispatchQueue.main.asyncAfter(deadline: .now() + HBConstants.Timing.flashDuration) {
            self.flashingSlotIndex = nil
        }

        // Execute on serial queue to prevent interleaving
        stratagemExecutionQueue.async {
            self.executeStratagemAtSlot(slotIndex: slotIndex)

            // Clear lock-protected flag immediately (no queue dependency)
            self.executingLock.lock()
            self._isExecutingFlag = false
            self.executingLock.unlock()

            // Update UI on main thread
        }
    }

    private func executeStratagemAtSlot(slotIndex: Int) {
        guard slotIndex < equippedStratagems.count else { return }

        let stratagemName = equippedStratagems[slotIndex]
        guard let stratagem = stratagemLookup[stratagemName],
            let superKeyCode = keySimulator.hexStringToKeyCode(superKey.keyCode)
        else {
            return
        }

        logger.info("Executing stratagem: \(stratagemName)")
        keySimulator.executeStratagem(
            sequence: stratagem.sequence,
            superKeyCode: superKeyCode,
            directionalKeys: directionalKeys,
            activationMode: activationMode
        )
    }

    func updateEquippedStratagem(at index: Int, with stratagemName: String) {
        guard index < equippedStratagems.count else { return }
        equippedStratagems[index] = stratagemName
        activeLoadoutId = nil  // Mark as dirty - config modified
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
        activeLoadoutId = nil  // Mark as dirty - config modified

        // Re-setup event tap with new keybinds
        setupHotkeys()
        logger.info("Slot \(index) rebound to '\(letter)'")

        saveUserData()
    }

    func clearKeybind(at index: Int) {
        guard index < keybinds.count else { return }

        // Set to empty keybind (won't trigger on any key)
        keybinds[index] = Keybind(keyCode: "", letter: "")
        activeLoadoutId = nil  // Mark as dirty - config modified

        // Re-setup event tap with new keybinds
        setupHotkeys()
        logger.info("Slot \(index) keybind cleared")

        saveUserData()
    }

    func clearStratagem(at index: Int) {
        guard index < equippedStratagems.count else { return }

        // Set to empty stratagem name (slot will be empty)
        equippedStratagems[index] = ""
        activeLoadoutId = nil  // Mark as dirty - config modified

        logger.info("Slot \(index) stratagem cleared")
        saveUserData()
    }

    func cancelKeybindListening() {
        // Re-enable event tap after cancel
        setupHotkeys()
        logger.debug("Rebind cancelled")
    }

    func saveAllSettings() {
        saveUserData()
        updateCachedAppState()  // Refresh cache in case allowed apps changed
    }

    private func saveUserData() {
        // Save to Application Support, not bundle
        let userData = UserData(
            equippedStratagems: equippedStratagems,
            keybinds: keybinds,
            allowedApps: allowedApps,
            superKey: superKey,
            activationMode: activationMode,
            directionalKeys: directionalKeys,
            comboKey: comboKey,
            loadoutKey: loadoutKey,
            loadouts: loadouts,
            activeLoadoutId: activeLoadoutId?.uuidString,
            hoverPreviewEnabled: hoverPreviewEnabled,
            voiceFeedbackEnabled: voiceFeedbackEnabled,
            selectedVoice: selectedVoice,
            voiceVolume: voiceVolume,
            recentStratagemNames: recentStratagemNames
        )
        guard let data = try? JSONEncoder().encode(userData),
            let url = userDataURL
        else {
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

    // MARK: - Game Keybind Settings

    func updateSuperKey(keyCode: String, letter: String) {
        superKey = Keybind(keyCode: keyCode, letter: letter)
        saveUserData()
        logger.info("Super key updated to '\(letter)'")
    }

    func updateActivationMode(_ mode: ActivationMode) {
        activationMode = mode
        saveUserData()
        logger.info("Activation mode updated to '\(mode.rawValue)'")
    }

    func updateDirectionalKey(_ direction: String, keyCode: String, letter: String) {
        let newKeybind = Keybind(keyCode: keyCode, letter: letter)
        switch direction {
        case "up":
            directionalKeys.up = newKeybind
        case "down":
            directionalKeys.down = newKeybind
        case "left":
            directionalKeys.left = newKeybind
        case "right":
            directionalKeys.right = newKeybind
        default:
            return
        }
        saveUserData()
        logger.info("Directional key '\(direction)' updated to '\(letter)'")
    }

    func updateComboKey(keyCode: String, letter: String) {
        comboKey = Keybind(keyCode: keyCode, letter: letter)
        saveUserData()
        setupHotkeys()  // Re-setup to use new combo key
        logger.info("Combo key updated to '\(letter)'")
    }

    func updateLoadoutKey(keyCode: String, letter: String) {
        loadoutKey = Keybind(keyCode: keyCode, letter: letter)
        saveUserData()
        logger.info("Loadout key updated to '\(letter)'")
    }

    // MARK: - Loadout Management

    func saveLoadout(name: String, overwriteId: UUID? = nil) {
        let loadout = Loadout(
            id: overwriteId ?? UUID(),
            name: name,
            equippedStratagems: equippedStratagems,
            keybinds: keybinds
        )

        if let overwriteId = overwriteId,
            let index = loadouts.firstIndex(where: { $0.id == overwriteId })
        {
            // Overwrite existing loadout
            loadouts[index] = loadout
            logger.info("Overwrote loadout: \(name)")
        } else {
            // Add new loadout
            loadouts.append(loadout)
            logger.info("Saved new loadout: \(name)")
        }

        activeLoadoutId = loadout.id
        saveUserData()
    }

    func loadLoadout(id: UUID) {
        guard let loadout = loadouts.first(where: { $0.id == id }) else {
            logger.error("Loadout not found: \(id)")
            return
        }

        equippedStratagems = loadout.equippedStratagems
        keybinds = loadout.keybinds
        activeLoadoutId = id

        // Re-setup hotkeys since keybinds changed
        setupHotkeys()
        saveUserData()
        logger.info("Loaded loadout: \(loadout.name)")

        if voiceFeedbackEnabled {
            if let voice = selectedVoice {
                speechSynthesizer.setVoice(NSSpeechSynthesizer.VoiceName(rawValue: voice))
            } else {
                speechSynthesizer.setVoice(nil)  // Reset to system default
            }
            speechSynthesizer.volume = voiceVolume
            speechSynthesizer.startSpeaking("\(loadout.name) loaded")
        }
    }

    func deleteLoadout(id: UUID) {
        loadouts.removeAll { $0.id == id }

        // If deleted loadout was active, clear active state
        if activeLoadoutId == id {
            activeLoadoutId = nil
        }

        saveUserData()
        logger.info("Deleted loadout: \(id)")
    }

    func renameLoadout(id: UUID, to newName: String) {
        guard let index = loadouts.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = newName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        loadouts[index].name = trimmed
        saveUserData()
        logger.info("Renamed loadout to: \(trimmed)")
    }

    // MARK: - Loadout Export/Import

    /// Export loadouts to JSON data
    func exportLoadouts(_ loadoutsToExport: [Loadout]) -> Data? {
        let export = LoadoutExport(loadouts: loadoutsToExport)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        do {
            let data = try encoder.encode(export)
            logger.info("Exported \(loadoutsToExport.count) loadout(s) (format v\(export.version))")
            return data
        } catch {
            logger.error("Failed to encode loadouts for export: \(error.localizedDescription)")
            return nil
        }
    }

    /// Import loadouts from JSON data
    /// Returns the number of loadouts imported, or nil on failure
    func importLoadouts(from data: Data) -> Int? {
        let decoder = JSONDecoder()

        do {
            let imported = try decoder.decode(LoadoutExport.self, from: data)
            logger.info("Importing loadouts export (format v\(imported.version))")
            var importCount = 0

            for loadout in imported.loadouts {
                // VALIDATION: Ensure arrays are exactly size 8 to prevent crashes
                var safeStratagems = loadout.equippedStratagems
                var safeKeybinds = loadout.keybinds

                // Pad or trim stratagems to exactly 8
                if safeStratagems.count < 8 {
                    safeStratagems.append(
                        contentsOf: Array(repeating: "", count: 8 - safeStratagems.count))
                } else if safeStratagems.count > 8 {
                    safeStratagems = Array(safeStratagems.prefix(8))
                }

                // Pad or trim keybinds to exactly 8
                if safeKeybinds.count < 8 {
                    safeKeybinds.append(
                        contentsOf: Array(
                            repeating: Keybind(keyCode: "", letter: ""),
                            count: 8 - safeKeybinds.count))
                } else if safeKeybinds.count > 8 {
                    safeKeybinds = Array(safeKeybinds.prefix(8))
                }

                // Generate new UUID to avoid conflicts
                let newLoadout = Loadout(
                    id: UUID(),
                    name: generateUniqueImportName(baseName: loadout.name),
                    equippedStratagems: safeStratagems,
                    keybinds: safeKeybinds
                )
                loadouts.append(newLoadout)
                importCount += 1
            }

            if importCount > 0 {
                saveUserData()
                logger.info("Imported \(importCount) loadout(s)")
            }

            return importCount
        } catch {
            logger.error("Failed to decode loadouts for import: \(error.localizedDescription)")
            return nil
        }
    }

    /// Generate a unique name for imported loadout, avoiding duplicates
    private func generateUniqueImportName(baseName: String) -> String {
        // Check if name already exists
        if !loadouts.contains(where: { $0.name == baseName }) {
            return baseName
        }

        // Find a unique name by appending "(imported)" or number
        var counter = 1
        var name = "\(baseName) (imported)"
        while loadouts.contains(where: { $0.name == name }) {
            counter += 1
            name = "\(baseName) (imported \(counter))"
        }
        return name
    }
}
