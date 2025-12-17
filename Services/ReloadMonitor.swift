import Foundation
import CoreGraphics
import os.log

private let logger = Logger(subsystem: "com.hellpad.app", category: "reload-monitor")

final class ReloadMonitor {
    struct Detection: Equatable {
        let needsReload: Bool
        let redRatio: Double
        let sampledPixelCount: Int
    }

    private let captureRectProvider: () -> CGRect
    private let iconRectProvider: (CGSize) -> CGRect
    private let displayId: CGDirectDisplayID
    private let scanInterval: TimeInterval
    private let announceCooldown: TimeInterval

    private var timer: DispatchSourceTimer?
    private var lastAnnouncedAt: Date?
    private var lastNeedsReload: Bool = false
    private var lastDetection: Detection?

    var onDetection: ((Detection) -> Void)?
    var onReloadNeeded: (() -> Void)?

    init(
        displayId: CGDirectDisplayID = CGMainDisplayID(),
        captureRectProvider: @escaping () -> CGRect = ReloadMonitor.defaultCaptureRectProvider,
        iconRectProvider: @escaping (CGSize) -> CGRect = ReloadMonitor.defaultIconRectProvider,
        scanInterval: TimeInterval = 0.25,
        announceCooldown: TimeInterval = 6.0
    ) {
        self.displayId = displayId
        self.captureRectProvider = captureRectProvider
        self.iconRectProvider = iconRectProvider
        self.scanInterval = scanInterval
        self.announceCooldown = announceCooldown
    }

    deinit {
        stop()
    }

    func start() {
        if timer != nil {
            return
        }

        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "com.hellpad.reload-monitor"))
        timer.schedule(deadline: .now() + scanInterval, repeating: scanInterval)
        timer.setEventHandler { [weak self] in
            self?.scanOnce()
        }
        self.timer = timer
        timer.resume()
    }

    func stop() {
        timer?.cancel()
        timer = nil
        lastAnnouncedAt = nil
        lastNeedsReload = false
        lastDetection = nil
    }

    private func scanOnce() {
        guard CGPreflightScreenCaptureAccess() else {
            return
        }

        let rect = captureRectProvider()
        guard let cgImage = CGDisplayCreateImage(displayId, rect: rect) else {
            return
        }

        let detection = detect(capturedImage: cgImage)
        lastDetection = detection

        DispatchQueue.main.async { [weak self] in
            self?.onDetection?(detection)
        }

        if detection.needsReload && !lastNeedsReload {
            let now = Date()
            if let last = lastAnnouncedAt, now.timeIntervalSince(last) < announceCooldown {
                lastNeedsReload = detection.needsReload
                return
            }
            lastAnnouncedAt = now
            DispatchQueue.main.async { [weak self] in
                self?.onReloadNeeded?()
            }
        }

        lastNeedsReload = detection.needsReload
    }

    private func detect(capturedImage: CGImage) -> Detection {
        let iconRect = iconRectProvider(CGSize(width: capturedImage.width, height: capturedImage.height))
        guard let cropped = capturedImage.cropping(to: iconRect) else {
            return Detection(needsReload: false, redRatio: 0, sampledPixelCount: 0)
        }

        guard let bytes = rgbaBytes(from: cropped) else {
            return Detection(needsReload: false, redRatio: 0, sampledPixelCount: 0)
        }

        let width = cropped.width
        let height = cropped.height
        let pixelCount = width * height
        if pixelCount <= 0 {
            return Detection(needsReload: false, redRatio: 0, sampledPixelCount: 0)
        }

        var redCount = 0
        var sampled = 0

        for i in stride(from: 0, to: bytes.count, by: 4) {
            let r = Int(bytes[i])
            let g = Int(bytes[i + 1])
            let b = Int(bytes[i + 2])
            let a = Int(bytes[i + 3])

            if a < 32 {
                continue
            }

            sampled += 1

            let isRed = r > 150 && r > g + 40 && r > b + 40
            if isRed {
                redCount += 1
            }
        }

        let ratio = sampled > 0 ? Double(redCount) / Double(sampled) : 0
        let needsReload = ratio > 0.08

        return Detection(needsReload: needsReload, redRatio: ratio, sampledPixelCount: sampled)
    }

    private func rgbaBytes(from image: CGImage) -> [UInt8]? {
        let width = image.width
        let height = image.height

        let bytesPerPixel = 4
        let bytesPerRow = bytesPerPixel * width
        let bitsPerComponent = 8
        var rawData = Array<UInt8>(repeating: 0, count: Int(bytesPerRow * height))

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue

        guard let context = CGContext(
            data: &rawData,
            width: width,
            height: height,
            bitsPerComponent: bitsPerComponent,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            logger.error("Failed to create CGContext for reload detection")
            return nil
        }

        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return rawData
    }

    private static func defaultCaptureRectProvider() -> CGRect {
        let bounds = CGDisplayBounds(CGMainDisplayID())
        let width: CGFloat = 570
        let height: CGFloat = 200
        let x: CGFloat = 0
        let y: CGFloat = max(0, bounds.height - height)
        return CGRect(x: x, y: y, width: width, height: height)
    }

    private static func defaultIconRectProvider(_ imageSize: CGSize) -> CGRect {
        let w = imageSize.width
        let h = imageSize.height

        let iconWidth: CGFloat = min(180, w)
        let iconHeight: CGFloat = min(90, h)

        return CGRect(
            x: max(0, w - iconWidth),
            y: 0,
            width: iconWidth,
            height: iconHeight
        )
    }
}
