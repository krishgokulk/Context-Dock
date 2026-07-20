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
    /// Current controller power state, read natively (no shell/AppleScript).
    static func isPoweredOn() -> Bool {
        IOBluetoothHostController.default().powerState.rawValue == 1
    }

    /// Set controller power on/off natively.
    ///
    /// The visible Bluetooth toggle previously drove Control Center through
    /// System Events AppleScript, which fails silently whenever that UI shifts
    /// (leaving Bluetooth "on" after the user turned it off). This calls the
    /// IOBluetooth C entry point `IOBluetoothPreferenceSetControllerPowerState`
    /// directly — the same mechanism tools like `blueutil` use — resolved via
    /// `dlsym` so no bridging header/build-setting change is required.
    /// - Returns: `true` if the power call was dispatched.
    @discardableResult
    static func setPower(_ enabled: Bool) -> Bool {
        typealias SetPowerState = @convention(c) (Int32) -> Int32
        let path = "/System/Library/Frameworks/IOBluetooth.framework/IOBluetooth"
        guard let handle = dlopen(path, RTLD_NOW) else { return false }
        defer { dlclose(handle) }
        guard let symbol = dlsym(handle, "IOBluetoothPreferenceSetControllerPowerState") else {
            return false
        }
        let setPower = unsafeBitCast(symbol, to: SetPowerState.self)
        _ = setPower(enabled ? 1 : 0)
        return true
    }

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
