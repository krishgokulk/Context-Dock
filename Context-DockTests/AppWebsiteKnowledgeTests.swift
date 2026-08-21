import Testing
import Foundation
@testable import Context_Dock

// MARK: - What the vendor says about their own product
//
// Step 3 of docs/architecture/APP_KNOWLEDGE_SKILLS.md, and the only step that leaves the
// machine. Everything here is therefore built to be refusable: it is off unless the user
// turns it on, it fetches nothing it was not given, and it fetches once per app version.
//
// The URL is never guessed. Deriving "microsoft.com" from com.microsoft.VSCode would send
// a request somewhere the user never named, on the strength of a bundle id. The address
// comes from the adapter the user configured, or there is no fetch.
//
// These cover the parts that are pure: what counts as a fetchable address, how a page
// becomes text, and how much of it is kept.

struct AppWebsiteKnowledgeTests {

    // MARK: - What may be fetched

    @Test func onlyHTTPSAddressesAreFetchable() {
        #expect(AppWebsiteKnowledge.fetchableURL(from: "https://code.visualstudio.com") != nil)
        #expect(AppWebsiteKnowledge.fetchableURL(from: "http://example.com") == nil)
    }

    /// A URL that reaches back into this machine is not a product page. file:// would read
    /// the disk, and localhost is whatever happens to be listening.
    @Test func localAndFileAddressesAreRefused() {
        #expect(AppWebsiteKnowledge.fetchableURL(from: "file:///etc/passwd") == nil)
        #expect(AppWebsiteKnowledge.fetchableURL(from: "https://localhost/admin") == nil)
        #expect(AppWebsiteKnowledge.fetchableURL(from: "https://127.0.0.1/admin") == nil)
        #expect(AppWebsiteKnowledge.fetchableURL(from: "https://0.0.0.0/") == nil)
    }

    @Test func nonsenseIsNotAnAddress() {
        #expect(AppWebsiteKnowledge.fetchableURL(from: "") == nil)
        #expect(AppWebsiteKnowledge.fetchableURL(from: "   ") == nil)
        #expect(AppWebsiteKnowledge.fetchableURL(from: "not a url") == nil)
    }

    // MARK: - Page to text

    @Test func markupBecomesReadableText() {
        let html = "<html><head><title>Ignored</title></head><body>"
            + "<h1>Visual Studio Code</h1><p>Code editing. <b>Redefined.</b></p></body></html>"
        let text = AppWebsiteKnowledge.readableText(fromHTML: html)
        #expect(text.contains("Visual Studio Code"))
        #expect(text.contains("Code editing"))
        #expect(!text.contains("<h1>"))
    }

    /// Script and style bodies are not prose, and they are the bulk of a modern page.
    @Test func scriptsAndStylesAreDropped() {
        let html = "<body><script>var secret = 'tracking';</script>"
            + "<style>.a{color:red}</style><p>Real words</p></body>"
        let text = AppWebsiteKnowledge.readableText(fromHTML: html)
        #expect(text.contains("Real words"))
        #expect(!text.contains("tracking"))
        #expect(!text.contains("color:red"))
    }

    @Test func entitiesAreDecoded() {
        let text = AppWebsiteKnowledge.readableText(fromHTML: "<p>Fast &amp; small &mdash; free</p>")
        #expect(text.contains("Fast & small"))
        #expect(!text.contains("&amp;"))
    }

    @Test func runsOfWhitespaceCollapse() {
        let text = AppWebsiteKnowledge.readableText(fromHTML: "<p>a</p>\n\n\n   <p>b</p>")
        #expect(!text.contains("\n\n\n"))
        #expect(text.contains("a"))
        #expect(text.contains("b"))
    }

    /// A page is context, not a document store. It shares the prompt with everything else
    /// the app knows, so it is capped.
    @Test func pagesAreCapped() {
        let huge = String(repeating: "word ", count: 20_000)
        let text = AppWebsiteKnowledge.readableText(fromHTML: "<p>\(huge)</p>")
        #expect(text.count <= AppWebsiteKnowledge.maximumCharacters)
    }

    // MARK: - Fetching once

    /// Keyed by app version, so a page is fetched once and then not again until the app
    /// updates — not on every launch, and not on every question.
    @Test func theCacheKeyIsTheAppVersion() {
        let a = AppWebsiteKnowledge.cacheKey(bundleId: "com.microsoft.VSCode", version: "1.95.0")
        let b = AppWebsiteKnowledge.cacheKey(bundleId: "com.microsoft.VSCode", version: "1.96.0")
        let c = AppWebsiteKnowledge.cacheKey(bundleId: "com.apple.Safari", version: "1.95.0")
        #expect(a != b)
        #expect(a != c)
        #expect(a == AppWebsiteKnowledge.cacheKey(
            bundleId: "com.microsoft.VSCode", version: "1.95.0"))
    }

    /// The key becomes a filename, so it must never contain a path.
    @Test func cacheKeysAreSafeAsFilenames() {
        let key = AppWebsiteKnowledge.cacheKey(bundleId: "com/../etc", version: "1/0")
        #expect(!key.contains("/"))
        #expect(!key.contains(".."))
    }
}
