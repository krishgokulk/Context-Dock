import Foundation

final class CacheStore {
    static let shared = CacheStore()

    private init() {}

    func menuSnapshot(bundleId: String) -> PersistedMenuSnapshot? {
        ContextDockStore.shared.loadMenuSnapshot(bundleId: bundleId)
    }
}

@MainActor
final class ExtensionStore {
    static let shared = ExtensionStore()

    private init() {}

    var extensions: [ILExtension] {
        LayeredExtensionManager.shared.allExtensions
    }
}

final class SettingsStore {
    static let shared = SettingsStore()

    let settings = AppSettings.shared

    private init() {}
}

final class AutomationRuleStore {
    static let shared = AutomationRuleStore()

    private init() {}

    func rules(bundleId: String? = nil) -> [AXTriggerRule] {
        ContextDockStore.shared.loadRules(bundleId: bundleId)
    }

    func save(_ rules: [AXTriggerRule], bundleId: String? = nil) {
        ContextDockStore.shared.saveRules(rules, bundleId: bundleId)
    }
}
