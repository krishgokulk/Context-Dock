import AppKit
import ApplicationServices
import Foundation

struct ContextDockMenuRefreshResult {
    var items: [AXMenuItem]
    var debugText: String
}

/// Context Dock engine boundary.
/// Rule: frontmost app context is live-first, with cached rows as first paint only.
final class ContextDockEngine {
    nonisolated static let shared = ContextDockEngine()

    nonisolated private init() {}

    nonisolated func cachedMenuItems(for app: NSRunningApplication, maxResults: Int = 120) -> [AXMenuItem] {
        AppMenuCapabilityCache.shared.menuItems(for: app, maxResults: maxResults)
    }

    nonisolated func refreshMenus(
        for app: NSRunningApplication,
        cachedItems: [AXMenuItem],
        fallbackItems: [AXMenuItem] = [],
        maxResults: Int = 120,
        force: Bool = true
    ) async -> ContextDockMenuRefreshResult? {
        guard !app.isTerminated else { return nil }
        let pid = app.processIdentifier
        let name = app.localizedName ?? app.bundleIdentifier ?? "App"

        await MenuWarmCacheService.shared.warm(app: app, force: force)

        var liveItems = await AXMenuReader.shared.peekCachedAllMenuItems(for: pid)
        if liveItems.isEmpty {
            liveItems = AppMenuCapabilityCache.shared.menuItems(for: app, maxResults: maxResults)
        }
        if liveItems.isEmpty {
            liveItems = fallbackItems
        }
        guard !liveItems.isEmpty else { return nil }

        stampSource(&liveItems, pid: pid, appName: name)
        let mergedItems = mergeCachedMenusWithLiveAvailability(cached: cachedItems, live: liveItems)
        let debug = await AXMenuReader.shared.lastDebug(for: pid) ?? "no reader detail"
        return ContextDockMenuRefreshResult(
            items: mergedItems,
            debugText: "\(name): \(mergedItems.count) menus, \(debug), cache+live"
        )
    }

    nonisolated func mergeCachedMenusWithLiveAvailability(
        cached cachedItems: [AXMenuItem],
        live liveItems: [AXMenuItem]
    ) -> [AXMenuItem] {
        guard !cachedItems.isEmpty else { return liveItems }
        guard !liveItems.isEmpty else { return cachedItems }

        var liveByPath: [String: AXMenuItem] = [:]
        liveByPath.reserveCapacity(liveItems.count)
        for item in liveItems {
            let key = normalizedMenuPathForMerge(item.path)
            guard !key.isEmpty else { continue }
            liveByPath[key] = item
        }

        var merged: [AXMenuItem] = []
        merged.reserveCapacity(max(cachedItems.count, liveItems.count))
        var consumedLiveKeys = Set<String>()

        for cached in cachedItems {
            let key = normalizedMenuPathForMerge(cached.path)
            guard let live = liveByPath[key] else {
                merged.append(cached)
                continue
            }
            consumedLiveKeys.insert(key)

            if live.isEnabled {
                var updated = live
                updated.hasLiveAvailability = true
                updated.resolvedFilePath = live.resolvedFilePath ?? cached.resolvedFilePath
                merged.append(updated)
            } else {
                var updated = cached
                updated.isEnabled = false
                updated.children = mergeCachedMenusWithLiveAvailability(
                    cached: cached.children,
                    live: live.children
                )
                updated.shortcutChar = cached.shortcutChar ?? live.shortcutChar
                if updated.shortcutModifiers == 0 {
                    updated.shortcutModifiers = live.shortcutModifiers
                }
                updated.image = cached.image ?? live.image
                updated.resolvedFilePath = cached.resolvedFilePath ?? live.resolvedFilePath
                updated.hasLiveAvailability = true
                merged.append(updated)
            }
        }

        for live in liveItems {
            let key = normalizedMenuPathForMerge(live.path)
            guard !key.isEmpty, !consumedLiveKeys.contains(key), live.isEnabled else { continue }
            var item = live
            item.hasLiveAvailability = true
            merged.append(item)
        }

        return merged
    }

    nonisolated private func stampSource(_ items: inout [AXMenuItem], pid: pid_t, appName: String) {
        for index in items.indices {
            items[index].sourcePID = pid
            items[index].sourceAppName = appName
        }
    }

    nonisolated private func normalizedMenuPathForMerge(_ path: [String]) -> String {
        path.map {
            $0
                .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
                .lowercased()
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        .filter { !$0.isEmpty }
        .joined(separator: " > ")
    }
}
