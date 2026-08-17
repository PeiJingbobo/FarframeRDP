import AVFoundation
import Foundation

struct MicrophoneInputDevice: Equatable, Identifiable, Sendable {
    let name: String
    let isDefault: Bool

    var id: String { name }
}

struct MicrophoneDeviceMenuOption: Equatable, Identifiable {
    enum Kind: Equatable {
        case systemDefault
        case device
        case unavailableSavedDevice
    }

    let value: String
    let title: String
    let kind: Kind

    var id: String { value.isEmpty ? "__default_microphone__" : value }

    static func options(
        availableDevices: [MicrophoneInputDevice],
        savedSelection: String
    ) -> [MicrophoneDeviceMenuOption] {
        var options = [
            MicrophoneDeviceMenuOption(
                value: "",
                title: "默认输入设备",
                kind: .systemDefault
            )
        ]
        var seenNames = Set<String>()
        for device in availableDevices where seenNames.insert(device.name).inserted {
            options.append(
                MicrophoneDeviceMenuOption(
                    value: device.name,
                    title: device.isDefault ? "\(device.name)（当前默认）" : device.name,
                    kind: .device
                )
            )
        }

        if !savedSelection.isEmpty && !seenNames.contains(savedSelection) {
            options.append(
                MicrophoneDeviceMenuOption(
                    value: savedSelection,
                    title: "\(savedSelection)（当前不可用）",
                    kind: .unavailableSavedDevice
                )
            )
        }

        return options
    }

    static func resolvedDeviceName(
        savedSelection: String,
        availableDevices: [MicrophoneInputDevice]
    ) -> String {
        guard !savedSelection.isEmpty else {
            return ""
        }
        return availableDevices.contains { $0.name == savedSelection }
            ? savedSelection
            : ""
    }
}

enum MicrophoneInputDeviceSource {
    static func availableDevices() -> [MicrophoneInputDevice] {
        let defaultDeviceID = AVCaptureDevice.default(for: .audio)?.uniqueID

        let discoverySession = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external],
            mediaType: .audio,
            position: .unspecified
        )

        return discoverySession.devices
            .compactMap { device -> MicrophoneInputDevice? in
                let name = device.localizedName.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty else {
                    return nil
                }
                return MicrophoneInputDevice(
                    name: name,
                    isDefault: device.uniqueID == defaultDeviceID
                )
            }
            .sorted { lhs, rhs in
                if lhs.isDefault != rhs.isDefault {
                    return lhs.isDefault
                }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
    }
}
