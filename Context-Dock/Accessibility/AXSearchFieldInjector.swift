// AXSearchFieldInjector.swift
// Context-Dock
//
// Injects a search query into another app's search field.
//
// Strategy (in order):
//   1. Activate target app and open its search UI (Cmd-F or app-specific)
//   2. Resolve the focused AX element — validate it is a safe search field
//   3. Set AXValue directly (instant, no typing animation) + update NSFindPboard
//   4. If AX set fails, fall back to paste via clipboard (works for Electron / non-AppKit)
//
// AXUIElementSetAttributeValue is an IPC request to the target app, not
// a direct memory write. Some apps accept it and refresh results immediately;
// others need a follow-up input event — handled by the paste fallback.

import AppKit
import ApplicationServices

final class AXSearchFieldInjector {
    static let shared = AXSearchFieldInjector()
    private init() {}

    private let safeRoles: Set<String> = ["AXSearchField", "AXTextField", "AXComboBox", "AXTextArea"]
    private let searchKeywords = ["search", "find", "filter", "query", "look"]

    // MARK: - Public

    func inject(query: String, into app: NSRunningApplication) async -> String {
        let pid     = app.processIdentifier
        let bundleId = app.bundleIdentifier ?? ""
        let appName = app.localizedName ?? bundleId

        _ = app.activate(options: [.activateIgnoringOtherApps])
        await AXActionResolver.waitForActivation(of: app)
        await openSearchUI(bundleId: bundleId, pid: pid)

        guard let field = await resolveSearchField(pid: pid) else {
            return QueryFailureGuide.shared.instant(
                for: .axFieldNotFound(appName: appName),
                originalQuery: query
            )
        }

        injectQuery(
            query,
            into: field,
            pid: pid,
            submitAfterInjection: submitsSearchAfterInjection(bundleId: bundleId)
        )
        return "✅ Searching for \"\(query)\" in \(appName)"
    }

    // MARK: - Stage 1: Open Search UI

    private func openSearchUI(bundleId: String, pid: pid_t) async {
        let fKey: CGKeyCode = 3 // f
        switch bundleId {
        case "com.apple.mail":
            // Cmd+Option+F focuses the mailbox search bar (Cmd+F opens in-message Find)
            sendKey(fKey, modifiers: [.maskCommand, .maskAlternate], pid: pid)
        case "com.apple.Photos":
            // Photos toolbar search is always visible; Cmd+F focuses it
            sendKey(fKey, modifiers: .maskCommand, pid: pid)
        case "com.apple.Safari", "com.google.Chrome", "org.mozilla.firefox":
            // Browser content search means web search, not in-page Find.
            sendKey(37, modifiers: .maskCommand, pid: pid) // Cmd+L
        case "com.microsoft.VSCode":
            // Workspace search. Cmd+F only searches current editor.
            sendKey(fKey, modifiers: [.maskCommand, .maskShift], pid: pid)
        default:
            sendKey(fKey, modifiers: .maskCommand, pid: pid)
        }
        try? await Task.sleep(nanoseconds: 200_000_000)
    }

    // MARK: - Stage 2: Resolve Search Field

    private func resolveSearchField(pid: pid_t) async -> AXUIElement? {
        for attempt in 0..<4 {
            if attempt > 0 { try? await Task.sleep(nanoseconds: 120_000_000) }
            let axApp = AXUIElementCreateApplication(pid)
            if let field = focusedField(axApp) ?? walkForSearchField(axApp, depth: 0) {
                return field
            }
        }
        return nil
    }

    private func focusedField(_ axApp: AXUIElement) -> AXUIElement? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXFocusedUIElementAttribute as CFString, &ref) == .success,
              let r = ref else { return nil }
        let el = unsafeBitCast(r, to: AXUIElement.self)
        return isValidSearchField(el) ? el : nil
    }

    private func walkForSearchField(_ element: AXUIElement, depth: Int) -> AXUIElement? {
        guard depth < 12 else { return nil }
        var roleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef)
        let role = roleRef as? String ?? ""
        if safeRoles.contains(role) && isValidSearchField(element) { return element }
        var childRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childRef) == .success,
              let children = childRef as? [AXUIElement] else { return nil }
        // Prefer AXSearchField in a first pass before recursing
        for child in children {
            var cr: CFTypeRef?
            AXUIElementCopyAttributeValue(child, kAXRoleAttribute as CFString, &cr)
            if (cr as? String) == "AXSearchField", isValidSearchField(child) { return child }
        }
        for child in children {
            if let found = walkForSearchField(child, depth: depth + 1) { return found }
        }
        return nil
    }

    private func isValidSearchField(_ element: AXUIElement) -> Bool {
        var roleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef)
        let role = roleRef as? String ?? ""
        guard safeRoles.contains(role), role != "AXSecureTextField" else { return false }
        if role == "AXSearchField" { return true }

        let metadata = ["AXDescription", "AXIdentifier", "AXPlaceholderValue"]
            .compactMap { attr -> String? in
                var ref: CFTypeRef?
                return AXUIElementCopyAttributeValue(element, attr as CFString, &ref) == .success
                    ? ref as? String : nil
            }
            .joined(separator: " ")
            .lowercased()

        if searchKeywords.contains(where: { metadata.contains($0) }) { return true }

        // Accept the element if the app chose to focus it after Cmd-F
        var focusRef: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXFocusedAttribute as CFString, &focusRef)
        return (focusRef as? Bool) == true
    }

    // MARK: - Stage 3: Inject (Hybrid)

    private func injectQuery(
        _ query: String,
        into field: AXUIElement,
        pid: pid_t,
        submitAfterInjection: Bool
    ) {
        AXUIElementSetAttributeValue(field, kAXFocusedAttribute as CFString, true as CFTypeRef)

        let axResult = AXUIElementSetAttributeValue(field, kAXValueAttribute as CFString, query as CFTypeRef)

        // Sync NSFindPboard so native macOS Find commands stay consistent
        let findBoard = NSPasteboard(name: .find)
        findBoard.clearContents()
        findBoard.setString(query, forType: .string)

        if axResult == .success {
            // Nudge the app to refresh results — some AppKit search fields only
            // re-query on an input event even when AXValue is set programmatically
            sendKey(submitAfterInjection ? 36 : 125, modifiers: [], pid: pid) // Return / Down arrow
        } else {
            pasteQuery(query, pid: pid, submitAfterInjection: submitAfterInjection)
        }
    }

    private func pasteQuery(_ query: String, pid: pid_t, submitAfterInjection: Bool) {
        let board = NSPasteboard.general
        let saved = board.string(forType: .string)
        board.clearContents()
        board.setString(query, forType: .string)
        sendKey(0, modifiers: .maskCommand, pid: pid) // Cmd+A
        sendKey(9, modifiers: .maskCommand, pid: pid) // Cmd+V
        if submitAfterInjection {
            sendKey(36, modifiers: [], pid: pid) // Return
        }
        Task.detached {
            try? await Task.sleep(nanoseconds: 600_000_000)
            await MainActor.run {
                if let saved {
                    board.clearContents()
                    board.setString(saved, forType: .string)
                }
            }
        }
    }

    private func submitsSearchAfterInjection(bundleId: String) -> Bool {
        ["com.apple.Safari", "com.google.Chrome", "org.mozilla.firefox"].contains(bundleId)
    }

    // MARK: - Key event helper

    private func sendKey(_ key: CGKeyCode, modifiers: CGEventFlags, pid: pid_t) {
        let src = CGEventSource(stateID: .hidSystemState)
        let dn  = CGEvent(keyboardEventSource: src, virtualKey: key, keyDown: true)
        let up  = CGEvent(keyboardEventSource: src, virtualKey: key, keyDown: false)
        dn?.flags = modifiers
        up?.flags = modifiers
        dn?.postToPid(pid)
        up?.postToPid(pid)
    }
}
