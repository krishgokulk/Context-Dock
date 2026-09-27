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

    var isEmpty: Bool { text.isEmpty && url.isEmpty }
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
        return page.isEmpty ? nil : page
    }
}
