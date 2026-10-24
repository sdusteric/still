// Usage: winlist <pid>
// Lists the on-screen windows owned by a process, one line each:
//   id x y w h layer=<layer> alpha=<alpha> name=<name>
// Exit status: 0 when the process owns no on-screen window, 1 when it owns at least one (they are
// printed), 2 on a usage error. CGWindowListCopyWindowInfo needs no Screen Recording permission
// for owner PID and bounds, and it reads no pixels. Never activates or touches any window.
// scripts/shots.sh polls it every 100 ms while a shot-mode Snap runs.
import CoreGraphics
import Foundation

let args = CommandLine.arguments
guard args.count == 2, let pid = Int32(args[1]) else {
    FileHandle.standardError.write(Data("usage: winlist <pid>\n".utf8))
    exit(2)
}
guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else {
    FileHandle.standardError.write(Data("winlist: CGWindowListCopyWindowInfo failed\n".utf8))
    exit(2)
}
var found = 0
for window in list {
    guard let owner = window[kCGWindowOwnerPID as String] as? Int32, owner == pid else { continue }
    let id = window[kCGWindowNumber as String] as? Int ?? 0
    let bounds = window[kCGWindowBounds as String] as? [String: Any] ?? [:]
    let layer = window[kCGWindowLayer as String] as? Int ?? -1
    let alpha = window[kCGWindowAlpha as String] as? Double ?? -1
    let name = window[kCGWindowName as String] as? String ?? ""
    let x = Int(bounds["X"] as? Double ?? 0)
    let y = Int(bounds["Y"] as? Double ?? 0)
    let width = Int(bounds["Width"] as? Double ?? 0)
    let height = Int(bounds["Height"] as? Double ?? 0)
    print("\(id) \(x) \(y) \(width) \(height) layer=\(layer) alpha=\(alpha) name=\(name)")
    found += 1
}
exit(found > 0 ? 1 : 0)
