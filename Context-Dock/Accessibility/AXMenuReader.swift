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
    var image: NSImage? = nil           // Native icon from AXImage attribute, if available
    var hasLiveAvailability: Bool = true // false for persistent-cache placeholders

    // Keyboard shortcut read from kAXMenuItemCmdChar / kAXMenuItemCmdModifiers
    var shortcutChar: String? = nil     // e.g. "n", "t", "w"
    var shortcutModifiers: Int = 0      // 0=⌘  1=⇧⌘  2=⌥⌘  4=⌃⌘  8=no-command  16=fn/globe

    var isChecked: Bool = false  // AXMenuItemMarkChar is non-empty (✓ state)
    var resolvedFilePath: String? = nil  // Persistent cache inversion for document/recent-file menu rows.

    var isLeaf: Bool { children.isEmpty }
    var pathString: String { path.joined(separator: " › ") }

    /// Human-readable shortcut string shown on pill, e.g. "⌘T", "⇧⌘P", "⌘⌫"
    var shortcutDisplay: String? {
        MenuShortcutFormatter.display(char: shortcutChar, modifiers: shortcutModifiers)
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
    private var lastDebugMessage: [pid_t: String] = [:]
    private var lastMenuBarProbe: [pid_t: String] = [:]
    private let cacheMaxAge: TimeInterval = 60   // invalidate after 60 s or app switch

    // Global AX scan lock — AX API is serialized by the OS accessibility server.
    // Running two concurrent full-tree reads blocks both threads and freezes input.
    private var activeScanPID: pid_t = 0

    /// Like allMenuItems but returns the cached tree on repeat calls within 60 s.
    func cachedAllMenuItems(for pid: pid_t, maxDepth: Int = 6) -> [AXMenuItem] {
        if let entry = menuCache[pid],
           Date().timeIntervalSince(entry.date) < cacheMaxAge,
           !entry.items.isEmpty {
            return entry.items
        }
        let items = allMenuItems(for: pid, maxDepth: maxDepth)
        if !items.isEmpty {
            menuCache[pid] = CacheEntry(items: items, date: Date())
        } else {
            menuCache.removeValue(forKey: pid)
        }
        return items
    }

    /// Return a still-fresh cached menu tree if one already exists.
    /// Unlike `cachedAllMenuItems`, this never performs a new AX crawl.
    func peekCachedAllMenuItems(for pid: pid_t) -> [AXMenuItem] {
        guard let entry = menuCache[pid],
              Date().timeIntervalSince(entry.date) < cacheMaxAge,
              !entry.items.isEmpty else {
            return []
        }
        return entry.items
    }

    /// Re-read the full menu tree now and replace the structural cache.
    /// Use this for the frontmost app while the dock is visible; menu labels like
    /// Safari's "Show Bookmarks" / "Hide Bookmarks" can change without an app switch.
    func refreshAllMenuItems(for pid: pid_t, maxDepth: Int = 6) -> [AXMenuItem] {
        let items = allMenuItems(for: pid, maxDepth: maxDepth)
        if !items.isEmpty {
            menuCache[pid] = CacheEntry(items: items, date: Date())
        } else {
            menuCache.removeValue(forKey: pid)
        }
        return items
    }

    /// Force-evict a pid from the cache (call on app relaunch / app switch).
    func invalidateCache(for pid: pid_t) {
        menuCache.removeValue(forKey: pid)
    }

    func lastDebug(for pid: pid_t) -> String? {
        lastDebugMessage[pid]
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
        guard let bar = menuBarElement(for: pid) else { return [] }
        return readChildren(of: bar, path: [], depth: 0, maxDepth: maxDepth)
    }

    /// Flatten the tree to all leaf menu items (no submenus), skipping separators.
    /// Falls back to AppleScript when AX returns an empty tree (Electron, Catalyst apps).
    var isScanningMenus: Bool { activeScanPID != 0 }

    func allMenuItems(for pid: pid_t, maxDepth: Int = 5) -> [AXMenuItem] {
        activeScanPID = pid
        defer { if activeScanPID == pid { activeScanPID = 0 } }
        let tree = menuTree(for: pid, maxDepth: maxDepth)
        let flattened = flatten(tree, includeGroups: true)
        let probe = lastMenuBarProbe[pid] ?? "probe unavailable"
        let trusted = AXIsProcessTrusted() ? "trusted" : "not_trusted"

        if !flattened.isEmpty {
            lastDebugMessage[pid] = "ax \(trusted), \(probe), tree \(flattened.count)"
            return flattened
        }

        // AX returned nothing — try AppleScript walk (handles Electron, Catalyst, etc.)
        let appElement = AXUIElementCreateApplication(pid)
        let (scriptItems, scriptErr) = scriptedMenuItems(for: pid, appElement: appElement)
        let scriptResult = scriptErr.map { "as_err:\($0)" } ?? "as_ok:\(scriptItems.count)"
        lastDebugMessage[pid] = "ax \(trusted), \(probe), tree 0, \(scriptResult)"
        if !scriptItems.isEmpty {
            menuCache[pid] = CacheEntry(items: scriptItems, date: Date())
        }
        return scriptItems
    }

    /// Search menu items by keyword — returns up to `maxResults` best matches.
    /// Only returns leaf (directly clickable) items; skips submenu containers and disabled items.
    func searchMenuItems(query: String, in pid: pid_t, maxResults: Int = 8) -> [AXMenuItem] {
        guard !query.isEmpty else { return [] }
        let q = query.lowercased()
        let all = allMenuItems(for: pid)
        let matches = all.filter { item in
            guard item.isLeaf, item.isEnabled else { return false }  // skip containers + disabled
            return item.title.lowercased().contains(q) ||
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

    func menuItem(path: [String], in pid: pid_t, refresh: Bool = false, maxDepth: Int = 6) -> AXMenuItem? {
        let target = normalizedPath(path)
        guard !target.isEmpty else { return nil }
        let items =
            refresh
            ? refreshAllMenuItems(for: pid, maxDepth: maxDepth)
            : cachedAllMenuItems(for: pid, maxDepth: maxDepth)
        return items.first { normalizedPath($0.path) == target }
    }

    /// Click a menu item identified by its path (case-insensitive).
    /// Example: ["File", "New Tab"]  or  ["Develop", "Show Web Inspector"]
    /// Must be called from a background thread — uses Thread.sleep for menu open timing.
    @discardableResult
    func clickMenuItem(path: [String], in pid: pid_t) -> Bool {
        if let app = NSWorkspace.shared.runningApplications.first(where: { $0.processIdentifier == pid }) {
            _ = app.activate(options: [.activateIgnoringOtherApps])
            Thread.sleep(forTimeInterval: 0.08)
        }
        guard let bar = menuBarElement(for: pid) else { return false }
        return traverse(element: bar, path: path)
    }

    // MARK: - Private — tree reading

    private func readChildren(of parent: AXUIElement, path: [String],
                              depth: Int, maxDepth: Int) -> [AXMenuItem] {
        guard depth < maxDepth else { return [] }
        guard let children = childElements(of: parent) else { return [] }

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
            let subItems   = readChildren(of: submenuContainer(for: child) ?? child,
                                          path: childPath,
                                          depth: depth + 1,
                                          maxDepth: maxDepth)

            // Read keyboard shortcut and checked state from AX attributes
            let shortcutChar      = strAttr(child, "AXMenuItemCmdChar" as CFString)
            let shortcutModifiers = intAttr(child, "AXMenuItemCmdModifiers" as CFString) ?? 0
            let markChar          = strAttr(child, "AXMenuItemMarkChar" as CFString)
            let isChecked         = markChar != nil && !markChar!.isEmpty

            // Read native menu item icon via AXImage
            var menuImage: NSImage? = nil
            var imgRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(child, "AXImage" as CFString, &imgRef) == .success {
                if let img = imgRef as? NSImage {
                    menuImage = img
                } else if let cgImg = imgRef {
                    // Some apps return a CGImage wrapped in CFTypeRef
                    let typeID = CFGetTypeID(cgImg)
                    if typeID == CGImage.typeID {
                        let cg = unsafeBitCast(cgImg, to: CGImage.self)
                        menuImage = NSImage(cgImage: cg, size: NSSize(width: 16, height: 16))
                    }
                }
            }

            // Apple menu is depth-0, path[0] == "" (the  title)
            let isApple = path.isEmpty || (path.count == 1 && path[0].isEmpty)

            result.append(AXMenuItem(
                title: title,
                path: childPath,
                isEnabled: isEnabled,
                element: child,
                children: subItems,
                isAppleMenu: isApple,
                image: menuImage,
                shortcutChar: (shortcutChar?.isEmpty == false) ? shortcutChar : nil,
                shortcutModifiers: shortcutModifiers,
                isChecked: isChecked
            ))
        }
        return result
    }

    private func menuBarElement(for pid: pid_t) -> AXUIElement? {
        let appElement = AXUIElementCreateApplication(pid)
        var appRef: CFTypeRef?
        let appResult = AXUIElementCopyAttributeValue(appElement, kAXMenuBarAttribute as CFString, &appRef)
        if appResult == .success, let resolved = appRef {
            lastMenuBarProbe[pid] = "appMenuBar success"
            return unsafeBitCast(resolved, to: AXUIElement.self)
        }
        lastMenuBarProbe[pid] = "appMenuBar \(appResult.rawValue)"
        return nil
    }

    private func scriptedMenuItems(for pid: pid_t, appElement: AXUIElement) -> (items: [AXMenuItem], error: String?) {
        guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.processIdentifier == pid }),
              let appName = app.localizedName, !appName.isEmpty else {
            return ([], "target app not found")
        }

        let escapedName = appName.replacingOccurrences(of: "\"", with: "\\\"")
        let script = """
        on walkMenu(theMenu, prefixText)
            set outLines to {}
            try
                set itemList to every menu item of theMenu
            on error
                return outLines
            end try
            repeat with mi in itemList
                try
                    tell mi
                        set itemName to (name as text)
                        if itemName is not "" and itemName is not "-" then
                            set isEnabled to true
                            try
                                set isEnabled to enabled
                            end try
                            set enabledFlag to "1"
                            if isEnabled is false then set enabledFlag to "0"
                            set end of outLines to (prefixText & itemName & "|||" & enabledFlag)
                            try
                                set outLines to outLines & my walkMenu(menu 1, prefixText & itemName & " > ")
                            end try
                        end if
                    end tell
                end try
            end repeat
            return outLines
        end walkMenu

        tell application "System Events"
            tell process "\(escapedName)"
                set outLines to {}
                try
                    set topItems to every menu bar item of menu bar 1
                on error
                    return ""
                end try
                repeat with mbi in topItems
                    try
                        set menuName to (name of mbi as text)
                        if menuName is not "" then
                            set end of outLines to (menuName & "|||1")
                            try
                                set outLines to outLines & my walkMenu(menu 1 of mbi, menuName & " > ")
                            end try
                        end if
                    end try
                end repeat
                set AppleScript's text item delimiters to linefeed
                return outLines as text
            end tell
        end tell
        """

        let scriptResult = runAppleScript(script) ?? runOsaScriptProcess(script)
        guard let raw = scriptResult.output, !raw.isEmpty else {
            return ([], scriptResult.error ?? "empty result")
        }

        let items = raw
            .components(separatedBy: .newlines)
            .compactMap { line -> AXMenuItem? in
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return nil }
                let parts = trimmed.components(separatedBy: "|||")
                guard let rawPath = parts.first?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !rawPath.isEmpty else { return nil }
                let path = rawPath
                    .components(separatedBy: " > ")
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                guard let title = path.last, !title.isEmpty else { return nil }
                let enabled = (parts.count > 1 ? Int(parts[1]) : 1) != 0
                return AXMenuItem(
                    title: title,
                    path: path,
                    isEnabled: enabled,
                    element: appElement,
                    children: [],
                    isAppleMenu: path.first == "Apple",
                    shortcutChar: nil,
                    shortcutModifiers: 0
                )
            }
        return (items, scriptResult.error)
    }

    private func runAppleScript(_ source: String) -> (output: String?, error: String?)? {
        var error: NSDictionary?
        guard let script = NSAppleScript(source: source) else { return (nil, "failed to compile AppleScript") }
        let result = script.executeAndReturnError(&error)
        if let error {
            let message = error[NSAppleScript.errorMessage] as? String
                ?? error.description
            return (nil, message)
        }
        return (result.stringValue, nil)
    }

    private func runOsaScriptProcess(_ source: String) -> (output: String?, error: String?) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", source]

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return (nil, error.localizedDescription)
        }

        let out = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let err = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if process.terminationStatus == 0 {
            return (out, err?.isEmpty == false ? err : nil)
        }
        return (out, err ?? "osascript exit \(process.terminationStatus)")
    }

    private func attributeElement(_ element: AXUIElement, attribute: CFString) -> AXUIElement? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &ref) == .success,
              let resolved = ref else { return nil }
        return unsafeBitCast(resolved, to: AXUIElement.self)
    }

    private func childElements(of element: AXUIElement) -> [AXUIElement]? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &ref) == .success else {
            return nil
        }
        return ref as? [AXUIElement]
    }

    /// Some apps expose submenu contents under AXMenu instead of AXChildren on the menu bar item itself.
    private func submenuContainer(for element: AXUIElement) -> AXUIElement? {
        if let children = childElements(of: element), !children.isEmpty {
            return element
        }
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, "AXMenu" as CFString, &ref) == .success,
              let menu = ref else { return nil }
        return unsafeBitCast(menu, to: AXUIElement.self)
    }

    private func flatten(_ items: [AXMenuItem], includeGroups: Bool = false) -> [AXMenuItem] {
        var out: [AXMenuItem] = []
        for item in items {
            if includeGroups || item.isLeaf { out.append(item) }
            if !item.children.isEmpty {
                out += flatten(item.children, includeGroups: includeGroups)
            }
        }
        return out
    }

    private func dedupeKey(for path: [String]) -> String {
        path.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
            .joined(separator: " > ")
    }

    private func normalizedPath(_ path: [String]) -> String {
        path
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
            .joined(separator: " > ")
    }

    // MARK: - Private — clicking

    /// Recursively descend the AX tree matching path components to item titles.
    @discardableResult
    private func traverse(element: AXUIElement, path: [String]) -> Bool {
        guard !path.isEmpty else { return false }
        let target = path[0].lowercased()
        let rest   = Array(path.dropFirst())

        let container = submenuContainer(for: element) ?? element
        guard let children = childElements(of: container), !children.isEmpty else { return false }

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
                return AXUIElementPerformAction(child, kAXPressAction as CFString) == .success
            }

            // Open this submenu and wait for children to appear (retry up to 150 ms)
            AXUIElementPerformAction(child, kAXPressAction as CFString)
            var waited: TimeInterval = 0
            while waited < 0.15 {
                Thread.sleep(forTimeInterval: 0.04)
                waited += 0.04
                if let menuContainer = submenuContainer(for: child),
                   let kids = childElements(of: menuContainer),
                   !kids.isEmpty {
                    break
                }
            }
            return traverse(element: submenuContainer(for: child) ?? child, path: rest)
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
    /// Returns false if the key code is unknown (caller should fall back to AX menu click).
    @discardableResult
    func executeShortcut(char: String, modifiers: Int, in pid: pid_t) -> Bool {
        guard let src = CGEventSource(stateID: .hidSystemState),
              let ch = char.unicodeScalars.first else { return false }

        var cgMods: CGEventFlags = []
        if modifiers & 8 == 0 { cgMods.insert(.maskCommand) }  // bit 3 set = no-command shortcut
        if modifiers & 1 != 0 { cgMods.insert(.maskShift) }
        if modifiers & 2 != 0 { cgMods.insert(.maskAlternate) }
        if modifiers & 4 != 0 { cgMods.insert(.maskControl) }
        if modifiers & 16 != 0 { cgMods.insert(.maskSecondaryFn) }

        let keyCode = MenuShortcutFormatter.virtualKeyCode(for: ch.value)
        guard keyCode != 0xFFFF else { return false }  // unsupported key — let caller fall back

        if let down = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: true),
           let up   = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: false) {
            down.flags = cgMods
            down.postToPid(pid)
            up.postToPid(pid)
        }
        return true
    }

    /// Execute a shortcut through the normal HID event stream. Use only after
    /// target app has been activated; some apps ignore postToPid for command
    /// equivalents such as Xcode's Stop (⌘.).
    @discardableResult
    func executeShortcutToFrontmost(char: String, modifiers: Int) -> Bool {
        guard let src = CGEventSource(stateID: .hidSystemState),
              let ch = char.unicodeScalars.first else { return false }

        var cgMods: CGEventFlags = []
        if modifiers & 8 == 0 { cgMods.insert(.maskCommand) }
        if modifiers & 1 != 0 { cgMods.insert(.maskShift) }
        if modifiers & 2 != 0 { cgMods.insert(.maskAlternate) }
        if modifiers & 4 != 0 { cgMods.insert(.maskControl) }
        if modifiers & 16 != 0 { cgMods.insert(.maskSecondaryFn) }

        let keyCode = MenuShortcutFormatter.virtualKeyCode(for: ch.value)
        guard keyCode != 0xFFFF else { return false }

        if let down = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: true),
           let up = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: false) {
            down.flags = cgMods
            up.flags = cgMods
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
            return true
        }
        return false
    }

}
