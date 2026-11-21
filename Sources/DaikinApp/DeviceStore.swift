import DaikinKit
import Foundation
import Observation
import SwiftUI

/// The saved devices (shared with the `daikin` CLI through the same config file) and the one on screen.
@MainActor @Observable
final class DeviceStore {
    private(set) var devices: [DeviceConfig] = []
    private(set) var controller: ACController?
    private(set) var loadError: String?

    private static let selectionKey = "selectedDevice"

    init() {
        do {
            devices = try Config.load().devices
        } catch {
            loadError = "Não foi possível ler \(Config.defaultURL.path): \(error.localizedDescription)"
        }
        let preferred = UserDefaults.standard.string(forKey: Self.selectionKey)
        select(devices.first { $0.name == preferred } ?? devices.first)
    }

    func select(_ device: DeviceConfig?) {
        guard device != controller?.device else { return }
        controller?.stop()
        controller = device.map(ACController.init)
        controller?.start()
        if let device {
            UserDefaults.standard.set(device.name, forKey: Self.selectionKey)
        }
    }

    /// For pickers that choose among the saved devices by name.
    var selectedName: Binding<String> {
        Binding { [self] in
            controller?.device.name ?? ""
        } set: { [self] name in
            select(devices.first { $0.name == name })
        }
    }

    /// Adds or replaces a device, writes the config file and shows it.
    func save(_ device: DeviceConfig) throws {
        var config = try Config.load()
        config.upsert(device)
        try config.save()
        devices = config.devices
        loadError = nil
        select(device)
    }
}
