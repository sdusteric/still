import SnapCore
import SwiftUI

/// The 3 x 3 Align grid of 18 pt squares (design 10.4, 17.6). Index 0 is top-left, 4 the centre,
/// 8 bottom-right, as `BackgroundPreset.alignment`. Alignment only matters with a ratio, so the
/// grid is dimmed to 55% and disabled while Ratio is Auto.
struct AlignmentGrid: View {
    @Binding var selection: Int
    let isEnabled: Bool

    static let gap: Double = 4
    private static let names = [
        "Top Left", "Top", "Top Right", "Left", "Center", "Right", "Bottom Left", "Bottom", "Bottom Right",
    ]

    var body: some View {
        let side = Theme.BackgroundEditor.alignmentSquare
        Grid(horizontalSpacing: Self.gap, verticalSpacing: Self.gap) {
            ForEach(0..<3, id: \.self) { row in
                GridRow {
                    ForEach(0..<3, id: \.self) { column in
                        let index = row * 3 + column
                        Button {
                            selection = index
                        } label: {
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .fill(index == selection ? selectedFill : Theme.Colors.fill.color)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                                        .strokeBorder(Theme.Colors.separator.color, lineWidth: 0.5)
                                )
                                .frame(width: side, height: side)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(Self.names[index])
                        .accessibilityAddTraits(index == selection ? .isSelected : [])
                    }
                }
            }
        }
        .opacity(isEnabled ? 1 : Theme.BackgroundEditor.alignmentDimmedOpacity)
        .disabled(!isEnabled)
        .help(isEnabled ? "Where the card sits in the extra space" : "Choose a ratio to align the card")
    }

    /// The selected square: the accent with a ratio, a neutral gray while dimmed (as in the mockup).
    private var selectedFill: Color {
        isEnabled ? Theme.Colors.accent.color : Theme.Colors.text3.color
    }
}
