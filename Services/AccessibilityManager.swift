import Foundation
import AppKit
import os.log

private let logger = Logger(subsystem: "com.hellpad.app", category: "accessibility")

class AccessibilityManager {
    static let shared = AccessibilityManager()

    private init() {}

    func checkAccessibilityPermission() -> Bool {
        return AXIsProcessTrusted()
    }

    func requestAccessibilityPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        AXIsProcessTrustedWithOptions(options as CFDictionary)
    }

    func showAccessibilityAlert() {
        let alert = NSAlert()
        alert.messageText = "Accessibility Access Required"
        alert.informativeText = """
        HellPad needs Accessibility permissions to:
        • Register global hotkeys
        • Simulate key presses for stratagem execution

        Please grant access in System Settings:
        1. Open System Settings
        2. Go to Privacy & Security → Accessibility
        3. Enable HellPad

        The app will restart after you grant permission.
        """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Quit")

        let response = alert.runModal()

        if response == .alertFirstButtonReturn {
            // Open System Settings to Accessibility pane
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                NSWorkspace.shared.open(url)
            }
        } else {
            NSApplication.shared.terminate(nil)
        }
    }

    func ensureAccessibilityPermission(onSuccess: @escaping () -> Void) {
        if checkAccessibilityPermission() {
            logger.info("Accessibility permission already granted")
            onSuccess()
        } else {
            logger.info("Accessibility permission NOT granted - requesting...")

            // First, try the system prompt
            requestAccessibilityPermission()

            // Then show our custom alert
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self.showAccessibilityAlert()
            }

            // Check every second if permission has been granted
            Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { timer in
                if self.checkAccessibilityPermission() {
                    logger.info("Accessibility permission granted!")
                    timer.invalidate()
                    onSuccess()
                }
            }
        }
    }
}
