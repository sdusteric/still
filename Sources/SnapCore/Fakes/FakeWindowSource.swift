import CoreGraphics
import Foundation
import Synchronization

/// Returns a canned front-to-back window list (design section 16).
public final class FakeWindowSource: WindowSource {
    private let windows: Mutex<[WindowInfo]>
    private let calls = Atomic<Int>(0)

    public init(windows: [WindowInfo] = FakeWindowSource.sample) {
        self.windows = Mutex(windows)
    }

    public func snapshot() async throws -> [WindowInfo] {
        calls.add(1, ordering: .relaxed)
        return windows.withLock { $0 }
    }

    /// Replaces the list, for tests that change windows between captures.
    public func setWindows(_ list: [WindowInfo]) {
        windows.withLock { $0 = list }
    }

    public var snapshotCount: Int { calls.load(ordering: .relaxed) }

    /// PID the sample list uses for Snap itself, so hit-testing can skip it.
    public static let snapPID: Int32 = 900

    /// A desktop like this Mac's on a 2560x1440 point display, front to back: Snap's overlay,
    /// the menu bar and status items, the Dock, an alpha-0 Finder helper, Notes over Safari, a
    /// tiny window, Finder's desktop icons and the wallpaper.
    public static let sample: [WindowInfo] = {
        let entries: [(WindowID, Int32, String?, String?, CGRect, Int, Double)] = [
            (5001, snapPID, "Snap", "dev.sdusteric.snap", CGRect(x: 0, y: 0, width: 2560, height: 1440), 1000, 1),
            (101, 300, "Window Server", nil, CGRect(x: 0, y: 0, width: 2560, height: 24), WindowLayer.mainMenu, 1),
            (102, 310, "Control Center", "com.apple.controlcenter",
             CGRect(x: 2380, y: 0, width: 40, height: 24), WindowLayer.statusItems, 1),
            // On macOS 27 the Dock window covers the whole display, in front of every app window.
            (103, 320, "Dock", "com.apple.dock", CGRect(x: 0, y: 0, width: 2560, height: 1440), WindowLayer.dock, 1),
            (201, 400, "Finder", "com.apple.finder", CGRect(x: 0, y: 0, width: 2560, height: 1440), 0, 0),
            (202, 410, "Notes", "com.apple.Notes", CGRect(x: 400, y: 200, width: 842, height: 516), 0, 1),
            (203, 420, "Safari", "com.apple.Safari", CGRect(x: 200, y: 120, width: 1400, height: 900), 0, 1),
            (204, 430, "Clock Mini", nil, CGRect(x: 2000, y: 300, width: 30, height: 30), 0, 1),
            (301, 400, "Finder", "com.apple.finder", CGRect(x: 0, y: 0, width: 2560, height: 1440),
             WindowLayer.desktopIcons, 1),
            (302, 440, "Wallpaper", "com.apple.wallpaper.agent", CGRect(x: 0, y: 0, width: 2560, height: 1440),
             -2_147_483_624, 1),
        ]
        return entries.enumerated().map { order, entry in
            WindowInfo(
                id: entry.0, ownerPID: entry.1, ownerName: entry.2, bundleID: entry.3, name: nil,
                frame: entry.4, layer: entry.5, alpha: entry.6, order: order
            )
        }
    }()
}
