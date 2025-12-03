import SwiftUI

struct StratagemPickerView: View {
    let stratagems: [Stratagem]
    let currentlySelected: String
    let onSelect: (Stratagem) -> Void
    let onCancel: () -> Void
    @State private var escKeyMonitor: Any?
    @State private var hoveredStratagem: Stratagem?
    @State private var hoverPosition: CGPoint = .zero

    private static let columns = Array(
        repeating: GridItem(.fixed(HBConstants.UI.pickerIconSize), spacing: HBConstants.UI.pickerSpacing),
        count: HBConstants.UI.pickerColumns
    )

    var body: some View {
        ZStack {
            ScrollView {
                LazyVGrid(columns: Self.columns, alignment: .leading, spacing: HBConstants.UI.pickerSpacing) {
                    ForEach(stratagems) { stratagem in
                        PickerIconButton(
                            stratagem: stratagem,
                            isCurrentlySelected: stratagem.name == currentlySelected,
                            onSelect: onSelect,
                            onHover: { isHovered, position in
                                if isHovered {
                                    // Lock position when entering to prevent drift while hovering
                                    if hoveredStratagem?.id != stratagem.id {
                                        hoverPosition = position
                                    }
                                    withAnimation(.easeOut(duration: 0.12)) {
                                        hoveredStratagem = stratagem
                                    }
                                } else if hoveredStratagem?.id == stratagem.id {
                                    withAnimation(.easeOut(duration: 0.12)) {
                                        hoveredStratagem = nil
                                    }
                                }
                            }
                        )
                    }
                }
                .padding(5)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            // Magnified overlay - rendered separately for z-ordering
            if let hovered = hoveredStratagem,
               let image = NSImage.stratagemIcon(named: hovered.name) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(width: HBConstants.UI.pickerIconSize - 4, height: HBConstants.UI.pickerIconSize - 4)
                    .padding(2)
                    .background(Color(red: 0.1, green: 0.1, blue: 0.1))
                    .cornerRadius(2)
                    .scaleEffect(HBConstants.UI.hoverScale)
                    .shadow(color: .black, radius: 4)
                    .position(
                        x: min(max(hoverPosition.x, HBConstants.UI.hoverPadding), HBConstants.UI.hoverMaxX),
                        y: min(max(hoverPosition.y, HBConstants.UI.hoverPadding), HBConstants.UI.hoverMaxY)
                    )
                    .allowsHitTesting(false)
            }
        }
        .coordinateSpace(name: "picker")
        .frame(width: HBConstants.UI.pickerWidth, height: HBConstants.UI.pickerHeight)
        .background(Color.black)
        .onAppear {
            escKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                if event.keyCode == HBConstants.KeyCode.escape {
                    onCancel()
                    return nil
                }
                return event
            }
        }
        .onDisappear {
            if let monitor = escKeyMonitor {
                NSEvent.removeMonitor(monitor)
                escKeyMonitor = nil
            }
        }
    }
}

struct PickerIconButton: View {
    let stratagem: Stratagem
    let isCurrentlySelected: Bool
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
