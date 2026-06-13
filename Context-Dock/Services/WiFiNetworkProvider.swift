import CoreWLAN
import Foundation

struct WiFiNetworkSnapshot: Identifiable, Hashable {
    let id: String
    let ssid: String
    let isConnected: Bool
    let rssi: Int
    let isSecure: Bool

    var signalPercent: Int {
        let clamped = min(max(rssi, -90), -30)
        return Int(round((Double(clamped + 90) / 60.0) * 100.0))
    }

    var status: String {
        if isConnected { return "Connected • \(signalPercent)%" }
        let security = isSecure ? "Secured" : "Open"
        return "\(security) • \(signalPercent)%"
    }
}

enum WiFiNetworkProvider {
    static func visibleNetworks() -> [WiFiNetworkSnapshot] {
        guard let interface = CWWiFiClient.shared().interface() else { return [] }
        let currentSSID = interface.ssid() ?? ""
        let networks = (try? interface.scanForNetworks(withSSID: nil)) ?? []
        var bestBySSID: [String: WiFiNetworkSnapshot] = [:]

        for network in networks {
            guard let ssid = network.ssid?.trimmingCharacters(in: .whitespacesAndNewlines),
                !ssid.isEmpty
            else { continue }
            let snapshot = WiFiNetworkSnapshot(
                id: ssid,
                ssid: ssid,
                isConnected: ssid == currentSSID,
                rssi: network.rssiValue,
                isSecure: network.supportsSecurity(.wpaPersonal)
                    || network.supportsSecurity(.wpa2Personal)
                    || network.supportsSecurity(.wpa3Personal)
                    || network.supportsSecurity(.wpaEnterprise)
                    || network.supportsSecurity(.wpa2Enterprise)
                    || network.supportsSecurity(.wpa3Enterprise)
                    || network.supportsSecurity(.dynamicWEP)
            )
            if let existing = bestBySSID[ssid], existing.rssi >= snapshot.rssi {
                continue
            }
            bestBySSID[ssid] = snapshot
        }

        if !currentSSID.isEmpty, bestBySSID[currentSSID] == nil {
            bestBySSID[currentSSID] = WiFiNetworkSnapshot(
                id: currentSSID,
                ssid: currentSSID,
                isConnected: true,
                rssi: interface.rssiValue(),
                isSecure: true
            )
        }

        return bestBySSID.values.sorted {
            if $0.isConnected != $1.isConnected { return $0.isConnected && !$1.isConnected }
            if $0.signalPercent != $1.signalPercent { return $0.signalPercent > $1.signalPercent }
            return $0.ssid.localizedCaseInsensitiveCompare($1.ssid) == .orderedAscending
        }
    }
}
