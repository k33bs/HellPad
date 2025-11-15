import Foundation
import CoreGraphics
import AppKit
import os.log

private let logger = Logger(subsystem: "com.hellpad.app", category: "input")

class EventTapManager {
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private let shiftStateLock = NSLock()
    private var wasShiftPressed: Bool = false  // Track previous Shift state
    var onKeyPressed: ((CGKeyCode, Bool, Bool) -> Bool)?  // (keyCode, isShiftHeld, isCtrlHeld) -> shouldConsume
    var onShiftReleased: (() -> Void)?  // Called when Shift key is released
    var onMouseClicked: (() -> Void)?  // Called when left mouse button is clicked

    func setupEventTap() {
        // Clean up any existing event tap first
        disable()

        // Create event tap to monitor key down, flags changed, and left mouse down events
        let eventMask = (1 << CGEventType.keyDown.rawValue) |
                        (1 << CGEventType.flagsChanged.rawValue) |
                        (1 << CGEventType.leftMouseDown.rawValue)

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(eventMask),
            callback: { (proxy, type, event, refcon) -> Unmanaged<CGEvent>? in
                let manager = Unmanaged<EventTapManager>.fromOpaque(refcon!).takeUnretainedValue()

                if type == .keyDown {
                    let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
                    let isShiftHeld = event.flags.contains(.maskShift)
                    let isCtrlHeld = event.flags.contains(.maskControl)

                    // Update shift state on key down too (thread-safe)
                    manager.shiftStateLock.lock()
                    manager.wasShiftPressed = isShiftHeld
                    manager.shiftStateLock.unlock()

                    // Call the callback to check if we should handle this key
                    if let shouldConsume = manager.onKeyPressed?(keyCode, isShiftHeld, isCtrlHeld), shouldConsume {
                        // Return nil to consume the event (block it from propagating)
                        return nil
                    }
                } else if type == .flagsChanged {
                    // Detect when Shift key is released (was pressed, now not pressed)
                    let isShiftPressed = event.flags.contains(.maskShift)

                    // Thread-safe state check and update
                    manager.shiftStateLock.lock()
                    let wasPressed = manager.wasShiftPressed
                    manager.wasShiftPressed = isShiftPressed
                    manager.shiftStateLock.unlock()

                    // Only trigger if transitioning from pressed to released
                    if wasPressed && !isShiftPressed {
                        manager.onShiftReleased?()
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
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
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
