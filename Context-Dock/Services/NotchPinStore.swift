// Context-Dock
//
// Persists which capabilities are pinned to Page 2 of the Dynamic Notch, keyed by app bundleID.
// Max 4 pins per app (capped to the safe-area pill row).

import Combine
import Foundation

@MainActor
final class NotchPinStore: ObservableObject {
    static let shared = NotchPinStore()
    static let maxPinsPerApp = 4

    private static let udKey = "notchPinnedCapabilities.v1"

    // bundleID → [capabilityID], ordered (insertion order = display order)
    @Published private(set) var pins: [String: [String]] = [:]

    private let defaults: UserDefaults

    init() {
        self.defaults = .standard
        if let stored = UserDefaults.standard.dictionary(forKey: Self.udKey)
            as? [String: [String]] {
            pins = stored
        }
    }

    // Test-only: isolated suite so test cases don't bleed into shared state.
    init(userDefaultsSuite suite: String) {
        self.defaults = UserDefaults(suiteName: suite) ?? .standard
        if let stored = self.defaults.dictionary(forKey: Self.udKey)
            as? [String: [String]] {
            pins = stored
        }
    }

    func isPinned(_ capabilityID: String, for bundleID: String) -> Bool {
        pins[bundleID]?.contains(capabilityID) ?? false
    }

    func pinnedIDs(for bundleID: String) -> [String] {
        pins[bundleID] ?? []
    }

    func toggle(_ capabilityID: String, for bundleID: String) {
        var current = pins[bundleID] ?? []
        if let idx = current.firstIndex(of: capabilityID) {
            current.remove(at: idx)
        } else {
            guard current.count < Self.maxPinsPerApp else { return }
            current.append(capabilityID)
        }
        pins[bundleID] = current.isEmpty ? nil : current
        persist()
    }

    func unpin(_ capabilityID: String, for bundleID: String) {
        guard var current = pins[bundleID] else { return }
        current.removeAll { $0 == capabilityID }
        pins[bundleID] = current.isEmpty ? nil : current
        persist()
    }

    private func persist() {
        let sanitized = pins.compactMapValues { $0.isEmpty ? nil : $0 }
        defaults.set(sanitized, forKey: Self.udKey)
    }
}
