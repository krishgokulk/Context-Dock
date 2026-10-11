import Foundation
import Testing

@testable import Context_Dock

// Reading a page once per version, and never reading the wrong one.
//
// Three questions about one page used to pay three full reads: extraction, compaction and tokens,
// for a page that had not changed. And nothing stopped a read of a bank page — which mattered
// little while reading was passive, and matters completely now that a chat can navigate and click.

@MainActor
struct BrowserPageCacheTests {

    private func cache() -> BrowserPageCache { BrowserPageCache() }

    @Test func aPageIsRememberedByWhatItSaid() {
        let store = cache()
        store.store(url: "https://docs.brew.sh/", title: "Homebrew", text: "Install with curl.")
        #expect(store.cached(url: "https://docs.brew.sh/")?.title == "Homebrew")
    }

    @Test func aChangedPageIsNotTheSamePage() {
        // Same URL is not same page on anything that updates itself, and a stale answer is
        // worse than a slow one.
        let store = cache()
        store.store(url: "https://example.com/", title: "Dash", text: "3 builds failing")
        #expect(store.cached(url: "https://example.com/", freshText: "1 build failing") == nil)
    }

    @Test func aSecondQuestionReusesWhatWasRead() {
        let store = cache()
        store.store(
            url: "https://example.com/", title: "Pricing",
            text: "Free tier. Pro is $19.99 a month. Enterprise on request.")
        store.rememberSummary("A pricing page: free, Pro at $19.99, enterprise on request.",
                              url: "https://example.com/")

        let grounding = store.groundingText(
            url: "https://example.com/", query: "how much is pro", limit: 2_000)
        #expect(grounding?.contains("read earlier this conversation") == true)
        #expect(grounding?.contains("$19.99") == true)
    }

    @Test func theFirstQuestionStillGetsThePage() {
        // No summary yet — the compacted page, exactly as before this cache existed.
        let store = cache()
        store.store(url: "https://example.com/", title: "T", text: "Body about widgets.")
        let grounding = store.groundingText(
            url: "https://example.com/", query: "widgets", limit: 2_000)
        #expect(grounding?.contains("read earlier this conversation") == false)
        #expect(grounding?.contains("widgets") == true)
    }

    @Test func anUnreadPageHasNothingToGiveBack() {
        #expect(cache().groundingText(url: "https://nope.example/", query: "x", limit: 100) == nil)
    }

    @Test func itStaysAWorkingSetRatherThanAHistory() {
        let store = cache()
        for index in 0..<40 {
            store.store(url: "https://example.com/\(index)", title: "t", text: "body \(index)")
        }
        #expect(store.count <= 20)
    }

    @Test func aSummaryIsCappedSoItCannotBecomeThePage() {
        let store = cache()
        store.store(url: "https://example.com/", title: "T", text: "Body.")
        store.rememberSummary(String(repeating: "x", count: 5_000), url: "https://example.com/")
        #expect((store.cached(url: "https://example.com/")?.summary?.count ?? 0) <= 1_200)
    }
}

struct SensitivePageGuardTests {

    @Test func moneyPagesAreRefused() {
        for url in [
            "https://www.chase.com/accounts",
            "https://secure.barclays.co.uk/",
            "https://checkout.stripe.com/pay/cs_live_123",
            "https://shop.example.com/checkout",
        ] {
            #expect(SensitivePageGuard.refusal(for: url) != nil, "\(url)")
        }
    }

    @Test func credentialPagesAreRefused() {
        for url in [
            "https://accounts.google.com/signin",
            "https://my.1password.com/vaults",
            "https://example.com/login",
        ] {
            #expect(SensitivePageGuard.refusal(for: url) != nil, "\(url)")
        }
    }

    @Test func anAddressThatIsItselfACredentialIsRefused() {
        // A magic-link URL is the credential. Reading it is handing it over.
        #expect(
            SensitivePageGuard.refusal(
                for: "https://app.example.com/callback?code=abcd1234efgh5678")
                == .tokenInURL)
        #expect(
            SensitivePageGuard.refusal(
                for: "https://example.com/#access_token=ya29.a0ARrdaM9xxxxxxxxxxxx")
                == .tokenInURL)
    }

    @Test func aShortValueIsNotAToken() {
        // `?code=gb` is a country, not a credential — refusing it would refuse half the web.
        #expect(SensitivePageGuard.allows("https://example.com/prices?code=gb"))
    }

    @Test func aPasswordFieldIsEnoughOnItsOwn() {
        #expect(
            SensitivePageGuard.refusal(for: "https://example.com/", hasPasswordField: true)
                == .passwordField)
    }

    @Test func ordinaryPagesAreFine() {
        for url in [
            "https://docs.brew.sh/",
            "https://webkit.org/blog/18136/introducing-the-safari-mcp-server-for-web-developers/",
            "https://github.com/dtDhruv/ytkew",
        ] {
            #expect(SensitivePageGuard.allows(url), "\(url)")
        }
    }

    @Test func theUsersOwnDenylistWins() {
        #expect(
            SensitivePageGuard.refusal(
                for: "https://mail.example.com/inbox", userDenylist: ["mail.example.com"])
                == .userDenied("mail.example.com"))
    }

    @Test func aRefusalExplainsWithoutQuotingThePage() {
        // Printing the token to explain why the token is dangerous is the harm it avoids.
        let reason = SensitivePageGuard.refusal(
            for: "https://app.example.com/callback?code=abcd1234efgh5678")
        #expect(reason?.message.contains("abcd1234") == false)
        #expect(reason?.message.contains("sign-in token") == true)
    }
}

struct BrowserActionGateTests {

    @Test func readingIsFree() {
        for tool in ["get_page_content", "list_tabs", "page_info", "browser_console_messages"] {
            #expect(BrowserActionGate.decide(tool: tool, arguments: [:]) == .allow, "\(tool)")
        }
    }

    @Test func everyNavigationIsAsked() {
        // The owner's call: per navigation, not per host. A site can link anywhere, and
        // "I allowed this site" is not "I allowed wherever this site sends me".
        let decision = BrowserActionGate.decide(
            tool: "navigate_to_url", arguments: ["url": "https://example.com/docs"])
        guard case .askFirst(_, let detail) = decision else {
            Issue.record("navigation was not gated")
            return
        }
        #expect(detail == "https://example.com/docs")
    }

    @Test func scriptIsAskedWithTheScriptShown() {
        let decision = BrowserActionGate.decide(
            tool: "evaluate_javascript", arguments: ["script": "document.title"])
        guard case .askFirst(let what, let detail) = decision else {
            Issue.record("evaluate_javascript was not gated")
            return
        }
        #expect(what.contains("JavaScript"))
        #expect(detail == "document.title")
    }

    @Test func aSensitiveDestinationIsRefusedRatherThanOffered() {
        // An approval card naming a bank is an invitation to click through.
        let decision = BrowserActionGate.decide(
            tool: "navigate_to_url", arguments: ["url": "https://www.chase.com/login"])
        guard case .refuse = decision else {
            Issue.record("a bank page was offered for approval")
            return
        }
    }

    @Test func anUnknownToolIsGatedRatherThanAllowed() {
        // A tool Apple adds later must be asked about by default, not let through because
        // nobody remembered to list it.
        let decision = BrowserActionGate.decide(tool: "some_future_tool", arguments: [:])
        #expect(decision != .allow)
    }
}

@MainActor
struct BrowsedPageIndexTests {

    private func index() -> BrowsedPageIndex {
        BrowsedPageIndex(
            fileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("browsed-\(UUID().uuidString).json"))
    }

    @Test func itKeepsWhatAPageWasAboutRatherThanWhatItSaid() {
        let store = index()
        store.record(
            url: "https://docs.brew.sh/", title: "Homebrew Documentation",
            question: "how do I update a cask")
        let line = store.groundingLine(for: "homebrew cask update")
        #expect(line?.contains("Homebrew Documentation") == true)
        #expect(line?.contains("how do I update a cask") == true)
    }

    @Test func aRefusedPageIsNotEvenNoted() {
        // Not reading something and then recording that it existed is not a boundary anybody
        // would recognise as one.
        let store = index()
        store.record(url: "https://www.chase.com/", title: "Bank", question: "balance")
        #expect(store.pages.isEmpty)
    }

    @Test func theSameQuestionTwiceIsOneFact() {
        let store = index()
        store.record(url: "https://example.com/", title: "T", question: "what is this")
        store.record(url: "https://example.com/", title: "T", question: "what is this")
        #expect(store.pages.count == 1)
    }

    @Test func clearingLeavesNothing() {
        let store = index()
        store.record(url: "https://example.com/", title: "T", question: "q")
        store.clear()
        #expect(store.pages.isEmpty)
        #expect(store.groundingLine(for: "q") == nil)
    }
}
