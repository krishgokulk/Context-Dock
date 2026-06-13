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

        guard
            let field = await openSearchUIAndResolveField(
                bundleId: bundleId, appName: appName, pid: pid)
        else {
            return QueryFailureGuide.shared.instant(
                for: .axFieldNotFound(appName: appName),
                originalQuery: query
            )
        }

        let injected = await injectQuery(
            query,
            into: field,
            pid: pid,
            bundleId: bundleId,
            submitAfterInjection: submitsSearchAfterInjection(bundleId: bundleId)
        )
        guard injected else {
            return QueryFailureGuide.shared.instant(
                for: .axFieldNotFound(appName: appName),
                originalQuery: query
            )
        }
        return "✅ Searching for \"\(query)\" in \(appName)"
    }

    // MARK: - Stage 1: Open Search UI (shortcut ladder)

    private struct SearchShortcut {
        let key: CGKeyCode
        let modifiers: CGEventFlags
    }

    /// Per-app primary shortcut followed by generic fallbacks. Each rung is
    /// tried and verified (did a search field appear/focus?) before moving on,
    /// so apps with non-standard shortcuts still resolve.
    private func searchShortcutLadder(bundleId: String) -> [SearchShortcut] {
        let cmdF = SearchShortcut(key: 3, modifiers: .maskCommand)
        let cmdK = SearchShortcut(key: 40, modifiers: .maskCommand)
        let cmdL = SearchShortcut(key: 37, modifiers: .maskCommand)
        let cmdOptF = SearchShortcut(key: 3, modifiers: [.maskCommand, .maskAlternate])
        let cmdShiftF = SearchShortcut(key: 3, modifiers: [.maskCommand, .maskShift])
        let cmdP = SearchShortcut(key: 35, modifiers: .maskCommand)

        let primary: [SearchShortcut]
        switch bundleId {
        case "com.apple.mail":
            // Cmd+Option+F focuses the mailbox search bar (Cmd+F opens in-message Find)
            primary = [cmdOptF]
        case "com.apple.Safari", "com.google.Chrome", "org.mozilla.firefox",
            "com.brave.Browser", "com.microsoft.edgemac", "company.thebrowser.Browser":
            // Browser content search means web search, not in-page Find.
            primary = [cmdL]
        case "com.microsoft.VSCode", "com.microsoft.VSCodeInsiders":
            // Workspace search. Cmd+F only searches current editor.
            primary = [cmdShiftF]
        case "com.spotify.client":
            // Spotify focuses its search box with Cmd+K (older builds: Cmd+L).
            primary = [cmdK, cmdL]
        case "com.tinyspeck.slackmacgap", "com.hnc.Discord", "com.discordapp.Discord":
            primary = [cmdK]
        case "notion.id":
            primary = [cmdP]
        default:
            primary = [cmdF]
        }

        var ladder = primary
        for fallback in [cmdF, cmdK, cmdL, cmdOptF] {
            if !ladder.contains(where: {
                $0.key == fallback.key && $0.modifiers == fallback.modifiers
            }) {
                ladder.append(fallback)
            }
        }
        return ladder
    }

    /// Apps with a curated primary shortcut where the menu route would be wrong
    /// (e.g. browsers: Edit > Find is in-page find; app search is the URL bar).
    private func hasCuratedSearchShortcut(bundleId: String) -> Bool {
        switch bundleId {
        case "com.apple.Safari", "com.google.Chrome", "org.mozilla.firefox",
            "com.brave.Browser", "com.microsoft.edgemac", "company.thebrowser.Browser",
            "com.microsoft.VSCode", "com.microsoft.VSCodeInsiders",
            "com.spotify.client":
            return true
        default:
            return false
        }
    }

    /// Find the app's own canonical search command from its cached menu
    /// snapshot — "Mailbox Search" (Mail), "Note List Search…" (Notes), plain
    /// "Search"/"Find…" elsewhere. Clicking the app's declared item beats
    /// guessing shortcuts: it's correct per app by definition.
    private func menuDerivedSearchOpeners(bundleId: String, appName: String) -> [[String]] {
        let excludedTitles: Set<String> = [
            "find next", "find previous", "find again", "find and replace",
            "use selection for find", "jump to selection", "jump to top",
            "hide find banner", "replace", "find selection",
        ]

        func score(_ item: AXMenuItem) -> Int? {
            let title = AppMenuCapabilityCache.normalize(item.title)
            guard !title.isEmpty, !excludedTitles.contains(title) else { return nil }
            let root = item.path.first.map(AppMenuCapabilityCache.normalize) ?? ""
            // Every app has Help > Search — that one searches the Help menu, never content.
            guard root != "help" else { return nil }
            if title.contains("search") {
                // Named searches ("mailbox search", "note list search") are the
                // app's primary search surface — strongest signal.
                return title == "search" ? 90 : 100
            }
            if title == "find" { return 60 }
            return nil
        }

        var seen = Set<String>()
        var scored: [(path: [String], score: Int)] = []
        for query in ["search", "find"] {
            let items = GlobalContextEngine.shared.cachedMenuItems(
                bundleIdentifier: bundleId,
                appName: appName,
                query: query,
                maxResults: 24
            )
            for item in items {
                guard let value = score(item) else { continue }
                let key = item.path.joined(separator: ">")
                guard seen.insert(key).inserted else { continue }
                scored.append((item.path, value))
            }
        }
        return scored.sorted { $0.score > $1.score }.map(\.path)
    }

    /// Open the app's search UI: app-declared menu item first (unless the app
    /// has a curated shortcut), then the shortcut ladder, then a bare field scan.
    private func openSearchUIAndResolveField(
        bundleId: String,
        appName: String,
        pid: pid_t
    ) async -> AXUIElement? {
        if !hasCuratedSearchShortcut(bundleId: bundleId) {
            let openers = menuDerivedSearchOpeners(bundleId: bundleId, appName: appName)
            for path in openers.prefix(2) {
                let clicked = await MainActor.run {
                    AXMenuReader.shared.clickMenuItem(path: path, in: pid)
                }
                guard clicked else { continue }
                try? await Task.sleep(nanoseconds: 200_000_000)
                if let field = await resolveSearchField(pid: pid, attempts: 3) {
                    return field
                }
            }
        }

        for (index, shortcut) in searchShortcutLadder(bundleId: bundleId).enumerated() {
            sendKey(shortcut.key, modifiers: shortcut.modifiers, pid: pid)
            try? await Task.sleep(nanoseconds: 200_000_000)
            // First rung gets more patience (app may animate its search UI in).
            if let field = await resolveSearchField(pid: pid, attempts: index == 0 ? 4 : 2) {
                return field
            }
        }
        // Last resort: a visible search field that doesn't need a shortcut at all.
        return walkForSearchField(AXUIElementCreateApplication(pid), depth: 0)
    }

    // MARK: - Stage 2: Resolve Search Field

    private func resolveSearchField(pid: pid_t, attempts: Int = 4) async -> AXUIElement? {
        for attempt in 0..<max(1, attempts) {
            if attempt > 0 { try? await Task.sleep(nanoseconds: 120_000_000) }
            let axApp = AXUIElementCreateApplication(pid)
            // Prefer a real search field in the window over the currently-focused
            // element: apps like Messages keep the message-compose box focused, so
            // focused-first would paste the query into the conversation instead of
            // the search box. Fall back to the focused field only if no dedicated
            // search field exists.
            if let field = walkForSearchField(axApp, depth: 0)
                ?? focusedSearchField(axApp)
                ?? focusedPlainField(axApp)
            {
                return field
            }
        }
        return nil
    }

    /// Absolute last resort: the focused element if it is an editable field at
    /// all. Used only when no labelled search field exists anywhere.
    private func focusedPlainField(_ axApp: AXUIElement) -> AXUIElement? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXFocusedUIElementAttribute as CFString, &ref) == .success,
              let r = ref else { return nil }
        let el = unsafeBitCast(r, to: AXUIElement.self)
        var roleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &roleRef)
        let role = roleRef as? String ?? ""
        guard safeRoles.contains(role), role != "AXSecureTextField" else { return nil }
        return el
    }

    /// The focused element, accepted only when it is itself a genuine search
    /// field (real AXSearchField role or search-labelled) — never a plain
    /// focused text/compose field.
    private func focusedSearchField(_ axApp: AXUIElement) -> AXUIElement? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXFocusedUIElementAttribute as CFString, &ref) == .success,
              let r = ref else { return nil }
        let el = unsafeBitCast(r, to: AXUIElement.self)
        return isSearchLabelledField(el) ? el : nil
    }

    /// Finds a labelled search field anywhere in the tree. Strict: only genuine
    /// search fields match — never a focused compose/text field.
    private func walkForSearchField(_ element: AXUIElement, depth: Int) -> AXUIElement? {
        guard depth < 12 else { return nil }
        if isSearchLabelledField(element) { return element }
        var childRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childRef) == .success,
              let children = childRef as? [AXUIElement] else { return nil }
        // Prefer a dedicated AXSearchField before recursing deeper.
        for child in children {
            var cr: CFTypeRef?
            AXUIElementCopyAttributeValue(child, kAXRoleAttribute as CFString, &cr)
            if (cr as? String) == "AXSearchField" { return child }
        }
        for child in children {
            if let found = walkForSearchField(child, depth: depth + 1) { return found }
        }
        return nil
    }

    /// A genuine search field: dedicated AXSearchField role, or a text field
    /// whose description/identifier/placeholder reads as search. No focus
    /// fallback — so a focused compose box never qualifies.
    private func isSearchLabelledField(_ element: AXUIElement) -> Bool {
        var roleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef)
        let role = roleRef as? String ?? ""
        guard safeRoles.contains(role), role != "AXSecureTextField" else { return false }
        if role == "AXSearchField" { return true }
        // AXTextField with search subrole also counts.
        var subroleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subroleRef)
        if (subroleRef as? String) == "AXSearchField" { return true }

        let metadata = ["AXDescription", "AXIdentifier", "AXPlaceholderValue", "AXRoleDescription"]
            .compactMap { attr -> String? in
                var ref: CFTypeRef?
                return AXUIElementCopyAttributeValue(element, attr as CFString, &ref) == .success
                    ? ref as? String : nil
            }
            .joined(separator: " ")
            .lowercased()
        return searchKeywords.contains(where: { metadata.contains($0) })
    }


    // MARK: - Stage 3: Inject (Hybrid)

    private func injectQuery(
        _ query: String,
        into field: AXUIElement,
        pid: pid_t,
        bundleId: String,
        submitAfterInjection: Bool
    ) async -> Bool {
        AXUIElementSetAttributeValue(field, kAXFocusedAttribute as CFString, true as CFTypeRef)

        // Sync NSFindPboard so native macOS Find commands stay consistent
        let findBoard = NSPasteboard(name: .find)
        findBoard.clearContents()
        findBoard.setString(query, forType: .string)

        // Web/Electron fields (Spotify, Slack, Discord, VS Code, …): a direct
        // AXValue write updates the pixels but not the framework's internal
        // state (React-style controlled inputs), so the app never actually
        // searches. Paste generates real input events — always use it there.
        if prefersPasteInjection(bundleId: bundleId, field: field) {
            return await pasteQuery(
                query, into: field, pid: pid,
                submitAfterInjection: submitAfterInjection)
        }

        let axResult = AXUIElementSetAttributeValue(field, kAXValueAttribute as CFString, query as CFTypeRef)

        if axResult == .success {
            try? await Task.sleep(nanoseconds: 60_000_000)
            guard fieldValue(field) == query else {
                return await pasteQuery(
                    query, into: field, pid: pid,
                    submitAfterInjection: submitAfterInjection)
            }
            // Nudge the app to refresh results — some AppKit search fields only
            // re-query on an input event even when AXValue is set programmatically
            sendKey(submitAfterInjection ? 36 : 125, modifiers: [], pid: pid) // Return / Down arrow
            return true
        } else {
            return await pasteQuery(
                query, into: field, pid: pid,
                submitAfterInjection: submitAfterInjection)
        }
    }

    private let pastePreferredBundleIds: Set<String> = [
        "com.spotify.client",
        "com.tinyspeck.slackmacgap",
        "com.hnc.Discord",
        "com.discordapp.Discord",
        "com.microsoft.VSCode",
        "com.microsoft.VSCodeInsiders",
        "notion.id",
        "com.figma.Desktop",
        "com.whatsapp.WhatsApp",
        "org.telegram.desktop",
    ]

    private func prefersPasteInjection(bundleId: String, field: AXUIElement) -> Bool {
        if pastePreferredBundleIds.contains(bundleId) { return true }
        return hasWebAreaAncestor(field)
    }

    private func hasWebAreaAncestor(_ element: AXUIElement) -> Bool {
        var current = element
        for _ in 0..<12 {
            var parentRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(
                current, kAXParentAttribute as CFString, &parentRef) == .success,
                let parentRef
            else { return false }
            let parent = unsafeBitCast(parentRef, to: AXUIElement.self)
            var roleRef: CFTypeRef?
            AXUIElementCopyAttributeValue(parent, kAXRoleAttribute as CFString, &roleRef)
            if (roleRef as? String) == "AXWebArea" { return true }
            current = parent
        }
        return false
    }

    private func pasteQuery(
        _ query: String,
        into field: AXUIElement,
        pid: pid_t,
        submitAfterInjection: Bool
    ) async -> Bool {
        AXUIElementSetAttributeValue(field, kAXFocusedAttribute as CFString, true as CFTypeRef)
        let board = NSPasteboard.general
        let saved = board.string(forType: .string)
        board.clearContents()
        board.setString(query, forType: .string)
        sendKey(0, modifiers: .maskCommand, pid: pid) // Cmd+A
        sendKey(9, modifiers: .maskCommand, pid: pid) // Cmd+V
        try? await Task.sleep(nanoseconds: 140_000_000)
        // Web/Electron fields often don't expose AXValue at all — an unreadable
        // value is not a failure; only a readable mismatch is.
        let readBack = fieldValue(field)
        let injected = readBack == nil || readBack == query
        if injected, submitAfterInjection {
            sendKey(36, modifiers: [], pid: pid) // Return
        }
        try? await Task.sleep(nanoseconds: 460_000_000)
        board.clearContents()
        if let saved {
            board.setString(saved, forType: .string)
        }
        return injected
    }

    private func fieldValue(_ field: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            field, kAXValueAttribute as CFString, &value) == .success
        else { return nil }
        return value as? String
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
