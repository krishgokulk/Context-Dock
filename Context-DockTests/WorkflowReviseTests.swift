import Testing
import Foundation
@testable import Context_Dock

// MARK: - Adjusting an action instead of writing another
//
// B1 of docs/superpowers/plans/2026-09-18-actions-that-adjust.md.
//
// When the request changes more than a number — "minimise after 10 min AND THEN MUTE" —
// A cannot help: there is no slot for "and then mute". A model has to write the new script.
// What keeps this from being "author a second action with extra steps" is identity: the
// revision keeps the existing action's name, so `stableID` matches and saving replaces.
//
// The model's reply is read by the same pure reader the authoring path uses; these are the
// parts that make a revision a revision.

struct WorkflowReviseTests {

    private func existing() -> AdapterAction {
        AdapterAction(
            id: "ai.minimise-after-a-delay", name: "Minimise after a delay",
            icon: "sparkles", description: "Minimises the front window after a pause",
            triggers: ["minimise", "delay"], type: .shell,
            script: "sleep {{value}}; osascript -e 'minimise'",
            requiresApproval: true, valueLabel: "seconds", valueDefault: "300")
    }

    private let reply = """
        {"name":"Anything The Model Calls It","summary":"Minimises, then mutes",
         "kind":"shell","script":"sleep {{value}}; osascript -e 'minimise'; osascript -e 'set volume 0'",
         "triggers":["minimise","mute"],"value":{"label":"seconds","default":"300"}}
        """

    /// The revision is the same action. A model that renames it would produce a second
    /// action beside the first — the exact failure this exists to prevent.
    @MainActor @Test func aRevisionKeepsTheExistingName() throws {
        let revised = try #require(WorkflowAuthor.revision(
            fromReply: reply, existing: existing(),
            request: "minimise after 10 min and then mute",
            bundleID: "com.apple.finder", appName: "Finder"))
        #expect(revised.name == "Minimise after a delay")
    }

    /// Same name, same derivation, same id — so saving replaces rather than accumulates.
    @MainActor @Test func aRevisionSavesOverTheOriginal() throws {
        let revised = try #require(WorkflowAuthor.revision(
            fromReply: reply, existing: existing(),
            request: "minimise after 10 min and then mute",
            bundleID: "com.apple.finder", appName: "Finder"))
        #expect(AdapterActionProposalInstaller.stableID(for: revised.name)
            == AdapterActionProposalInstaller.stableID(for: existing().name))
    }

    /// The new script is the model's. That is the whole point of asking it.
    @MainActor @Test func aRevisionTakesTheNewScript() throws {
        let revised = try #require(WorkflowAuthor.revision(
            fromReply: reply, existing: existing(),
            request: "minimise after 10 min and then mute",
            bundleID: "com.apple.finder", appName: "Finder"))
        #expect(revised.script.contains("set volume 0"))
        #expect(revised.valueLabel == "seconds")
    }

    /// A reply that drops the value slot does not silently take the action's adjustability
    /// away: the existing declaration stands unless the new script has no slot to fill.
    @MainActor @Test func aRevisionKeepsTheValueWhenTheScriptStillHasASlot() throws {
        let noDeclaration = """
            {"name":"x","summary":"Minimises, then mutes","kind":"shell",
             "script":"sleep {{value}}; osascript -e 'mute'","triggers":["minimise"]}
            """
        let revised = try #require(WorkflowAuthor.revision(
            fromReply: noDeclaration, existing: existing(),
            request: "minimise after 10 min and then mute",
            bundleID: "com.apple.finder", appName: "Finder"))
        #expect(revised.valueLabel == "seconds")
        #expect(revised.valueDefault == "300")
    }

    /// A revision whose script has no slot has no value — keeping the label would promise
    /// an adjustment that cannot happen.
    @MainActor @Test func aRevisionWithoutASlotHasNoValue() throws {
        let fixed = """
            {"name":"x","summary":"Minimises immediately","kind":"shell",
             "script":"osascript -e 'minimise'","triggers":["minimise"]}
            """
        let revised = try #require(WorkflowAuthor.revision(
            fromReply: fixed, existing: existing(),
            request: "minimise right now, no delay",
            bundleID: "com.apple.finder", appName: "Finder"))
        #expect(revised.valueLabel == nil)
        #expect(revised.valueDefault == nil)
    }

    /// The prompt shows the model what it is changing, and says to change only that.
    @MainActor @Test func theRevisionPromptCarriesTheExistingScript() {
        let prompt = WorkflowAuthor.revisionPrompt(
            existing: existing(), request: "minimise after 10 min and then mute",
            appName: "Finder")
        #expect(prompt.contains("sleep {{value}}; osascript -e 'minimise'"))
        #expect(prompt.contains("minimise after 10 min and then mute"))
        #expect(prompt.contains("{{value}}"))
    }

    // MARK: - What the user approves

    /// A revision is not an install: the user is replacing something that already runs, so
    /// the card shows what it was as well as what it becomes.
    @MainActor @Test func theDiffShowsBothScripts() throws {
        let revised = try #require(WorkflowAuthor.revision(
            fromReply: reply, existing: existing(),
            request: "minimise after 10 min and then mute",
            bundleID: "com.apple.finder", appName: "Finder"))
        let text = WorkflowAuthor.revisionText(existing: existing(), revised: revised)
        #expect(text.contains("set volume 0"), "the new script is not shown")
        #expect(text.contains("sleep {{value}}; osascript -e 'minimise'"), "the old script is not shown")
        #expect(text.contains("Minimise after a delay"))
        // It must be unmistakable that nothing new is being added.
        #expect(text.lowercased().contains("replace"))
    }
}
