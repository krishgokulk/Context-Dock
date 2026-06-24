import AppKit
import Foundation

struct AXMenuItemInfo: Identifiable, Codable, Equatable {
    let id: UUID
    let title: String
    let fullPath: String   // e.g., "File > New Tab"
    let enabled: Bool
    let shortcutDisplay: String?  // e.g., "⌘T"
}

// MARK: - PersistedMenuSnapshot
// Wraps cached menu items with version metadata for disk validation.
// menuSignature is a cheap fingerprint of top-level bar titles (e.g. "File|Edit|View|…")
// that can catch dynamic menu changes without a full re-enumeration.

struct PersistedMenuSnapshot: Codable {
    let bundleVersion: String
    let menuSignature: String
    let items: [AXMenuItemInfo]
    let savedAt: Date
}

// MARK: - AXMenuCache (in-memory, session-scoped)

private final class AXMenuCache {
    private struct Entry {
        let items: [AXMenuItemInfo]
        let bundleVersion: String
        let menuSignature: String
    }

    private var store: [String: Entry] = [:]
    private let lock = NSLock()

    func get(bundleId: String, bundleVersion: String) -> [AXMenuItemInfo]? {
        lock.lock()
        defer { lock.unlock() }
        guard let e = store[bundleId], e.bundleVersion == bundleVersion else { return nil }
        return e.items
    }

    func set(_ items: [AXMenuItemInfo], bundleId: String, bundleVersion: String, menuSignature: String = "") {
        lock.lock()
        store[bundleId] = Entry(items: items, bundleVersion: bundleVersion, menuSignature: menuSignature)
        lock.unlock()
    }

    func invalidate(bundleId: String) {
        lock.lock()
        store.removeValue(forKey: bundleId)
        lock.unlock()
    }
}

// MARK: - AXMenuEnumerator

final class AXMenuEnumerator {
    static let shared = AXMenuEnumerator()

    private let memCache = AXMenuCache()

    private init() {}

    // MARK: - Async cached API (three tiers)

    /// memory → disk (version-validated) → live AX enumeration.
    /// Does NOT invalidate on app switch — invalidation happens only on version change.
    func getMenuAsync(for app: NSRunningApplication) async -> [AXMenuItemInfo] {
        let bundleId = app.bundleIdentifier ?? ""
        let version  = bundleVersionString(for: app)

        // Tier 1: in-memory (zero cost, same session)
        if let cached = memCache.get(bundleId: bundleId, bundleVersion: version) {
            return cached
        }

        // Tier 2: disk snapshot (survives restarts, version-validated)
        if let snapshot = ContextDockStore.shared.loadMenuSnapshot(bundleId: bundleId) {
            if snapshot.bundleVersion == version {
                memCache.set(snapshot.items, bundleId: bundleId,
                             bundleVersion: version, menuSignature: snapshot.menuSignature)
                return snapshot.items
            }
            // Version changed — disk cache stale, fall through to live enumeration
        }

        // Tier 3: live AX enumeration — runs on a background thread to avoid blocking the UI
        let pid   = app.processIdentifier
        let items = await Task.detached(priority: .userInitiated) { [self] in
            self.enumerateMenuItems(for: pid)
        }.value

        let sig = topLevelMenuSignature(for: pid)
        memCache.set(items, bundleId: bundleId, bundleVersion: version, menuSignature: sig)

        if !items.isEmpty {
            let snapshot = PersistedMenuSnapshot(
                bundleVersion: version,
                menuSignature: sig,
                items: items,
                savedAt: Date()
            )
            ContextDockStore.shared.saveMenuSnapshot(snapshot, bundleId: bundleId)
        }

        return items
    }

    /// Force-clear both tiers — call only on explicit user action or bundle uninstall.
    /// Do NOT call on every app switch; that defeats the disk cache entirely.
    func invalidate(bundleId: String) {
        memCache.invalidate(bundleId: bundleId)
        ContextDockStore.shared.deleteMenuSnapshot(bundleId: bundleId)
    }

    // MARK: - Menu signature (fingerprint of top-level bar titles)

    func topLevelMenuSignature(for pid: pid_t) -> String {
        guard let menuBar = menuBarElement(for: pid) else { return "" }
        var childRef: AnyObject?
        guard AXUIElementCopyAttributeValue(menuBar, "AXChildren" as CFString, &childRef) == .success,
              let children = childRef as? [AXUIElement] else { return "" }
        return children
            .compactMap { stringAttr($0, "AXTitle") }
            .filter { !$0.isEmpty }
            .joined(separator: "|")
    }

    // MARK: - Synchronous API (kept for compatibility)

    func enumerateMenuItemsForFrontmostApp() -> [AXMenuItemInfo] {
        guard let front = NSWorkspace.shared.frontmostApplication else { return [] }
        return enumerateMenuItems(for: front.processIdentifier)
    }

    func enumerateMenuItems(for pid: pid_t) -> [AXMenuItemInfo] {
        guard let menuBar = menuBarElement(for: pid) else { return [] }
        var results: [AXMenuItemInfo] = []
        var seenPaths = Set<String>()
        recurse(menuElement: menuBar, currentPath: [], results: &results,
                seenPaths: &seenPaths, depth: 0)
        return results
    }

    // MARK: - Private recursion

    private func recurse(menuElement: AXUIElement,
                         currentPath: [String],
                         results: inout [AXMenuItemInfo],
                         seenPaths: inout Set<String>,
                         depth: Int) {
        guard depth < 10 else { return }

        var childRef: AnyObject?
        guard AXUIElementCopyAttributeValue(menuElement, "AXChildren" as CFString, &childRef) == .success,
              let children = childRef as? [AXUIElement] else { return }

        for child in children {
            guard let title = stringAttr(child, "AXTitle"), !title.isEmpty else { continue }
            let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || trimmed == "-" || trimmed == "separator" { continue }
            // Services submenu (app menu > Services) is system-wide and
            // selection-dependent — don't snapshot it into per-app caches.
            if trimmed == "Services", currentPath.count == 1 { continue }
            if let role = stringAttr(child, "AXRole"), role == "AXMenuItemRole", trimmed == "-" { continue }

            let enabled  = boolAttr(child, "AXEnabled") ?? true
            let fullPath = (currentPath + [trimmed]).joined(separator: " > ")
            guard !seenPaths.contains(fullPath) else { continue }
            seenPaths.insert(fullPath)

            // Skip section-header style items: disabled, no shortcut, no submenu
            var subCheckRef: AnyObject?
            let hasSub = AXUIElementCopyAttributeValue(child, "AXChildren" as CFString, &subCheckRef) == .success
                && (subCheckRef as? [AXUIElement])?.isEmpty == false
            if !enabled, !hasSub {
                if let role = stringAttr(child, "AXRole"), role != "AXMenuItem" { continue }
                // If it has no shortcut either, it's a section label — skip it
                let cmdChar = stringAttr(child, "AXMenuItemCmdChar") ?? ""
                if cmdChar.isEmpty { continue }
            }

            var shortcutDisplay: String? = nil
            if let cmdChar = stringAttr(child, "AXMenuItemCmdChar"), !cmdChar.isEmpty {
                let mods = intAttr(child, "AXMenuItemCmdModifiers") ?? 0
                shortcutDisplay = shortcutString(for: cmdChar, modifiers: mods)
            }

            results.append(AXMenuItemInfo(
                id: UUID(), title: trimmed, fullPath: fullPath,
                enabled: enabled, shortcutDisplay: shortcutDisplay
            ))

            var subRef: AnyObject?
            if AXUIElementCopyAttributeValue(child, "AXChildren" as CFString, &subRef) == .success,
               let sub = subRef as? [AXUIElement], !sub.isEmpty {
                recurse(menuElement: child, currentPath: currentPath + [trimmed],
                        results: &results, seenPaths: &seenPaths, depth: depth + 1)
            } else if AXUIElementCopyAttributeValue(child, "AXMenu" as CFString, &subRef) == .success,
                      let subMenu = subRef as! AXUIElement? {
                recurse(menuElement: subMenu, currentPath: currentPath + [trimmed],
                        results: &results, seenPaths: &seenPaths, depth: depth + 1)
            }
        }
    }

    // MARK: - AX attribute helpers

    private func menuBarElement(for pid: pid_t) -> AXUIElement? {
        let appEl = AXUIElementCreateApplication(pid)
        if let bar = elementAttr(appEl, "AXMenuBar") { return bar }
        let sysWide = AXUIElementCreateSystemWide()
        if let focusedApp = elementAttr(sysWide, kAXFocusedApplicationAttribute as String) {
            var focPID: pid_t = 0
            AXUIElementGetPid(focusedApp, &focPID)
            if focPID == pid, let bar = elementAttr(focusedApp, "AXMenuBar") { return bar }
        }
        return nil
    }

    private func stringAttr(_ el: AXUIElement, _ attr: String) -> String? {
        var ref: AnyObject?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &ref) == .success else { return nil }
        return ref as? String
    }

    private func boolAttr(_ el: AXUIElement, _ attr: String) -> Bool? {
        var ref: AnyObject?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &ref) == .success else { return nil }
        return ref as? Bool
    }

    private func intAttr(_ el: AXUIElement, _ attr: String) -> Int? {
        var ref: AnyObject?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &ref) == .success else { return nil }
        return ref as? Int
    }

    private func elementAttr(_ el: AXUIElement, _ attr: String) -> AXUIElement? {
        var ref: AnyObject?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &ref) == .success,
              let resolved = ref else { return nil }
        return unsafeBitCast(resolved, to: AXUIElement.self)
    }

    private func shortcutString(for char: String, modifiers: Int) -> String {
        var parts: [String] = []
        if (modifiers & (1 << 20)) != 0 { parts.append("⌘") }
        if (modifiers & (1 << 19)) != 0 { parts.append("⌥") }
        if (modifiers & (1 << 18)) != 0 { parts.append("⌃") }
        if (modifiers & (1 << 17)) != 0 { parts.append("⇧") }
        parts.append(char.uppercased())
        return parts.joined()
    }

    private func bundleVersionString(for app: NSRunningApplication) -> String {
        guard let url = app.bundleURL, let bundle = Bundle(url: url) else { return "" }
        return bundle.infoDictionary?["CFBundleShortVersionString"] as? String
            ?? bundle.infoDictionary?["CFBundleVersion"] as? String
            ?? ""
    }
}
