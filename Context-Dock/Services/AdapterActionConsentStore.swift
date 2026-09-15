//
//  AdapterActionConsentStore.swift
//  Context-Dock
//
//  Remembers "always allow" grants for adapter actions that declare
//  requiresApproval — chiefly Browser Extensions (pageJS userscripts), which
//  otherwise re-prompt on every single run.
//
//  Mirrors AppMenuConsentStore, but keyed by bundleId + action id instead of a
//  menu path. Kept separate because the two consent surfaces are revoked
//  independently in Settings.
//

import Foundation
import Combine

final class AdapterActionConsentStore: ObservableObject {
    static let shared = AdapterActionConsentStore()

    private let defaultsKey = "AdapterActionConsentStore.allowedActions"
    private let lock = NSLock()
    private var allowed: Set<String>

    /// Bumped on every grant/revoke so SwiftUI settings views refresh.
    @Published private(set) var revision: Int = 0

    private init() {
        allowed = Set(UserDefaults.standard.stringArray(forKey: defaultsKey) ?? [])
    }

    private func key(bundleId: String, actionId: String) -> String {
        "\(bundleId.lowercased())|\(actionId.lowercased())"
    }

    /// True when the user previously chose "Always Allow" for this exact action.
    func isAllowed(bundleId: String, actionId: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return allowed.contains(key(bundleId: bundleId, actionId: actionId))
    }

    func allowAlways(bundleId: String, actionId: String) {
        mutate { $0.insert(key(bundleId: bundleId, actionId: actionId)) }
    }

    func revoke(bundleId: String, actionId: String) {
        mutate { $0.remove(key(bundleId: bundleId, actionId: actionId)) }
    }

    /// Every grant, as (bundleId, actionId) pairs — drives the Settings list.
    func allGrants() -> [(bundleId: String, actionId: String)] {
        lock.lock(); defer { lock.unlock() }
        return allowed.compactMap { entry in
            let parts = entry.split(separator: "|", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { return nil }
            return (bundleId: parts[0], actionId: parts[1])
        }
    }

    func reset() {
        mutate { $0.removeAll() }
    }

    private func mutate(_ body: (inout Set<String>) -> Void) {
        lock.lock()
        body(&allowed)
        let snapshot = Array(allowed)
        lock.unlock()
        UserDefaults.standard.set(snapshot, forKey: defaultsKey)
        Task { @MainActor in self.revision &+= 1 }
    }
}
