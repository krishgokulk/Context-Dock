import Testing
@testable import Context_Dock

struct BrowserPageUnderstandingIntentTests {
    @Test func recognizesUnderstandingRequestAsReadOnlyPageIntent() {
        #expect(BrowserPageUnderstandingIntent.matches(
            "Understand this page and tell me what it installs."))
        #expect(BrowserPageUnderstandingIntent.matches("Extract the key points from this article"))
    }

    @Test func doesNotTreatPageOperationAsUnderstandingOnly() {
        #expect(!BrowserPageUnderstandingIntent.matches("Install this into my VS Code project"))
        #expect(!BrowserPageUnderstandingIntent.matches("Click the download button on this page"))
        #expect(!BrowserPageUnderstandingIntent.matches("Minimize Safari"))
    }
}
