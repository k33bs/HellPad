import SwiftUI

struct StratagemPickerView: View {
    let stratagems: [Stratagem]
    let currentlySelected: String
    let onSelect: (Stratagem) -> Void
    let onCancel: () -> Void
    @State private var escKeyMonitor: Any?

    var columns: [GridItem] {
        Array(repeating: GridItem(.fixed(HBConstants.UI.pickerIconSize), spacing: HBConstants.UI.pickerSpacing),
              count: HBConstants.UI.pickerColumns)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Scrollable Grid (no header - click outside to close)
            ScrollView {
                LazyVGrid(columns: columns, alignment: .leading, spacing: HBConstants.UI.pickerSpacing) {
                    ForEach(stratagems) { stratagem in
                        PickerIconButton(
                            stratagem: stratagem,
                            isCurrentlySelected: stratagem.name == currentlySelected,
                            onSelect: onSelect
                        )
                    }
                }
                .padding(5)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Color.black)
        }
        .frame(width: 186, height: 475)  // Match main window size exactly
        .background(Color.black)
        .onAppear {
            // Set up ESC key listener
            escKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                if event.keyCode == HBConstants.KeyCode.escape {
                    onCancel()
                    return nil  // Consume ESC
                }
                return event
            }
        }
        .onDisappear {
            // Clean up ESC key monitor
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
    @State private var isHovered = false

    var body: some View {
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
                    .fill(Color.gray.opacity(0.3))
                    .frame(width: HBConstants.UI.pickerIconSize,
                           height: HBConstants.UI.pickerIconSize)
            }
        }
        .buttonStyle(PlainButtonStyle())
        .background(
            isCurrentlySelected ? HBConstants.Visual.flashYellow.opacity(0.3) :
            isHovered ? Color.white.opacity(0.2) :
            Color(red: 0.1, green: 0.1, blue: 0.1)
        )
        .cornerRadius(3)
        .onHover { hovering in
            isHovered = hovering
        }
        .help(stratagem.name)  // Tooltip shows full name
    }
}
