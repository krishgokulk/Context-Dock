import Testing
import Foundation
@testable import Context_Dock

// MARK: - AIProvider Codable tests
// AIProvider is stored in AppSettings (UserDefaults). If encode/decode breaks,
// the user's provider selection is silently reset to the default on next launch.

struct AIProviderCodableTests {

    @Test func allProvidersRoundTripThroughJSON() throws {
        for provider in AIProvider.allCases {
            let data = try JSONEncoder().encode(provider)
            let decoded = try JSONDecoder().decode(AIProvider.self, from: data)
            #expect(decoded == provider, "Failed round-trip for \(provider)")
        }
    }

    @Test func rawValueIdentityIsStable() {
        // Raw values are persisted to disk — changing them is a breaking change.
        #expect(AIProvider.onDevice.rawValue == "onDevice")
        #expect(AIProvider.anthropic.rawValue == "anthropic")
        #expect(AIProvider.openAI.rawValue == "openAI")
        #expect(AIProvider.googleGemini.rawValue == "googleGemini")
        #expect(AIProvider.ollama.rawValue == "ollama")
        #expect(AIProvider.openAICompatible.rawValue == "openAICompatible")
        #expect(AIProvider.shortcuts.rawValue == "shortcuts")
        #expect(AIProvider.claudeBridge.rawValue == "claudeBridge")
        #expect(AIProvider.chatGPTBridge.rawValue == "chatGPTBridge")
    }

    @Test func displayNamesAreNonEmpty() {
        for provider in AIProvider.allCases {
            #expect(!provider.displayName.isEmpty, "displayName empty for \(provider)")
            #expect(!provider.shortName.isEmpty, "shortName empty for \(provider)")
        }
    }

    @Test func decodesFromStoredRawValues() throws {
        // Simulate reading a value previously written to UserDefaults as a raw string
        let json = "\"anthropic\"".data(using: .utf8)!
        let decoded = try JSONDecoder().decode(AIProvider.self, from: json)
        #expect(decoded == .anthropic)
    }
}

// MARK: - DetectedContext description tests
// description is shown in the UI; regressions here cause blank/wrong labels.

struct DetectedContextTests {

    @Test func filesDescriptionSingular() {
        let ctx = DetectedContext.files([URL(fileURLWithPath: "/tmp/test.pdf")])
        #expect(ctx.description == "1 file selected")
    }

    @Test func filesDescriptionPlural() {
        let urls = [URL(fileURLWithPath: "/tmp/a.pdf"), URL(fileURLWithPath: "/tmp/b.txt")]
        let ctx = DetectedContext.files(urls)
        #expect(ctx.description == "2 files selected")
    }

    @Test func textDescriptionCountsWords() {
        let ctx = DetectedContext.text("hello world foo")
        #expect(ctx.description.contains("3"))
    }

    @Test func browserTabDescriptionUsesTitle() {
        let ctx = DetectedContext.browserTab(url: "https://apple.com", title: "Apple")
        #expect(ctx.description == "Apple")
    }

    @Test func browserTabEmptyTitleFallsBack() {
        let ctx = DetectedContext.browserTab(url: "https://apple.com", title: "")
        #expect(ctx.description == "Current tab")
    }

    @Test func musicDescriptionContainsTitle() {
        let ctx = DetectedContext.music(title: "Bohemian Rhapsody", artist: "Queen", album: "A Night at the Opera")
        #expect(ctx.description.contains("Bohemian Rhapsody"))
        #expect(ctx.description.contains("Queen"))
    }

    @Test func clipboardDescriptionContainsPreview() {
        let ctx = DetectedContext.clipboard("hello clipboard")
        #expect(ctx.description.contains("hello clipboard"))
    }

    @Test func emailDescriptionUsesSubject() {
        let ctx = DetectedContext.email(subject: "Meeting tomorrow", from: "boss@example.com", content: "...")
        #expect(ctx.description == "Meeting tomorrow")
    }

    @Test func appDescriptionIsName() {
        let ctx = DetectedContext.app(bundleID: "com.apple.safari", name: "Safari")
        #expect(ctx.description == "Safari")
    }
}
