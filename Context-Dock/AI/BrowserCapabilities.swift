// BrowserCapabilities.swift
// Context-Dock
//
// The two things a browser question needed and could not ask for.
//
// `LocalDataCapabilities` already registers the browser reads — `browser.history`,
// `browser.bookmarks`, `browser.tabs`, `browser.currentPage` — and `SafariAdapterEvalTests`
// holds the line they were built on: every browser capability is a *read*, because operating
// the browser goes through the menu route where `AppMenuConsentStore` gates it. Nothing here
// changes that. A first draft of this file added a page-script capability at `.medium` and
// the contract test caught it, which is the test doing exactly its job.
//
// What was missing is narrower than "the browser": searching the page the user is looking at,
// and opening a link that page contains. Both were reachable only through keyword classifiers
// chosen before the model spoke — `isSafariPageLinkOpenQuery` recognised three verbs, so on
// 2026-09-10 "launch troubleshoot page from this page" was refused while the app had every
// piece needed to do it. A classifier fails absolutely; a capability lets the model ask.
//
// Opening a link is a read's natural end and stays `.low`: the dock already opens page links
// without an approval when its own classifier fires, and a capability must not be more
// dangerous than the button beside it. Anything that *changes* a page still belongs to
// `BrowserActionAuthor`, which shows the script and keeps it.

import AppKit
import Foundation

@MainActor
enum BrowserCapabilities {

    static func register(in registry: CapabilityRegistry) {
        registerFindInPage(in: registry)
        registerOpenURL(in: registry)
    }

    // MARK: - Which browser

    /// The browser this call is about: the scoped or frontmost one when it is a browser,
    /// Safari when it is not.
    ///
    /// A capability call carries no scope of its own, and "whichever app is frontmost" is
    /// Context Dock itself while the dock has the keyboard — which is where every one of
    /// these questions is asked from.
    static func resolvedBrowserBundleID() -> String {
        let frontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
        if !frontmost.isEmpty, frontmost != Bundle.main.bundleIdentifier,
            ScopedAppPromptBuilder.isBrowserBundle(frontmost)
        {
            return frontmost
        }
        if let previous = AppDelegate.shared?.previousFrontmostApp?.bundleIdentifier,
            ScopedAppPromptBuilder.isBrowserBundle(previous)
        {
            return previous
        }
        return "com.apple.Safari"
    }

    private static func isBrowserRunning(_ bundleID: String) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }

    // MARK: - Find in page

    private static func registerFindInPage(in registry: CapabilityRegistry) {
        registry.register(AICapability(
            id: "browser.findInPage",
            title: "Find Text on the Current Page",
            appBundleID: nil,
            inputSchema: AICapabilityInputSchema(fields: [
                AICapabilityInputField(
                    name: "text",
                    description:
                        "What to look for in the page's readable text and its links — a "
                        + "word, a name, \"social\", a domain.",
                    required: true),
            ]),
            riskLevel: .low
        ) { request in
            let needle = (request.input["text"] ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !needle.isEmpty else {
                return AICapabilityExecutionResult(
                    success: false, output: "browser.findInPage requires text.")
            }
            let bundleID = resolvedBrowserBundleID()
            guard isBrowserRunning(bundleID) else {
                return AICapabilityExecutionResult(
                    success: false, output: "No browser is running.")
            }
            // The same block scoped chat is grounded with — compacted around this term
            // rather than around the first five thousand characters, and carrying the
            // page's links, which is where a question about a destination is answered.
            let block = ScopedGroundingBlocks.browserPage(
                bundleId: bundleID, query: needle, liveURL: nil)
            guard !block.isEmpty else {
                return AICapabilityExecutionResult(
                    success: false,
                    output:
                        "Could not read the current page. The Context Dock Safari extension "
                        + "may be off for this website and the page exposes no accessible "
                        + "text. This is not the same as the text being absent.")
            }
            let hits = matchingLines(in: block, for: needle)
            guard !hits.isEmpty else {
                return AICapabilityExecutionResult(
                    success: true,
                    output: "\"\(needle)\" does not appear in the readable text or the "
                        + "links of the current page.")
            }
            return AICapabilityExecutionResult(
                success: true,
                output: "\(hits.count) line(s) on this page mention \"\(needle)\":\n"
                    + hits.joined(separator: "\n"))
        })
    }

    /// Lines of a page block that mention the term, trimmed and capped.
    ///
    /// Pure and separate so the matching rule is testable without a browser: reading the
    /// page needs Safari, deciding what matched does not.
    static func matchingLines(in block: String, for needle: String, limit: Int = 20)
        -> [String]
    {
        let term = needle.lowercased()
        guard !term.isEmpty else { return [] }
        return block
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && $0.lowercased().contains(term) }
            .prefix(limit)
            .map { String($0.prefix(300)) }
    }

    // MARK: - Open a URL the page or the tab list gave

    private static func registerOpenURL(in registry: CapabilityRegistry) {
        registry.register(AICapability(
            id: "browser.openURL",
            title: "Open a URL in the Browser",
            appBundleID: nil,
            inputSchema: AICapabilityInputSchema(fields: [
                AICapabilityInputField(
                    name: "url",
                    description:
                        "The exact URL to open. Use one read from the page, the tab list, "
                        + "history or bookmarks — never a guessed address.",
                    required: true),
            ]),
            riskLevel: .low
        ) { request in
            let raw = (request.input["url"] ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !raw.isEmpty else {
                return AICapabilityExecutionResult(
                    success: false, output: "browser.openURL requires a url.")
            }
            // http(s) only. A capability that opened `file://` or `javascript:` would be a
            // way to reach the disk and to run script, through a door labelled "open a
            // link the page already has".
            guard let url = URL(string: raw), let scheme = url.scheme?.lowercased(),
                scheme == "http" || scheme == "https"
            else {
                return AICapabilityExecutionResult(
                    success: false,
                    output: "\"\(raw)\" is not an http(s) URL, so nothing was opened.")
            }
            // Switching to a tab that is already open beats opening a second copy of it,
            // which is what "go to the docs" means when the docs are already open.
            SafariTabManager.shared.switchToOpenTabOrOpenURL(url.absoluteString)
            return AICapabilityExecutionResult(
                success: true, output: "Opened \(url.absoluteString).")
        })
    }
}
