import Foundation
import CoreGraphics
import AppKit
import os.log

private let logger = Logger(subsystem: "com.hellpad.app", category: "input")

class EventTapManager {
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private let comboKeyStateLock = NSLock()
    private var wasComboKeyPressed: Bool = false  // Track previous combo key state
    private var _comboKeyCode: CGKeyCode = 0x38   // Default: Left Shift

    var comboKeyCode: CGKeyCode {
        get {
            comboKeyStateLock.lock()
            defer { comboKeyStateLock.unlock() }
            return _comboKeyCode
        }
        set {
            comboKeyStateLock.lock()
            _comboKeyCode = newValue
            comboKeyStateLock.unlock()
        }
    }

    var onKeyPressed: ((CGKeyCode, Bool, Bool) -> Bool)?  // (keyCode, isComboKeyHeld, isCtrlHeld) -> shouldConsume
    var onComboKeyReleased: (() -> Void)?  // Called when combo key is released
    var onMouseClicked: (() -> Void)?  // Called when left mouse button is clicked

    func setupEventTap() {
        // Clean up any existing event tap first
        disable()

        // Reset state to avoid stale values from previous tap
        comboKeyStateLock.lock()
        wasComboKeyPressed = false
        comboKeyStateLock.unlock()

        // Create event tap to monitor key down, key up, flags changed, and left mouse down events
        let eventMask = (1 << CGEventType.keyDown.rawValue) |
                        (1 << CGEventType.keyUp.rawValue) |
                        (1 << CGEventType.flagsChanged.rawValue) |
                        (1 << CGEventType.leftMouseDown.rawValue)

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(eventMask),
            callback: { (proxy, type, event, refcon) -> Unmanaged<CGEvent>? in
                let manager = Unmanaged<EventTapManager>.fromOpaque(refcon!).takeUnretainedValue()

                // Get the current combo key code (thread-safe)
                manager.comboKeyStateLock.lock()
                let comboKey = manager._comboKeyCode
                manager.comboKeyStateLock.unlock()

                if type == .keyDown {
                    let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))

                    // Check if combo key is held using physical key state
                    let isComboKeyHeld = CGEventSource.keyState(.hidSystemState, key: comboKey)
                    let isCtrlHeld = event.flags.contains(.maskControl)

                    // Update combo key state on key down too (thread-safe)
                    manager.comboKeyStateLock.lock()
                    manager.wasComboKeyPressed = isComboKeyHeld
                    manager.comboKeyStateLock.unlock()

                    // Call the callback to check if we should handle this key
                    if let shouldConsume = manager.onKeyPressed?(keyCode, isComboKeyHeld, isCtrlHeld), shouldConsume {
                        // Return nil to consume the event (block it from propagating)
                        return nil
                    }
                } else if type == .keyUp {
                    let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))

                    // Check if the released key is our combo key (for non-modifier combo keys)
                    if keyCode == comboKey {
                        manager.comboKeyStateLock.lock()
                        let wasPressed = manager.wasComboKeyPressed
                        manager.wasComboKeyPressed = false
                        manager.comboKeyStateLock.unlock()

                        if wasPressed {
                            manager.onComboKeyReleased?()
                        }
                    }
                } else if type == .flagsChanged {
                    // For modifier combo keys, detect when they are released
                    let isComboKeyPressed = CGEventSource.keyState(.hidSystemState, key: comboKey)

                    // Thread-safe state check and update
                    manager.comboKeyStateLock.lock()
                    let wasPressed = manager.wasComboKeyPressed
                    manager.wasComboKeyPressed = isComboKeyPressed
                    manager.comboKeyStateLock.unlock()

                    // Only trigger if transitioning from pressed to released
                    if wasPressed && !isComboKeyPressed {
                        manager.onComboKeyReleased?()
                    }
                } else if type == .leftMouseDown {
                    // Notify about mouse click
                    manager.onMouseClicked?()
                }

                // Pass the event through without retaining
                return Unmanaged.passUnretained(event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            logger.error("Failed to create event tap - accessibility permissions may be missing")
            // Show alert to user
            DispatchQueue.main.async {
                let alert = NSAlert()
                alert.messageText = "Accessibility Permission Required"
                alert.informativeText = "HellPad needs Accessibility permissions to monitor keyboard input.\n\nPlease grant permissions in:\nSystem Settings > Privacy & Security > Accessibility"
                alert.alertStyle = .warning
                alert.addButton(withTitle: "Open System Settings")
                alert.addButton(withTitle: "Quit")

                let response = alert.runModal()
                if response == .alertFirstButtonReturn {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                }
                NSApplication.shared.terminate(nil)
            }
            return
        }

        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)  // Use main run loop explicitly
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    func disable() {
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
            runLoopSource = nil
        }

        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
            eventTap = nil
        }
    }

    deinit {
        disable()
    }
}
