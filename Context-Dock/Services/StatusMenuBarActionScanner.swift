import AppKit
import ApplicationServices
import Foundation

final class StatusMenuBarActionScanner {
    static let shared = StatusMenuBarActionScanner()

    private init() {}

    @discardableResult
    nonisolated func scanAndStoreInstalledStatusMenus(maxStatusItems: Int = 28) -> Bool {
        guard AXIsProcessTrusted(),
            let systemUIServer = NSWorkspace.shared.runningApplications.first(where: {
                $0.bundleIdentifier == "com.apple.systemuiserver"
            })
        else { return false }

        let systemElement = AXUIElementCreateApplication(systemUIServer.processIdentifier)
        guard let extrasBar = extrasMenuBar(for: systemUIServer.processIdentifier) else {
            return false
        }
        let statusItems = statusMenuBarItems(in: extrasBar)
        guard !statusItems.isEmpty else { return false }

        let runningApps = NSWorkspace.shared.runningApplications.filter {
            !$0.isTerminated
                && $0.bundleIdentifier != "com.apple.systemuiserver"
                && $0.bundleIdentifier != Bundle.main.bundleIdentifier
        }
        guard !runningApps.isEmpty else { return false }

        var stored = false
        for statusItem in statusItems.prefix(maxStatusItems) {
            let labels = statusItemLabels(statusItem)
            guard shouldProbeStatusItem(labels: labels) else { continue }

            AXUIElementPerformAction(statusItem, kAXPressAction as CFString)
            Thread.sleep(forTimeInterval: 0.16)

            guard let menu = menuContainer(for: statusItem)
                ?? activeMenuContainer(in: systemElement)
            else {
                closeStatusMenu(statusItem, menu: nil)
                continue
            }
            let rawItems = readChildren(of: menu, path: [], depth: 0, maxDepth: 5)
            closeStatusMenu(statusItem, menu: menu)
            guard !rawItems.isEmpty else { continue }

            let flattened = flatten(rawItems)
            guard let owner = ownerApp(for: labels, menuItems: flattened, runningApps: runningApps),
                let bundleId = owner.bundleIdentifier,
                !bundleId.isEmpty
            else { continue }

            let appName = statusMenuDisplayName(
                owner: owner,
                labels: labels,
                menuItems: flattened
            )
            var scopedItems = flattened.map { item in
                var copy = item
                copy.path = [appName] + item.path
                copy.sourcePID = owner.processIdentifier
                copy.sourceAppName = appName
                copy.isAppleMenu = false
                return copy
            }
            scopedItems.removeAll { item in
                let normalized = AppMenuCapabilityCache.normalize(item.title)
                return normalized.isEmpty
                    || normalized == AppMenuCapabilityCache.normalize(appName)
            }
            guard !scopedItems.isEmpty else { continue }

            AppMenuCapabilityCache.shared.store(items: scopedItems, for: owner, replace: false)
            stored = true
        }

        return stored
    }

    nonisolated private func shouldProbeStatusItem(labels: [String]) -> Bool {
        let normalized = labels.map(AppMenuCapabilityCache.normalize)
        let systemLabels: Set<String> = [
            "wifi", "wi fi", "battery", "sound", "volume", "control center",
            "clock", "siri", "spotlight", "bluetooth", "display", "keyboard brightness",
            "focus", "now playing", "screen mirroring", "user", "fast user switching"
        ]
        if normalized.contains(where: { value in
            systemLabels.contains(value) || systemLabels.contains(where: value.contains)
        }) {
            return false
        }
        return true
    }

    nonisolated private func extrasMenuBar(for pid: pid_t) -> AXUIElement? {
        let appElement = AXUIElementCreateApplication(pid)
        for attr in ["AXExtrasMenuBar", "AXMenuBar"] {
            var ref: CFTypeRef?
            if AXUIElementCopyAttributeValue(appElement, attr as CFString, &ref) == .success,
                let resolved = ref
            {
                return unsafeBitCast(resolved, to: AXUIElement.self)
            }
        }
        return nil
    }

    nonisolated private func statusItemLabels(_ element: AXUIElement) -> [String] {
        var labels = [
            kAXTitleAttribute as String,
            kAXDescriptionAttribute as String,
            kAXHelpAttribute as String,
            "AXIdentifier",
            "AXValue"
        ].compactMap { attr in
            strAttr(element, attr as CFString)?.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }
        if labels.isEmpty,
            let children = childElements(of: element)
        {
            labels += children.flatMap(statusItemLabels)
        }
        return Array(NSOrderedSet(array: labels)) as? [String] ?? labels
    }

    nonisolated private func ownerApp(
        for labels: [String],
        menuItems: [AXMenuItem],
        runningApps: [NSRunningApplication]
    ) -> NSRunningApplication? {
        let normalizedLabels = labels.map(AppMenuCapabilityCache.normalize).filter { !$0.isEmpty }
        let menuTexts = menuItems.flatMap { item in
            [item.title] + item.path
        }.map(AppMenuCapabilityCache.normalize).filter { !$0.isEmpty }

        var best: (app: NSRunningApplication, score: Int)?
        for app in runningApps {
            let appName = AppMenuCapabilityCache.normalize(app.localizedName ?? "")
            let bundleTail = AppMenuCapabilityCache.normalize(
                app.bundleIdentifier?.components(separatedBy: ".").last ?? ""
            )
            let executableName = AppMenuCapabilityCache.normalize(
                app.executableURL?.deletingPathExtension().lastPathComponent ?? ""
            )
            let aliases = Set([appName, bundleTail, executableName].filter { $0.count >= 2 })
            guard !aliases.isEmpty else { continue }

            var score = 0
            for alias in aliases {
                if normalizedLabels.contains(alias) { score += 900 }
                if normalizedLabels.contains(where: { $0.contains(alias) || alias.contains($0) }) {
                    score += 420
                }
                if menuTexts.contains("quit \(alias)") { score += 1_200 }
                if menuTexts.contains(where: { $0.hasPrefix("quit ") && $0.contains(alias) }) {
                    score += 650
                }
                if menuTexts.contains(where: { $0.contains(alias) }) { score += 120 }
            }

            guard score > 0 else { continue }
            if best.map({ score > $0.score }) ?? true {
                best = (app, score)
            }
        }
        return best?.app
    }

    nonisolated private func readChildren(
        of parent: AXUIElement,
        path: [String],
        depth: Int,
        maxDepth: Int
    ) -> [AXMenuItem] {
        guard depth < maxDepth,
            let children = childElements(of: parent)
        else { return [] }

        var result: [AXMenuItem] = []
        for child in children {
            let role = strAttr(child, kAXRoleAttribute as CFString) ?? ""
            let title = strAttr(child, kAXTitleAttribute as CFString) ?? ""

            if role == "AXMenu" {
                result += readChildren(of: child, path: path, depth: depth, maxDepth: maxDepth)
                continue
            }
            guard !title.isEmpty, title != "-" else { continue }

            let childPath = path + [title]
            let subItems = readChildren(
                of: menuContainer(for: child) ?? child,
                path: childPath,
                depth: depth + 1,
                maxDepth: maxDepth
            )
            let shortcutChar = strAttr(child, "AXMenuItemCmdChar" as CFString)
            let shortcutModifiers = intAttr(child, "AXMenuItemCmdModifiers" as CFString) ?? 0
            let markChar = strAttr(child, "AXMenuItemMarkChar" as CFString)

            result.append(
                AXMenuItem(
                    title: title,
                    path: childPath,
                    isEnabled: boolAttr(child, kAXEnabledAttribute as CFString) ?? true,
                    element: child,
                    children: subItems,
                    isAppleMenu: false,
                    shortcutChar: shortcutChar?.isEmpty == false ? shortcutChar : nil,
                    shortcutModifiers: shortcutModifiers,
                    isChecked: markChar?.isEmpty == false
                )
            )
        }
        return result
    }

    nonisolated private func statusMenuDisplayName(
        owner: NSRunningApplication,
        labels: [String],
        menuItems: [AXMenuItem]
    ) -> String {
        for item in menuItems {
            let normalized = AppMenuCapabilityCache.normalize(item.title)
            guard normalized.hasPrefix("quit ") else { continue }
            let suffix = item.title
                .dropFirst(5)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if suffix.count >= 2 { return suffix }
        }
        for label in labels {
            let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
            let normalized = AppMenuCapabilityCache.normalize(trimmed)
            if normalized.count >= 2,
                !normalized.contains("menu extra"),
                !normalized.contains("status item")
            {
                return trimmed
            }
        }
        return owner.localizedName ?? owner.bundleIdentifier ?? "Menu Bar App"
    }

    nonisolated private func flatten(_ items: [AXMenuItem]) -> [AXMenuItem] {
        var output: [AXMenuItem] = []
        for item in items {
            output.append(item)
            output.append(contentsOf: flatten(item.children))
        }
        return output
    }

    nonisolated private func closeStatusMenu(_ statusItem: AXUIElement, menu: AXUIElement?) {
        if let menu {
            AXUIElementPerformAction(menu, kAXCancelAction as CFString)
        } else {
            AXUIElementPerformAction(statusItem, kAXPressAction as CFString)
        }
        Thread.sleep(forTimeInterval: 0.025)
    }

    nonisolated private func menuContainer(for element: AXUIElement) -> AXUIElement? {
        var ref: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, "AXMenu" as CFString, &ref) == .success,
            let menu = ref
        {
            return unsafeBitCast(menu, to: AXUIElement.self)
        }
        if let children = childElements(of: element) {
            for child in children {
                let role = strAttr(child, kAXRoleAttribute as CFString) ?? ""
                if role == "AXMenu" { return child }
            }
        }
        return nil
    }

    nonisolated private func activeMenuContainer(in systemElement: AXUIElement) -> AXUIElement? {
        if let focused = elementAttribute(systemElement, kAXFocusedUIElementAttribute as CFString),
            let menu = menuContainer(for: focused) ?? firstDescendantMenu(in: focused)
        {
            return menu
        }
        if let windows = elementArrayAttribute(systemElement, kAXWindowsAttribute as CFString) {
            for window in windows {
                if let menu = menuContainer(for: window) ?? firstDescendantMenu(in: window) {
                    return menu
                }
            }
        }
        if let menus = elementArrayAttribute(systemElement, "AXMenus" as CFString),
            let first = menus.first
        {
            return first
        }
        return nil
    }

    nonisolated private func firstDescendantMenu(in element: AXUIElement, depth: Int = 0) -> AXUIElement? {
        guard depth < 4,
            let children = childElements(of: element)
        else { return nil }
        for child in children {
            let role = strAttr(child, kAXRoleAttribute as CFString) ?? ""
            if role == "AXMenu" { return child }
            if let found = firstDescendantMenu(in: child, depth: depth + 1) {
                return found
            }
        }
        return nil
    }

    nonisolated private func statusMenuBarItems(in element: AXUIElement) -> [AXUIElement] {
        var result: [AXUIElement] = []
        func walk(_ node: AXUIElement, depth: Int) {
            guard depth < 4 else { return }
            let role = strAttr(node, kAXRoleAttribute as CFString) ?? ""
            let subrole = strAttr(node, kAXSubroleAttribute as CFString) ?? ""
            if role == "AXMenuBarItem" || role == "AXButton" || subrole == "AXStatusItem" {
                result.append(node)
            }
            guard let children = childElements(of: node) else { return }
            for child in children {
                walk(child, depth: depth + 1)
            }
        }
        walk(element, depth: 0)
        return result
    }

    nonisolated private func childElements(of element: AXUIElement) -> [AXUIElement]? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &ref)
            == .success
        else { return nil }
        return ref as? [AXUIElement]
    }

    nonisolated private func elementAttribute(_ element: AXUIElement, _ attr: CFString) -> AXUIElement? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attr, &ref) == .success,
            let value = ref
        else { return nil }
        return unsafeBitCast(value, to: AXUIElement.self)
    }

    nonisolated private func elementArrayAttribute(_ element: AXUIElement, _ attr: CFString) -> [AXUIElement]? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attr, &ref) == .success else { return nil }
        return ref as? [AXUIElement]
    }

    nonisolated private func strAttr(_ element: AXUIElement, _ attr: CFString) -> String? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attr, &ref) == .success,
            let value = ref
        else { return nil }
        if let string = value as? String { return string }
        if let attributed = value as? NSAttributedString { return attributed.string }
        return nil
    }

    nonisolated private func boolAttr(_ element: AXUIElement, _ attr: CFString) -> Bool? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attr, &ref) == .success else { return nil }
        return (ref as? NSNumber)?.boolValue
    }

    nonisolated private func intAttr(_ element: AXUIElement, _ attr: CFString) -> Int? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attr, &ref) == .success else { return nil }
        return (ref as? NSNumber)?.intValue
    }
}
