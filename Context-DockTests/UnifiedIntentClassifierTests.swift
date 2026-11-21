// UnifiedIntentClassifierTests.swift
// Context-DockTests

import Testing

@testable import Context_Dock

@Suite("Unified intent classifier")
struct UnifiedIntentClassifierTests {

    // MARK: - Navigational (default)

    @Test("Single keyword is navigational")
    func singleKeyword() {
        #expect(UnifiedIntentClassifier.classify("safari") == .navigational)
    }

    @Test("Two-word app name is navigational")
    func twoWordApp() {
        #expect(UnifiedIntentClassifier.classify("visual studio") == .navigational)
    }

    @Test("Empty query is navigational")
    func emptyQuery() {
        #expect(UnifiedIntentClassifier.classify("") == .navigational)
    }

    @Test("Whitespace-only query is navigational")
    func whitespaceOnly() {
        #expect(UnifiedIntentClassifier.classify("   ") == .navigational)
    }

    // MARK: - Conversational

    @Test("Question word prefix triggers conversational")
    func questionPrefix() {
        #expect(UnifiedIntentClassifier.classify("how to export a PDF") == .conversational)
    }

    @Test("Trailing question mark triggers conversational")
    func questionMark() {
        #expect(UnifiedIntentClassifier.classify("is dark mode on?") == .conversational)
    }

    @Test("Directive verb triggers conversational")
    func directiveVerb() {
        #expect(UnifiedIntentClassifier.classify("explain this error") == .conversational)
    }

    @Test("More than three words without file extension is conversational")
    func longNaturalLanguage() {
        #expect(UnifiedIntentClassifier.classify("turn off the notifications") == .conversational)
    }

    @Test("'draft reply to' is conversational")
    func draftReply() {
        #expect(UnifiedIntentClassifier.classify("draft reply to John") == .conversational)
    }

    @Test("'tell me about' is conversational")
    func tellMe() {
        #expect(UnifiedIntentClassifier.classify("tell me about memory usage") == .conversational)
    }

    @Test("isConversational helper matches classify")
    func isConversationalHelper() {
        #expect(UnifiedIntentClassifier.isConversational("how do I save"))
        #expect(!UnifiedIntentClassifier.isConversational("safari"))
    }

    // MARK: - Explicit File

    @Test("File extension triggers explicit file")
    func fileExtension() {
        #expect(UnifiedIntentClassifier.classify("resume.pdf") == .explicitFile)
    }

    @Test("Path prefix triggers explicit file")
    func pathPrefix() {
        #expect(UnifiedIntentClassifier.classify("~/Downloads") == .explicitFile)
    }

    @Test("Absolute path triggers explicit file")
    func absolutePath() {
        #expect(UnifiedIntentClassifier.classify("/Applications/Safari.app") == .explicitFile)
    }

    @Test("Extension mid-query triggers explicit file")
    func extensionMidQuery() {
        #expect(UnifiedIntentClassifier.classify("resume.pdf from yesterday") == .explicitFile)
    }

    @Test("Swift file is explicit file")
    func swiftFile() {
        #expect(UnifiedIntentClassifier.classify("AppDelegate.swift") == .explicitFile)
    }

    // MARK: - Web Research

    @Test("'vs' between terms triggers web research")
    func vsComparison() {
        #expect(UnifiedIntentClassifier.classify("vim vs emacs") == .webResearch)
    }

    @Test("'latest' triggers web research")
    func latestKeyword() {
        #expect(UnifiedIntentClassifier.classify("latest macOS news") == .webResearch)
    }

    @Test("'search' prefix triggers web research")
    func searchPrefix() {
        #expect(UnifiedIntentClassifier.classify("search swift concurrency") == .webResearch)
    }

    @Test("'google' prefix triggers web research")
    func googlePrefix() {
        #expect(UnifiedIntentClassifier.classify("google swift package manager") == .webResearch)
    }

    @Test("'weather' triggers web research")
    func weather() {
        #expect(UnifiedIntentClassifier.classify("tokyo weather today") == .webResearch)
    }

    // MARK: - Priority: file > conversational

    @Test("File extension wins over conversational length")
    func fileOverConversational() {
        #expect(UnifiedIntentClassifier.classify("how to open resume.pdf in preview") == .explicitFile)
    }

    // MARK: - Scoring constants

    @Test("Conversational file penalty is -100")
    func penaltyConstant() {
        #expect(UnifiedIntentClassifier.conversationalFilePenalty == -100)
    }

    @Test("Frontmost app boost is 500")
    func boostConstant() {
        #expect(UnifiedIntentClassifier.frontmostAppBoost == 500)
    }

    @Test("Explicit file boost is 50")
    func fileBoostConstant() {
        #expect(UnifiedIntentClassifier.explicitFileBoost == 50)
    }
}
