import Foundation
import AppKit
import CoreGraphics
import Vision
import os.log

private let logger = Logger(subsystem: "com.hellpad.app", category: "stratagem-companion")

final class StratagemCompanion {
    struct DetectedStratagem: Equatable {
        let canonicalName: String
        let isReady: Bool
        let cooldownRemainingSeconds: Int?
        let isInbound: Bool
        let isUnavailable: Bool
    }

    static func hasScreenCapturePermission() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    static func requestScreenCapturePermission() {
        _ = CGRequestScreenCaptureAccess()
    }

    static func openScreenCaptureSystemSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
    }

    private let canonicalStratagemNames: [String]
    private let captureRect: CGRect
    private let displayId: CGDirectDisplayID
    private let ocrQueue = DispatchQueue(label: "com.hellpad.stratagem-companion.ocr", qos: .userInitiated)

    private var cooldownEndDatesByName: [String: Date] = [:]
    private var cooldownTimer: Timer?

    var onDetectedStratagems: (([DetectedStratagem]) -> Void)?
    var onRawOcrStrings: (([String]) -> Void)?
    var onStratagemBecameAvailable: ((String) -> Void)?

    init(
        canonicalStratagemNames: [String],
        captureRect: CGRect = CGRect(x: 0, y: 0, width: 500, height: 800),
        displayId: CGDirectDisplayID = CGMainDisplayID()
    ) {
        self.canonicalStratagemNames = canonicalStratagemNames
        self.captureRect = captureRect
        self.displayId = displayId
        startCooldownTimerIfNeeded()
    }

    deinit {
        cooldownTimer?.invalidate()
        cooldownTimer = nil
    }

    func scanAfter(delay: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.scanNow()
        }
    }

    func scanNow() {
        guard ensureScreenCapturePermission() else {
            return
        }

        ocrQueue.async { [weak self] in
            guard let self else { return }
            guard let cgImage = CGDisplayCreateImage(self.displayId, rect: self.captureRect) else {
                logger.error("Failed to capture screen region")
                return
            }

            self.performOCR(cgImage: cgImage)
        }
    }

    private func ensureScreenCapturePermission() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    private func performOCR(cgImage: CGImage) {
        let request = VNRecognizeTextRequest { [weak self] request, error in
            guard let self else { return }

            if let error {
                logger.error("OCR request failed: \(error.localizedDescription)")
                return
            }

            let observations = (request.results as? [VNRecognizedTextObservation]) ?? []
            let strings = observations.compactMap { $0.topCandidates(1).first?.string }
            let detected = self.parseDetectedStratagems(from: strings)

            DispatchQueue.main.async {
                self.onRawOcrStrings?(strings)
                self.onDetectedStratagems?(detected)
            }

            self.updateCooldowns(from: detected)
        }

        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        request.customWords = canonicalStratagemNames

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do {
            try handler.perform([request])
        } catch {
            logger.error("Failed to perform OCR handler: \(error.localizedDescription)")
        }
    }

    private func parseDetectedStratagems(from ocrStrings: [String]) -> [DetectedStratagem] {
        var results: [DetectedStratagem] = []
        results.reserveCapacity(ocrStrings.count)

        var pendingName: String?

        for raw in ocrStrings {
            let cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if cleaned.isEmpty {
                continue
            }

            let cleanedNormalized = cleaned
                .replacingOccurrences(of: "\u{00A0}", with: " ")
                .replacingOccurrences(of: "  ", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)

            if let currentPendingName = pendingName {
                if let status = parseStatusLine(cleanedNormalized) {
                    results.append(
                        DetectedStratagem(
                            canonicalName: currentPendingName,
                            isReady: status.isReady,
                            cooldownRemainingSeconds: status.cooldownSeconds,
                            isInbound: status.isInbound,
                            isUnavailable: status.isUnavailable
                        )
                    )
                    pendingName = nil
                    continue
                }
            }

            if let status = parseStatusLine(cleanedNormalized), pendingName == nil {
                continue
            }

            let nameCandidate = cleanedNormalized

            guard let matchedName = bestCanonicalMatch(for: nameCandidate) else {
                continue
            }

            if let currentPendingName = pendingName, currentPendingName != matchedName {
                results.append(
                    DetectedStratagem(
                        canonicalName: currentPendingName,
                        isReady: true,
                        cooldownRemainingSeconds: nil,
                        isInbound: false,
                        isUnavailable: false
                    )
                )
                pendingName = nil
            }

            if let status = parseStatusLine(cleanedNormalized) {
                results.append(
                    DetectedStratagem(
                        canonicalName: matchedName,
                        isReady: status.isReady,
                        cooldownRemainingSeconds: status.cooldownSeconds,
                        isInbound: status.isInbound,
                        isUnavailable: status.isUnavailable
                    )
                )
                continue
            }

            pendingName = matchedName
        }

        if let pendingName {
            results.append(
                DetectedStratagem(
                    canonicalName: pendingName,
                    isReady: true,
                    cooldownRemainingSeconds: nil,
                    isInbound: false,
                    isUnavailable: false
                )
            )
        }

        return deduplicateByNameKeepingLowestCooldown(results)
    }

    private func parseStatusLine(_ text: String) -> (isReady: Bool, cooldownSeconds: Int?, isInbound: Bool, isUnavailable: Bool)? {
        let lower = text.lowercased()

        if lower.contains("ready") {
            return (true, nil, false, false)
        }

        if lower.contains("unavailable") {
            return (false, nil, false, true)
        }

        let isInbound = lower.contains("inbound")
        let hasCooldownKeyword = lower.contains("cooldown") || isInbound
        let seconds = parseCooldownSeconds(from: text)

        if hasCooldownKeyword {
            return (false, seconds, isInbound, false)
        }

        if let seconds {
            return (false, seconds, false, false)
        }

        return nil
    }

    private func deduplicateByNameKeepingLowestCooldown(_ items: [DetectedStratagem]) -> [DetectedStratagem] {
        var best: [String: DetectedStratagem] = [:]
        var orderedNames: [String] = []
        orderedNames.reserveCapacity(items.count)

        for item in items {
            if let existing = best[item.canonicalName] {
                best[item.canonicalName] = preferredDetection(existing, item)
            } else {
                best[item.canonicalName] = item
                orderedNames.append(item.canonicalName)
            }
        }

        var deduped: [DetectedStratagem] = []
        deduped.reserveCapacity(orderedNames.count)
        for name in orderedNames {
            if let item = best[name] {
                deduped.append(item)
            }
        }
        return deduped
    }

    private func preferredDetection(_ a: DetectedStratagem, _ b: DetectedStratagem) -> DetectedStratagem {
        let aRank = detectionRank(a)
        let bRank = detectionRank(b)

        if aRank != bRank {
            return aRank < bRank ? a : b
        }

        switch aRank {
        case 0:
            return a
        case 1, 2:
            return preferredByRemainingSeconds(a, b)
        case 3:
            return a
        default:
            return a
        }
    }

    private func detectionRank(_ item: DetectedStratagem) -> Int {
        if item.isReady {
            return 0
        }
        if item.isUnavailable {
            return 3
        }
        if item.isInbound {
            return 2
        }
        return 1
    }

    private func preferredByRemainingSeconds(_ a: DetectedStratagem, _ b: DetectedStratagem) -> DetectedStratagem {
        let aSeconds = a.cooldownRemainingSeconds
        let bSeconds = b.cooldownRemainingSeconds

        switch (aSeconds, bSeconds) {
        case (nil, nil):
            return a
        case (let aValue?, nil):
            return aValue > 0 ? a : b
        case (nil, let bValue?):
            return bValue > 0 ? b : a
        case (let aValue?, let bValue?):
            if aValue <= 0 && bValue > 0 { return b }
            if bValue <= 0 && aValue > 0 { return a }
            if aValue <= 0 && bValue <= 0 { return a }
            return aValue <= bValue ? a : b
        }
    }

    private func updateCooldowns(from detected: [DetectedStratagem]) {
        let now = Date()

        var newEndDates: [String: Date] = [:]
        newEndDates.reserveCapacity(detected.count)

        var unavailableNames: [String] = []
        unavailableNames.reserveCapacity(detected.count)

        for item in detected {
            if item.isUnavailable {
                unavailableNames.append(item.canonicalName)
                continue
            }
            if item.isInbound {
                continue
            }
            if let seconds = item.cooldownRemainingSeconds, seconds > 0 {
                newEndDates[item.canonicalName] = now.addingTimeInterval(TimeInterval(seconds))
            }
        }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }

            for name in unavailableNames {
                self.cooldownEndDatesByName.removeValue(forKey: name)
            }

            for (name, newEndDate) in newEndDates {
                if let existing = self.cooldownEndDatesByName[name] {
                    if newEndDate > existing {
                        self.cooldownEndDatesByName[name] = newEndDate
                    }
                } else {
                    self.cooldownEndDatesByName[name] = newEndDate
                }
            }
        }
    }

    private func startCooldownTimerIfNeeded() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if self.cooldownTimer != nil {
                return
            }
            self.cooldownTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
                self?.tickCooldowns()
            }
        }
    }

    private func tickCooldowns() {
        let now = Date()
        var becameReady: [String] = []

        for (name, endDate) in cooldownEndDatesByName {
            if now >= endDate {
                becameReady.append(name)
            }
        }

        if becameReady.isEmpty {
            return
        }

        for name in becameReady {
            cooldownEndDatesByName.removeValue(forKey: name)
            onStratagemBecameAvailable?(name)
        }
    }

    private func parseCooldownSeconds(from text: String) -> Int? {
        let pattern = "(\\d{1,2})\\s*[:\\.\\-]\\s*(\\d{2})"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return nil
        }

        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range),
              match.numberOfRanges >= 3,
              let minutesRange = Range(match.range(at: 1), in: text),
              let secondsRange = Range(match.range(at: 2), in: text) else {
            return nil
        }

        let minutesString = String(text[minutesRange])
        let secondsString = String(text[secondsRange])

        guard let minutes = Int(minutesString),
              let seconds = Int(secondsString),
              seconds >= 0, seconds < 60 else {
            return nil
        }

        let total = minutes * 60 + seconds
        return total > 0 ? total : nil
    }

    private func bestCanonicalMatch(for rawName: String) -> String? {
        let normalizedCandidate = normalizeForMatching(rawName)
        if normalizedCandidate.isEmpty {
            return nil
        }

        var bestName: String?
        var bestScore: Double = 0
#if DEBUG
        var topMatches: [(name: String, score: Double)] = []
        topMatches.reserveCapacity(3)
#endif

        for canonical in canonicalStratagemNames {
            let normalizedCanonical = normalizeForMatching(canonical)
            if normalizedCanonical == normalizedCandidate {
                return canonical
            }

            let score = similarityScore(normalizedCandidate, normalizedCanonical)
#if DEBUG
            if topMatches.count < 3 {
                topMatches.append((canonical, score))
                topMatches.sort { $0.score > $1.score }
            } else if let last = topMatches.last, score > last.score {
                topMatches.removeLast()
                topMatches.append((canonical, score))
                topMatches.sort { $0.score > $1.score }
            }
#endif
            if score > bestScore {
                bestScore = score
                bestName = canonical
            }
        }

        if bestScore < 0.72 {
#if DEBUG
            let best = topMatches.indices.contains(0) ? topMatches[0] : nil
            let second = topMatches.indices.contains(1) ? topMatches[1] : nil
            let third = topMatches.indices.contains(2) ? topMatches[2] : nil
            logger.debug("No match for raw=\(rawName, privacy: .public) normalized=\(normalizedCandidate, privacy: .public). Best=\(best?.name ?? "nil", privacy: .public) score=\(best?.score ?? 0, privacy: .public); second=\(second?.name ?? "nil", privacy: .public) score=\(second?.score ?? 0, privacy: .public); third=\(third?.name ?? "nil", privacy: .public) score=\(third?.score ?? 0, privacy: .public)")
#endif
            return nil
        }

        return bestName
    }

    private func normalizeForMatching(_ value: String) -> String {
        let lower = value.lowercased()
        let allowed = lower.unicodeScalars.filter { scalar in
            CharacterSet.alphanumerics.contains(scalar) || scalar == " "
        }
        let cleaned = String(String.UnicodeScalarView(allowed))
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let corrected = applyOcrCorrections(to: cleaned)
        let tokenized = splitLettersAndDigits(in: corrected)
        return stripLeadingEquipmentCode(from: tokenized)
    }

    private func splitLettersAndDigits(in normalized: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: "([a-z])([0-9])|([0-9])([a-z])", options: []) else {
            return normalized
        }
        let range = NSRange(normalized.startIndex..<normalized.endIndex, in: normalized)
        let replaced = regex.stringByReplacingMatches(in: normalized, options: [], range: range, withTemplate: "$1$3 $2$4")
        return replaced.replacingOccurrences(of: "  ", with: " ")
    }

    private func applyOcrCorrections(to normalized: String) -> String {
        var value = normalized
        value = value.replacingOccurrences(of: "laster cannon", with: "laser cannon")
        value = value.replacingOccurrences(of: "laster", with: "laser")
        return value
    }

    private func stripLeadingEquipmentCode(from normalized: String) -> String {
        let parts = normalized.split(separator: " ").map(String.init)
        guard parts.count >= 2 else {
            return normalized
        }

        let first = parts[0]
        let second = parts[1]

        let isShortLetters = first.count <= 6 && first.allSatisfy { $0.isLetter }
        let isDigits = !second.isEmpty && second.allSatisfy { $0.isNumber }

        if isShortLetters && isDigits {
            let remainder = parts.dropFirst(2).joined(separator: " ")
            return remainder.isEmpty ? normalized : remainder
        }

        return normalized
    }

    private func similarityScore(_ a: String, _ b: String) -> Double {
        if a.isEmpty || b.isEmpty {
            return 0
        }
        let distance = levenshteinDistance(a, b)
        let maxLen = max(a.count, b.count)
        if maxLen == 0 {
            return 1
        }
        return 1.0 - (Double(distance) / Double(maxLen))
    }

    private func levenshteinDistance(_ a: String, _ b: String) -> Int {
        let aChars = Array(a)
        let bChars = Array(b)

        if aChars.isEmpty { return bChars.count }
        if bChars.isEmpty { return aChars.count }

        var prevRow = Array(0...bChars.count)
        var currRow = Array(repeating: 0, count: bChars.count + 1)

        for i in 1...aChars.count {
            currRow[0] = i
            for j in 1...bChars.count {
                let cost = (aChars[i - 1] == bChars[j - 1]) ? 0 : 1
                currRow[j] = min(
                    prevRow[j] + 1,
                    currRow[j - 1] + 1,
                    prevRow[j - 1] + cost
                )
            }
            prevRow = currRow
        }

        return prevRow[bChars.count]
    }
}
