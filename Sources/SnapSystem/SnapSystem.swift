import Foundation
import SnapCore

/// SnapSystem holds the live implementations of SnapCore's protocols: ScreenCaptureKit capture,
/// the CGWindowList window source, Carbon hotkeys, the pasteboard writer and the permission probe.
/// It is the only target allowed to import ScreenCaptureKit or call the permission request
/// (swiftlint enforces it), and `snapctl` never links it.
public enum SnapSystem {
    /// Frameworks this target links in Package.swift. `scripts/check.sh` verifies with `otool -L`
    /// that the release `snapctl` links none of them.
    public static let linkedFrameworks = ["ScreenCaptureKit", "Carbon"]
}
