import Testing
@testable import Context_Dock

@Suite("AIScriptSkillRecorder")
struct AIScriptSkillRecorderTests {

    // MARK: Rule 1: verify-discard

    @Test func failureDiscards() {
        #expect(AIScriptSkillRecorder.makeRecipe(
            command: "ls ~/Desktop",
            success: false,
            bundleID: "com.x", appName: "X",
            userQuery: "list desktop files") == nil)
    }

    // MARK: Rule 2: untrusted guard

    @Test func untrustedContentDiscards() {
        #expect(AIScriptSkillRecorder.makeRecipe(
            command: "ls ~/Desktop",
            success: true,
            bundleID: "com.x", appName: "X",
            userQuery: "list desktop files",
            hasUntrustedContent: true) == nil)
    }

    // MARK: Rule 3: templated names

    @Test func emptyQueryDiscards() {
        #expect(AIScriptSkillRecorder.makeRecipe(
            command: "ls ~/Desktop",
            success: true,
            bundleID: "com.x", appName: "X",
            userQuery: "") == nil)
    }

    @Test func leftoverValueBlocks() {
        // "compress Bob.pdf" — "Bob" is a proper noun mid-sentence with no slot context,
        // so it's a leftover value and the save is blocked (§205 rule 2 / spec §8 rule 3).
        #expect(AIScriptSkillRecorder.makeRecipe(
            command: "ditto -c -k Bob.pdf Bob.zip",
            success: true,
            bundleID: "com.apple.finder", appName: "Finder",
            userQuery: "compress Bob.pdf") == nil)
    }

    @Test func readUsesTemplatedName() {
        // A query with a file-reference slot ("this file") and a matching selected file
        // should produce a recipe named from the template, not the raw query.
        var ctx = SlotDerivationContext()
        ctx.selectedFilePaths = ["/Users/me/report.pdf"]
        let recipe = AIScriptSkillRecorder.makeRecipe(
            command: "ditto -c -k /Users/me/report.pdf /Users/me/report.zip",
            success: true,
            bundleID: "com.apple.finder", appName: "Finder",
            userQuery: "zip this file",
            slotContext: ctx)
        #expect(recipe != nil)
        // Template replaces "this" with "{file}", so the name contains "{file}" not "report"
        #expect(recipe?.name.contains("report") == false)
        #expect(recipe?.name.contains("{file}") == true)
    }

    @Test func slotFreeVerbPhraseAllowed() {
        // A pure verb phrase ("list desktop files") has no entities, so no leftover value.
        // It should save with the full query as the template name.
        let recipe = AIScriptSkillRecorder.makeRecipe(
            command: "ls ~/Desktop",
            success: true,
            bundleID: "com.x", appName: "X",
            userQuery: "list desktop files")
        #expect(recipe != nil)
        #expect(recipe?.name == "Script: list desktop files")
    }

    // MARK: Rule 4: reads auto-save / writes offered

    @Test @MainActor func writeQueuesOffer() async {
        let recorder = AIScriptSkillRecorder.shared
        recorder.discardOffer()
        let ctx = AIScriptContext(
            bundleID: "com.x", appName: "X",
            userQuery: "list desktop files",
            slotContext: .empty,
            hasUntrustedContent: false)
        recorder.record(
            command: "ls ~/Desktop", success: true,
            context: ctx, isRead: false,
            store: SkillStore.shared)
        #expect(recorder.pendingOffer != nil)
        recorder.discardOffer()
    }
}
