import AppKit
import SnapCore
import SwiftUI

/// One background swatch: a named gradient, a solid colour, or "no background".
public enum Swatch: Hashable, Identifiable, Sendable {
    case gradient(GradientID)
    case solid(SolidSwatch)

    public var id: String {
        switch self {
        case .gradient(let gradient): "gradient-\(gradient.rawValue)"
        case .solid(let solid): "solid-\(solid.id)"
        }
    }

    public var name: String {
        switch self {
        case .gradient(let gradient): gradient.displayName
        case .solid(let solid): solid.name
        }
    }

    public var fill: BackgroundFill {
        switch self {
        case .gradient(let gradient): .gradient(gradient)
        case .solid(let solid): .solid(solid.color)
        }
    }

    public static let gradients: [Swatch] = GradientID.allCases.map { .gradient($0) }
    public static let solids: [Swatch] = SolidSwatch.all.map { .solid($0) }
}

extension RGBAColor {
    var swiftUIColor: Color { Color(.sRGB, red: red, green: green, blue: blue, opacity: alpha) }

    init(_ color: Color) {
        let resolved = NSColor(color).usingColorSpace(.sRGB) ?? .black
        self.init(
            red: Double(resolved.redComponent), green: Double(resolved.greenComponent),
            blue: Double(resolved.blueComponent), alpha: Double(resolved.alphaComponent)
        )
    }
}

extension GradientID {
    /// The CSS 135 degree gradient: first stop top-left, last stop bottom-right.
    var linearGradient: LinearGradient {
        LinearGradient(colors: stops.map(\.swiftUIColor), startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

/// 36 pt swatches, radius 8, in 6 columns with an 8 pt gap; the selected one has a 2 pt accent
/// ring 4 pt outside it that appears in 100 ms (design 10.4, 17.4, M11). In the Color tab the last
/// cell is a colour well for any other colour.
struct SwatchGrid: View {
    let swatches: [Swatch]
    let selection: BackgroundFill
    let onSelect: (BackgroundFill) -> Void
    /// Shown after the swatches when set: the custom colour well.
    var customColor: Binding<Color>?

    private var columns: [GridItem] {
        Array(
            repeating: GridItem(.fixed(Theme.Controls.swatchSize), spacing: Theme.Controls.swatchGap),
            count: Theme.Controls.swatchColumns
        )
    }

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: Theme.Controls.swatchGap) {
            ForEach(swatches) { swatch in
                SwatchCell(swatch: swatch, isSelected: swatch.fill == selection) {
                    onSelect(swatch.fill)
                }
            }
            if let customColor {
                CustomColorCell(color: customColor, isSelected: isCustomSelected)
            }
        }
    }

    private var isCustomSelected: Bool {
        guard case .solid = selection else { return false }
        return !swatches.contains { $0.fill == selection }
    }
}

private struct SwatchCell: View {
    let swatch: Swatch
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            shape
                .frame(width: Theme.Controls.swatchSize, height: Theme.Controls.swatchSize)
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Controls.swatchRadius, style: .continuous)
                        // The card edge token, so the navy and teal swatches keep an edge in dark mode.
                        .strokeBorder(Theme.Colors.cardEdge.color, lineWidth: 0.5)
                )
                .overlay(SelectionRing(isSelected: isSelected))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(swatch.name)
        .accessibilityLabel(swatch.name)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    @ViewBuilder private var shape: some View {
        let rounded = RoundedRectangle(cornerRadius: Theme.Controls.swatchRadius, style: .continuous)
        switch swatch {
        case .gradient(let gradient): rounded.fill(gradient.linearGradient)
        case .solid(let solid): rounded.fill(solid.color.swiftUIColor)
        }
    }
}

private struct CustomColorCell: View {
    @Binding var color: Color
    let isSelected: Bool

    var body: some View {
        ColorPicker("Custom Color", selection: $color, supportsOpacity: false)
            .labelsHidden()
            .frame(width: Theme.Controls.swatchSize, height: Theme.Controls.swatchSize)
            .overlay(SelectionRing(isSelected: isSelected).allowsHitTesting(false))
            .help("Custom Color")
    }
}

/// The 2 pt accent ring 4 pt outside a 36 pt swatch.
private struct SelectionRing: View {
    let isSelected: Bool

    var body: some View {
        let offset = Theme.Controls.swatchRingOffset
        RoundedRectangle(cornerRadius: Theme.Controls.swatchRadius + offset, style: .continuous)
            .strokeBorder(Theme.Colors.accent.color, lineWidth: Theme.Controls.swatchRingWidth)
            .padding(-offset)
            .opacity(isSelected ? 1 : 0)
            .animation(Theme.Motion.enter(Theme.Motion.swatchRing), value: isSelected)
    }
}
