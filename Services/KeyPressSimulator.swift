import Foundation
import CoreGraphics
import AppKit

class KeyPressSimulator {
    // Map direction strings to WASD macOS key codes
    private let directionKeyCodes: [String: CGKeyCode] = [
        "W": 0x0D,  // W key (up)
        "A": 0x00,  // A key (left)
        "S": 0x01,  // S key (down)
        "D": 0x02   // D key (right)
    ]

    func executeStratagem(sequence: [String], stratagemMenuKeyCode: CGKeyCode) {
        // Press stratagem menu key
        pressKey(keyCode: stratagemMenuKeyCode)
        usleep(HBConstants.Timing.betweenKeyDelay)

        // Execute the sequence
        for direction in sequence {
            usleep(HBConstants.Timing.betweenKeyDelay)
            if let keyCode = directionKeyCodes[direction] {
                tapKey(keyCode: keyCode)
            }
            usleep(HBConstants.Timing.betweenKeyDelay)
        }

        // Release stratagem menu key
        usleep(HBConstants.Timing.betweenKeyDelay)
        releaseKey(keyCode: stratagemMenuKeyCode)
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
