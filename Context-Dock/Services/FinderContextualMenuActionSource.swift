import AppKit
import ApplicationServices
import Foundation

struct FinderContextualMenuAction: Identifiable {
    let id: String
    let title: String
    let path: [String]
    let isEnabled: Bool
}

@MainActor
final class FinderContextualMenuActionSource {
    static let shared = FinderContextualMenuActionSource()

    private struct CacheEntry {
        let selectionKey: String
        let actions: [FinderContextualMenuAction]
        let date: Date
    }

    private var cache: CacheEntry?
    private let cacheMaxAge: TimeInterval = 60.0

    private init() {}

    func cachedActions(for selectedURLs: [URL]) -> [FinderContextualMenuAction] {
        let key = selectionKey(for: selectedURLs)
        guard !key.isEmpty,
            let cache,
            cache.selectionKey == key,
            Date().timeIntervalSince(cache.date) < cacheMaxAge
        else { return [] }
        return cache.actions
    }

    func hasFreshCache(for selectedURLs: [URL]) -> Bool {
        let key = selectionKey(for: selectedURLs)
        guard !key.isEmpty,
            let cache,
            cache.selectionKey == key,
            Date().timeIntervalSince(cache.date) < cacheMaxAge
        else { return false }
        return true
    }

    func actions(for selectedURLs: [URL], forceRefresh: Bool = false) -> [FinderContextualMenuAction] {
        let key = selectionKey(for: selectedURLs)
        guard !key.isEmpty else { return [] }
        if !forceRefresh,
            let cache,
            cache.selectionKey == key,
            Date().timeIntervalSince(cache.date) < cacheMaxAge
        {
            return cache.actions
        }

        guard let finder = finderApp(),
            let target = selectedFinderElement(app: finder, selectedURLs: selectedURLs)
        else { return [] }

        let opened = AXUIElementPerformAction(target, kAXShowMenuAction as CFString) == .success
        guard opened else { return [] }
        Thread.sleep(forTimeInterval: 0.12)
        let actions = readOpenContextMenuActions(app: finder)
        closeOpenMenu()

        let filtered = dedupe(actions).filter { action in
            let parts = action.path.map(Self.normalized)
            return parts.contains("quick actions") || parts.contains("services")
        }
        cache = CacheEntry(selectionKey: key, actions: filtered, date: Date())
        return filtered
    }

    func execute(_ action: FinderContextualMenuAction, selectedURLs: [URL]) -> Bool {
        guard let finder = finderApp(),
            let target = selectedFinderElement(app: finder, selectedURLs: selectedURLs)
        else { return false }

        guard AXUIElementPerformAction(target, kAXShowMenuAction as CFString) == .success else {
            return false
        }
        Thread.sleep(forTimeInterval: 0.12)
        defer { closeOpenMenu() }

        guard let item = findOpenMenuItem(app: finder, path: action.path) else { return false }
        return AXUIElementPerformAction(item, kAXPressAction as CFString) == .success
    }

    private func finderApp() -> NSRunningApplication? {
        NSWorkspace.shared.runningApplications.first {
            $0.bundleIdentifier == "com.apple.finder"
        }
    }

    private func selectionKey(for selectedURLs: [URL]) -> String {
        selectedURLs
            .map { $0.standardizedFileURL.path }
            .sorted()
            .joined(separator: "\n")
    }

    private func selectedFinderElement(
        app: NSRunningApplication,
        selectedURLs: [URL]
    ) -> AXUIElement? {
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        let selectedPaths = Set(selectedURLs.map { $0.standardizedFileURL.path })

        if let focused = elementAttribute(axApp, kAXFocusedUIElementAttribute as CFString),
            elementMatchesSelection(focused, selectedPaths: selectedPaths)
        {
            return focused
        }

        for attr in [kAXFocusedWindowAttribute as String, kAXMainWindowAttribute as String] {
            if let window = elementAttribute(axApp, attr as CFString),
                let match = firstMatchingElement(in: window, selectedPaths: selectedPaths)
            {
                return match
            }
        }

        if let windows = elementsAttribute(axApp, kAXWindowsAttribute as CFString) {
            for window in windows {
                if let match = firstMatchingElement(in: window, selectedPaths: selectedPaths) {
                    return match
                }
            }
        }
        return nil
    }

    private func firstMatchingElement(
        in root: AXUIElement,
        selectedPaths: Set<String>,
        limit: Int = 1_400
    ) -> AXUIElement? {
        var queue = [root]
        var visited = 0
        while !queue.isEmpty, visited < limit {
            visited += 1
            let element = queue.removeFirst()
            if elementMatchesSelection(element, selectedPaths: selectedPaths) {
                return element
            }
            if let children = elementsAttribute(element, kAXChildrenAttribute as CFString) {
                queue.append(contentsOf: children)
            }
            if let rows = elementsAttribute(element, kAXRowsAttribute as CFString) {
                queue.append(contentsOf: rows)
            }
            if let cols = elementsAttribute(element, kAXColumnsAttribute as CFString) {
                queue.append(contentsOf: cols)
            }
        }
        return nil
    }

    private func elementMatchesSelection(_ element: AXUIElement, selectedPaths: Set<String>) -> Bool {
        if boolAttribute(element, kAXSelectedAttribute as CFString) == true {
            return true
        }
        if let url = urlAttribute(element),
            selectedPaths.contains(url.standardizedFileURL.path)
        {
            return true
        }
        return false
    }

    private func readOpenContextMenuActions(app: NSRunningApplication) -> [FinderContextualMenuAction] {
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        let roots = menuRoots(in: axApp) + menuRoots(in: AXUIElementCreateSystemWide())
        var actions: [FinderContextualMenuAction] = []
        for root in roots {
            actions.append(contentsOf: readMenuItems(root, path: []))
        }
        return actions
    }

    private func findOpenMenuItem(
        app: NSRunningApplication,
        path: [String]
    ) -> AXUIElement? {
        let target = path.map(Self.normalized)
        guard !target.isEmpty else { return nil }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        let roots = menuRoots(in: axApp) + menuRoots(in: AXUIElementCreateSystemWide())
        for root in roots {
            if let found = findMenuItem(root, currentPath: [], target: target) {
                return found
            }
        }
        return nil
    }

    private func menuRoots(in root: AXUIElement) -> [AXUIElement] {
        var result: [AXUIElement] = []
        var queue = [root]
        var visited = 0
        while !queue.isEmpty, visited < 800 {
            visited += 1
            let element = queue.removeFirst()
            let role = stringAttribute(element, kAXRoleAttribute as CFString) ?? ""
            if role == kAXMenuRole as String {
                result.append(element)
                continue
            }
            if let children = elementsAttribute(element, kAXChildrenAttribute as CFString) {
                queue.append(contentsOf: children)
            }
        }
        return result
    }

    private func readMenuItems(_ element: AXUIElement, path: [String]) -> [FinderContextualMenuAction] {
        guard let children = elementsAttribute(element, kAXChildrenAttribute as CFString) else { return [] }
        var actions: [FinderContextualMenuAction] = []
        for child in children {
            let role = stringAttribute(child, kAXRoleAttribute as CFString) ?? ""
            guard role == kAXMenuItemRole as String else {
                actions.append(contentsOf: readMenuItems(child, path: path))
                continue
            }
            let title = stringAttribute(child, kAXTitleAttribute as CFString)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !title.isEmpty else { continue }
            let nextPath = path + [title]
            let submenus = elementsAttribute(child, kAXChildrenAttribute as CFString) ?? []
            if submenus.isEmpty {
                actions.append(FinderContextualMenuAction(
                    id: nextPath.map(Self.normalized).joined(separator: ">"),
                    title: title,
                    path: nextPath,
                    isEnabled: boolAttribute(child, kAXEnabledAttribute as CFString) ?? true
                ))
            } else {
                for submenu in submenus {
                    actions.append(contentsOf: readMenuItems(submenu, path: nextPath))
                }
            }
        }
        return actions
    }

    private func findMenuItem(
        _ element: AXUIElement,
        currentPath: [String],
        target: [String]
    ) -> AXUIElement? {
        guard let children = elementsAttribute(element, kAXChildrenAttribute as CFString) else { return nil }
        for child in children {
            let role = stringAttribute(child, kAXRoleAttribute as CFString) ?? ""
            guard role == kAXMenuItemRole as String else {
                if let found = findMenuItem(child, currentPath: currentPath, target: target) {
                    return found
                }
                continue
            }
            let title = stringAttribute(child, kAXTitleAttribute as CFString)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !title.isEmpty else { continue }
            let nextPath = currentPath + [title]
            if nextPath.map(Self.normalized) == target {
                return child
            }
            let submenus = elementsAttribute(child, kAXChildrenAttribute as CFString) ?? []
            for submenu in submenus {
                if let found = findMenuItem(submenu, currentPath: nextPath, target: target) {
                    return found
                }
            }
        }
        return nil
    }

    private func dedupe(_ actions: [FinderContextualMenuAction]) -> [FinderContextualMenuAction] {
        var seen = Set<String>()
        var result: [FinderContextualMenuAction] = []
        for action in actions {
            let key = action.path.map(Self.normalized).joined(separator: ">")
            guard !key.isEmpty, seen.insert(key).inserted else { continue }
            result.append(action)
        }
        return result
    }

    private func closeOpenMenu() {
        let source = CGEventSource(stateID: .hidSystemState)
        for _ in 0..<2 {
            let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 53, keyDown: true)
            let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 53, keyDown: false)
            keyDown?.post(tap: .cghidEventTap)
            keyUp?.post(tap: .cghidEventTap)
            Thread.sleep(forTimeInterval: 0.03)
        }
    }

    private func elementAttribute(_ element: AXUIElement, _ attr: CFString) -> AXUIElement? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attr, &ref) == .success else { return nil }
        guard let ref, CFGetTypeID(ref) == AXUIElementGetTypeID() else { return nil }
        return (ref as! AXUIElement)
    }

    private func elementsAttribute(_ element: AXUIElement, _ attr: CFString) -> [AXUIElement]? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attr, &ref) == .success else { return nil }
        return ref as? [AXUIElement]
    }

    private func stringAttribute(_ element: AXUIElement, _ attr: CFString) -> String? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attr, &ref) == .success else { return nil }
        return ref as? String
    }

    private func boolAttribute(_ element: AXUIElement, _ attr: CFString) -> Bool? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attr, &ref) == .success else { return nil }
        return (ref as? NSNumber)?.boolValue
    }

    private func urlAttribute(_ element: AXUIElement) -> URL? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXURLAttribute as CFString, &ref) == .success else {
            return nil
        }
        if let url = ref as? URL { return url }
        if let string = ref as? String { return URL(fileURLWithPath: string) }
        return nil
    }

    private static func normalized(_ value: String) -> String {
        value
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
            .replacingOccurrences(of: "[^a-z0-9 ]+", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
