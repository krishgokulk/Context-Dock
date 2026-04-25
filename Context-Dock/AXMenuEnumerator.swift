import AppKit
import Foundation

struct AXMenuItemInfo: Identifiable, Codable, Equatable {
    let id: UUID
    let title: String
    let fullPath: String   // e.g., "File > New Tab"
    let enabled: Bool
    let shortcutDisplay: String?  // e.g., "⌘T"
}

final class AXMenuEnumerator {
    static let shared = AXMenuEnumerator()

    private init() {}

    func enumerateMenuItemsForFrontmostApp() -> [AXMenuItemInfo] {
        guard let frontmostApp = NSWorkspace.shared.frontmostApplication else { return [] }
        return enumerateMenuItems(for: frontmostApp.processIdentifier)
    }

    func enumerateMenuItems(for pid: pid_t) -> [AXMenuItemInfo] {
        guard let menuBar = menuBarElement(for: pid) else { return [] }

        var results: [AXMenuItemInfo] = []
        var seenPaths = Set<String>()
        recurse(menuElement: menuBar, currentPath: [], results: &results, seenPaths: &seenPaths)
        return results
    }

    // MARK: - Private

    private func recurse(menuElement: AXUIElement,
                         currentPath: [String],
                         results: inout [AXMenuItemInfo],
                         seenPaths: inout Set<String>) {
        var childRef: AnyObject?
        guard AXUIElementCopyAttributeValue(menuElement, "AXChildren" as CFString, &childRef) == .success,
              let children = childRef as? [AXUIElement] else { return }

        for child in children {
            guard let title = stringAttr(child, "AXTitle"), !title.isEmpty else { continue }

            let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || trimmed == "-" || trimmed == "separator" { continue }

            if let role = stringAttr(child, "AXRole"), role == "AXMenuItemRole",
               trimmed == "-" { continue }

            let enabled = boolAttr(child, "AXEnabled") ?? true
            let fullPath = (currentPath + [trimmed]).joined(separator: " > ")
            guard !seenPaths.contains(fullPath) else { continue }
            seenPaths.insert(fullPath)

            var shortcutDisplay: String? = nil
            if let cmdChar = stringAttr(child, "AXMenuItemCmdChar"), !cmdChar.isEmpty {
                let mods = intAttr(child, "AXMenuItemCmdModifiers") ?? 0
                shortcutDisplay = shortcutString(for: cmdChar, modifiers: mods)
            }

            results.append(AXMenuItemInfo(
                id: UUID(),
                title: trimmed,
                fullPath: fullPath,
                enabled: enabled,
                shortcutDisplay: shortcutDisplay
            ))

            // Recurse into submenu
            var subRef: AnyObject?
            if AXUIElementCopyAttributeValue(child, "AXChildren" as CFString, &subRef) == .success,
               let sub = subRef as? [AXUIElement], !sub.isEmpty {
                recurse(menuElement: child, currentPath: currentPath + [trimmed],
                        results: &results, seenPaths: &seenPaths)
            } else if AXUIElementCopyAttributeValue(child, "AXMenu" as CFString, &subRef) == .success,
                      let subMenu = subRef as! AXUIElement? {
                recurse(menuElement: subMenu, currentPath: currentPath + [trimmed],
                        results: &results, seenPaths: &seenPaths)
            }
        }
    }

    // MARK: - Attribute helpers

    private func menuBarElement(for pid: pid_t) -> AXUIElement? {
        let appElement = AXUIElementCreateApplication(pid)
        if let bar = elementAttr(appElement, "AXMenuBar") {
            return bar
        }

        let systemWide = AXUIElementCreateSystemWide()
        if let focusedApp = elementAttr(systemWide, kAXFocusedApplicationAttribute as String) {
            var focusedPID: pid_t = 0
            AXUIElementGetPid(focusedApp, &focusedPID)
            if focusedPID == pid, let bar = elementAttr(focusedApp, "AXMenuBar") {
                return bar
            }
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
}
