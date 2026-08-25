import Foundation
import Testing

@testable import Context_Dock

// The Safari adapter's canonical question set.
//
// Safari needs a variant of group one. For Reminders and Mail, grounding means forcing a live
// read before the model answers. Here the equivalent decision is which *path* the turn takes:
// a page-reading question gets a fresh snapshot and deliberately no tools at all
// (BrowserPageUnderstandingIntent), because handing the model the tool catalogue let it choose
// app.menu.click and repeat tools until the step limit on a question no menu can improve.
//
// That makes the matcher load-bearing in both directions. Too narrow and a page question is
// answered by a model clicking menus; too wide and a request that genuinely needs a tool is
// routed to a path that has none, where the only outcomes are answering from the wrong
// evidence or refusing.

@MainActor
struct SafariAdapterEvalTests {

    private static let bundleId = "com.apple.Safari"

    // MARK: - Page questions take the answer-only path

    @Test func readingTheOpenPageNeedsNoTools() {
        for query in [
            "summarise this page",
            "explain the page",
            "what is this article about?",
            "what are the key points of this page?",
            "describe this website",
        ] {
            #expect(
                BrowserPageUnderstandingIntent.matches(query),
                "\"\(query)\" is answerable from a page snapshot and must not be given tools")
        }
    }

    // MARK: - Requests that need a tool must keep one

    /// The answer-only path has no tools, so anything routed there that needs one cannot
    /// succeed — it either answers from the page snapshot, which is the wrong evidence, or
    /// reports that it could not identify the page, which is not what was asked.
    @Test func requestsThatNeedACapabilityAreNotRoutedToTheToollessPath() {
        for query in [
            "find this page in my bookmarks",
            "bookmark this page",
            "what tabs do i have open?",
            "show me my history from today",
            "open the downloads folder",
        ] {
            #expect(
                !BrowserPageUnderstandingIntent.matches(query),
                "\"\(query)\" needs a capability, but the tool-less page path would take it")
        }
    }

    // MARK: - Questions that name no page at all

    /// The matcher requires the sentence to name the page. A question about something else
    /// entirely must not be swallowed just because Safari happens to be in front.
    @Test func unrelatedQuestionsAreNotPageReads() {
        for query in ["what's 2+2?", "hi hello?", "what do i need to finish today?"] {
            #expect(!BrowserPageUnderstandingIntent.matches(query))
        }
    }

    // MARK: - Consequence is declared

    /// Every browser capability is a read. Safari has no write capability at all — operating
    /// the browser goes through the menu route, which AppMenuConsentStore gates.
    @Test func everyBrowserCapabilityIsAFreeRead() {
        let registry = CapabilityRegistry.shared
        for id in ["browser.history", "browser.bookmarks", "browser.tabs", "browser.currentPage"]
        {
            guard let capability = registry.capability(id: id) else {
                Issue.record("\(id) is not registered"); continue
            }
            #expect(!capability.riskLevel.requiresApproval, "\(id) is a read but asks approval")
        }
    }

    /// Reading someone's browsing history and bookmarks is a privacy boundary even though it
    /// changes nothing, so these must stay declared reads rather than quietly becoming writes.
    @Test func noBrowserCapabilityWrites() {
        let writes = CapabilityRegistry.shared.all.filter {
            $0.id.hasPrefix("browser.") && $0.riskLevel.requiresApproval
        }
        #expect(
            writes.isEmpty,
            "browser capabilities that now require approval: \(writes.map(\.id).joined(separator: ", "))")
    }

    // MARK: - Absence stays a finding

    /// Verbatim from the scoped turn: when no snapshot is available it says so, and explicitly
    /// refuses to substitute history or remembered tabs. That is a finding, not a shrug.
    @Test func aMissingSnapshotIsReportedNotSubstituted() {
        let answer = "I couldn't identify the current browser page from live data. "
            + "I did not use browser history or remembered tabs as a substitute. "
            + "For Safari, open the page and activate the Context Dock extension, then try again."
        #expect(
            !EvidenceSufficiency.admitsDefeat(answer),
            "this names the failed source and what to do — retrying it would repeat the same read")
    }
}
