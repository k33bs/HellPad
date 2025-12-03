import Foundation
import Carbon
import SwiftUI

enum HBConstants {
    // MARK: - Key Codes
    enum KeyCode {
        static let pause = kVK_ANSI_P  // 0x23
        static let escape = kVK_Escape  // 0x35
    }

    // MARK: - Timing Delays
    enum Timing {
        // Flash effects (TimeInterval for DispatchQueue, microseconds for usleep)
        static let flashDuration: TimeInterval = 0.15  // 150ms
        static let flashDurationMicros: UInt32 = 150_000  // 150ms

        // Key simulation
        static let keyPressDuration: UInt32 = 50_000  // 50ms
        static let betweenKeyDelay: UInt32 = 50_000   // 50ms

        // Combo execution
        static let beforeMouseClick: UInt32 = 500_000   // 500ms
        static let afterMouseClick: UInt32 = 1_000_000  // 1000ms (1 second)
        static let ctrlReleaseDelay: TimeInterval = 0.25  // 250ms - longer to ensure Ctrl fully released
        static let comboWaitTimeout: TimeInterval = 3.0  // 3 seconds to wait for mouse click

        // Mouse click
        static let mouseClickDuration: UInt32 = 50_000  // 50ms
    }

    // MARK: - UI Dimensions
    enum UI {
        static let iconSize: CGFloat = 63
        static let iconFrameSize: CGFloat = 83  // icon + 10px border
        static let slotHeight: CGFloat = 111  // icon frame + keybind button
        static let cornerRadius: CGFloat = 6
        static let borderWidth: CGFloat = 4
        static let borderInset: CGFloat = 2

        // Stratagem Picker
        static let pickerIconSize: CGFloat = 27  // Adjustable icon size
        static let pickerColumns: Int = 6        // Number of columns
        static let pickerSpacing: CGFloat = 3    // Space between icons
        static let pickerWidth: CGFloat = 186
        static let pickerHeight: CGFloat = 475

        // Hover Preview
        static let hoverPreviewSize: CGFloat = 60  // Rendered at full size for sharpness
        static let hoverPadding: CGFloat = 36      // Half of preview size for edge clamping
        static var hoverMaxX: CGFloat { pickerWidth - hoverPadding }
        static var hoverMaxY: CGFloat { pickerHeight - hoverPadding }
    }

    // MARK: - Visual Effects
    enum Visual {
        // Opacities
        static let flashBackgroundOpacity: Double = 0.4
        static let comboBorderOpacity: Double = 0.9
        static let comboBackgroundOpacity: Double = 0.1

        // Colors
        static let flashYellow = Color(red: 1.0, green: 0.906, blue: 0.063)  // #FFE710
        static let comboCyan = Color.cyan
        static let errorRed = Color.red
    }
}
