// SafariExtensionHookRegistry.swift
// Context-Dock
//
// Lightweight in-memory registry of extension hooks contributed by installed .doraxpack bundles.
// Hooks are executable JavaScript snippets that run in the user's real Safari tabs via
// SafariExtensionCommandBridge, registered here so the capability layer can discover them.

import Foundation

// MARK: - Capability

/// A registered extension hook ready for execution through SafariExtensionCommandBridge.
struct ExtensionHookCapability: Identifiable, Equatable {
    /// Stable identifier matching DoraxExtensionHook.id (e.g. "safari.extractStructured").
    let id: String
    let name: String
    /// URL pattern the hook declares itself applicable to (e.g. "*" for all pages).
    let urlPattern: String
    /// Filename inside the pack's `page_scripts/` folder.
    let scriptFile: String
    /// Source pack identifier (e.g. "safari").
    let packID: String
}

// MARK: - Registry

/// Collects `ExtensionHookCapability` entries from every installed .doraxpack.
/// Registered by `StorePackInstaller.installV2` and `installAllV2`; cleared on uninstall.
final class ExtensionHookRegistry {
    static let shared = ExtensionHookRegistry()
    private init() {}

    private(set) var capabilities: [ExtensionHookCapability] = []

    /// Register hooks contributed by a pack. Idempotent: re-registering the same `id` replaces
    /// the existing entry so reinstalls and updates stay consistent.
    func register(hooks: [DoraxExtensionHook], packID: String) {
        for hook in hooks {
            let cap = ExtensionHookCapability(
                id: hook.id, name: hook.name,
                urlPattern: hook.urlPattern, scriptFile: hook.scriptFile,
                packID: packID)
            if let idx = capabilities.firstIndex(where: { $0.id == cap.id }) {
                capabilities[idx] = cap
            } else {
                capabilities.append(cap)
            }
        }
    }

    /// Remove all hooks contributed by a pack (call on uninstall / replacement).
    func unregister(packID: String) {
        capabilities.removeAll { $0.packID == packID }
    }

    func capability(for id: String) -> ExtensionHookCapability? {
        capabilities.first { $0.id == id }
    }
}
