import Foundation
import AppKit
import CoreGraphics

enum ScreenCapture {
    enum PermissionState: Equatable {
        case granted
        case denied
    }

    static func hasPermission() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    static func permissionState() -> PermissionState {
        hasPermission() ? .granted : .denied
    }

    @discardableResult
    static func requestPermission() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    static func openSystemSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    static func displayBounds(displayId: CGDirectDisplayID = CGMainDisplayID()) -> CGRect {
        CGDisplayBounds(displayId)
    }

    static func clampRectToImage(_ rect: CGRect, imageWidth: Int, imageHeight: Int) -> CGRect {
        let imageRect = CGRect(x: 0, y: 0, width: imageWidth, height: imageHeight)
        let standardized = rect.standardized.integral
        return imageRect.intersection(standardized)
    }

    static func clampRectToDisplay(_ rect: CGRect, displayId: CGDirectDisplayID = CGMainDisplayID()) -> CGRect {
        let bounds = displayBounds(displayId: displayId)
        let standardized = rect.standardized.integral
        return bounds.intersection(standardized)
    }

    static func capture(displayId: CGDirectDisplayID, rect: CGRect) -> CGImage? {
        let clipped = clampRectToDisplay(rect, displayId: displayId)
        guard !clipped.isNull, clipped.width > 0, clipped.height > 0 else {
            return nil
        }
        return CGDisplayCreateImage(displayId, rect: clipped)
    }

    static func captureMainDisplay(rect: CGRect) -> CGImage? {
        capture(displayId: CGMainDisplayID(), rect: rect)
    }

    static func captureMainDisplayFull() -> CGImage? {
        CGDisplayCreateImage(CGMainDisplayID())
    }

    static func cropClamped(image: CGImage, rect: CGRect) -> CGImage? {
        let clipped = clampRectToImage(rect, imageWidth: image.width, imageHeight: image.height)

        guard !clipped.isNull, clipped.width > 0, clipped.height > 0 else {
            return nil
        }

        return image.cropping(to: clipped)
    }
}
