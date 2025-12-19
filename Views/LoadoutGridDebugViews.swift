import AppKit
import Combine
import SwiftUI

#if DEBUG

// MARK: - Debug Window Controller

final class LoadoutGridDebugWindowController: ObservableObject {
    @Published var snapshot: LoadoutGridDebugSnapshot?
    @Published var originalSnapshot: LoadoutGridDebugSnapshot?
    @Published var weights = MatchWeights.default
    private var window: NSWindow?
    var loadoutGridReader: LoadoutGridReader?

    func show() {
        if window == nil {
            let w = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 1100, height: 850),
                styleMask: [.titled, .closable, .resizable, .miniaturizable],
                backing: .buffered,
                defer: false
            )
            w.title = "Loadout Grid Debug"
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(
                rootView: LoadoutGridDebugWindowView(controller: self))
            window = w
        }

        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func setSnapshot(_ newSnapshot: LoadoutGridDebugSnapshot) {
        originalSnapshot = newSnapshot
        snapshot = newSnapshot
        weights = MatchWeights.default
    }

    func reEvaluate() {
        guard let original = originalSnapshot, let reader = loadoutGridReader else { return }
        snapshot = reader.reEvaluateWithWeights(original, weights: weights)
    }
}

// MARK: - Debug Window View

struct LoadoutGridDebugWindowView: View {
    @ObservedObject var controller: LoadoutGridDebugWindowController

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Loadout Grid Debug").font(.title2).bold()
                Spacer()
                if let snapshot = controller.snapshot {
                    Text(snapshot.timestamp.formatted(date: .omitted, time: .standard))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let snapshot = controller.snapshot {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Detected")
                                .font(.headline)
                            Text(
                                snapshot.names.enumerated().map {
                                    "\($0.offset + 1): \($0.element.isEmpty ? "(no match)" : $0.element)"
                                }.joined(separator: "\n")
                            )
                            .font(.system(.body, design: .monospaced))
                        }

                        VStack(alignment: .leading, spacing: 6) {
                            Text("READY UP")
                                .font(.headline)
                            Text("method=\(snapshot.readyUpDetectionMethod)")
                                .font(.system(.caption, design: .monospaced))
                            Text(
                                "analysisRectInFull=\(Int(snapshot.quadrantRectInFullCapture.minX)),\(Int(snapshot.quadrantRectInFullCapture.minY)) \(Int(snapshot.quadrantRectInFullCapture.width))x\(Int(snapshot.quadrantRectInFullCapture.height))"
                            )
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            if !snapshot.readyUpOcrCandidates.isEmpty {
                                Text(
                                    snapshot.readyUpOcrCandidates.map {
                                        "dx=\($0.centerDxFromScreenCenter)\tconf=\($0.confidence)\t\($0.text)\trect=\(Int($0.rect.minX)),\(Int($0.rect.minY)) \(Int($0.rect.width))x\(Int($0.rect.height))"
                                    }.joined(separator: "\n")
                                )
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(.secondary)
                            }
                        }

                        HStack(alignment: .top, spacing: 12) {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Full capture").font(.headline)
                                LoadoutGridCGImageView(cgImage: snapshot.fullCapture)
                                    .frame(height: 260)
                            }

                            VStack(alignment: .leading, spacing: 6) {
                                Text("Analysis + overlays").font(.headline)
                                LoadoutGridOverlayImage(
                                    cgImage: snapshot.quadrant,
                                    readyUpRect: snapshot.readyUpRect,
                                    iconRects: snapshot.iconRects
                                )
                                .frame(height: 260)
                            }
                        }

                        VStack(alignment: .leading, spacing: 8) {
                            Text("Icon tiles").font(.headline)
                            HStack(alignment: .top, spacing: 10) {
                                ForEach(Array(snapshot.iconTiles.enumerated()), id: \.offset) {
                                    idx, tile in
                                    VStack(alignment: .leading, spacing: 6) {
                                        LoadoutGridCGImageView(cgImage: tile)
                                            .frame(width: 150, height: 150)
                                        let name =
                                            idx < snapshot.names.count
                                            ? snapshot.names[idx] : ""
                                        Text(name.isEmpty ? "(no match)" : name)
                                            .font(.caption)
                                    }
                                }
                            }
                        }

                        WeightSlidersView(controller: controller)

                        LoadoutGridMatchesView(matches: snapshot.matches)
                    }
                    .padding(.vertical, 10)
                }
            } else {
                Spacer()
                Text("Press Option+0 to capture and populate this window.")
                    .foregroundStyle(.secondary)
                Spacer()
            }
        }
        .padding(14)
        .frame(minWidth: 900, minHeight: 600)
    }
}

// MARK: - Weight Tuning Views

private struct WeightSlidersView: View {
    @ObservedObject var controller: LoadoutGridDebugWindowController

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Weight Tuning").font(.headline)
                Spacer()
                Button("Reset") {
                    controller.weights = MatchWeights.default
                    controller.reEvaluate()
                }
                .buttonStyle(.bordered)
            }

            HStack(spacing: 20) {
                WeightSlider(label: "IoU", value: $controller.weights.iou, onChanged: { controller.reEvaluate() })
                WeightSlider(label: "Color", value: $controller.weights.color, onChanged: { controller.reEvaluate() })
                WeightSlider(label: "Hash", value: $controller.weights.hash, onChanged: { controller.reEvaluate() })
                WeightSlider(label: "FP", value: $controller.weights.fp, onChanged: { controller.reEvaluate() })
            }

            Text("Total: \(String(format: "%.2f", controller.weights.iou + controller.weights.color + controller.weights.hash + controller.weights.fp))")
                .font(.caption)
                .foregroundColor(abs(controller.weights.iou + controller.weights.color + controller.weights.hash + controller.weights.fp - 1.0) < 0.01 ? .secondary : .orange)
        }
        .padding(10)
        .background(Color.secondary.opacity(0.1))
        .cornerRadius(8)
    }
}

private struct WeightSlider: View {
    let label: String
    @Binding var value: Double
    let onChanged: () -> Void

    var body: some View {
        VStack(spacing: 4) {
            Text("\(label): \(String(format: "%.2f", value))")
                .font(.system(.caption, design: .monospaced))
            Slider(value: $value, in: 0...1, step: 0.05)
                .frame(width: 150)
                .onChange(of: value) { _ in
                    onChanged()
                }
        }
    }
}

// MARK: - Match Display Views

private struct LoadoutGridMatchesView: View {
    let matches: [LoadoutGridDebugMatch]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Matches (Feature Print Distance)").font(.headline)
            ForEach(Array(matches.enumerated()), id: \.offset) { _, match in
                LoadoutGridMatchRow(match: match)
                Divider()
            }
        }
    }
}

private struct LoadoutGridMatchRow: View {
    let match: LoadoutGridDebugMatch

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Slot \(match.slotIndex + 1)")
                    .font(.system(.caption, design: .monospaced).bold())
                Text("rect=\(Int(match.rect.minX)),\(Int(match.rect.minY)) \(Int(match.rect.width))x\(Int(match.rect.height))")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Text("Best: \(match.bestName ?? "(no match)") (dist: \(String(format: "%.1f", match.bestDistance)))")
                .font(.system(.caption, design: .monospaced))
                .foregroundColor(match.bestDistance <= 18 ? .primary : .red)

            Text("Top 5 matches:")
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.secondary)
            HStack(alignment: .top, spacing: 8) {
                ForEach(Array(match.topCandidates.enumerated()), id: \.offset) { _, candidate in
                    LoadoutGridCandidateView(candidate: candidate)
                }
            }
        }
        .padding(.vertical, 6)
    }
}

private struct LoadoutGridCandidateView: View {
    let candidate: LoadoutGridDebugCandidate

    var body: some View {
        VStack(spacing: 2) {
            if let refIcon = candidate.referenceIcon {
                LoadoutGridCGImageView(cgImage: refIcon)
                    .frame(width: 40, height: 40)
            } else {
                Rectangle()
                    .fill(Color.gray.opacity(0.3))
                    .frame(width: 40, height: 40)
            }
            Text(String(format: "%.1f", candidate.distance))
                .font(.system(.caption2, design: .monospaced))
                .foregroundColor(candidate.distance <= 18 ? .green : .red)

            if candidate.combinedScore > 0 {
                Text(String(format: "C:%.2f", candidate.combinedScore))
                    .font(.system(size: 8, design: .monospaced))
                    .foregroundColor(.blue)
                Text(String(format: "I%.0f H%.0f", candidate.iouScore * 100, candidate.hashScore * 100))
                    .font(.system(size: 7, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Image Display Views

private struct LoadoutGridCGImageView: View {
    let cgImage: CGImage

    var body: some View {
        let nsImage = NSImage(
            cgImage: cgImage, size: CGSize(width: cgImage.width, height: cgImage.height))
        return Image(nsImage: nsImage)
            .resizable()
            .interpolation(.none)
            .aspectRatio(contentMode: .fit)
            .background(Color.black.opacity(0.15))
            .cornerRadius(6)
    }
}

private struct LoadoutGridOverlayImage: View {
    let cgImage: CGImage
    let readyUpRect: CGRect
    let iconRects: [CGRect]

    var body: some View {
        GeometryReader { geo in
            let iw = CGFloat(cgImage.width)
            let ih = CGFloat(cgImage.height)
            let scale = min(geo.size.width / iw, geo.size.height / ih)
            let dw = iw * scale
            let dh = ih * scale
            let ox = (geo.size.width - dw) / 2
            let oy = (geo.size.height - dh) / 2

            ZStack(alignment: .topLeading) {
                LoadoutGridCGImageView(cgImage: cgImage)
                    .frame(width: dw, height: dh)
                    .clipped()

                Path { p in
                    func scaleRect(_ rect: CGRect) -> CGRect {
                        CGRect(
                            x: rect.origin.x * scale,
                            y: rect.origin.y * scale,
                            width: rect.size.width * scale,
                            height: rect.size.height * scale
                        )
                    }

                    p.addRect(scaleRect(readyUpRect))
                    for rect in iconRects {
                        p.addRect(scaleRect(rect))
                    }
                }
                .stroke(Color.red, lineWidth: 2)
                .frame(width: dw, height: dh)
            }
            .offset(x: ox, y: oy)
        }
        .background(Color.black.opacity(0.05))
        .cornerRadius(6)
    }
}

#endif
