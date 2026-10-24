import AppKit
import CoreGraphics
import Foundation
import SnapCore

/// The on-screen window list from `CGWindowListCopyWindowInfo([.optionOnScreenOnly])` (design 6.5),
/// front to back. Owner and bounds need no Screen Recording permission; titles may be missing.
/// Desktop elements stay in the list, so Finder's icon window can be matched by layer.
public struct LiveWindowSource: WindowSource {
    public init() {}

    public func snapshot() async throws -> [WindowInfo] {
        guard let raw = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else {
            throw CaptureError.failed("CGWindowListCopyWindowInfo returned nothing")
        }
        var bundleIDs: [Int32: String?] = [:]
        return LiveWindowSource.windows(from: raw) { pid in
            if let known = bundleIDs[pid] { return known }
            let found = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
            bundleIDs[pid] = found
            return found
        }
    }

    /// Parses CGWindowList dictionaries. `bundleID` maps an owner PID to its bundle id.
    public static func windows(from list: [[String: Any]], bundleID: (Int32) -> String?) -> [WindowInfo] {
        var result: [WindowInfo] = []
        for dictionary in list {
            guard let number = dictionary[kCGWindowNumber as String] as? NSNumber,
                  let pidNumber = dictionary[kCGWindowOwnerPID as String] as? NSNumber,
                  let boundsDictionary = dictionary[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDictionary as CFDictionary) else { continue }
            let pid = pidNumber.int32Value
            result.append(WindowInfo(
                id: number.uint32Value,
                ownerPID: pid,
                ownerName: dictionary[kCGWindowOwnerName as String] as? String,
                bundleID: bundleID(pid),
                name: dictionary[kCGWindowName as String] as? String,
                frame: bounds,
                layer: (dictionary[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0,
                alpha: (dictionary[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1,
                order: result.count
            ))
        }
        return result
    }
}
