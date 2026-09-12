// ScopedGroundingBlocks.swift
// Context-Dock
//
// What an app-scoped chat knows about an app beyond its list of capabilities.
//
// The dock built three of these on LauncherView — the workspace the app is working in, the
// vendor's own documentation for it, and the page a browser is currently on — and the chat
// window could not reach any of them, because LauncherView's state dies with the launcher.
// So the dock could answer "what did I just commit" and "what does this setting do" and the
// window, asked the same thing about the same app, could only describe its own tool
// inventory.
//
// Nothing here needs a view. They read singletons, which either surface can reach.

import AppKit
import Foundation

@MainActor
enum ScopedGroundingBlocks {

    /// Live state of the workspace this scope is working in — the project, its branch and
    /// changes, the agents running in it. A co-worker knows the state of the work before
    /// being asked about it.
    static func workspace(
        bundleId: String, appName: String, forceRefresh: Bool = false
    ) async -> String {
        guard !bundleId.isEmpty else { return "" }
        // The window title of the app being asked about, read for that app rather than taken
        // from whichever app the shared snapshot belongs to — in a chat window the launcher
        // or the window itself is frontmost, so the shared snapshot is never the right one.
        let windowTitle = ContextResolver.axContext(for: bundleId, appName: appName).windowTitle
        let finderFolder = bundleId == ChatAppDirectory.finderBundleID
            ? AppleAppsAPI.shared.getCurrentFolder() : nil
        let identity = AppWorkspaceService.identity(
            bundleId: bundleId,
            appName: appName,
            windowTitle: windowTitle,
            finderFolder: finderFolder)
        return await AppWorkspaceService.shared.contextBlock(
            for: identity,
            linkedCLIs: runnableCommandBinaries(forBundleId: bundleId),
            forceRefresh: forceRefresh)
    }

    /// What the vendor documents about this app, fetched fresh when the question is about
    /// the product rather than about the machine.
    static func reference(bundleId: String, appName: String, query: String) async -> String {
        guard !bundleId.isEmpty else { return "" }
        let references = await AppReferenceIndex.shared.references(
            bundleId: bundleId, appName: appName)
        guard !references.isEmpty else { return "" }

        var lines = ["## \(appName) references"]
        lines += references.map { "- \($0.kind.label): \($0.title) — \($0.url)" }

        // "What can this app do" is answered from the app's own documentation, one link
        // deeper than its homepage — the features and the FAQ are never on the front page.
        // Without this the model had a homepage blurb and a menu list, and answered with the
        // menu list, which describes every Mac app and this one not at all.
        if AppReferenceIndex.describesTheProduct(query),
            let digest = await AppReferenceIndex.shared.documentationDigest(
                bundleId: bundleId, appName: appName, query: query)
        {
            let age = RelativeDateTimeFormatter().localizedString(
                for: digest.syncedAt, relativeTo: Date())
            lines += [
                "",
                "### What \(appName) says about itself (read \(age) from \(digest.sourceURL))",
                digest.text,
                "",
                "Answer from this, and cite the page. A list of menu commands is NOT a "
                    + "description of what an app does — never answer \"what does this app "
                    + "do\" with its menu bar.",
            ]
            return lines.joined(separator: "\n")
        }

        // Reading a page costs a network round trip, so only a question that is actually
        // about the product pays for it — and only for the one page it names.
        if AppReferenceIndex.looksLikeReferenceQuestion(query),
            let best = AppReferenceIndex.bestReference(for: query, in: references)
                ?? references.first(where: { $0.kind == .documentation }),
            let snapshot = await AppReferenceIndex.shared.pageSnapshot(
                for: best, bundleId: bundleId, query: query, limit: 4_000)
        {
            let age = RelativeDateTimeFormatter().localizedString(
                for: snapshot.syncedAt, relativeTo: Date())
            lines += [
                "",
                "### Current content of \(best.title) (\(best.url))",
                snapshot.text,
                "",
                "Reference freshness: synced \(age) via \(snapshot.converter).",
                "Prefer this cached official text over recalled knowledge, and cite the link "
                    + "when the answer comes from it.",
            ]
        }
        return lines.joined(separator: "\n")
    }

    /// The page a browser scope is on: title, URL, selection, readable text and the links
    /// that text drops.
    ///
    /// - Parameter liveURL: the URL the caller already knows. The dock reads this from its
    ///   own live context; a caller without one leaves it nil and the browser is asked.
    static func browserPage(
        bundleId: String, query: String? = nil, liveURL: String? = nil
    ) -> String {
        guard ScopedAppPromptBuilder.isBrowserBundle(bundleId) else { return "" }

        var pageTitle = ""
        var pageURL = ""
        var pageText = ""
        var selected = ""
        var links: [SafariPageLink] = []

        // The Safari Web Extension payload — reliable URL, readable page text, no automation
        // prompt — when it is fresh enough to be describing the page on screen now.
        if SafariBrowserBridge.shared.isFresh,
            let context = SafariBrowserBridge.shared.currentContext()
        {
            pageTitle = context.title
            pageURL = context.url
            pageText = context.pageText
            selected = context.selectedText
            links = context.links
        }

        // The accessibility snapshot, for other browsers and for a disabled extension. The
        // process is resolved from the scoped bundle id first: reading whichever app was
        // last frontmost answers about the wrong window whenever the question is asked from
        // somewhere other than the dock.
        if pageText.isEmpty {
            let browser = NSRunningApplication
                .runningApplications(withBundleIdentifier: bundleId).first
                ?? AppDelegate.shared?.previousFrontmostApp
            if let browser {
                let pid = browser.processIdentifier
                let currentURL = liveURL ?? ""
                var snapshot = AXWebReader.shared.cachedSnapshot(for: pid)
                if snapshot?.text.isEmpty != false || snapshot?.isStale == true,
                    !currentURL.isEmpty
                {
                    AXWebReader.shared.refresh(pid: pid, currentURL: currentURL)
                    snapshot = AXWebReader.shared.cachedSnapshot(for: pid)
                }
                pageText = snapshot?.text ?? ""
                if pageURL.isEmpty {
                    pageURL = snapshot?.url.isEmpty == false ? (snapshot?.url ?? currentURL) : currentURL
                }
                if pageTitle.isEmpty { pageTitle = snapshot?.title ?? "" }
            }
        }

        // Every other tab the browser has open. `dorax_browser_tabs` has always been exposed
        // over MCP to other agents, while DoraX's own turn got the front page and nothing
        // else — so "which tab has the invoice" was unanswerable by any provider, and
        // unanswerable at all by one with no tools.
        let tabsSection = openTabsSection(bundleId: bundleId, activeURL: pageURL)

        guard !pageText.isEmpty || !pageURL.isEmpty || !tabsSection.isEmpty else { return "" }
        // The extension already strips browser chrome; this is the same query-aware compactor
        // documents get. Re-fetching the URL would be slower, could see a different
        // signed-out page, and would discard the user's live selection.
        if !pageText.isEmpty {
            pageText = MarkItDownService.compact(pageText, for: query, limit: 5_000)
        }

        let selectedSection = selected.isEmpty
            ? "" : "\nSELECTED TEXT:\n\(String(selected.prefix(1500)))"
        // Where the page can take the user. Page text drops every href, so a download or
        // docs button reads as an ordinary word — and the model then says it cannot find one.
        let linkSection: String = {
            guard !links.isEmpty else { return "" }
            let rows = links.prefix(30).map { "- \($0.text) → \($0.url)" }
            return """

                PAGE LINKS (action links first, as they appear on the page):
                \(rows.joined(separator: "\n"))
                Use these exact URLs when the answer is a page to open — never invent one, \
                and never tell the user to hunt for a button that is listed here.
                """
        }()

        // Tabs sit above the page's own text so the two never run together: the evidence
        // parser reads everything after `PAGE TEXT EXCERPT:` as page text, and a tab list
        // below it would be counted as characters the page does not have.
        return """
            CURRENT PAGE TITLE: \(pageTitle.isEmpty ? "(unknown)" : pageTitle)
            CURRENT PAGE URL: \(pageURL.isEmpty ? "(unknown)" : pageURL)\(selectedSection)\(tabsSection)
            \(pageText.isEmpty
                ? "PAGE TEXT: (unavailable — could not read the page)"
                : "PAGE TEXT EXCERPT:\n\(String(pageText.prefix(5000)))")\(linkSection)
            """
    }

    /// Every tab the scoped browser has open, with the one the page block describes marked
    /// active. Empty when the browser exposes none, so the caller can tell "no tabs" from
    /// "a tab list that happens to be short".
    static func openTabsSection(bundleId: String, activeURL: String) -> String {
        let tabs = openTabs(bundleId: bundleId)
        guard !tabs.isEmpty else { return "" }
        return Self.formatTabs(tabs, activeURL: activeURL)
    }

    /// Pure formatter, so the shape of the block is testable without a running browser.
    ///
    /// Rows deliberately avoid the `- [` prefix and the ` → ` arrow that
    /// `BrowserPageReadEvidence` uses to recognise a page link; a tab counted as a link
    /// would report evidence the page does not contain.
    static func formatTabs(_ tabs: [BrowserTab], activeURL: String, limit: Int = 40) -> String {
        guard !tabs.isEmpty else { return "" }
        let rows = tabs.prefix(limit).map { tab -> String in
            let title = tab.title.isEmpty ? tab.url : tab.title
            let active = !activeURL.isEmpty && tab.url == activeURL ? " (active — the page above)" : ""
            return "- \(title) — \(tab.url)\(active)"
        }
        let more = tabs.count > limit
            ? "\n…and \(tabs.count - limit) more open tabs, not listed."
            : ""
        return """


            OPEN TABS (\(tabs.count) open in this browser):
            \(rows.joined(separator: "\n"))\(more)
            These are open right now. A question about another tab is answered from this list, \
            with its exact URL — never say a tab cannot be seen when it is named here.
            """
    }

    /// The scoped browser's tabs, cached briefly. One turn asks for the page block several
    /// times — the chat, `read_page`, `browser.findInPage` — and each read is an AppleScript
    /// round trip into the browser, so without this a single question enumerates every tab
    /// three or four times.
    static func openTabs(bundleId: String) -> [BrowserTab] {
        if let cached = tabCache[bundleId], Date().timeIntervalSince(cached.readAt) < 15 {
            return cached.tabs
        }
        // Only ask a browser that is actually running: AppleScript to a stopped app launches
        // it, and a grounding read must never open a browser the user closed.
        guard NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).isEmpty == false
        else { return [] }
        let detector = ContextDetector.shared
        let tabs: [BrowserTab]
        switch bundleId {
        case "com.apple.Safari":
            tabs = detector.getAllSafariTabs()
        case "com.google.Chrome", "com.brave.Browser", "org.chromium.Chromium",
            "com.microsoft.edgemac":
            tabs = detector.getAllChromeTabs()
        case "company.thebrowser.Browser":
            tabs = detector.getAllArcTabs()
        default:
            tabs = []
        }
        tabCache[bundleId] = (tabs, Date())
        return tabs
    }

    private static var tabCache: [String: (tabs: [BrowserTab], readAt: Date)] = [:]

    /// Binaries this scope may run: the scope's own executable when it is a CLI thread, the
    /// packages linked to the app, and any CLI actions its adapter installs.
    static func runnableCommandBinaries(forBundleId bundleId: String) -> Set<String> {
        guard !bundleId.isEmpty else { return [] }
        var allowed: Set<String> = []
        if let own = ScopedAppPromptBuilder.cliCommand(forScopeBundleID: bundleId) {
            allowed.insert(own.lowercased())
        }
        for package in TerminalPackageManager.shared.packages
        where package.isEnabled && package.contextAppBundleIds.contains(bundleId) {
            allowed.insert(package.command.lowercased())
        }
        if let adapter = AppAdapterManager.shared.adapter(for: bundleId) {
            for action in adapter.actions where action.type == .cliTool {
                let command = (action.cliToolCommand ?? "")
                    .split(separator: " ").first.map(String.init) ?? ""
                if !command.isEmpty { allowed.insert(command.lowercased()) }
            }
        }
        return allowed
    }
}
