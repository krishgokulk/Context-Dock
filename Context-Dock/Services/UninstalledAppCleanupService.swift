// UninstalledAppCleanupService.swift
// Context-Dock
//
// Removes all per-app data (menu snapshots, capability cache, adapters/rules)
// for apps that are no longer installed, so uninstalled apps never linger in
// the dock, Global Context, or Advanced > Menu Cache. Runs once at launch in
// the background.

import AppKit
import Foundation

enum UninstalledAppCleanupService {
    /// System bundle ids that resolve oddly or are always present — never purge.
    private static let protectedBundleIds: Set<String> = [
        "com.apple.finder", "com.apple.systempreferences",
    ]

    static func cleanupInBackground() {
        Task.detached(priority: .utility) {
            purgeUninstalled()
        }
    }

    private static func purgeUninstalled() {
        var bundleIds = Set(AppMenuCapabilityCache.shared.allCachedBundleIdentifiers())

        // Per-app store directories: Application Support/Context-Dock/apps/<bundleId>/
        let appsDir = ContextDockStore.root.appendingPathComponent("apps", isDirectory: true)
        if let entries = try? FileManager.default.contentsOfDirectory(
            at: appsDir, includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles])
        {
            for entry in entries where entry.hasDirectoryPath {
                bundleIds.insert(entry.lastPathComponent)
            }
        }

        let uninstalled = bundleIds.filter { id in
            guard !id.isEmpty, !protectedBundleIds.contains(id),
                !id.hasPrefix("cli://"), !id.hasPrefix("syscmd://"),
                id != Bundle.main.bundleIdentifier
            else { return false }
            // Installed if LaunchServices can resolve a URL for the bundle id.
            return NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) == nil
        }

        guard !uninstalled.isEmpty else { return }

        for id in uninstalled {
            // Per-app folder (menu snapshot + rules/adapters all live here).
            ContextDockStore.shared.delete(at: ContextDockStore.appDir(bundleId: id))
            // In-memory + on-disk menu enumerator caches.
            AXMenuEnumerator.shared.invalidate(bundleId: id)
        }
        // Trim the consolidated capability cache in one pass.
        AppMenuCapabilityCache.shared.purge(bundleIdentifiers: uninstalled)
    }
}
