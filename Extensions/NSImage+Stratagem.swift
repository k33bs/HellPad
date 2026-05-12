import AppKit
import os.log

// logger for icon load failures, replaces ad-hoc print() so output is consistent with the rest of the app
private let logger = Logger(subsystem: "com.hellpad.app", category: "icons")

// Image cache for stratagem icons
// the cache is read from main (views) and from LoadoutGridReader's background queue.
// the bare Dictionary was a data race; an NSLock around reads/writes makes it safe.
// note: two threads asking for the same slug at the same time may both load it once
// (we only lock the dictionary access, not the disk read) — wasteful but harmless.
private let stratagemIconCacheLock = NSLock()
private var stratagemIconCache = [String: NSImage]()

extension NSImage {
    static func stratagemIcon(named name: String) -> NSImage? {
        // Convert stratagem name to slug (matches icon filename format)
        let slug = name.slugified()

        // Check cache first (locked)
        stratagemIconCacheLock.lock()
        if let cachedImage = stratagemIconCache[slug] {
            stratagemIconCacheLock.unlock()
            return cachedImage
        }
        stratagemIconCacheLock.unlock()

        // Load from disk if not cached (no lock held during disk i/o)
        guard let url = Bundle.main.url(forResource: slug, withExtension: "png"),
              let image = NSImage(contentsOf: url) else {
            // missing icon now logs via os.log instead of print
            logger.error("Stratagem icon not found: \(slug).png (from name: \(name))")
            return nil
        }

        // Set image size to half of pixels to treat as @2x Retina asset
        if let rep = image.representations.first {
            image.size = NSSize(width: CGFloat(rep.pixelsWide) / 2.0, height: CGFloat(rep.pixelsHigh) / 2.0)
        }

        // Cache the image (locked)
        stratagemIconCacheLock.lock()
        stratagemIconCache[slug] = image
        stratagemIconCacheLock.unlock()
        return image
    }
}

extension String {
    func slugified() -> String {
        // Match generator's toKebabCase: remove special chars, then replace spaces with hyphens
        return self
            .lowercased()
            .replacingOccurrences(of: "[^a-z0-9\\s-]", with: "", options: .regularExpression)  // Remove special chars (keep spaces/hyphens)
            .replacingOccurrences(of: "\\s+", with: "-", options: .regularExpression)  // Replace spaces with hyphens
            .replacingOccurrences(of: "-+", with: "-", options: .regularExpression)  // Collapse multiple hyphens
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }
}
