import SwiftUI

/// The one filled action of a bar (the editor's Save): white text on the brand fill, drawn here
/// rather than by `.borderedProminent`, which loses its fill inside an `NSToolbar` and leaves
/// white text on the light bar.
struct AccentFillButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.Typography.button.font)
            .foregroundStyle(Color.white)
            .padding(.horizontal, 12)
            .frame(height: Theme.Annotate.toolButtonSize.height)
            .background(
                Capsule().fill(Theme.Colors.brand.color.opacity(configuration.isPressed ? 0.8 : 1))
            )
            .opacity(isEnabled ? 1 : 0.5)
            .contentShape(Capsule())
    }
}
