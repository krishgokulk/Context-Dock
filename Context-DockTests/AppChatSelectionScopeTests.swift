// AppChatSelectionScopeTests.swift
// Context-DockTests

import Testing

@testable import Context_Dock

@Suite("App chat selection scope")
struct AppChatSelectionScopeTests {

    private func context(
        bundleID: String, text: String? = nil, files: [String] = []
    ) -> AXContext {
        var ctx = AXContext(appName: "App", bundleId: bundleID, pid: 1)
        ctx.selectedText = text
        ctx.selectedFilePaths = files
        return ctx
    }

    @Test("Selected text is reported with its length")
    func textSelection() {
        let scope = AppChatSelectionScope.from(
            context: context(bundleID: "com.microsoft.VSCode", text: "let x = 1"),
            scopedTo: "com.microsoft.VSCode")

        #expect(scope?.kind == .text(characters: 9))
    }

    @Test("Selected files win over text, because that is the stronger subject")
    func filesBeatText() {
        let scope = AppChatSelectionScope.from(
            context: context(
                bundleID: "com.apple.finder", text: "ignored", files: ["/a", "/b"]),
            scopedTo: "com.apple.finder")

        #expect(scope?.kind == .files(count: 2))
    }

    @Test("A selection in another app is never attributed to this one")
    func selectionMustBelongToTheScopedApp() {
        let scope = AppChatSelectionScope.from(
            context: context(bundleID: "com.apple.Safari", text: "selected in Safari"),
            scopedTo: "com.microsoft.VSCode")

        #expect(scope == nil)
    }

    @Test("Whitespace alone is not a selection")
    func whitespaceIsNotASelection() {
        let scope = AppChatSelectionScope.from(
            context: context(bundleID: "com.microsoft.VSCode", text: "   \n  "),
            scopedTo: "com.microsoft.VSCode")

        #expect(scope == nil)
    }

    @Test("With no scope there is nothing to attribute a selection to")
    func emptyScopeYieldsNothing() {
        let scope = AppChatSelectionScope.from(
            context: context(bundleID: "com.microsoft.VSCode", text: "hi"), scopedTo: "")

        #expect(scope == nil)
    }

    @Test("Labels read the way a person would say them")
    func labelsArePlain() {
        #expect(AppChatSelectionScope(kind: .files(count: 1)).label == "1 file")
        #expect(AppChatSelectionScope(kind: .files(count: 3)).label == "3 files")
        #expect(AppChatSelectionScope(kind: .text(characters: 1)).label == "1 char")
    }
}
