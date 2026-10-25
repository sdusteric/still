import AppKit
import SnapCore
import SwiftUI

/// One background swatch: a named gradient, a solid colour, or "no background".
public enum Swatch: Hashable, Identifiable, Sendable {
    case gradient(GradientID)
    case mesh(MeshID)
    case solid(SolidSwatch)

    public var id: String {
        switch self {
        case .gradient(let gradient): "gradient-\(gradient.rawValue)"
        case .mesh(let mesh): "mesh-\(mesh.rawValue)"
        case .solid(let solid): "solid-\(solid.id)"
        }
    }

    public var name: String {
        switch self {
        case .gradient(let gradient): gradient.displayName
        case .mesh(let mesh): mesh.displayName
        case .solid(let solid): solid.name
        }
    }

    public var fill: BackgroundFill {
        switch self {
        case .gradient(let gradient): .gradient(gradient)
        case .mesh(let mesh): .mesh(mesh)
        case .solid(let solid): .solid(solid.color)
        }
    }

    public static let gradients: [Swatch] = GradientID.allCases.map { .gradient($0) }
    public static let meshes: [Swatch] = MeshID.allCases.map { .mesh($0) }
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
        case .mesh(let mesh): MeshSwatchImage.view(for: mesh).clipShape(rounded)
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

/// The mesh swatch pictures, drawn by the same code as the canvas background and kept per mesh.
@MainActor
private enum MeshSwatchImage {
    private static var cache: [MeshID: CGImage] = [:]

    static func view(for mesh: MeshID) -> some View {
        let pixels = Int(Theme.Controls.swatchSize * 2)
        if cache[mesh] == nil {
            cache[mesh] = MeshGradientPainter.image(mesh, width: pixels, height: pixels)
        }
        return Group {
            if let image = cache[mesh] {
                Image(decorative: image, scale: 2)
                    .resizable()
                    .frame(width: Theme.Controls.swatchSize, height: Theme.Controls.swatchSize)
            } else {
                Color.clear
            }
        }
    }
}

/// The first tile of the Image tab: the capture itself, blurred (design 20.9). Same 36 pt tile and
/// selection ring as the swatches.
struct BlurredCaptureTile: View {
    let capture: CGImage
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        let rounded = RoundedRectangle(cornerRadius: Theme.Controls.swatchRadius, style: .continuous)
        HStack(spacing: Theme.Spacing.xs) {
            Button(action: action) {
                Image(decorative: capture, scale: 1)
                    .resizable()
                    .scaledToFill()
                    .frame(width: Theme.Controls.swatchSize, height: Theme.Controls.swatchSize)
                    .blur(radius: 6)
                    .clipShape(rounded)
                    .overlay(rounded.strokeBorder(Theme.Colors.cardEdge.color, lineWidth: 0.5))
                    .overlay(SelectionRing(isSelected: isSelected))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Blurred capture")
            .accessibilityLabel("Blurred capture")
            .accessibilityAddTraits(isSelected ? .isSelected : [])
            Text("Blurred capture")
                .font(Theme.Typography.body.font)
                .foregroundStyle(Theme.Colors.text.color)
        }
    }
}

/// The five-segment Background tab control (mockup 13): a 22 pt track with a raised pill on the
/// selected segment. The native segmented control cannot fit five labels into the 260 pt sidebar.
struct BackgroundTabControl: View {
    let selection: BackgroundTab
    let onSelect: (BackgroundTab) -> Void

    private static let trackRadius: Double = 9
    private static let segmentRadius: Double = 7
    private static let padding: Double = 2
    private static let segmentHeight = Theme.Controls.segmentedHeight

    var body: some View {
        HStack(spacing: 1) {
            ForEach(BackgroundTab.allCases) { tab in
                let isSelected = tab == selection
                Button { onSelect(tab) } label: {
                    Text(tab.title)
                        .font(.system(size: 11.5, weight: isSelected ? .medium : .regular))
                        .foregroundStyle(Theme.Colors.text.color)
                        .frame(maxWidth: .infinity, minHeight: Self.segmentHeight, maxHeight: Self.segmentHeight)
                        .background {
                            if isSelected {
                                RoundedRectangle(cornerRadius: Self.segmentRadius, style: .continuous)
                                    .fill(Theme.Colors.button.color)
                                    .shadow(color: .black.opacity(0.12), radius: 1, y: 1)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: Self.segmentRadius, style: .continuous)
                                            .strokeBorder(Theme.Colors.separator.color, lineWidth: 0.5)
                                    )
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(tab.title)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .padding(Self.padding)
        .background(
            RoundedRectangle(cornerRadius: Self.trackRadius, style: .continuous).fill(Theme.Colors.fill.color)
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Background")
    }
}
