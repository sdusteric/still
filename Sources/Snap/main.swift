import AppKit
import Foundation

let arguments = Array(CommandLine.arguments.dropFirst())

if arguments.contains("--shot") {
    // Shot mode never reaches NSApplication: no run loop of its own, no window, no status item,
    // no hotkeys, no permission check.
    switch ShotOptions.parse(arguments) {
    case .success(let options): ShotMode.run(options)
    case .failure(let error): ShotMode.fail(error)
    }
}

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
// Menu bar only (LSUIElement): never a Dock icon, never activates on launch.
application.setActivationPolicy(.accessory)
application.run()
