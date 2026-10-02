import Foundation
import Testing

@testable import Context_Dock

/// What the model is told about what could and could not be read from the app in front.
///
/// Asked "what does this page say, and what's my latest message?" in the Claude desktop app,
/// the chat answered "Page text not readable ... Want me to re-read page?": no app named, no
/// cause, and an offer that would return the same nothing. The host supplies facts; the model
/// answers in its own words. These pin the facts and the instruction, with injected values:
/// no live accessibility, no OS permission query, no shared singleton driven.
@MainActor
@Suite("Readability facts")
struct ReadabilityFactsTests {

    private static let claudeBundle = "com.anthropic.claudefordesktop"
    private static let ownersQuestion = "what does this page say, and what's my latest message?"

    private var appWithText: ReadabilityFacts {
        ReadabilityFacts(
            appName: "Notes", bundleId: "com.apple.Notes", windowTitle: "Shopping list",
            axTextCharacterCount: 240)
    }

    private var appWithNothing: ReadabilityFacts {
        ReadabilityFacts(
            appName: "Claude", bundleId: Self.claudeBundle, windowTitle: "Claude",
            axTextCharacterCount: 0)
    }

    private var permissionMissing: ReadabilityFacts {
        ReadabilityFacts(
            appName: "Claude", bundleId: Self.claudeBundle, windowTitle: "Claude",
            axTextCharacterCount: 0,
            missingPermissions: ReadabilityPermissions(
                accessibilityGranted: false, screenRecordingGranted: true
            ).missing)
    }

    // MARK: The three fixtures

    @Test func anAppWithTextSaysItWasRead() {
        let facts = appWithText
        #expect(facts.hasReadableText)
        #expect(facts.reason == nil)
        #expect(
            facts.block() == """
                ## What I could and could not read (facts, read just now)
                - Frontmost app: Notes (com.apple.Notes)
                - Window title: "Shopping list" (readable)
                - Text that reached DoraX: 240 characters (selection or web page)
                - Missing permission: none
                Verdict: text from Notes was read; answer from it and say which part you used.
                """)
    }

    @Test func anAppThatExposesNothingSaysWhatItCanSeeAndWhy() {
        let facts = appWithNothing
        #expect(!facts.hasReadableText)
        #expect(facts.reason == .appExposesNoText)
        #expect(
            facts.block() == """
                ## What I could and could not read (facts, read just now)
                - Frontmost app: Claude (com.anthropic.claudefordesktop)
                - Window title: "Claude" (readable)
                - Text that reached DoraX: none (DoraX reads only your selection or a web page; nothing like that is available from Claude)
                - Missing permission: none
                Verdict: the content of Claude is NOT available to me; only the window title "Claude" is readable, because DoraX only reads your selection or a web page and there is none right now. Next step: select the text and ask again, or paste it.
                """)
    }

    @Test func aMissingPermissionIsNamedWithWhereToGrantIt() {
        let facts = permissionMissing
        #expect(facts.reason == .permissionMissing(.accessibility))
        let block = facts.block()
        #expect(
            block.contains(
                "- Missing permission: Accessibility (System Settings ▸ Privacy & Security ▸ Accessibility)"
            ))
        #expect(block.contains("Next step: grant Accessibility in System Settings"))
        #expect(!block.contains("there is none right now"))
    }

    /// TextEdit has text on screen but nothing is selected. The host only knows no text
    /// reached DoraX; it must not claim the app cannot expose text, nor blame accessibility.
    @Test func anAppWithTextButNoSelectionIsNotSaidToExposeNothing() {
        let facts = ReadabilityFacts(
            appName: "TextEdit", bundleId: "com.apple.TextEdit", windowTitle: "Untitled",
            axTextCharacterCount: 0)
        let all = facts.block() + "\n" + facts.guidance()
        #expect(!all.contains("exposes no text"))
        #expect(!all.contains("none exposed"))
        #expect(!all.lowercased().contains("accessibility"))
        #expect(all.contains("select the text"))
        #expect(all.contains("paste"))
        #expect(all.contains("DoraX only reads your selection or a web page"))
    }

    // MARK: Screenshot and OCR

    @Test func ocrThatFoundNothingIsSaidPlainlyAndIsNotAFailure() {
        var facts = appWithNothing
        facts.screenshotTaken = true
        facts.ocrCharacterCount = 0
        #expect(facts.reason == .ocrFoundNothing)
        #expect(facts.block().contains("- Screenshot: taken; OCR found 0 characters"))
        #expect(facts.guidance().contains("screenshot OCR found no text"))
    }

    @Test func ocrThatFailedIsNotReportedAsNoText() {
        var facts = appWithNothing
        facts.screenshotTaken = true
        facts.ocrFailureReason = "the image could not be decoded"
        #expect(facts.reason == .ocrFailed("the image could not be decoded"))
        let block = facts.block()
        #expect(block.contains("- Screenshot: taken; OCR failed (the image could not be decoded)"))
        #expect(!block.contains("OCR found 0 characters"))
    }

    @Test func textFromOCRCountsAsReadable() {
        var facts = appWithNothing
        facts.screenshotTaken = true
        facts.ocrCharacterCount = 90
        #expect(facts.hasReadableText)
        #expect(facts.reason == nil)
    }

    @Test func theThreeOCROutcomesAreDescribedDifferently() {
        let read = OCROutcome.recognized("hello").summary(label: "pasted-1.png")
        let none = OCROutcome.nothingFound.summary(label: "pasted-1.png")
        let failed = OCROutcome.failed(reason: "the image could not be decoded")
            .summary(label: "pasted-1.png")
        #expect(read.contains("read 5 characters"))
        #expect(none.contains("found no text"))
        #expect(none.contains("not a failure"))
        #expect(failed.contains("could not run"))
        #expect(failed.contains("do not say it has none"))
        #expect(Set([read, none, failed]).count == 3)
        #expect(OCROutcome.nothingFound.text.isEmpty)
        #expect(OCROutcome.failed(reason: "x").characterCount == 0)
    }

    // MARK: Where the facts come from

    @Test func aResolvedAppWithNoSelectionOrPageHasNoReadableText() {
        var resolved = ResolvedContext(
            scope: .app(bundleId: Self.claudeBundle), appName: "Claude",
            bundleId: Self.claudeBundle)
        resolved.slots = [.init(name: "window", value: "Claude", source: "AX")]
        let facts = ContextResolver.readabilityFacts(
            for: resolved, permissions: .allGranted)
        #expect(facts.windowTitle == "Claude")
        #expect(facts.axTextCharacterCount == 0)
        #expect(facts.reason == .appExposesNoText)
    }

    @Test func aResolvedSelectionCountsAsAccessibilityText() {
        var resolved = ResolvedContext(
            scope: .app(bundleId: "com.apple.Notes"), appName: "Notes",
            bundleId: "com.apple.Notes")
        resolved.slots = [
            .init(name: "window", value: "Shopping list", source: "AX"),
            .init(name: "selection", value: "milk and eggs", source: "AX snapshot"),
        ]
        let facts = ContextResolver.readabilityFacts(
            for: resolved, permissions: .allGranted)
        #expect(facts.axTextCharacterCount == "milk and eggs".count)
        #expect(facts.reason == nil)
    }

    @Test func theFactsRideInTheResolvedPromptBlock() {
        var resolved = ResolvedContext(
            scope: .app(bundleId: Self.claudeBundle), appName: "Claude",
            bundleId: Self.claudeBundle)
        resolved.slots = [.init(name: "window", value: "Claude", source: "AX")]
        resolved.readability = ContextResolver.readabilityFacts(
            for: resolved,
            permissions: ReadabilityPermissions(
                accessibilityGranted: false, screenRecordingGranted: true))
        let block = resolved.promptBlock()
        #expect(block.contains("## What I could and could not read"))
        #expect(block.contains("Missing permission: Accessibility"))
    }

    @Test func theDockSnapshotBlockCarriesTheFactsToo() {
        let snapshot = ContextSnapshot(
            frontmostApp: "Claude", bundleIdentifier: Self.claudeBundle,
            windowTitle: "Claude", selectedText: nil, selectedTextSource: nil,
            selectedTextCharacterCount: 0, selectedFiles: [], currentDirectory: nil,
            browserContext: nil, menuCapabilities: [], registeredCapabilities: [])
        let block = AIContextBuilder.shared.liveContextBlock(
            snapshot, query: Self.ownersQuestion, permissions: .allGranted)
        #expect(block.contains("- Window: Claude"))
        #expect(block.contains("- Frontmost app: Claude (\(Self.claudeBundle))"))
        #expect(block.contains("Text that reached DoraX: none"))
        #expect(block.contains("DoraX only reads your selection or a web page"))
        #expect(!block.contains("none exposed"))
    }

    // MARK: The instruction

    @Test func theInstructionAsksForTheAppTheReadablePartsTheReasonAndANextStep() {
        let text = ReadabilityFacts.instruction.lowercased()
        #expect(text.contains("name the app that is in front"))
        #expect(text.contains("what is readable"))
        #expect(text.contains("give the reason"))
        #expect(text.contains("one concrete next step"))
        #expect(text.contains("select the text and ask again"))
        #expect(text.contains("paste it"))
        #expect(text.contains("grant the named permission"))
    }

    @Test func theInstructionForbidsAPointlessReRead() {
        let text = ReadabilityFacts.instruction
        #expect(text.contains("Never offer to re-read"))
        #expect(text.contains("a second read returns the same nothing"))
    }

    @Test func theOwnersSentenceInAClaudeAppScopeCarriesTheInstruction() {
        // Owner's question, Claude app in front. The identity block is what both shells send.
        let full = ScopedAppPromptBuilder.appIdentityBlock(
            bundleId: Self.claudeBundle, appName: "Claude", query: Self.ownersQuestion,
            windowTitle: "Claude")
        #expect(full.contains("Frontmost window title: \"Claude\""))
        #expect(full.contains(ReadabilityFacts.instruction))
        #expect(full.contains("This chat is scoped to Claude"))

        // The on-device prompt is compact and keeps the rule.
        let compact = ScopedAppPromptBuilder.appIdentityBlock(
            bundleId: Self.claudeBundle, appName: "Claude", query: Self.ownersQuestion,
            compact: true, windowTitle: "Claude")
        #expect(compact.contains(ReadabilityFacts.instruction))

        // And the facts that go with it name Claude, not "the page".
        let verdict = appWithNothing.guidance()
        #expect(verdict.contains("Claude"))
        #expect(!verdict.lowercased().contains("re-read"))
        #expect(!verdict.contains("this page"))
    }
}
