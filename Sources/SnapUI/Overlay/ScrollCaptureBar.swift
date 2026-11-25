import AppKit
import Observation
import SnapCore
import SwiftUI

/// What the scrolling capture bar shows: the status line, the size so far, Done and Cancel.
@Observable
public final class ScrollCaptureBarModel {
    public var progress: ScrollCaptureProgress?
    /// Display scale, to show the size in points like the Quick Access card.
    public let scale: Double
    /// A fixed width for the bar, so it keeps its size as the status line changes. Nil fits the content.
    public var barWidth: Double?
    @ObservationIgnored public var onDone: @MainActor () -> Void = {}
    @ObservationIgnored public var onCancel: @MainActor () -> Void = {}

    public init(scale: Double) {
        self.scale = max(scale, 1)
    }

    public var message: String {
        switch progress?.status {
        case .tooFast: "Too fast. Scroll back up a little."
        case .full: "Size limit reached"
        case .stopped: "Capture stopped. Done keeps what is there."
        case .waiting, .growing, .none: "Scroll down to capture more"
        }
    }

    public var isWarning: Bool {
        progress?.status == .tooFast || progress?.status == .full || progress?.status == .stopped
    }

    /// `W × H` in points, nil before the first frame.
    public var sizeText: String? {
        guard let size = progress?.pixelSize, size.width > 0 else { return nil }
        let width = Int((Double(size.width) / scale).rounded())
        let height = Int((Double(size.height) / scale).rounded())
        return "\(width) \u{00D7} \(height)"
    }
}

/// Where the bar goes: centered under the area, else above it, else inside its bottom edge, and
/// always inside the visible frame. Global top-left points.
public enum ScrollCaptureLayout {
    public static func barFrame(area: CGRect, visibleFrame: CGRect, barSize: CGSize) -> CGRect {
        let gap = Theme.ScrollCapture.barGap
        var x = area.midX - barSize.width / 2
        x = min(max(x, visibleFrame.minX + gap), visibleFrame.maxX - gap - barSize.width)
        let below = area.maxY + gap
        let above = area.minY - gap - barSize.height
        let y: Double
        if below + barSize.height <= visibleFrame.maxY {
            y = below
        } else if above >= visibleFrame.minY {
            y = above
        } else {
            y = min(area.maxY, visibleFrame.maxY) - gap - barSize.height
        }
        return CGRect(x: x, y: y, width: barSize.width, height: barSize.height)
    }
}

/// The bar: a status dot and line, the size, then Cancel and Done with their keys.
struct ScrollCaptureBar: View {
    let model: ScrollCaptureBarModel

    var body: some View {
        HStack(spacing: Theme.ScrollCapture.barSpacing) {
            HStack(spacing: 7) {
                if model.isWarning {
                    Circle().fill(Theme.Colors.warningDot.color).frame(width: 7, height: 7)
                }
                Text(model.message)
                    .font(Theme.Typography.caption.font)
                    .lineLimit(1)
                    .fixedSize()
            }
            .padding(.leading, 10)
            if let size = model.sizeText {
                Text(size)
                    .font(Theme.Typography.chip.font)
                    .foregroundStyle(Theme.Colors.chipText.color.opacity(0.72))
                    .fixedSize()
            }
            Spacer(minLength: 0)
            Rectangle()
                .fill(Theme.Colors.chipDivider.color)
                .frame(width: 1, height: 16)
            Button { model.onCancel() } label: {
                keyLabel("Cancel", key: "Esc")
            }
            .buttonStyle(.plain)
            .help("Cancel (Esc)")
            Button { model.onDone() } label: {
                keyLabel("Done", key: "\u{21A9}")
                    .padding(.horizontal, 10)
                    .frame(height: Theme.ScrollCapture.buttonHeight)
                    .background(Capsule().fill(Theme.Colors.brand.color))
            }
            .buttonStyle(.plain)
            .help("Done (Return)")
        }
        .foregroundStyle(Theme.Colors.chipText.color)
        .padding(.horizontal, Theme.ScrollCapture.barPadding)
        .frame(width: model.barWidth.map { CGFloat($0) }, height: Theme.ScrollCapture.barHeight)
        .background(
            Capsule()
                .fill(Theme.Colors.chip.color)
                .overlay(Capsule().strokeBorder(Theme.Colors.chipRing.color, lineWidth: Theme.Overlay.chipRingWidth))
        )
        .environment(\.colorScheme, .dark)
        .accessibilityElement(children: .contain)
    }

    private func keyLabel(_ title: String, key: String) -> some View {
        HStack(spacing: 6) {
            Text(title).font(Theme.Typography.captionSemibold.font)
            Text(key)
                .font(Theme.Typography.chip.font)
                .padding(.horizontal, 5)
                .frame(height: 18)
                .background(RoundedRectangle(cornerRadius: Theme.History.keyCapRadius, style: .continuous).fill(Color.white.opacity(0.16)))
        }
        .padding(.horizontal, 4)
        .contentShape(Rectangle())
    }
}

/// The non-activating panel that carries the bar near the area. It takes clicks for Done and
/// Cancel but never focus; the keys come in as grabbed hotkeys. Made on the first `show`, so
/// tests and shot mode never create it.
public final class ScrollCaptureBarPanel {
    private var panel: NSPanel?
    private var host: NSHostingView<AnyView>?

    public init() {}

    public var windowID: WindowID? {
        guard let panel, panel.windowNumber > 0 else { return nil }
        return WindowID(panel.windowNumber)
    }

    /// The bar's size for `model` as it reads now.
    public static func barSize(_ model: ScrollCaptureBarModel) -> CGSize {
        let host = NSHostingView(rootView: ScrollCaptureBar(model: model))
        let fitting = host.fittingSize
        return CGSize(width: ceil(fitting.width), height: Theme.ScrollCapture.barHeight)
    }

    /// Shows the bar at `frame` (global top-left points, the bar itself without its margin).
    public func show(_ model: ScrollCaptureBarModel, frame: CGRect, primaryHeight: Double) {
        let margin = Theme.ScrollCapture.panelMargin
        let outer = frame.insetBy(dx: -margin, dy: -margin)
        let screenFrame = CGRect(x: outer.minX, y: primaryHeight - outer.maxY, width: outer.width, height: outer.height)
        let panel = self.panel ?? makePanel(model: model, frame: screenFrame)
        self.panel = panel
        panel.setFrame(screenFrame, display: true)
        panel.orderFrontRegardless()
    }

    public func hide() {
        panel?.orderOut(nil)
    }

    /// Internal so `PanelGlueTests` can check its level without showing it.
    func makePanel(model: ScrollCaptureBarModel, frame: CGRect) -> NSPanel {
        let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.becomesKeyOnlyIfNeeded = true
        let content = ScrollCaptureBar(model: model)
            .shadow(color: .black.opacity(Theme.Materials.cardShadowOpacity), radius: 10, y: 4)
            .padding(Theme.ScrollCapture.panelMargin)
        let host = NSHostingView(rootView: AnyView(content))
        host.frame = CGRect(origin: .zero, size: frame.size)
        host.autoresizingMask = [.width, .height]
        panel.contentView = host
        self.host = host
        return panel
    }
}

/// Shot mode: the bar under an outlined area while it grows, and with the too-fast warning.
public enum ScrollCaptureDemo {
    public static let size = CGSize(width: 760, height: 420)

    public static func scene(dark: Bool) -> some View {
        let growing = ScrollCaptureBarModel(scale: 2)
        growing.progress = ScrollCaptureProgress(status: .growing, pixelSize: PixelSize(width: 1040, height: 8460))
        let fast = ScrollCaptureBarModel(scale: 2)
        fast.progress = ScrollCaptureProgress(status: .tooFast, pixelSize: PixelSize(width: 1040, height: 8460))
        let longest = ScrollCaptureBarModel(scale: 2)
        longest.progress = ScrollCaptureProgress(status: .stopped, pixelSize: PixelSize(width: 1040, height: 8460))
        let width = ScrollCaptureBarPanel.barSize(longest).width
        growing.barWidth = width
        fast.barWidth = width
        return ZStack(alignment: .top) {
            Color(nsColor: (dark ? ThemeRGBA(hex: 0x1D2240) : ThemeRGBA(hex: 0xD9E2F5)).nsColor)
            VStack(spacing: Theme.ScrollCapture.barGap) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(dark ? Color(white: 0.16) : Color.white)
                    .overlay(alignment: .topLeading) {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(0..<7, id: \.self) { line in
                                Capsule().fill(Color.gray.opacity(0.35)).frame(width: line % 3 == 2 ? 220 : 400, height: 8)
                            }
                        }
                        .padding(20)
                    }
                    .frame(width: 520, height: 220)
                    .overlay(Rectangle().strokeBorder(Color.white, lineWidth: 1).padding(-3))
                ScrollCaptureBar(model: growing)
                ScrollCaptureBar(model: fast)
            }
            .padding(.top, 28)
        }
        .frame(width: size.width, height: size.height)
    }
}
