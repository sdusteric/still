// swift-tools-version: 6.4
import PackageDescription

// Design section 15. SnapCore is pure (no AppKit), SnapSystem is the only target that touches
// ScreenCaptureKit and Carbon, and snapctl links SnapCore only so it never loads ScreenCaptureKit.
let mainActorByDefault: [SwiftSetting] = [.defaultIsolation(MainActor.self)]

let package = Package(
    name: "Snap",
    platforms: [.macOS(.v27)],
    products: [
        .executable(name: "Snap", targets: ["Snap"]),
        .executable(name: "snapctl", targets: ["snapctl"]),
    ],
    targets: [
        .target(name: "SnapCore"),
        .target(
            name: "SnapSystem",
            dependencies: ["SnapCore"],
            linkerSettings: [
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("Carbon"),
            ]
        ),
        .target(name: "SnapUI", dependencies: ["SnapCore"], swiftSettings: mainActorByDefault),
        .executableTarget(
            name: "Snap",
            dependencies: ["SnapUI", "SnapSystem", "SnapCore"],
            swiftSettings: mainActorByDefault
        ),
        .executableTarget(name: "snapctl", dependencies: ["SnapCore"]),
        .testTarget(name: "SnapCoreTests", dependencies: ["SnapCore"]),
        .testTarget(name: "SnapSystemTests", dependencies: ["SnapSystem", "SnapCore"]),
        .testTarget(name: "SnapUITests", dependencies: ["SnapUI", "SnapCore"]),
    ],
    swiftLanguageModes: [.v6]
)
