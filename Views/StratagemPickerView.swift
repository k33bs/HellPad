import SwiftUI

struct StratagemPickerView: View {
    let stratagems: [Stratagem]
    let recentStratagemNames: [String]
    let currentlySelected: String
    let hoverPreviewEnabled: Bool
    let keyboardNavigationEnabled: Bool
    let onSelect: (Stratagem) -> Void
    let onCancel: () -> Void
    @State private var keyMonitor: Any?
    @State private var hoveredStratagem: Stratagem?
    @State private var hoverPosition: CGPoint = .zero
    @State private var hoverDebounceTask: DispatchWorkItem?
    @State private var searchQuery: String = ""
    @State private var selectedIndex: Int = 0

    private var searchFilteredStratagems: [Stratagem] {
        if searchQuery.isEmpty {
            return stratagems
        }
        return stratagems.filter { $0.name.localizedCaseInsensitiveContains(searchQuery) }
    }

    private struct PickerGridItem {
        let stratagem: Stratagem?
    }

    private var gridItems: [PickerGridItem] {
        if !searchQuery.isEmpty {
            return searchFilteredStratagems.map { PickerGridItem(stratagem: $0) }
        }

        let columns = HBConstants.UI.pickerColumns
        let recent = Array(recentStratagemNames.prefix(columns)).compactMap { recentName in
            stratagems.first { $0.name == recentName }
        }

        if recent.isEmpty {
            return stratagems.map { PickerGridItem(stratagem: $0) }
        }

        let recentNames = Set(recent.map { $0.name })
        let remaining = stratagems.filter { !recentNames.contains($0.name) }

        return recent.map { PickerGridItem(stratagem: $0) } + remaining.map { PickerGridItem(stratagem: $0) }
    }

    private func isSelectable(_ index: Int) -> Bool {
        guard index >= 0 && index < gridItems.count else { return false }
        return gridItems[index].stratagem != nil
    }

    private func nextSelectableIndex(from index: Int, step: Int) -> Int {
        if step == 0 {
            return index
        }

        var candidate = index
        while candidate >= 0 && candidate < gridItems.count {
            if isSelectable(candidate) {
                return candidate
            }
            candidate += step
        }

        return index
    }

    private func nextSelectableIndexUp(from index: Int) -> Int {
        let columns = HBConstants.UI.pickerColumns
        let candidate = index - columns
        guard candidate >= 0 else { return index }
        if isSelectable(candidate) {
            return candidate
        }

        // If the target cell is a placeholder (e.g. recent row partially filled), slide left within that row.
        let rowStart = (candidate / columns) * columns
        var cursor = candidate
        while cursor >= rowStart {
            if isSelectable(cursor) {
                return cursor
            }
            cursor -= 1
        }

        return index
    }

    private static let columns = Array(
        repeating: GridItem(.fixed(HBConstants.UI.pickerIconSize), spacing: HBConstants.UI.pickerSpacing),
        count: HBConstants.UI.pickerColumns
    )

    private var isKeyboardNavigationActive: Bool {
        keyboardNavigationEnabled || !searchQuery.isEmpty
    }

    var body: some View {
        ZStack {
            ScrollView {
                LazyVGrid(columns: Self.columns, alignment: .leading, spacing: HBConstants.UI.pickerSpacing) {
                    ForEach(Array(gridItems.enumerated()), id: \.offset) { index, item in
                        if let stratagem = item.stratagem {
                            PickerIconButton(
                                stratagem: stratagem,
                                isCurrentlySelected: stratagem.name == currentlySelected,
                                isKeyboardSelected: index == selectedIndex && isKeyboardNavigationActive,
                                onSelect: onSelect,
                                onHover: { isHovered, position in
                                    if isHovered {
                                        // Cancel any pending hover
                                        hoverDebounceTask?.cancel()

                                        // Lock position when entering
                                        hoverPosition = position

                                        // Debounce: wait 220ms before showing preview
                                        let task = DispatchWorkItem {
                                            withAnimation(.easeOut(duration: 0.12)) {
                                                hoveredStratagem = stratagem
                                            }
                                        }
                                        hoverDebounceTask = task
                                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22, execute: task)
                                    } else if hoveredStratagem?.id == stratagem.id {
                                        // Cancel pending and hide immediately
                                        hoverDebounceTask?.cancel()
                                        withAnimation(.easeOut(duration: 0.12)) {
                                            hoveredStratagem = nil
                                        }
                                    }
                                }
                            )
                        } else {
                            Color.clear
                                .frame(width: HBConstants.UI.pickerIconSize, height: HBConstants.UI.pickerIconSize)
                                .allowsHitTesting(false)
                        }
                    }
                }
                .padding(5)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            // Magnified overlay - rendered separately for z-ordering
            if hoverPreviewEnabled,
               let hovered = hoveredStratagem,
               let image = NSImage.stratagemIcon(named: hovered.name) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(width: HBConstants.UI.hoverPreviewSize, height: HBConstants.UI.hoverPreviewSize)
                    .padding(3)
                    .background(Color(red: 0.1, green: 0.1, blue: 0.1))
                    .cornerRadius(4)
                    .shadow(color: .black, radius: 4)
                    .position(
                        x: min(max(hoverPosition.x, HBConstants.UI.hoverPadding), HBConstants.UI.hoverMaxX),
                        y: min(max(hoverPosition.y, HBConstants.UI.hoverPadding), HBConstants.UI.hoverMaxY)
                    )
                    .allowsHitTesting(false)
            }

            // Search bar at bottom
            if !searchQuery.isEmpty {
                VStack {
                    Spacer()
                    HStack {
                        Image(systemName: "magnifyingglass")
                            .foregroundColor(.gray)
                        Text(searchQuery)
                            .foregroundColor(.white)
                        Spacer()
                        Text("\(searchFilteredStratagems.count) results")
                            .foregroundColor(.gray)
                            .font(.caption)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(Color(red: 0.15, green: 0.15, blue: 0.15))
                    .cornerRadius(6)
                    .padding(5)
                }
                .allowsHitTesting(false)
            }
        }
        .coordinateSpace(name: "picker")
        .frame(width: HBConstants.UI.pickerWidth, height: HBConstants.UI.pickerHeight)
        .background(Color.black)
        .onAppear {
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                // Ignore events with Command, Control, or Option modifiers (allow system shortcuts)
                let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                if modifiers.contains(.command) || modifiers.contains(.control) || modifiers.contains(.option) {
                    return event
                }

                // ESC: clear search or close picker
                if event.keyCode == HBConstants.KeyCode.escape {
                    if !searchQuery.isEmpty {
                        searchQuery = ""
                        selectedIndex = 0
                        return nil
                    }
                    onCancel()
                    return nil
                }

                // Enter: select current item
                if event.keyCode == 0x24 {  // Return key
                    if isKeyboardNavigationActive,
                       selectedIndex < gridItems.count,
                       let stratagem = gridItems[selectedIndex].stratagem {
                        onSelect(stratagem)
                        return nil
                    }
                    return event
                }

                // Arrow keys: navigate grid (6 columns)
                if isKeyboardNavigationActive {
                    let columns = HBConstants.UI.pickerColumns
                    switch event.keyCode {
                    case 0x7B:  // Left arrow
                        if selectedIndex > 0 {
                            let target = selectedIndex - 1
                            selectedIndex = nextSelectableIndex(from: target, step: -1)
                        }
                        return nil
                    case 0x7C:  // Right arrow
                        if selectedIndex < gridItems.count - 1 {
                            let target = selectedIndex + 1
                            selectedIndex = nextSelectableIndex(from: target, step: 1)
                        }
                        return nil
                    case 0x7E:  // Up arrow
                        if selectedIndex >= columns {
                            selectedIndex = nextSelectableIndexUp(from: selectedIndex)
                        }
                        return nil
                    case 0x7D:  // Down arrow
                        if selectedIndex + columns < gridItems.count {
                            let target = selectedIndex + columns
                            if isSelectable(target) {
                                selectedIndex = target
                            } else {
                                selectedIndex = nextSelectableIndex(from: target, step: 1)
                            }
                        } else if selectedIndex < gridItems.count - 1 {
                            // No icon directly below - jump to last icon
                            selectedIndex = nextSelectableIndex(from: gridItems.count - 1, step: -1)
                        }
                        return nil
                    default:
                        break
                    }
                }

                // Backspace: remove last character
                if event.keyCode == 0x33 {  // Delete key
                    if !searchQuery.isEmpty {
                        searchQuery.removeLast()
                        selectedIndex = 0
                        // Clear hover preview when search changes
                        hoverDebounceTask?.cancel()
                        hoveredStratagem = nil
                    }
                    return nil
                }

                // Type letters/numbers to search (always lowercase)
                if let chars = event.charactersIgnoringModifiers?.lowercased(), !chars.isEmpty {
                    let char = chars.first!
                    if char.isLetter || char.isNumber || char == " " {
                        searchQuery += String(char)
                        selectedIndex = 0
                        // Clear hover preview when search changes
                        hoverDebounceTask?.cancel()
                        hoveredStratagem = nil
                        return nil
                    }
                }

                return event
            }
        }
        .onDisappear {
            if let monitor = keyMonitor {
                NSEvent.removeMonitor(monitor)
                keyMonitor = nil
            }
        }
    }
}

struct PickerIconButton: View {
    let stratagem: Stratagem
    let isCurrentlySelected: Bool
    var isKeyboardSelected: Bool = false
    let onSelect: (Stratagem) -> Void
    var onHover: ((Bool, CGPoint) -> Void)? = nil
    @State private var isHovered = false

    var body: some View {
        GeometryReader { geo in
            Button(action: {
                onSelect(stratagem)
            }) {
                if let image = NSImage.stratagemIcon(named: stratagem.name) {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                        .frame(width: HBConstants.UI.pickerIconSize,
                               height: HBConstants.UI.pickerIconSize)
                } else {
                    Rectangle()
                        .fill(Color.gray)
                        .frame(width: HBConstants.UI.pickerIconSize,
                               height: HBConstants.UI.pickerIconSize)
                }
            }
            .buttonStyle(PlainButtonStyle())
            .background(
                isCurrentlySelected ? HBConstants.Visual.flashYellow.opacity(HBConstants.Visual.flashBackgroundOpacity) :
                isHovered ? Color(red: 0.2, green: 0.2, blue: 0.2) :
                Color(red: 0.1, green: 0.1, blue: 0.1)
            )
            .cornerRadius(3)
            .overlay(
                // White inner border for keyboard selection
                RoundedRectangle(cornerRadius: 3)
                    .strokeBorder(Color.white, lineWidth: isKeyboardSelected ? 2 : 0)
            )
            .onHover { hovering in
                isHovered = hovering
                let frame = geo.frame(in: .named("picker"))
                let center = CGPoint(x: frame.midX, y: frame.midY)
                onHover?(hovering, center)
            }
            .help(stratagem.name)
        }
        .frame(width: HBConstants.UI.pickerIconSize, height: HBConstants.UI.pickerIconSize)
    }
}
