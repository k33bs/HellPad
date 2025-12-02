import Foundation
import CoreGraphics
import AppKit

class KeyPressSimulator {
    // Modifier key codes
    private let modifierKeyCodes: [CGKeyCode: CGEventFlags] = [
        0x3B: .maskControl,    // Left Control
        0x3E: .maskControl,    // Right Control
        0x3A: .maskAlternate,  // Left Option
        0x3D: .maskAlternate,  // Right Option
        0x37: .maskCommand,    // Left Command
        0x36: .maskCommand,    // Right Command
        0x38: .maskShift,      // Left Shift
        0x3C: .maskShift,      // Right Shift
    ]

    func executeStratagem(
        sequence: [String],
        superKeyCode: CGKeyCode,
        directionalKeys: DirectionalKeybinds,
        activationMode: ActivationMode
    ) {
        // Build direction to keycode map from user's configured keys
        let directionKeyCodes = buildDirectionKeyCodeMap(from: directionalKeys)

        // Check if super key is a modifier - if so, we need to set flags on directional events
        let modifierFlag = modifierKeyCodes[superKeyCode]

        switch activationMode {
        case .hold:
            // Hold mode: Hold super key while pressing directionals
            // Always press the super key first (games need to see the key event, not just flags)
            pressKey(keyCode: superKeyCode)
            usleep(HBConstants.Timing.betweenKeyDelay)

            for direction in sequence {
                usleep(HBConstants.Timing.betweenKeyDelay)
                if let keyCode = directionKeyCodes[direction] {
                    if let modifierFlag = modifierFlag {
                        // For modifier super keys, also set the flag on directional events
                        tapKeyWithModifier(keyCode: keyCode, modifierFlag: modifierFlag)
                    } else {
                        tapKey(keyCode: keyCode)
                    }
                }
                usleep(HBConstants.Timing.betweenKeyDelay)
            }

            usleep(HBConstants.Timing.betweenKeyDelay)
            releaseKey(keyCode: superKeyCode)

        case .toggle:
            // Toggle mode: Tap super key once, then press directionals without holding
            tapKey(keyCode: superKeyCode)
            usleep(HBConstants.Timing.betweenKeyDelay)

            for direction in sequence {
                usleep(HBConstants.Timing.betweenKeyDelay)
                if let keyCode = directionKeyCodes[direction] {
                    tapKey(keyCode: keyCode)
                }
                usleep(HBConstants.Timing.betweenKeyDelay)
            }
        }
    }

    private func buildDirectionKeyCodeMap(from directionalKeys: DirectionalKeybinds) -> [String: CGKeyCode] {
        var map: [String: CGKeyCode] = [:]

        if let code = hexStringToKeyCode(directionalKeys.up.keyCode) {
            map["W"] = code  // "W" in sequence maps to user's up key
        }
        if let code = hexStringToKeyCode(directionalKeys.down.keyCode) {
            map["S"] = code  // "S" in sequence maps to user's down key
        }
        if let code = hexStringToKeyCode(directionalKeys.left.keyCode) {
            map["A"] = code  // "A" in sequence maps to user's left key
        }
        if let code = hexStringToKeyCode(directionalKeys.right.keyCode) {
            map["D"] = code  // "D" in sequence maps to user's right key
        }

        return map
    }

    private func pressKey(keyCode: CGKeyCode) {
        let keyDown = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true)
        keyDown?.post(tap: .cghidEventTap)
    }

    private func releaseKey(keyCode: CGKeyCode) {
        let keyUp = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: false)
        keyUp?.post(tap: .cghidEventTap)
    }

    private func tapKey(keyCode: CGKeyCode) {
        pressKey(keyCode: keyCode)
        usleep(HBConstants.Timing.keyPressDuration)
        releaseKey(keyCode: keyCode)
    }

    private func tapKeyWithModifier(keyCode: CGKeyCode, modifierFlag: CGEventFlags) {
        // Create key events with the modifier flag set
        let keyDown = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true)
        keyDown?.flags = modifierFlag
        keyDown?.post(tap: .cghidEventTap)

        usleep(HBConstants.Timing.keyPressDuration)

        let keyUp = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: false)
        keyUp?.flags = modifierFlag
        keyUp?.post(tap: .cghidEventTap)
    }

    func hexStringToKeyCode(_ hexString: String) -> CGKeyCode? {
        let cleanHex = hexString.replacingOccurrences(of: "0x", with: "")
        guard let value = UInt16(cleanHex, radix: 16) else { return nil }
        return CGKeyCode(value)
    }
}

// Extension to check app activity
extension KeyPressSimulator {
    func isAllowedAppActive(allowedApps: [String]) -> Bool {
        // Use NSWorkspace to get the frontmost application
        guard let frontmostApp = NSWorkspace.shared.frontmostApplication,
              let appName = frontmostApp.localizedName else {
            return false
        }

        // Check if frontmost app name contains any of the allowed app names (case-insensitive)
        return allowedApps.contains(where: { allowedName in
            appName.localizedCaseInsensitiveContains(allowedName)
        })
    }
}
