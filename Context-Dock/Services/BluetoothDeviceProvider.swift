import Foundation
import IOBluetooth

struct BluetoothDeviceSnapshot: Identifiable, Hashable {
    let id: String
    let name: String
    let address: String
    let isConnected: Bool

    var status: String {
        isConnected ? "Connected" : "Disconnected"
    }
}

enum BluetoothDeviceProvider {
    static func pairedDevices() -> [BluetoothDeviceSnapshot] {
        let rawDevices = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? []
        return rawDevices.compactMap { device in
            let address = device.addressString ?? ""
            let name = (device.name ?? address).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return nil }
            return BluetoothDeviceSnapshot(
                id: address.isEmpty ? name : address,
                name: name,
                address: address,
                isConnected: device.isConnected()
            )
        }
        .sorted {
            if $0.isConnected != $1.isConnected { return $0.isConnected && !$1.isConnected }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }
}
