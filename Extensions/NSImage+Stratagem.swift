import AppKit

// Image cache for stratagem icons
private var stratagemIconCache = [String: NSImage]()

extension NSImage {
    static func stratagemIcon(named name: String) -> NSImage? {
        // Convert stratagem name to slug (matches icon filename format)
        let slug = name.slugified()

        // Check cache first
        if let cachedImage = stratagemIconCache[slug] {
            return cachedImage
        }

        // Load from disk if not cached
        guard let url = Bundle.main.url(forResource: slug, withExtension: "png"),
              let image = NSImage(contentsOf: url) else {
            print("Stratagem icon not found: \(slug).png (from name: \(name))")
            return nil
        }

        // Set image size to half of pixels to treat as @2x Retina asset
        if let rep = image.representations.first {
            image.size = NSSize(width: CGFloat(rep.pixelsWide) / 2.0, height: CGFloat(rep.pixelsHigh) / 2.0)
        }

        // Cache the image
        stratagemIconCache[slug] = image
        return image
    }

    static func clearIconCache() {
        stratagemIconCache.removeAll()
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
