import AVFoundation
import Foundation

/// One audio input for the Recording tab's microphone popup (design 20.10).
public struct AudioInputDevice: Sendable, Hashable, Identifiable {
    /// `AVCaptureDevice.uniqueID`, stored as `recording.microphoneDeviceID` and passed to
    /// `SCStreamConfiguration.microphoneCaptureDeviceID`.
    public let id: String
    public let name: String
    /// The system default input.
    public let isDefault: Bool

    public init(id: String, name: String, isDefault: Bool) {
        self.id = id
        self.name = name
        self.isDefault = isDefault
    }
}

/// Lists audio input devices with `AVCaptureDevice.DiscoverySession`. Listing only: no capture
/// session is made, the microphone is never opened and no permission prompt appears. Compiled and
/// linted, but never called by a test, tool or agent.
public enum InputDevices {
    /// Every audio input, the system default first, then by name.
    public static func audioInputs() -> [AudioInputDevice] {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified
        )
        let found = discovery.devices.map { (id: $0.uniqueID, name: $0.localizedName) }
        return ordered(found, defaultID: AVCaptureDevice.default(for: .audio)?.uniqueID)
    }

    /// The device to record from now: the chosen one while it is connected, otherwise nil (the
    /// system default), so a device that disappeared does not fail the recording.
    public static func connectedDeviceID(_ chosenID: String?) -> String? {
        guard chosenID != nil else { return nil }
        return resolve(chosenID, among: audioInputs())
    }

    /// `chosenID` when `devices` has it, otherwise nil.
    public static func resolve(_ chosenID: String?, among devices: [AudioInputDevice]) -> String? {
        guard let chosenID, devices.contains(where: { $0.id == chosenID }) else { return nil }
        return chosenID
    }

    /// Drops repeated ids (a device can match two device types), puts the default first and sorts
    /// the rest by name.
    public static func ordered(_ devices: [(id: String, name: String)], defaultID: String?) -> [AudioInputDevice] {
        var seen: Set<String> = []
        var unique: [AudioInputDevice] = []
        for device in devices where seen.insert(device.id).inserted {
            unique.append(AudioInputDevice(id: device.id, name: device.name, isDefault: device.id == defaultID))
        }
        return unique.sorted { lhs, rhs in
            if lhs.isDefault != rhs.isDefault { return lhs.isDefault }
            let order = lhs.name.localizedStandardCompare(rhs.name)
            return order == .orderedSame ? lhs.id < rhs.id : order == .orderedAscending
        }
    }
}
