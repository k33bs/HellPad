import SwiftUI
import AppKit
import os.log

private let logger = Logger(subsystem: "com.hellpad.app", category: "ui")

struct ContentView: View {
    @ObservedObject var stratagemManager: StratagemManager
    @State private var showingStratagemPicker = false
    @State private var selectedSlotIndex = 0
    @State private var pickerOpenedFromKeyboard = false
    @State private var keyboardSelectedSlotIndex: Int? = nil
    @State private var slotNavigationEventMonitor: Any?
    @State private var slotNavigationTimeoutTask: DispatchWorkItem?
    @State private var listeningForKeybind = false
    @State private var selectedKeybindIndex: Int? = nil
    @State private var localEventMonitor: Any?
    @State private var duplicateKeys: Set<Int> = []
    @State private var keybindTimeoutTask: DispatchWorkItem?

    var body: some View {
        ZStack {
            // Stratagem Grid (4x2)
            VStack(spacing: 0) {
                ForEach(0..<4) { row in
                    HStack(spacing: 0) {
                        ForEach(0..<2) { col in
                            let index = row * 2 + col
                            if index < stratagemManager.equippedStratagems.count && index < stratagemManager.keybinds.count {
                                StratagemSlotView(
                                    stratagemName: stratagemManager.equippedStratagems[index],
                                    keybind: getKeybindText(for: index),
                                    isError: duplicateKeys.contains(index),
                                    isFlashing: stratagemManager.flashingSlotIndex == index,
                                    isInCombo: stratagemManager.comboQueue.contains(index),
                                    isKeyboardSelected: keyboardSelectedSlotIndex == index,
                                    onStratagemTapped: {
                                        selectedSlotIndex = index
                                        pickerOpenedFromKeyboard = false
                                        showingStratagemPicker = true
                                    },
                                    onKeybindTapped: {
                                        // Can't rebind keys while a combo is running
                                        guard !stratagemManager.isExecutingCombo else {
                                            logger.debug("Cannot rebind during combo execution")
                                            return
                                        }

                                        logger.debug("Keybind button clicked for index: \(index)")

                                        // Cancel any other active rebinding first
                                        if let oldIndex = selectedKeybindIndex, oldIndex != index {
                                            stratagemManager.cancelKeybindListening()
                                        }

                                        selectedKeybindIndex = index
                                        listeningForKeybind = true
                                        stratagemManager.startListeningForKeybind(at: index)
                                        setupKeyMonitor()
                                        startKeybindTimeout()
                                        logger.debug("Key monitor setup, event tap disabled")
                                    },
                                    onStratagemClear: {
                                        stratagemManager.clearStratagem(at: index)
                                    },
                                    onKeybindClear: {
                                        stratagemManager.clearKeybind(at: index)
                                    }
                                )
                            }
                        }
                    }
                }
            }
            .background(Color.black)
            .grayscale(stratagemManager.isPaused ? 1.0 : 0.0)
            .overlay(
                stratagemManager.isPaused ? Color.black.opacity(0.2) : Color.clear
            )

            // Pause overlay text
            if stratagemManager.isPaused {
                VStack(spacing: 4) {
                    Text("PAUSED")
                        .font(.title)
                        .fontWeight(.bold)
                        .foregroundColor(.black)
                    Text("Press P to resume")
                        .font(.caption)
                        .foregroundColor(.black.opacity(0.8))
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.white.opacity(0.8))
                )
                .allowsHitTesting(false)
            }

            // Stratagem Picker Overlay
            if showingStratagemPicker {
                Color.black.opacity(0.8)
                    .ignoresSafeArea()
                    .onTapGesture {
                        showingStratagemPicker = false
                        pickerOpenedFromKeyboard = false
                        keyboardSelectedSlotIndex = nil
                        cancelSlotNavigationTimeout()
                    }

                StratagemPickerView(
                    stratagems: stratagemManager.allStratagems,
                    recentStratagemNames: stratagemManager.recentStratagemNames,
                    currentlySelected: stratagemManager.equippedStratagems[selectedSlotIndex],
                    hoverPreviewEnabled: stratagemManager.hoverPreviewEnabled,
                    keyboardNavigationEnabled: pickerOpenedFromKeyboard,
                    onSelect: { stratagem in
                        stratagemManager.recordRecentStratagem(name: stratagem.name)
                        stratagemManager.updateEquippedStratagem(at: selectedSlotIndex, with: stratagem.name)
                        showingStratagemPicker = false
                        pickerOpenedFromKeyboard = false
                        keyboardSelectedSlotIndex = nil
                        cancelSlotNavigationTimeout()
                    },
                    onCancel: {
                        showingStratagemPicker = false
                        pickerOpenedFromKeyboard = false
                        keyboardSelectedSlotIndex = nil
                        cancelSlotNavigationTimeout()
                    }
                )
            }
        }
        .onAppear {
            setupSlotNavigationMonitor()
        }
        .onDisappear {
            cancelKeybindTimeout()
            if let monitor = localEventMonitor {
                NSEvent.removeMonitor(monitor)
                localEventMonitor = nil
            }
            cancelSlotNavigationTimeout()
            if let monitor = slotNavigationEventMonitor {
                NSEvent.removeMonitor(monitor)
                slotNavigationEventMonitor = nil
            }
        }
    }

    private func getKeybindText(for index: Int) -> String {
        if listeningForKeybind && selectedKeybindIndex == index {
            return "..."
        } else {
            return stratagemManager.keybinds[index].letter
        }
    }

    private func setupKeyMonitor() {
        logger.debug("setupKeyMonitor called, listening: \(listeningForKeybind)")

        // Remove existing monitor if any
        if let monitor = localEventMonitor {
            NSEvent.removeMonitor(monitor)
            localEventMonitor = nil
        }

        localEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [self] event in
            logger.debug("Key event captured, listening: \(listeningForKeybind)")

            guard listeningForKeybind, let index = selectedKeybindIndex else {
                return event
            }

            // Handle Escape to cancel
            if event.keyCode == HBConstants.KeyCode.escape {
                cancelKeybindTimeout()
                stratagemManager.cancelKeybindListening()
                listeningForKeybind = false
                selectedKeybindIndex = nil

                // Remove the event monitor
                if let monitor = localEventMonitor {
                    NSEvent.removeMonitor(monitor)
                    localEventMonitor = nil
                }
                return nil
            }

            // Get key information
            let keyCode = event.keyCode
            let keyCodeHex = String(format: "0x%02X", keyCode)
            let keyString = event.charactersIgnoringModifiers?.uppercased() ?? ""

            logger.debug("Key pressed for rebinding: \(keyString)")

            // Prevent rebinding special keys
            if keyCode == HBConstants.KeyCode.pause || keyCode == HBConstants.KeyCode.escape {
                logger.debug("Cannot rebind special key: \(keyString)")
                return nil
            }

            if !keyString.isEmpty {
                // Find if key is already assigned to another slot
                var duplicateSlotIndex: Int? = nil
                for (i, keybind) in stratagemManager.keybinds.enumerated() {
                    if i != index && keybind.letter.uppercased() == keyString {
                        duplicateSlotIndex = i
                        break
                    }
                }

                if let conflictIndex = duplicateSlotIndex {
                    logger.debug("Key \(keyString) already assigned to slot \(conflictIndex)")

                    // Flash the conflicting slot twice
                    duplicateKeys.insert(conflictIndex)
                    DispatchQueue.main.asyncAfter(deadline: .now() + HBConstants.Timing.flashDuration) {
                        duplicateKeys.remove(conflictIndex)
                        DispatchQueue.main.asyncAfter(deadline: .now() + HBConstants.Timing.flashDuration) {
                            duplicateKeys.insert(conflictIndex)
                            DispatchQueue.main.asyncAfter(deadline: .now() + HBConstants.Timing.flashDuration) {
                                duplicateKeys.remove(conflictIndex)
                            }
                        }
                    }

                    // Keep listening for another key
                    return nil
                }

                cancelKeybindTimeout()
                stratagemManager.updateKeybind(at: index, keyCode: keyCodeHex, letter: keyString)
                listeningForKeybind = false
                selectedKeybindIndex = nil

                // Remove the event monitor after successful assignment
                if let monitor = localEventMonitor {
                    NSEvent.removeMonitor(monitor)
                    localEventMonitor = nil
                }
            }

            return nil
        }
    }

    private func startKeybindTimeout() {
        // Cancel any existing timeout
        keybindTimeoutTask?.cancel()

        // Create new timeout task
        let task = DispatchWorkItem { [self] in
            guard listeningForKeybind else { return }

            logger.debug("Keybind timeout - cancelling")
            stratagemManager.cancelKeybindListening()
            listeningForKeybind = false
            selectedKeybindIndex = nil

            // Remove the event monitor
            if let monitor = localEventMonitor {
                NSEvent.removeMonitor(monitor)
                localEventMonitor = nil
            }
        }

        keybindTimeoutTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 6.0, execute: task)
    }

    private func cancelKeybindTimeout() {
        keybindTimeoutTask?.cancel()
        keybindTimeoutTask = nil
    }

    private func setupSlotNavigationMonitor() {
        if let monitor = slotNavigationEventMonitor {
            NSEvent.removeMonitor(monitor)
            slotNavigationEventMonitor = nil
        }

        slotNavigationEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [self] event in
            guard NSApp.keyWindow?.title == "HellPad" else { return event }
            guard !listeningForKeybind, !showingStratagemPicker else { return event }

            switch event.keyCode {
            case HBConstants.KeyCode.escape:
                if keyboardSelectedSlotIndex != nil {
                    keyboardSelectedSlotIndex = nil
                    cancelSlotNavigationTimeout()
                    return nil
                }
                return event

            case 0x7B, 0x7C, 0x7D, 0x7E:
                if keyboardSelectedSlotIndex == nil {
                    keyboardSelectedSlotIndex = 0
                    resetSlotNavigationTimeout()
                    return nil
                }

                let currentIndex = keyboardSelectedSlotIndex ?? 0
                let row = currentIndex / 2
                let col = currentIndex % 2

                var newRow = row
                var newCol = col

                switch event.keyCode {
                case 0x7B:
                    newCol = max(0, col - 1)
                case 0x7C:
                    newCol = min(1, col + 1)
                case 0x7E:
                    newRow = max(0, row - 1)
                case 0x7D:
                    newRow = min(3, row + 1)
                default:
                    break
                }

                keyboardSelectedSlotIndex = (newRow * 2) + newCol
                resetSlotNavigationTimeout()
                return nil

            case 0x24:
                guard let slotIndex = keyboardSelectedSlotIndex else { return event }
                selectedSlotIndex = slotIndex
                pickerOpenedFromKeyboard = true
                showingStratagemPicker = true
                return nil

            default:
                return event
            }
        }
    }

    private func resetSlotNavigationTimeout() {
        cancelSlotNavigationTimeout()
        let task = DispatchWorkItem { [self] in
            keyboardSelectedSlotIndex = nil
        }
        slotNavigationTimeoutTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 8.0, execute: task)
    }

    private func cancelSlotNavigationTimeout() {
        slotNavigationTimeoutTask?.cancel()
        slotNavigationTimeoutTask = nil
    }
}

struct StratagemSlotView: View {
    let stratagemName: String
    let keybind: String
    let isError: Bool
    let isFlashing: Bool
    let isInCombo: Bool
    let isKeyboardSelected: Bool
    let onStratagemTapped: () -> Void
    let onKeybindTapped: () -> Void
    var onStratagemClear: (() -> Void)? = nil
    var onKeybindClear: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 0) {
            // Stratagem Icon Button - 63px icon + 10px frame = 83px total
            Button(action: onStratagemTapped) {
                if !stratagemName.isEmpty, let image = NSImage.stratagemIcon(named: stratagemName) {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                        .frame(width: 63, height: 63)
                } else {
                    Rectangle()
                        .fill(Color(red: 0.06, green: 0.06, blue: 0.06))
                        .frame(width: 63, height: 63)
                }
            }
            .buttonStyle(PlainButtonStyle())
            .frame(width: 83, height: 83)
            .background(
                RoundedCorner(radius: HBConstants.UI.cornerRadius, corners: [.topLeft, .topRight])
                    .fill(
                        isFlashing ? HBConstants.Visual.flashYellow.opacity(HBConstants.Visual.flashBackgroundOpacity) :
                        isInCombo ? HBConstants.Visual.comboCyan.opacity(HBConstants.Visual.comboBackgroundOpacity) :
                        Color(red: 0.06, green: 0.06, blue: 0.06)
                    )
            )
            .overlay(
                // Only draw border for combo mode (not flash)
                TopAndSidesBorder(radius: HBConstants.UI.cornerRadius - HBConstants.UI.borderInset, inset: HBConstants.UI.borderInset)
                    .stroke(
                        isInCombo ? HBConstants.Visual.comboCyan.opacity(HBConstants.Visual.comboBorderOpacity) : Color.clear,
                        lineWidth: isInCombo ? HBConstants.UI.borderWidth : 0
                    )
            )
            .overlay(
                RoundedCorner(radius: HBConstants.UI.cornerRadius - HBConstants.UI.borderInset, corners: [.topLeft, .topRight])
                    .stroke(Color.white, lineWidth: HBConstants.UI.borderWidth)
                    .frame(
                        width: HBConstants.UI.iconFrameSize - HBConstants.UI.borderWidth,
                        height: HBConstants.UI.iconFrameSize - HBConstants.UI.borderWidth
                    )
                    .opacity(isKeyboardSelected ? 1 : 0)
            )
            .contextMenu {
                Button("Clear") {
                    onStratagemClear?()
                }
                .disabled(stratagemName.isEmpty)
            }

            // Keybind Button - slightly lighter color, rounded bottom corners
            Button(action: onKeybindTapped) {
                ZStack {
                    // Tappable background fill
                    (isError ? HBConstants.Visual.errorRed.opacity(0.7) :
                     isFlashing ? HBConstants.Visual.flashYellow :
                     isInCombo ? HBConstants.Visual.comboCyan.opacity(HBConstants.Visual.comboBorderOpacity) :
                     Color(red: 0.12, green: 0.12, blue: 0.12))
                    Text(keybind)
                        .foregroundColor(.white)
                        .font(.system(size: 14, weight: .bold))
                }
                .frame(width: 83, height: 28)
                .clipShape(RoundedCorner(radius: HBConstants.UI.cornerRadius, corners: [.bottomLeft, .bottomRight]))
            }
            .buttonStyle(PlainButtonStyle())
            .contextMenu {
                Button("Clear") {
                    onKeybindClear?()
                }
                .disabled(keybind.isEmpty)
            }
        }
        .padding(.horizontal, 3)
        .padding(.vertical, 3)
    }
}

// Custom shape for U-shaped border (top and sides only)
struct TopAndSidesBorder: Shape {
    var radius: CGFloat
    var inset: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()

        let adjustedRect = rect.insetBy(dx: inset, dy: inset)

        // Start at bottom-left (extend to actual bottom edge)
        path.move(to: CGPoint(x: adjustedRect.minX, y: rect.maxY))

        // Left side up to top-left corner
        path.addLine(to: CGPoint(x: adjustedRect.minX, y: adjustedRect.minY + radius))

        // Top-left arc
        path.addArc(center: CGPoint(x: adjustedRect.minX + radius, y: adjustedRect.minY + radius),
                   radius: radius,
                   startAngle: .degrees(180),
                   endAngle: .degrees(270),
                   clockwise: false)

        // Top edge
        path.addLine(to: CGPoint(x: adjustedRect.maxX - radius, y: adjustedRect.minY))

        // Top-right arc
        path.addArc(center: CGPoint(x: adjustedRect.maxX - radius, y: adjustedRect.minY + radius),
                   radius: radius,
                   startAngle: .degrees(270),
                   endAngle: .degrees(0),
                   clockwise: false)

        // Right side down to actual bottom edge
        path.addLine(to: CGPoint(x: adjustedRect.maxX, y: rect.maxY))

        return path
    }
}

// Define RectCorner first, before it's used
struct RectCorner: OptionSet, Sendable {
    let rawValue: Int

    static let topLeft = RectCorner(rawValue: 1 << 0)
    static let topRight = RectCorner(rawValue: 1 << 1)
    static let bottomLeft = RectCorner(rawValue: 1 << 2)
    static let bottomRight = RectCorner(rawValue: 1 << 3)
    static let allCorners: RectCorner = [.topLeft, .topRight, .bottomLeft, .bottomRight]
}

// Custom shape for rounded specific corners
struct RoundedCorner: Shape {
    var radius: CGFloat = 6
    var corners: RectCorner = .allCorners

    nonisolated func path(in rect: CGRect) -> Path {
        var path = Path()

        // Use manual bit checking to avoid actor isolation issues
        let topLeft = corners.rawValue & (1 << 0) != 0
        let topRight = corners.rawValue & (1 << 1) != 0
        let bottomLeft = corners.rawValue & (1 << 2) != 0
        let bottomRight = corners.rawValue & (1 << 3) != 0

        // Start from top-left corner
        if topLeft {
            path.move(to: CGPoint(x: rect.minX, y: rect.minY + radius))
            path.addArc(center: CGPoint(x: rect.minX + radius, y: rect.minY + radius),
                       radius: radius, startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false)
        } else {
            path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        }

        // Top edge and top-right corner
        if topRight {
            path.addLine(to: CGPoint(x: rect.maxX - radius, y: rect.minY))
            path.addArc(center: CGPoint(x: rect.maxX - radius, y: rect.minY + radius),
                       radius: radius, startAngle: .degrees(270), endAngle: .degrees(0), clockwise: false)
        } else {
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        }

        // Right edge and bottom-right corner
        if bottomRight {
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - radius))
            path.addArc(center: CGPoint(x: rect.maxX - radius, y: rect.maxY - radius),
                       radius: radius, startAngle: .degrees(0), endAngle: .degrees(90), clockwise: false)
        } else {
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        }

        // Bottom edge and bottom-left corner
        if bottomLeft {
            path.addLine(to: CGPoint(x: rect.minX + radius, y: rect.maxY))
            path.addArc(center: CGPoint(x: rect.minX + radius, y: rect.maxY - radius),
                       radius: radius, startAngle: .degrees(90), endAngle: .degrees(180), clockwise: false)
        } else {
            path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        }

        // Close the path properly
        path.closeSubpath()

        return path
    }
}

