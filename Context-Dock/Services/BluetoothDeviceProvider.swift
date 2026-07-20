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
        let snapshots: [BluetoothDeviceSnapshot] = rawDevices.compactMap {
            device -> BluetoothDeviceSnapshot? in
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
        var seen = Set<String>()
        return snapshots.filter { device in
            // IOBluetooth can expose the same paired accessory through multiple
            // controller records/addresses. The UI identity is its visible name;
            // collapse those records so filtering never renders duplicate rows.
            let identity = device.name.lowercased()
            return seen.insert(identity).inserted
        }
        .sorted {
            if $0.isConnected != $1.isConnected { return $0.isConnected && !$1.isConnected }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }
}
