import AppKit
import CoreGraphics
import Foundation
import Vision
import os.log

private let logger = Logger(subsystem: "com.hellpad.app", category: "loadout-grid-reader")

#if DEBUG
    struct LoadoutGridDebugReadyUpOcrCandidate: Identifiable {
        let id = UUID()
        let text: String
        let confidence: Float
        let rect: CGRect
        let centerDxFromScreenCenter: Int
    }

    struct LoadoutGridDebugCandidate: Identifiable {
        let id = UUID()
        let name: String
        let distance: Float  // Changed to Float for feature print distances
        let referenceIcon: CGImage?  // The bundled icon for comparison
        var combinedScore: Double = 0  // For debug display
        var iouScore: Double = 0
        var colorScore: Double = 0
        var hashScore: Double = 0
        var fpScore: Double = 0
    }

    struct LoadoutGridDebugMatch: Identifiable {
        let id = UUID()
        let slotIndex: Int
        let rect: CGRect  // The icon rect in the quadrant
        var bestName: String?
        let bestDistance: Float  // Changed to Float
        var topCandidates: [LoadoutGridDebugCandidate]  // Top 5 matches
    }

    struct LoadoutGridDebugSnapshot {
        let timestamp: Date
        let fullCapture: CGImage
        let quadrant: CGImage
        let quadrantRectInFullCapture: CGRect
        let readyUpDetectionMethod: String
        let readyUpOcrCandidates: [LoadoutGridDebugReadyUpOcrCandidate]
        let readyUpRect: CGRect
        let iconRects: [CGRect]
        let iconTiles: [CGImage]
        var matches: [LoadoutGridDebugMatch]
        var names: [String]
    }

    struct MatchWeights {
        var iou: Double = 0.40
        var color: Double = 0.05
        var hash: Double = 0.15
        var fp: Double = 0.40

        static let `default` = MatchWeights()
    }
#endif

// MARK: - LoadoutGridReader

final class LoadoutGridReader {

    private let canonicalStratagemNames: [String]
    private var croppedReferenceIcons: [String: CGImage]?

    init(canonicalStratagemNames: [String]) {
        self.canonicalStratagemNames = canonicalStratagemNames
    }

    // MARK: - Reference Icon Pre-processing

    /// Pre-compute cropped reference icons (cropped to content bounds, removing background)
    private func ensureCroppedReferenceIconsLoaded() -> [String: CGImage] {
        if let existing = croppedReferenceIcons {
            return existing
        }

        var cache: [String: CGImage] = [:]
        for name in canonicalStratagemNames {
            guard let nsImage = NSImage.stratagemIcon(named: name),
                  let cgImage = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                continue
            }

            // Crop to content bounds
            if let cropped = cropToContentBounds(cgImage, threshold: 30) {
                cache[name] = cropped
            } else {
                cache[name] = cgImage  // Fallback to original
            }
        }

        croppedReferenceIcons = cache
        logger.info("Pre-computed \(cache.count) cropped reference icons")
        return cache
    }

    /// Find the bounding box of non-background content and crop to it
    private func cropToContentBounds(_ image: CGImage, threshold: Int) -> CGImage? {
        let width = image.width
        let height = image.height
        let bytesPerRow = width * 4
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue

        guard let context = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: bytesPerRow,
            space: colorSpace, bitmapInfo: bitmapInfo
        ) else { return nil }

        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        guard let data = context.data else { return nil }
        let buffer = data.bindMemory(to: UInt8.self, capacity: bytesPerRow * height)

        var minX = width, maxX = 0, minY = height, maxY = 0

        for y in 0..<height {
            for x in 0..<width {
                let offset = (y * width + x) * 4
                let r = Int(buffer[offset])
                let g = Int(buffer[offset + 1])
                let b = Int(buffer[offset + 2])
                let a = Int(buffer[offset + 3])

                // Check if this pixel is "content" (not background)
                let brightness = max(r, max(g, b))
                let isContent = brightness > threshold || (a > 50 && a < 250)

                if isContent {
                    minX = min(minX, x)
                    maxX = max(maxX, x)
                    minY = min(minY, y)
                    maxY = max(maxY, y)
                }
            }
        }

        // Add small padding
        let padding = 2
        minX = max(0, minX - padding)
        minY = max(0, minY - padding)
        maxX = min(width - 1, maxX + padding)
        maxY = min(height - 1, maxY + padding)

        guard maxX > minX && maxY > minY else { return nil }

        // CGImage origin is top-left, so we need to flip Y for cropping
        let cropRect = CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
        return image.cropping(to: cropRect)
    }

    /// Crop captured tile to content bounds (for comparison with pre-cropped references)
    private func cropCapturedTileToContent(_ image: CGImage) -> CGImage? {
        return cropToContentBounds(image, threshold: 60)  // Higher threshold for captures (darker bg)
    }

    // MARK: - Public API

    func readMissionStratagemNames() -> [String]? {
        guard let result = performDetection() else {
            return nil
        }
        return result.names.allSatisfy({ $0.isEmpty }) ? nil : result.names
    }

    #if DEBUG
    func readMissionStratagemDebug() -> LoadoutGridDebugSnapshot? {
        guard ScreenCapture.ensurePermission(requestIfNeeded: true, openSystemSettingsIfDenied: false) else {
            return errorSnapshot("Screen capture permission denied")
        }

        guard let fullCapture = ScreenCapture.captureMainDisplayFull() else {
            return errorSnapshot("Failed to capture screen")
        }

        // Get bottom-left quarter
        let quarterRect = CGRect(
            x: 0,
            y: fullCapture.height / 2,
            width: fullCapture.width / 2,
            height: fullCapture.height / 2
        )

        guard let quarterCG = fullCapture.cropping(to: quarterRect) else {
            return errorSnapshot("Failed to crop quarter")
        }

        // Run OCR to find READY UP
        let ocrResults = runOCRForReadyUp(in: quarterCG)
        let ocrCandidates: [LoadoutGridDebugReadyUpOcrCandidate] = ocrResults.map { result in
            LoadoutGridDebugReadyUpOcrCandidate(
                text: result.text,
                confidence: result.confidence,
                rect: result.buttonRect,
                centerDxFromScreenCenter: Int(result.buttonRect.midX - CGFloat(quarterCG.width) / 2)
            )
        }

        // Pick best candidate (leftmost, closest to center-left)
        guard let bestCandidate = pickBestReadyUpCandidate(from: ocrResults, imageWidth: quarterCG.width) else {
            return LoadoutGridDebugSnapshot(
                timestamp: Date(),
                fullCapture: fullCapture,
                quadrant: quarterCG,
                quadrantRectInFullCapture: quarterRect,
                readyUpDetectionMethod: "ocr-failed",
                readyUpOcrCandidates: ocrCandidates,
                readyUpRect: .zero,
                iconRects: [],
                iconTiles: [],
                matches: [],
                names: ["READY UP not found via OCR"]
            )
        }

        let readyUpRect = bestCandidate.buttonRect

        // Calculate icon rects
        let iconRects = calculateIconRects(readyUpRect: readyUpRect, imageWidth: quarterCG.width, imageHeight: quarterCG.height)

        // Extract tiles and match using Vision feature prints
        var iconTiles: [CGImage] = []
        var matches: [LoadoutGridDebugMatch] = []
        var names: [String] = []

        let features = ensureIconFeaturesLoaded()

        for (i, rect) in iconRects.enumerated() {
            guard let tile = quarterCG.cropping(to: rect) else {
                names.append("")
                matches.append(LoadoutGridDebugMatch(
                    slotIndex: i,
                    rect: rect,
                    bestName: nil,
                    bestDistance: Float.greatestFiniteMagnitude,
                    topCandidates: []
                ))
                continue
            }

            iconTiles.append(tile)

            // Get top 5 matches with distances (sorted by FP distance)
            let topMatches = findTopMatchesByFeaturePrint(tile: tile, in: features, topN: 5)

            // Use the actual tiebreaker to determine best match (same as production code)
            let (actualBestName, actualBestDistance) = findBestMatchByFeaturePrint(tile: tile, in: features)

            // Create debug candidates with reference icons AND compute combined scores
            let croppedRefs = ensureCroppedReferenceIconsLoaded()
            let croppedTile = cropCapturedTileToContent(tile) ?? tile
            let defaultWeights = MatchWeights.default

            var scoredCandidates: [(candidate: LoadoutGridDebugCandidate, combined: Double)] = []
            for match in topMatches {
                let refIcon: CGImage? = {
                    guard let nsImage = NSImage.stratagemIcon(named: match.name) else { return nil }
                    return nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil)
                }()

                // Compute scores for display
                let refImage = croppedRefs[match.name] ?? refIcon
                var iouScore: Double = 0, colorScore: Double = 0, hashScore: Double = 0, fpScore: Double = 0, combined: Double = 0

                if let ref = refImage {
                    iouScore = computePixelSimilarity(tile: croppedTile, reference: ref)
                    colorScore = computeColorHistogramSimilarity(tile: croppedTile, reference: ref)
                    let tileHash = computeDHash(from: croppedTile)
                    let refHash = computeDHash(from: ref)
                    hashScore = 1.0 - (Double((tileHash ^ refHash).nonzeroBitCount) / 64.0)
                    fpScore = 1.0 - Double(match.distance)
                    combined = (iouScore * defaultWeights.iou) + (colorScore * defaultWeights.color) + (hashScore * defaultWeights.hash) + (fpScore * defaultWeights.fp)
                }

                let candidate = LoadoutGridDebugCandidate(
                    name: match.name,
                    distance: match.distance,
                    referenceIcon: refIcon,
                    combinedScore: combined,
                    iouScore: iouScore,
                    colorScore: colorScore,
                    hashScore: hashScore,
                    fpScore: fpScore
                )
                scoredCandidates.append((candidate, combined))
            }

            // Sort by combined score for display
            scoredCandidates.sort { $0.combined > $1.combined }
            let topCandidates = scoredCandidates.map { $0.candidate }

            names.append(actualBestName ?? "")
            matches.append(LoadoutGridDebugMatch(
                slotIndex: i,
                rect: rect,
                bestName: actualBestName,
                bestDistance: actualBestDistance,
                topCandidates: topCandidates
            ))
        }

        return LoadoutGridDebugSnapshot(
            timestamp: Date(),
            fullCapture: fullCapture,
            quadrant: quarterCG,
            quadrantRectInFullCapture: quarterRect,
            readyUpDetectionMethod: "ocr",
            readyUpOcrCandidates: ocrCandidates,
            readyUpRect: readyUpRect,
            iconRects: iconRects,
            iconTiles: iconTiles,
            matches: matches,
            names: names
        )
    }

    /// Re-evaluate a snapshot with custom weights - returns updated matches and names
    func reEvaluateWithWeights(_ snapshot: LoadoutGridDebugSnapshot, weights: MatchWeights) -> LoadoutGridDebugSnapshot {
        var newSnapshot = snapshot
        var newMatches: [LoadoutGridDebugMatch] = []
        var newNames: [String] = []

        // Get pre-cropped reference icons
        let croppedRefs = ensureCroppedReferenceIconsLoaded()

        for (idx, match) in snapshot.matches.enumerated() {
            guard idx < snapshot.iconTiles.count else {
                newMatches.append(match)
                newNames.append(idx < snapshot.names.count ? snapshot.names[idx] : "")
                continue
            }

            let tile = snapshot.iconTiles[idx]
            let croppedTile = cropCapturedTileToContent(tile) ?? tile

            // Re-score all candidates with new weights
            var scoredCandidates: [(candidate: LoadoutGridDebugCandidate, combined: Double)] = []

            for candidate in match.topCandidates {
                // Use pre-cropped reference icon if available
                let refImage: CGImage
                if let cropped = croppedRefs[candidate.name] {
                    refImage = cropped
                } else if let nsImage = NSImage.stratagemIcon(named: candidate.name),
                          let cgImage = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                    refImage = cgImage
                } else {
                    continue
                }

                // Compute all scores using cropped images
                let iouScore = computePixelSimilarity(tile: croppedTile, reference: refImage)
                let colorScore = computeColorHistogramSimilarity(tile: croppedTile, reference: refImage)
                let tileHash = computeDHash(from: croppedTile)
                let refHash = computeDHash(from: refImage)
                let hashDist = Double((tileHash ^ refHash).nonzeroBitCount)
                let hashScore = 1.0 - (hashDist / 64.0)
                let fpScore = 1.0 - Double(candidate.distance)

                // Apply custom weights
                let combined = (iouScore * weights.iou) + (colorScore * weights.color) + (hashScore * weights.hash) + (fpScore * weights.fp)

                var updatedCandidate = candidate
                updatedCandidate.combinedScore = combined
                updatedCandidate.iouScore = iouScore
                updatedCandidate.colorScore = colorScore
                updatedCandidate.hashScore = hashScore
                updatedCandidate.fpScore = fpScore

                scoredCandidates.append((updatedCandidate, combined))
            }

            // Sort by combined score (highest first)
            scoredCandidates.sort { $0.combined > $1.combined }

            let reorderedCandidates = scoredCandidates.map { $0.candidate }
            let bestName = scoredCandidates.first.map { $0.candidate.distance <= 18 ? $0.candidate.name : nil } ?? nil

            var newMatch = match
            newMatch.topCandidates = reorderedCandidates
            newMatch.bestName = bestName
            newMatches.append(newMatch)
            newNames.append(bestName ?? "")
        }

        newSnapshot.matches = newMatches
        newSnapshot.names = newNames
        return newSnapshot
    }

    private func errorSnapshot(_ message: String) -> LoadoutGridDebugSnapshot {
        let placeholder = createPlaceholderImage()
        return LoadoutGridDebugSnapshot(
            timestamp: Date(),
            fullCapture: placeholder,
            quadrant: placeholder,
            quadrantRectInFullCapture: .zero,
            readyUpDetectionMethod: "error",
            readyUpOcrCandidates: [],
            readyUpRect: .zero,
            iconRects: [],
            iconTiles: [],
            matches: [],
            names: [message]
        )
    }

    private func createPlaceholderImage() -> CGImage {
        let size = 4
        var data = Data(count: size * size * 4)
        data.withUnsafeMutableBytes { ptr in
            guard let base = ptr.baseAddress else { return }
            memset(base, 64, size * size * 4)
        }
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
        let provider = CGDataProvider(data: data as CFData)!
        return CGImage(
            width: size, height: size,
            bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: size * 4,
            space: colorSpace,
            bitmapInfo: CGBitmapInfo(rawValue: bitmapInfo),
            provider: provider,
            decode: nil, shouldInterpolate: false, intent: .defaultIntent
        )!
    }
    #endif

    // MARK: - Core Detection

    private struct DetectionResult {
        let readyUpRect: CGRect
        let iconRects: [CGRect]
        let names: [String]
    }

    private func performDetection() -> DetectionResult? {
        guard ScreenCapture.ensurePermission(requestIfNeeded: true, openSystemSettingsIfDenied: false) else {
            logger.debug("Screen capture permission denied")
            return nil
        }

        guard let fullCapture = ScreenCapture.captureMainDisplayFull() else {
            logger.debug("Failed to capture screen")
            return nil
        }

        // Bottom-left quarter - where leftmost READY UP will be
        // CGImage coordinates: origin at top-left, y increases downward
        // So "bottom" means y = height/2 to y = height
        let quarterRect = CGRect(
            x: 0,
            y: fullCapture.height / 2,
            width: fullCapture.width / 2,
            height: fullCapture.height / 2
        )

        guard let quarterCG = fullCapture.cropping(to: quarterRect) else {
            logger.debug("Failed to crop to quarter")
            return nil
        }

        // Find READY UP via OCR
        let ocrResults = runOCRForReadyUp(in: quarterCG)
        guard let bestCandidate = pickBestReadyUpCandidate(from: ocrResults, imageWidth: quarterCG.width) else {
            logger.debug("READY UP not found via OCR")
            return nil
        }

        let readyUpRect = bestCandidate.buttonRect
        logger.debug("Found READY UP at: \(Int(readyUpRect.minX)),\(Int(readyUpRect.minY)) \(Int(readyUpRect.width))x\(Int(readyUpRect.height))")

        // Calculate icon positions
        let iconRects = calculateIconRects(readyUpRect: readyUpRect, imageWidth: quarterCG.width, imageHeight: quarterCG.height)
        guard iconRects.count == 4 else {
            logger.debug("Expected 4 icon rects, got \(iconRects.count)")
            return nil
        }

        // Match icons using Vision feature prints
        let features = ensureIconFeaturesLoaded()
        guard !features.isEmpty else {
            logger.debug("No icon features loaded")
            return nil
        }

        var names: [String] = []
        for (i, rect) in iconRects.enumerated() {
            guard let tile = quarterCG.cropping(to: rect) else {
                logger.debug("Failed to crop icon \(i)")
                names.append("")
                continue
            }

            let (match, distance) = findBestMatchByFeaturePrint(tile: tile, in: features)
            names.append(match ?? "")
            logger.debug("Icon \(i): \(match ?? "(no match)") (distance: \(distance))")
        }

        return DetectionResult(readyUpRect: readyUpRect, iconRects: iconRects, names: names)
    }

    // MARK: - OCR Detection

    private struct OCRResult {
        let text: String
        let confidence: Float
        let textRect: CGRect      // The bounding box of the text itself
        let buttonRect: CGRect    // Estimated full button rectangle
    }

    private func runOCRForReadyUp(in image: CGImage) -> [OCRResult] {
        guard #available(macOS 10.15, *) else { return [] }

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        request.minimumTextHeight = 0.008
        // No regionOfInterest - search entire image to avoid coordinate confusion

        let handler = VNImageRequestHandler(cgImage: image, orientation: .up, options: [:])

        do {
            try handler.perform([request])
        } catch {
            logger.debug("OCR failed: \(error.localizedDescription)")
            return []
        }

        guard let observations = request.results else { return [] }

        var results: [OCRResult] = []
        let imageWidth = CGFloat(image.width)
        let imageHeight = CGFloat(image.height)

        for observation in observations {
            guard let candidate = observation.topCandidates(1).first else { continue }

            let text = candidate.string
            let normalized = text.uppercased().replacingOccurrences(of: " ", with: "")

            // Look for "READY UP" or "READYUP"
            guard normalized.contains("READYUP") || (normalized.contains("READY") && normalized.contains("UP")) else {
                continue
            }

            // Vision boundingBox is normalized 0-1 with BOTTOM-LEFT origin (y increases upward)
            // CGImage uses TOP-LEFT origin (y increases downward)
            //
            // Vision:  minY = bottom edge of text, maxY = top edge of text
            // CGImage: minY = top edge of rect, maxY = bottom edge of rect
            //
            // Conversion: CGImage_minY = imageHeight - Vision_maxY * imageHeight
            let bbox = observation.boundingBox

            logger.debug("Vision bbox for '\(text)': minY=\(bbox.minY) maxY=\(bbox.maxY)")

            let textRect = CGRect(
                x: bbox.minX * imageWidth,
                y: imageHeight - bbox.maxY * imageHeight,  // Flip Y: Vision top -> CGImage top
                width: bbox.width * imageWidth,
                height: bbox.height * imageHeight
            )

            logger.debug("Converted textRect: y=\(Int(textRect.minY)) (image height=\(Int(imageHeight)))")

            // Only accept READY UP text that's in the bottom 30% of the image
            // (READY UP button should be near the bottom)
            let bottomThreshold = imageHeight * 0.70
            guard textRect.minY > bottomThreshold else {
                logger.debug("Rejecting READY UP at y=\(Int(textRect.minY)) - not in bottom 30%")
                continue
            }

            // Estimate full button rectangle from text position
            let buttonRect = estimateButtonRect(fromTextRect: textRect, imageWidth: Int(imageWidth), imageHeight: Int(imageHeight))

            results.append(OCRResult(
                text: text,
                confidence: candidate.confidence,
                textRect: textRect,
                buttonRect: buttonRect
            ))
        }

        return results
    }

    private func estimateButtonRect(fromTextRect textRect: CGRect, imageWidth: Int, imageHeight: Int) -> CGRect {
        // The READY UP button contains:
        // - Padding on left edge
        // - A key indicator (e.g., "B") on the left
        // - "READY UP" text (OCR might find "B READY UP" as one block)
        // - Padding on right edge
        // - Yellow/orange border around entire button
        //
        // Based on game UI analysis:
        // - OCR text (including "B") is roughly 70% of button width
        // - Button height is roughly 2x the text height (includes border padding)
        // - Text is vertically centered in the button

        // Button spans full width of 5 icons above it
        // The "B READY UP" text is only about 25% of the full button width
        let buttonWidth = textRect.width * 4.0
        let buttonHeight = textRect.height * 2.2

        // Center the button vertically around the text
        let buttonY = textRect.minY - (buttonHeight - textRect.height) / 2

        // Text "B READY UP" is in the right portion of the button, not centered
        // Button starts about 1.7 text-widths to the left of where text starts
        let buttonX = textRect.minX - (textRect.width * 1.7)

        var rect = CGRect(x: buttonX, y: buttonY, width: buttonWidth, height: buttonHeight)

        // Clamp to image bounds
        rect = rect.intersection(CGRect(x: 0, y: 0, width: imageWidth, height: imageHeight))

        return rect
    }

    private func pickBestReadyUpCandidate(from results: [OCRResult], imageWidth: Int) -> OCRResult? {
        guard !results.isEmpty else { return nil }

        // We want the leftmost READY UP button (for multi-player screens)
        let centerX = CGFloat(imageWidth) / 2

        let sorted = results.sorted { a, b in
            let aMidX = a.buttonRect.midX
            let bMidX = b.buttonRect.midX

            // Prefer buttons in the left half
            let aInLeftHalf = aMidX < centerX
            let bInLeftHalf = bMidX < centerX

            if aInLeftHalf && !bInLeftHalf { return true }
            if !aInLeftHalf && bInLeftHalf { return false }

            // Both in same half - prefer leftmost
            return aMidX < bMidX
        }

        return sorted.first
    }

    // MARK: - Icon Position Calculation

    private func calculateIconRects(readyUpRect: CGRect, imageWidth: Int, imageHeight: Int) -> [CGRect] {
        // Game UI structure (from bottom to top in screen space):
        // 1. READY UP button (yellow border)
        // 2. Tiny gap
        // 3. Dark icon row: 4 mission stratagems + 1 heart booster (what we want!)
        // 4. Small gap
        // 5. Yellow icon row: 5 common stratagems (NOT what we want)
        //
        // The dark icons are IMMEDIATELY above READY UP with minimal gap.

        let buttonWidth = readyUpRect.width
        let buttonHeight = readyUpRect.height
        let buttonTop = readyUpRect.minY  // In CGImage coords, minY is the TOP edge

        // Icon dimensions based on button width
        // Button spans 5 icons + 4 gaps. If gap = 8% of icon width:
        // buttonWidth = 5*iconW + 4*0.08*iconW = 5.32*iconW
        let baseIconSize = buttonWidth / 5.32
        let iconSize = baseIconSize * 0.80  // 20% smaller, shrink from center
        let iconInset = baseIconSize * 0.10  // Half of 20% reduction to center it
        let horizontalGap = baseIconSize * 0.06  // Slightly tighter gap

        // The dark icons are above the button with small gap
        // Gap between icon bottom and button top (~28% of button height)
        let verticalGap = buttonHeight * 0.28

        // Icon bottom edge is just above the button top
        let iconBottom = buttonTop - verticalGap
        let iconTop = iconBottom - baseIconSize + iconInset  // Adjusted for centering

        // First icon aligns with left edge of button, plus extra inset to move right
        let startX = readyUpRect.minX + baseIconSize * 0.04

        var rects: [CGRect] = []
        for i in 0..<4 {  // Only first 4 icons (skip the booster heart)
            let x = startX + CGFloat(i) * (baseIconSize + horizontalGap) + iconInset
            var rect = CGRect(x: x, y: iconTop, width: iconSize, height: iconSize)

            // Clamp to image bounds
            rect = rect.intersection(CGRect(x: 0, y: 0, width: imageWidth, height: imageHeight))

            if rect.width > 10 && rect.height > 10 {
                rects.append(rect)
            }
        }

        return rects
    }

    // MARK: - Icon Feature Matching (Vision Framework)

    private var iconFeaturePrints: [(name: String, featurePrint: VNFeaturePrintObservation)]?

    private func ensureIconFeaturesLoaded() -> [(name: String, featurePrint: VNFeaturePrintObservation)] {
        if let existing = iconFeaturePrints {
            return existing
        }

        var features: [(name: String, featurePrint: VNFeaturePrintObservation)] = []

        for name in canonicalStratagemNames {
            guard let image = NSImage.stratagemIcon(named: name),
                  let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
                  let featurePrint = computeFeaturePrint(from: cgImage) else {
                continue
            }

            features.append((name: name, featurePrint: featurePrint))
        }

        iconFeaturePrints = features
        logger.debug("Loaded \(features.count) icon feature prints")
        return features
    }

    private func computeFeaturePrint(from image: CGImage) -> VNFeaturePrintObservation? {
        let request = VNGenerateImageFeaturePrintRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])

        do {
            try handler.perform([request])
            return request.results?.first
        } catch {
            logger.debug("Feature print failed: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Shape Matching (Tiebreaker Scoring)

    /// Compare images using color histogram on the dominant channel
    /// Works for all icon types (cyan weapons, green/red stratagems, etc.)
    private func computeColorHistogramSimilarity(tile: CGImage, reference: CGImage) -> Double {
        let size = 32

        guard let tileHist = getColorHistogram(from: tile, size: size),
              let refHist = getColorHistogram(from: reference, size: size) else {
            return 0
        }

        // Histogram intersection (similarity 0-1)
        var intersection: Double = 0
        for i in 0..<tileHist.count {
            intersection += min(tileHist[i], refHist[i])
        }

        return intersection
    }

    /// Get normalized color histogram (16 bins for brightness, weighted by saturation)
    private func getColorHistogram(from image: CGImage, size: Int) -> [Double]? {
        let bytesPerRow = size * 4
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue

        guard let context = CGContext(
            data: nil, width: size, height: size,
            bitsPerComponent: 8, bytesPerRow: bytesPerRow,
            space: colorSpace, bitmapInfo: bitmapInfo
        ) else { return nil }

        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))

        guard let data = context.data else { return nil }
        let buffer = data.bindMemory(to: UInt8.self, capacity: bytesPerRow * size)

        // 16-bin histogram for brightness of foreground pixels
        let numBins = 16
        var histogram = [Double](repeating: 0, count: numBins)
        var totalWeight: Double = 0

        for i in 0..<(size * size) {
            let offset = i * 4
            let r = Double(buffer[offset])
            let g = Double(buffer[offset + 1])
            let b = Double(buffer[offset + 2])

            let maxC = max(r, max(g, b))
            let minC = min(r, min(g, b))

            // Skip dark background pixels
            if maxC < 50 { continue }

            // Weight by saturation (colored pixels matter more than gray)
            let saturation = maxC > 0 ? (maxC - minC) / maxC : 0
            let weight = 0.3 + 0.7 * saturation  // Even gray pixels have some weight

            let brightness = maxC
            let bin = min(numBins - 1, Int(brightness / 256.0 * Double(numBins)))
            histogram[bin] += weight
            totalWeight += weight
        }

        // Normalize
        if totalWeight > 0 {
            for i in 0..<numBins {
                histogram[i] /= totalWeight
            }
        }

        return histogram
    }

    /// IoU (Intersection over Union) similarity with local alignment search
    private func computePixelSimilarity(tile: CGImage, reference: CGImage) -> Double {
        let size = 32

        // Use full image including bullet indicators - they help distinguish weapons
        guard let tileMask = generateBinaryMask(from: tile, width: size, height: size, isCapture: true),
              let refMask = generateBinaryMask(from: reference, width: size, height: size, isCapture: false) else {
            return 0
        }

        // Search for best alignment (IoU) within a small window
        // This handles jitter from the screen capture grid calculation
        let searchRange = 3
        var bestIoU: Double = 0

        for dy in -searchRange...searchRange {
            for dx in -searchRange...searchRange {
                var intersection = 0
                var union = 0

                for y in 0..<size {
                    for x in 0..<size {
                        let refVal = refMask[y * size + x]

                        // Apply shift to tile coordinates
                        let tx = x - dx
                        let ty = y - dy

                        let tileVal: Bool
                        if tx >= 0 && tx < size && ty >= 0 && ty < size {
                            tileVal = tileMask[ty * size + tx]
                        } else {
                            tileVal = false
                        }

                        if refVal && tileVal { intersection += 1 }
                        if refVal || tileVal { union += 1 }
                    }
                }

                if union > 0 {
                    let iou = Double(intersection) / Double(union)
                    if iou > bestIoU {
                        bestIoU = iou
                    }
                }
            }
        }

        return bestIoU
    }

    private func generateBinaryMask(from image: CGImage, width: Int, height: Int, isCapture: Bool) -> [Bool]? {
        let bytesPerRow = width * 4
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue

        guard let context = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: bytesPerRow,
            space: colorSpace, bitmapInfo: bitmapInfo
        ) else { return nil }

        // Draw scaled to fit with sharp edges
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        guard let data = context.data else { return nil }
        let buffer = data.bindMemory(to: UInt8.self, capacity: bytesPerRow * height)

        var mask = [Bool](repeating: false, count: width * height)

        for i in 0..<(width * height) {
            let offset = i * 4
            let r = Int(buffer[offset])
            let g = Int(buffer[offset + 1])
            let b = Int(buffer[offset + 2])
            let a = Int(buffer[offset + 3])

            // Use brightness for both - more consistent comparison
            // Reference icons may not have proper alpha channels
            let brightness = max(r, max(g, b))

            if isCapture {
                // Capture: Cyan/Blue on Dark Gray (~44), threshold at 80
                mask[i] = brightness > 80
            } else {
                // Reference: Yellow/gold icons on dark background
                // Also check alpha in case it's transparent
                mask[i] = (brightness > 100) || (a < 200 && a > 50)
            }
        }

        return mask
    }

    // MARK: - dHash (Difference Hash)

    /// Compute perceptual hash for shape comparison
    private func computeDHash(from image: CGImage) -> UInt64 {
        // Crop to center 60% to remove border/frame effects
        let cropMargin = 0.20
        let cropX = Int(Double(image.width) * cropMargin)
        let cropY = Int(Double(image.height) * cropMargin)
        let cropW = image.width - (cropX * 2)
        let cropH = image.height - (cropY * 2)

        let croppedImage: CGImage
        if cropW > 10 && cropH > 10,
           let cropped = image.cropping(to: CGRect(x: cropX, y: cropY, width: cropW, height: cropH)) {
            croppedImage = cropped
        } else {
            croppedImage = image
        }

        // Resize to 9x8 for dHash (produces 8x8 = 64 bit hash)
        let hashWidth = 9
        let hashHeight = 8

        guard let resized = resizeImage(croppedImage, width: hashWidth, height: hashHeight) else {
            return 0
        }

        // Convert to binary silhouette - extract shape regardless of color
        // Pixels with any significant color/brightness become "on"
        var binary = [[Int]](repeating: [Int](repeating: 0, count: hashWidth), count: hashHeight)

        resized.withUnsafeBytes { ptr in
            guard let base = ptr.bindMemory(to: UInt8.self).baseAddress else { return }

            for y in 0..<hashHeight {
                for x in 0..<hashWidth {
                    let offset = (y * hashWidth + x) * 4
                    let r = Int(base[offset])
                    let g = Int(base[offset + 1])
                    let b = Int(base[offset + 2])
                    // Use max channel value to detect any colored content
                    let maxChannel = max(r, max(g, b))
                    // Threshold at 60 - anything brighter is part of the icon
                    binary[y][x] = maxChannel > 60 ? 255 : 0
                }
            }
        }

        // Compute hash: compare each pixel to its right neighbor
        var hash: UInt64 = 0
        var bit: UInt64 = 1

        for y in 0..<hashHeight {
            for x in 0..<(hashWidth - 1) {
                if binary[y][x] < binary[y][x + 1] {
                    hash |= bit
                }
                bit <<= 1
            }
        }

        return hash
    }

    private func resizeImage(_ image: CGImage, width: Int, height: Int) -> Data? {
        let bytesPerRow = width * 4
        var data = Data(count: bytesPerRow * height)

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue

        let success = data.withUnsafeMutableBytes { ptr -> Bool in
            guard let base = ptr.baseAddress,
                  let context = CGContext(
                    data: base,
                    width: width,
                    height: height,
                    bitsPerComponent: 8,
                    bytesPerRow: bytesPerRow,
                    space: colorSpace,
                    bitmapInfo: bitmapInfo
                  ) else {
                return false
            }

            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }

        return success ? data : nil
    }

    private func findBestMatchByFeaturePrint(tile: CGImage, in features: [(name: String, featurePrint: VNFeaturePrintObservation)]) -> (name: String?, distance: Float) {
        guard let tileFeature = computeFeaturePrint(from: tile) else {
            return (nil, Float.greatestFiniteMagnitude)
        }

        // Collect all matches with distances
        var allMatches: [(name: String, distance: Float)] = []

        for (name, featurePrint) in features {
            var distance: Float = 0
            do {
                try tileFeature.computeDistance(&distance, to: featurePrint)
                allMatches.append((name: name, distance: distance))
            } catch {
                continue
            }
        }

        guard !allMatches.isEmpty else {
            return (nil, Float.greatestFiniteMagnitude)
        }

        // Sort by distance
        allMatches.sort { $0.distance < $1.distance }
        let bestDistance = allMatches[0].distance

        // Get all candidates within 0.25 of best (tie zone) - wide to catch similar shapes
        let tieCandidates = allMatches.filter { $0.distance <= bestDistance + 0.25 }

        // If only one candidate or can't compute dHash, use the first one
        if tieCandidates.count <= 1 {
            return bestDistance <= 18 ? (allMatches[0].name, bestDistance) : (nil, bestDistance)
        }

        // Use multiple signals combined for tiebreaker
        var bestTieName: String? = tieCandidates[0].name
        var bestCombinedScore: Double = -Double.greatestFiniteMagnitude

        // Get pre-cropped reference icons and crop the captured tile
        let croppedRefs = ensureCroppedReferenceIconsLoaded()
        let croppedTile = cropCapturedTileToContent(tile) ?? tile

        for candidate in tieCandidates {
            // Use pre-cropped reference icon if available
            let refImage: CGImage
            if let cropped = croppedRefs[candidate.name] {
                refImage = cropped
            } else if let nsImage = NSImage.stratagemIcon(named: candidate.name),
                      let cgImage = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                refImage = cgImage
            } else {
                continue
            }

            // IoU shape similarity (0-1, higher is better) - using cropped images
            let iouScore = computePixelSimilarity(tile: croppedTile, reference: refImage)

            // Color histogram similarity (0-1, higher is better) - works for all icon types
            let colorScore = computeColorHistogramSimilarity(tile: croppedTile, reference: refImage)

            // dHash similarity (0-64 bits different, convert to 0-1 where higher is better)
            let tileHash = computeDHash(from: croppedTile)
            let refHash = computeDHash(from: refImage)
            let hashDist = Double((tileHash ^ refHash).nonzeroBitCount)
            let hashScore = 1.0 - (hashDist / 64.0)

            // Feature print distance (lower is better, normalize and invert)
            let fpScore = 1.0 - Double(candidate.distance)

            // Combined score: IoU 40%, Color 5%, Hash 15%, FP 40%
            let combined = (iouScore * 0.40) + (colorScore * 0.05) + (hashScore * 0.15) + (fpScore * 0.40)

            if combined > bestCombinedScore {
                bestCombinedScore = combined
                bestTieName = candidate.name
            }
        }

        // Return best match after tiebreaker
        return bestDistance <= 18 ? (bestTieName, bestDistance) : (nil, bestDistance)
    }

    #if DEBUG
    private func findTopMatchesByFeaturePrint(tile: CGImage, in features: [(name: String, featurePrint: VNFeaturePrintObservation)], topN: Int = 5) -> [(name: String, distance: Float)] {
        guard let tileFeature = computeFeaturePrint(from: tile) else {
            return []
        }

        var results: [(name: String, distance: Float)] = []

        for (name, featurePrint) in features {
            var distance: Float = 0
            do {
                try tileFeature.computeDistance(&distance, to: featurePrint)
                results.append((name: name, distance: distance))
            } catch {
                continue
            }
        }

        results.sort { $0.distance < $1.distance }
        return Array(results.prefix(topN))
    }
    #endif
}
