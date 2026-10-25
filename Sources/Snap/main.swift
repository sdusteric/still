import AppKit
import Foundation

let arguments = Array(CommandLine.arguments.dropFirst())

if arguments.contains("--shot") {
    // Shot mode never calls NSApplication.run: no window, no status item, no hotkeys, no
    // permission check. Drawing views does create NSApplication.shared; the bundle's LSUIElement
    // keeps the process a UIElement, so ShotMode refuses to run outside the bundle.
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
