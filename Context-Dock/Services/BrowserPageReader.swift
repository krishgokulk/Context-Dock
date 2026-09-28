// BrowserPageReader.swift
// Context-Dock
//
// The page a browser is showing, read once, the way the chat has always read it: the Safari
// Web Extension's payload while it is fresh (reliable URL, readable text, no automation
// prompt), and the accessibility snapshot for other browsers or a disabled extension.
//
// Lifted out of `ScopedGroundingBlocks.browserPage` so the Safari actions ("Save as
// Markdown", "Ask AI about this page") read the page through the same door the chat does,
// instead of a second reader that could disagree with it about what is on screen.

import AppKit
import Foundation

/// What was read off the page in front of the user.
struct BrowserPageSnapshot: Equatable {
    var url: String
    var title: String
    var text: String
    var selectedText: String = ""
    var links: [SafariPageLink] = []
    /// Set when `SensitivePageGuard` refused the page: the reader then keeps nothing of it
    /// but its origin, so no caller can hand its text, title or links to a model.
    var withheld: SensitivePageGuard.Reason? = nil

    var isEmpty: Bool { text.isEmpty && url.isEmpty }

    /// Why DoraX stays out of this page, or nil when it may read it.
    var refusal: SensitivePageGuard.Reason? {
        withheld ?? SensitivePageGuard.refusal(for: url)
    }
}

@MainActor
enum BrowserPageReader {

    /// The page in `bundleId`'s front window, or nil when nothing could be read.
    ///
    /// - Parameter liveURL: the URL the caller already knows, used to refresh a stale
    ///   accessibility snapshot. A caller without one passes nil.
    static func current(bundleId: String, liveURL: String? = nil) -> BrowserPageSnapshot? {
        var page = BrowserPageSnapshot(url: "", title: "", text: "")

        if SafariBrowserBridge.shared.isFresh,
            let context = SafariBrowserBridge.shared.currentContext()
        {
            page.title = context.title
            page.url = context.url
            page.text = context.pageText
            page.selectedText = context.selectedText
            page.links = context.links
        }

        // The accessibility snapshot, for other browsers and for a disabled extension. The
        // process is resolved from the scoped bundle id first: reading whichever app was
        // last frontmost answers about the wrong window whenever the question is asked from
        // somewhere other than the dock.
        if page.text.isEmpty {
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
                page.text = snapshot?.text ?? ""
                if page.url.isEmpty {
                    page.url = snapshot?.url.isEmpty == false
                        ? (snapshot?.url ?? currentURL) : currentURL
                }
                if page.title.isEmpty { page.title = snapshot?.title ?? "" }
            }
        }
        return page.isEmpty ? nil : guarded(page)
    }

    /// Pure: `page` as a prompt may carry it. A page the guard refuses keeps only its origin
    /// (`https://host`) and the reason — no title, text, selection, links, path or query,
    /// since a token-bearing address is itself the secret.
    static func guarded(_ page: BrowserPageSnapshot) -> BrowserPageSnapshot {
        guard page.withheld == nil, let reason = SensitivePageGuard.refusal(for: page.url)
        else { return page }
        return BrowserPageSnapshot(
            url: origin(of: page.url), title: "", text: "", withheld: reason)
    }

    /// Pure: scheme and host of `urlString`, dropping path, query and fragment.
    static func origin(of urlString: String) -> String {
        guard var parts = URLComponents(string: urlString), parts.host != nil else {
            return ""
        }
        parts.path = ""
        parts.query = nil
        parts.fragment = nil
        parts.user = nil
        parts.password = nil
        return parts.string ?? ""
    }
}
