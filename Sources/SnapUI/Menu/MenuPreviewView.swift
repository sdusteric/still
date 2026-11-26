import AppKit
import SnapCore
import SwiftUI

/// The menu bar menu drawn from the same `MenuModel` as the real `NSMenu`, for shot mode: an
/// `NSMenu` cannot be drawn without showing it (design 16, D27). 280 pt wide, 6 pt padding,
/// 24 pt rows, 42 pt recent rows with 32 pt thumbnails, radius 12 (design 17.4, 17.6).
public struct MenuPreviewView: View {
    let thumbnails: [String: CGImage]
    /// The row drawn as hovered, as in the mockup.
    let highlighted: MenuItemID?
    let items: [MenuItem]
    let width: Double

    public init(model: MenuModel, thumbnails: [String: CGImage] = [:], highlighted: MenuItemID? = nil) {
        self.init(items: model.items, thumbnails: thumbnails, highlighted: highlighted)
    }

    /// Any list of rows, such as the recording menu (260 pt wide, design 20.6).
    public init(items: [MenuItem], thumbnails: [String: CGImage] = [:], highlighted: MenuItemID? = nil,
                width: Double = Theme.Menu.width) {
        self.items = items
        self.thumbnails = thumbnails
        self.highlighted = highlighted
        self.width = width
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // An Option alternate shows only while Option is held, so the preview leaves it out.
            ForEach(items.filter { !$0.isAlternate }) { item in
                row(item)
            }
        }
        .padding(Theme.Menu.padding)
        .frame(width: width)
        .background(
            RoundedRectangle(cornerRadius: Theme.Menu.radius, style: .continuous)
                .fill(Theme.Colors.menu.color)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Menu.radius, style: .continuous)
                .strokeBorder(Theme.Colors.cardEdge.color, lineWidth: Theme.Materials.edgeWidth)
        )
        .shadow(color: .black.opacity(0.22), radius: 16, y: 8)
    }

    @ViewBuilder private func row(_ item: MenuItem) -> some View {
        switch item.kind {
        case .separator:
            Rectangle()
                .fill(Theme.Colors.separatorStrong.color)
                .frame(height: 1)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
        case .header:
            Text(item.title)
                .font(Theme.Typography.captionMedium.font)
                .foregroundStyle(Theme.Colors.text2.color)
                .padding(.horizontal, 10)
                .frame(height: Theme.Menu.rowHeight, alignment: .bottomLeading)
        case .status:
            HStack(spacing: 8) {
                Circle()
                    .fill(Theme.Colors.warningDot.color)
                    .frame(width: Theme.Menu.statusDotSize, height: Theme.Menu.statusDotSize)
                Text(item.title)
                    .font(Theme.Typography.caption.font)
                    .foregroundStyle(Theme.Colors.warning.color)
            }
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: Theme.Menu.rowHeight, alignment: .leading)
        case .info:
            HStack(spacing: 8) {
                if let symbol = item.symbolName {
                    Image(systemName: symbol)
                        .font(.system(size: 12, weight: .regular))
                        .frame(width: 16)
                }
                Text(item.title).font(Theme.Recording.infoStyle.font)
            }
            .foregroundStyle(Theme.Colors.text2.color)
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: Theme.Menu.rowHeight, alignment: .leading)
        case .action:
            if let captureID = item.captureID {
                recentRow(item, image: thumbnails[captureID])
            } else {
                actionRow(item)
            }
        }
    }

    private func actionRow(_ item: MenuItem) -> some View {
        let isHighlighted = item.id == highlighted
        return HStack(spacing: 8) {
            if let symbol = item.symbolName {
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(titleColor(item, highlighted: isHighlighted))
                    .frame(width: Theme.Menu.symbolWidth)
            }
            Text(item.title)
                .font(Theme.Typography.body.font)
                .foregroundStyle(titleColor(item, highlighted: isHighlighted))
            Spacer(minLength: 12)
            if let shortcut = item.shortcutText {
                Text(shortcut)
                    .font(Theme.Typography.body.font)
                    .foregroundStyle(isHighlighted ? Color.white.opacity(0.85) : Theme.Colors.text2.color)
            }
            if !item.children.isEmpty {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(isHighlighted ? Color.white.opacity(0.85) : Theme.Colors.text2.color)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: Theme.Menu.rowHeight)
        .background {
            if isHighlighted {
                RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Theme.Colors.accent.color)
            }
        }
    }

    private func recentRow(_ item: MenuItem, image: CGImage?) -> some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: Theme.Menu.thumbnailRadius, style: .continuous)
                .fill(Theme.Colors.fill.color)
                .overlay {
                    if let image {
                        Image(decorative: image, scale: 1).resizable().aspectRatio(contentMode: .fill)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: Theme.Menu.thumbnailRadius, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Menu.thumbnailRadius, style: .continuous)
                        .strokeBorder(Theme.Colors.separator.color, lineWidth: 0.5)
                )
                .frame(width: Theme.Menu.thumbnailSize, height: Theme.Menu.thumbnailSize)
            VStack(alignment: .leading, spacing: 0) {
                Text(item.title)
                    .font(Theme.Typography.body.font)
                    .foregroundStyle(Theme.Colors.text.color)
                    .lineLimit(1)
                if let subtitle = item.subtitle {
                    Text(subtitle)
                        .font(Theme.Typography.captionSmall.font)
                        .foregroundStyle(Theme.Colors.text2.color)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .frame(height: Theme.Menu.recentRowHeight)
    }

    private func titleColor(_ item: MenuItem, highlighted: Bool) -> Color {
        if highlighted { return .white }
        return item.isEnabled ? Theme.Colors.text.color : Theme.Colors.text3.color
    }
}

/// The menu with three recent captures, CleanShot X running and the Background row hovered
/// (mockup section 5), over a plain desktop stage, for tests and shots.
public enum MenuDemo {
    public static let size = CGSize(width: Theme.Menu.width, height: 500)

    static let timeZone = TimeZone(identifier: "UTC") ?? .gmt
    /// Saturday 2026-10-24 14:05:22 UTC.
    static let now = Date(timeIntervalSince1970: 1_792_850_722)

    public static func makeModel() -> MenuModel {
        let captures: [(String, String, TimeInterval)] = [
            ("demo-1", "Screenshot 14.03.22", 120),
            ("demo-2", "Screenshot 11.48.09", 8_233),
            ("demo-3", "Screenshot 09.15.40", 17_382),
        ]
        let items = captures.map { id, name, age in
            CaptureItem(
                id: id, createdAt: now.addingTimeInterval(-age), mode: .area, scale: 2,
                originalURL: URL(filePath: "/demo/history/\(id)/\(name).png")
            )
        }
        let plan = HotkeyConflicts.evaluate(
            shortcuts: ShortcutSettings(), systemEntries: [], runningBundleIDs: ["com.getcleanshot.app-setapp"]
        )
        return MenuModel(MenuInput(recentCaptures: items, plan: plan, now: now, timeZone: timeZone))
    }

    /// Small generated thumbnails: a window on Dusk, a light window, a dark window.
    public static func makeThumbnails() -> [String: CGImage] {
        var result: [String: CGImage] = [:]
        let specs: [(String, GradientID, Double)] = [("demo-1", .dusk, 0.96), ("demo-2", .fog, 0.98), ("demo-3", .ocean, 0.85)]
        for (id, gradient, white) in specs {
            guard let context = SyntheticImages.makeContext(width: 64, height: 64, flipped: false) else { continue }
            GradientPainter.draw(gradient, in: context, rect: CGRect(x: 0, y: 0, width: 64, height: 64))
            context.setFillColor(CGColor(gray: white, alpha: 1))
            context.addPath(CGPath(roundedRect: CGRect(x: 18, y: 18, width: 28, height: 28), cornerWidth: 4, cornerHeight: 4, transform: nil))
            context.fillPath()
            if let image = context.makeImage() { result[id] = image }
        }
        return result
    }

    public static func makeView(dark: Bool = false) -> NSView {
        let content = ZStack(alignment: .top) {
            MenuStage(dark: dark)
            MenuPreviewView(model: makeModel(), thumbnails: makeThumbnails(), highlighted: .lastCapture)
                .padding(.top, 8)
        }
        .frame(width: size.width, height: size.height)
        let view = NSHostingView(rootView: content)
        view.frame = CGRect(origin: .zero, size: size)
        view.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        return view
    }
}

/// A soft desktop behind the menu preview, as in the mockup.
private struct MenuStage: View {
    let dark: Bool

    var body: some View {
        LinearGradient(
            colors: dark
                ? [ThemeRGBA(hex: 0x1D2240).color, ThemeRGBA(hex: 0x2A1F3A).color, ThemeRGBA(hex: 0x3A2A33).color]
                : [ThemeRGBA(hex: 0xD9E2F5).color, ThemeRGBA(hex: 0xE8DDF0).color, ThemeRGBA(hex: 0xF2E4D8).color],
            startPoint: .topLeading, endPoint: .bottomTrailing
        )
    }
}

// MARK: M2 menu

/// The `menu-m2` shot (mockup 15, design 20.10 and 20.11): the M2 menu model with a screenshot,
/// a recording and a screenshot in Recent Captures, Capture History hovered and three pins, under
/// a menu bar with the Snap symbol highlighted. 420 x 600 pt.
public enum MenuM2Demo {
    public static var size: CGSize { Theme.MenuM2.shotSize }
    /// The menu's top-left corner in the scene.
    static let menuOrigin = CGPoint(x: 112, y: 30)
    static let menuBarHeight = 24.0

    public static func makeModel() -> MenuModel {
        let now = MenuDemo.now
        let captures = [
            CaptureItem(id: "demo-1", createdAt: now.addingTimeInterval(-120), mode: .area, scale: 2,
                        originalURL: URL(filePath: "/demo/history/demo-1/shot.png")),
            CaptureItem(id: "demo-2", createdAt: now.addingTimeInterval(-8_233), mode: .area, scale: 2,
                        originalURL: URL(filePath: "/demo/history/demo-2/recording.mp4"), kind: .video,
                        durationSeconds: 42.4),
            CaptureItem(id: "demo-3", createdAt: now.addingTimeInterval(-17_382), mode: .window, scale: 2,
                        originalURL: URL(filePath: "/demo/history/demo-3/shot.png")),
        ]
        let pins = (1...3).map { index in
            PinnedCaptureEntry(id: index, itemID: "demo-\(index)", createdAt: now.addingTimeInterval(Double(-index) * 600),
                               clickThrough: index == 3)
        }
        return MenuModel(MenuInput(recentCaptures: captures, pins: pins, now: now, timeZone: MenuDemo.timeZone))
    }

    /// The mockup's thumbnails: a light window on violet, a light square on near-black (the
    /// recording's poster) and a light square on dark teal.
    public static func makeThumbnails() -> [String: CGImage] {
        var result: [String: CGImage] = [:]
        let specs: [(String, [UInt32], Double)] = [
            ("demo-1", [0x7B6CFF, 0xB65BFF], 0.95), ("demo-2", [0x1C1C1E, 0x1C1C1E], 0.84),
            ("demo-3", [0x163040, 0x2B4F5E], 0.86),
        ]
        for (id, stops, white) in specs {
            guard let context = SyntheticImages.makeContext(width: 64, height: 64, flipped: false) else { continue }
            let colors = stops.map { ThemeRGBA(hex: $0).cgColor }
            if let gradient = CGGradient(colorsSpace: SyntheticImages.colorSpace, colors: colors as CFArray, locations: [0, 1]) {
                context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: 64), end: CGPoint(x: 64, y: 0), options: [])
            }
            context.setFillColor(CGColor(gray: white, alpha: 1))
            context.addPath(CGPath(roundedRect: CGRect(x: 16, y: 16, width: 32, height: 32), cornerWidth: 4, cornerHeight: 4, transform: nil))
            context.fillPath()
            if let image = context.makeImage() { result[id] = image }
        }
        return result
    }

    /// The wallpaper and the menu bar with the Snap symbol highlighted, as one image.
    static func stage(dark: Bool, scale: Double = 2) -> CGImage? {
        M2DemoArt.render(size: size, scale: scale) { context in
            M2DemoArt.wallpaper(CGRect(origin: .zero, size: size), dark: dark, in: context)
            M2DemoArt.menuBar(width: size.width, dark: dark, in: context)
        }
    }

    public static func scene(dark: Bool) -> some View {
        let stage = stage(dark: dark)
        return ZStack(alignment: .topLeading) {
            if let stage {
                Image(decorative: stage, scale: 2).frame(width: size.width, height: size.height)
            }
            // The status item's pressed highlight behind the symbol, as the system draws it.
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(Theme.Colors.separatorStrong.color)
                .frame(width: 27, height: 20)
                .offset(x: statusItemX - 6, y: 2)
            MenuPreviewView(model: makeModel(), thumbnails: makeThumbnails(), highlighted: .captureHistory)
                .offset(x: menuOrigin.x, y: menuOrigin.y)
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .environment(\.colorScheme, dark ? .dark : .light)
    }

    /// Where `M2DemoArt.menuBar` puts the Snap symbol: left of the clock.
    static var statusItemX: Double {
        let clockWidth = M2DemoArt.lineWidth("Sat 14:03", font: M2DemoArt.font(13, .medium))
        return size.width - 14 - clockWidth - 14 - 15
    }

    /// The scene at `scale` through `ImageRenderer`: no window, no menu shown.
    public static func renderScene(dark: Bool, scale: Double = 2) -> CGImage? {
        QuickAccessDemo.render(scene(dark: dark), size: size, dark: dark, scale: scale)
    }
}

/// The `menu-permission` shot (design 13): a capture failed because macOS wants Screen Recording
/// approved again, so the symbol carries the badge and the menu shows "Screen Recording needs your
/// OK" above Settings. The scene matches `menu-m2` (420 x 600 pt) with the menu open.
public enum MenuPermissionDemo {
    public static var size: CGSize { MenuM2Demo.size }

    public static func makeModel() -> MenuModel {
        let now = MenuDemo.now
        let captures = [
            CaptureItem(id: "demo-1", createdAt: now.addingTimeInterval(-120), mode: .area, scale: 2,
                        originalURL: URL(filePath: "/demo/history/demo-1/shot.png")),
            CaptureItem(id: "demo-2", createdAt: now.addingTimeInterval(-8_233), mode: .area, scale: 2,
                        originalURL: URL(filePath: "/demo/history/demo-2/recording.mp4"), kind: .video,
                        durationSeconds: 42.4),
            CaptureItem(id: "demo-3", createdAt: now.addingTimeInterval(-17_382), mode: .window, scale: 2,
                        originalURL: URL(filePath: "/demo/history/demo-3/shot.png")),
        ]
        return MenuModel(MenuInput(
            recentCaptures: captures, permissionNeeded: true, offersRelaunch: true, hasPreviousArea: true,
            now: now, timeZone: MenuDemo.timeZone
        ))
    }

    static func stage(dark: Bool, scale: Double = 2) -> CGImage? {
        M2DemoArt.render(size: size, scale: scale) { context in
            M2DemoArt.wallpaper(CGRect(origin: .zero, size: size), dark: dark, in: context)
            M2DemoArt.menuBar(width: size.width, dark: dark, badge: true, in: context)
        }
    }

    public static func scene(dark: Bool) -> some View {
        let stage = stage(dark: dark)
        return ZStack(alignment: .topLeading) {
            if let stage {
                Image(decorative: stage, scale: 2).frame(width: size.width, height: size.height)
            }
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(Theme.Colors.separatorStrong.color)
                .frame(width: 27, height: 20)
                .offset(x: MenuM2Demo.statusItemX - 6, y: 2)
            MenuPreviewView(model: makeModel(), thumbnails: MenuM2Demo.makeThumbnails())
                .offset(x: MenuM2Demo.menuOrigin.x, y: MenuM2Demo.menuOrigin.y)
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .environment(\.colorScheme, dark ? .dark : .light)
    }

    public static func renderScene(dark: Bool, scale: Double = 2) -> CGImage? {
        QuickAccessDemo.render(scene(dark: dark), size: size, dark: dark, scale: scale)
    }
}
