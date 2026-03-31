//
//  AXMenuReader.swift
//  ILauncher
//
//  Reads the macOS menu bar for any running app via the Accessibility API
//  and clicks menu items without stealing focus from the target app.
//

import AppKit
import ApplicationServices

// MARK: - AXMenuItem

struct AXMenuItem: Identifiable {
    let id = UUID()
    var title: String
    var path: [String]          // Full path from root, e.g. ["File", "Export", "PDF…"]
    var isEnabled: Bool
    var element: AXUIElement
    var children: [AXMenuItem]
    var sourcePID: pid_t = 0            // Which app owns this item (0 = current frontmost)
    var sourceAppName: String = ""      // Display name of the source app
    var isAppleMenu: Bool = false       // True for universal Apple-menu items (System Settings, Sleep…)

    // Keyboard shortcut read from kAXMenuItemCmdChar / kAXMenuItemCmdModifiers
    var shortcutChar: String? = nil     // e.g. "n", "t", "w"
    var shortcutModifiers: Int = 0      // 0=⌘  1=⇧⌘  2=⌥⌘  4=⌃⌘

    var isLeaf: Bool { children.isEmpty }
    var pathString: String { path.joined(separator: " › ") }

    /// Human-readable shortcut string shown on pill, e.g. "⌘T", "⇧⌘P"
    var shortcutDisplay: String? {
        guard let ch = shortcutChar?.uppercased(), !ch.isEmpty else { return nil }
        var s = ""
        if shortcutModifiers & 4 != 0 { s += "⌃" }
        if shortcutModifiers & 2 != 0 { s += "⌥" }
        if shortcutModifiers & 1 != 0 { s += "⇧" }
        s += "⌘\(ch)"
        return s
    }
}

// MARK: - AXMenuReader

final class AXMenuReader {
    static let shared = AXMenuReader()
    private init() {}

    // MARK: - Structural cache

    private struct CacheEntry {
        var items: [AXMenuItem]
        var date:  Date
    }
    private var menuCache: [pid_t: CacheEntry] = [:]
    private let cacheMaxAge: TimeInterval = 60   // invalidate after 60 s or app switch

    /// Like allMenuItems but returns the cached tree on repeat calls within 60 s.
    func cachedAllMenuItems(for pid: pid_t, maxDepth: Int = 6) -> [AXMenuItem] {
        if let entry = menuCache[pid],
           Date().timeIntervalSince(entry.date) < cacheMaxAge {
            return entry.items
        }
        let items = allMenuItems(for: pid, maxDepth: maxDepth)
        menuCache[pid] = CacheEntry(items: items, date: Date())
        return items
    }

    /// Force-evict a pid from the cache (call on app relaunch / app switch).
    func invalidateCache(for pid: pid_t) {
        menuCache.removeValue(forKey: pid)
    }

    /// Re-reads only `kAXEnabled` for each item using its stored AXUIElement ref.
    /// ≈20× faster than a full tree walk — no DFS, one attribute call per leaf.
    /// Returns a [UUID: Bool] map so callers can apply the diff without
    /// touching the AXUIElement across concurrency boundaries.
    func refreshEnabledStates(for items: [AXMenuItem]) -> [UUID: Bool] {
        var result = [UUID: Bool](minimumCapacity: items.count)
        for item in items {
            var ref: CFTypeRef?
            if AXUIElementCopyAttributeValue(
                item.element, kAXEnabledAttribute as CFString, &ref
            ) == .success, let n = ref as? NSNumber {
                result[item.id] = n.boolValue
            }
        }
        return result
    }

    // MARK: - Public API

    /// Read the full menu bar tree for an app by PID.
    /// maxDepth limits recursion to keep reads fast (4 covers File › Export › PDF…).
    func menuTree(for pid: pid_t, maxDepth: Int = 5) -> [AXMenuItem] {
        let axApp = AXUIElementCreateApplication(pid)
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXMenuBarAttribute as CFString, &ref) == .success,
              let barCF = ref else { return [] }
        let bar = unsafeBitCast(barCF, to: AXUIElement.self)
        return readChildren(of: bar, path: [], depth: 0, maxDepth: maxDepth)
    }

    /// Flatten the tree to all leaf menu items (no submenus), skipping separators.
    func allMenuItems(for pid: pid_t, maxDepth: Int = 5) -> [AXMenuItem] {
        flatten(menuTree(for: pid, maxDepth: maxDepth))
    }

    /// Search menu items by keyword — returns up to `maxResults` best matches.
    func searchMenuItems(query: String, in pid: pid_t, maxResults: Int = 8) -> [AXMenuItem] {
        guard !query.isEmpty else { return [] }
        let q = query.lowercased()
        let all = allMenuItems(for: pid)
        let matches = all.filter { item in
            item.title.lowercased().contains(q) ||
            item.path.contains { $0.lowercased().contains(q) }
        }
        return Array(matches.sorted {
            // Title matches rank higher than path-only matches
            let aTitle = $0.title.lowercased().contains(q) ? 0 : 1
            let bTitle = $1.title.lowercased().contains(q) ? 0 : 1
            if aTitle != bTitle { return aTitle < bTitle }
            return $0.path.count < $1.path.count // prefer shallower items
        }.prefix(maxResults))
    }

    /// Click a menu item identified by its path (case-insensitive).
    /// Example: ["File", "New Tab"]  or  ["Develop", "Show Web Inspector"]
    /// Must be called from a background thread — uses Thread.sleep for menu open timing.
    @discardableResult
    func clickMenuItem(path: [String], in pid: pid_t) -> Bool {
        let axApp = AXUIElementCreateApplication(pid)
        var barRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXMenuBarAttribute as CFString, &barRef) == .success,
              let barCF = barRef else { return false }
        let bar = unsafeBitCast(barCF, to: AXUIElement.self)
        return traverse(element: bar, path: path)
    }

    // MARK: - Private — tree reading

    private func readChildren(of parent: AXUIElement, path: [String],
                              depth: Int, maxDepth: Int) -> [AXMenuItem] {
        guard depth < maxDepth else { return [] }
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(parent, kAXChildrenAttribute as CFString, &ref) == .success,
              let children = ref as? [AXUIElement] else { return [] }

        var result: [AXMenuItem] = []
        for child in children {
            let role  = strAttr(child, kAXRoleAttribute as CFString) ?? ""
            let title = strAttr(child, kAXTitleAttribute as CFString) ?? ""

            // AXMenu containers are transparent wrappers — recurse without adding a level
            if role == "AXMenu" {
                result += readChildren(of: child, path: path, depth: depth, maxDepth: maxDepth)
                continue
            }

            // Skip separators and unnamed items
            guard !title.isEmpty, title != "-" else { continue }

            let isEnabled  = boolAttr(child, kAXEnabledAttribute as CFString) ?? true
            let childPath  = path + [title]
            let subItems   = readChildren(of: child, path: childPath, depth: depth + 1, maxDepth: maxDepth)

            // Read keyboard shortcut from AX attributes
            let shortcutChar      = strAttr(child, "AXMenuItemCmdChar" as CFString)
            let shortcutModifiers = intAttr(child, "AXMenuItemCmdModifiers" as CFString) ?? 0

            // Apple menu is depth-0, path[0] == "" (the  title)
            let isApple = path.isEmpty || (path.count == 1 && path[0].isEmpty)

            result.append(AXMenuItem(
                title: title,
                path: childPath,
                isEnabled: isEnabled,
                element: child,
                children: subItems,
                isAppleMenu: isApple,
                shortcutChar: (shortcutChar?.isEmpty == false) ? shortcutChar : nil,
                shortcutModifiers: shortcutModifiers
            ))
        }
        return result
    }

    private func flatten(_ items: [AXMenuItem]) -> [AXMenuItem] {
        var out: [AXMenuItem] = []
        for item in items {
            if item.isLeaf { out.append(item) }
            else            { out += flatten(item.children) }
        }
        return out
    }

    // MARK: - Private — clicking

    /// Recursively descend the AX tree matching path components to item titles.
    @discardableResult
    private func traverse(element: AXUIElement, path: [String]) -> Bool {
        guard !path.isEmpty else { return false }
        let target = path[0].lowercased()
        let rest   = Array(path.dropFirst())

        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &ref) == .success,
              let children = ref as? [AXUIElement] else { return false }

        for child in children {
            let role  = strAttr(child, kAXRoleAttribute as CFString) ?? ""
            let title = strAttr(child, kAXTitleAttribute as CFString) ?? ""

            // AXMenu containers are transparent — pass through without consuming a path level
            if role == "AXMenu" {
                if traverse(element: child, path: path) { return true }
                continue
            }

            guard title.lowercased() == target else { continue }

            if rest.isEmpty {
                // Reached the target — press it
                AXUIElementPerformAction(child, kAXPressAction as CFString)
                return true
            }

            // Open this submenu and wait for children to appear (retry up to 150 ms)
            AXUIElementPerformAction(child, kAXPressAction as CFString)
            var waited: TimeInterval = 0
            while waited < 0.15 {
                Thread.sleep(forTimeInterval: 0.04)
                waited += 0.04
                var testRef: CFTypeRef?
                if AXUIElementCopyAttributeValue(child, kAXChildrenAttribute as CFString, &testRef) == .success,
                   let kids = testRef as? [AXUIElement], !kids.isEmpty { break }
            }
            return traverse(element: child, path: rest)
        }
        return false
    }

    // MARK: - AX attribute helpers

    private func strAttr(_ el: AXUIElement, _ attr: CFString) -> String? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr, &ref) == .success else { return nil }
        return ref as? String
    }

    private func boolAttr(_ el: AXUIElement, _ attr: CFString) -> Bool? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr, &ref) == .success else { return nil }
        if let n = ref as? NSNumber { return n.boolValue }
        return nil
    }

    private func intAttr(_ el: AXUIElement, _ attr: CFString) -> Int? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr, &ref) == .success else { return nil }
        if let n = ref as? NSNumber { return n.intValue }
        return nil
    }

    // MARK: - Shortcut execution

    /// Execute a menu item via its keyboard shortcut — faster than AX menu traversal.
    /// Sends a CGEvent directly to the target process. Call from background thread after app activation.
    func executeShortcut(char: String, modifiers: Int, in pid: pid_t) {
        guard let src = CGEventSource(stateID: .hidSystemState),
              let ch = char.unicodeScalars.first else { return }

        var cgMods: CGEventFlags = .maskCommand
        if modifiers & 1 != 0 { cgMods.insert(.maskShift) }
        if modifiers & 2 != 0 { cgMods.insert(.maskAlternate) }
        if modifiers & 4 != 0 { cgMods.insert(.maskControl) }

        let keyCode = virtualKeyCode(for: ch.value)
        guard keyCode != 0xFFFF else { return }  // unsupported key

        if let down = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: true),
           let up   = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: false) {
            down.flags = cgMods
            down.postToPid(pid)
            up.postToPid(pid)
        }
    }

    // Maps common characters to virtual key codes (US layout)
    private func virtualKeyCode(for scalar: UInt32) -> CGKeyCode {
        let map: [UInt32: CGKeyCode] = [
            UInt32(("a" as UnicodeScalar).value): 0,  UInt32(("s" as UnicodeScalar).value): 1,
            UInt32(("d" as UnicodeScalar).value): 2,  UInt32(("f" as UnicodeScalar).value): 3,
            UInt32(("h" as UnicodeScalar).value): 4,  UInt32(("g" as UnicodeScalar).value): 5,
            UInt32(("z" as UnicodeScalar).value): 6,  UInt32(("x" as UnicodeScalar).value): 7,
            UInt32(("c" as UnicodeScalar).value): 8,  UInt32(("v" as UnicodeScalar).value): 9,
            UInt32(("b" as UnicodeScalar).value): 11, UInt32(("q" as UnicodeScalar).value): 12,
            UInt32(("w" as UnicodeScalar).value): 13, UInt32(("e" as UnicodeScalar).value): 14,
            UInt32(("r" as UnicodeScalar).value): 15, UInt32(("y" as UnicodeScalar).value): 16,
            UInt32(("t" as UnicodeScalar).value): 17, UInt32(("1" as UnicodeScalar).value): 18,
            UInt32(("2" as UnicodeScalar).value): 19, UInt32(("3" as UnicodeScalar).value): 20,
            UInt32(("4" as UnicodeScalar).value): 21, UInt32(("6" as UnicodeScalar).value): 22,
            UInt32(("5" as UnicodeScalar).value): 23, UInt32(("=" as UnicodeScalar).value): 24,
            UInt32(("9" as UnicodeScalar).value): 25, UInt32(("7" as UnicodeScalar).value): 26,
            UInt32(("-" as UnicodeScalar).value): 27, UInt32(("8" as UnicodeScalar).value): 28,
            UInt32(("0" as UnicodeScalar).value): 29, UInt32(("]" as UnicodeScalar).value): 30,
            UInt32(("o" as UnicodeScalar).value): 31, UInt32(("u" as UnicodeScalar).value): 32,
            UInt32(("[" as UnicodeScalar).value): 33, UInt32(("i" as UnicodeScalar).value): 34,
            UInt32(("p" as UnicodeScalar).value): 35, UInt32(("l" as UnicodeScalar).value): 37,
            UInt32(("j" as UnicodeScalar).value): 38, UInt32(("'" as UnicodeScalar).value): 39,
            UInt32(("k" as UnicodeScalar).value): 40, UInt32((";" as UnicodeScalar).value): 41,
            UInt32(("\\" as UnicodeScalar).value): 42,UInt32(("," as UnicodeScalar).value): 43,
            UInt32(("/" as UnicodeScalar).value): 44, UInt32(("n" as UnicodeScalar).value): 45,
            UInt32(("m" as UnicodeScalar).value): 46, UInt32(("." as UnicodeScalar).value): 47,
            UInt32(("`" as UnicodeScalar).value): 50,
        ]
        let lower = scalar >= 65 && scalar <= 90 ? scalar + 32 : scalar  // uppercase → lowercase
        return map[lower] ?? 0xFFFF
    }
}
