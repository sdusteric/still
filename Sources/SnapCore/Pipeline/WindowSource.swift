import Foundation

/// The on-screen window list for hit-testing. Live: `CGWindowListCopyWindowInfo` in SnapSystem
/// (needs no Screen Recording permission for owner and bounds). Fake: `FakeWindowSource`.
public protocol WindowSource: Sendable {
    /// On-screen windows, front to back (`order` 0 is frontmost). Unfiltered: hit-testing decides
    /// which layers, alphas and owners count.
    func snapshot() async throws -> [WindowInfo]
}
