import Testing
import Foundation
@testable import Context_Dock

// MARK: - Authoring declares the value
//
// A4 of docs/superpowers/plans/2026-09-18-actions-that-adjust.md.
//
// A1–A3 let a saved action run with the number in the sentence. That is worth nothing
// unless the action was saved with a `{{value}}` slot and a declaration of what fills it.
// Two things author actions — the chat's proposal block and WorkflowAuthor's "teach it"
// rung — and both have to carry the declaration through to the saved action. A proposal
// without one must come out exactly as it did before.

struct ActionAuthoringValueTests {

    // MARK: - The chat's proposal block

    private func block(_ json: String) -> String {
        "Done.\n\(ExtensionProposalData.markerStart)\n\(json)\n\(ExtensionProposalData.markerEnd)"
    }

    private let withValue = """
        {"type":"extension_proposal","name":"Minimise after a delay",
         "description":"Minimises the front window after a pause","scriptType":"bash",
         "script":"sleep {{value}}; osascript -e 'tell application \\"System Events\\" to keystroke \\"m\\" using command down'",
         "layer":"contextDock","triggers":[{"type":"appContext","value":"Finder"}],
         "value":{"label":"seconds","default":"300"}}
        """

    private let withoutValue = """
        {"type":"extension_proposal","name":"Clean Build Folder","description":"",
         "scriptType":"bash","script":"rm -rf ~/Library/Developer/Xcode/DerivedData",
         "layer":"contextDock","triggers":[{"type":"appContext","value":"Xcode"}]}
        """

    @Test func aChatProposalCanDeclareItsValue() throws {
        let proposal = try #require(ExtensionProposalData.parse(from: block(withValue)))
        #expect(proposal.value?.label == "seconds")
        #expect(proposal.value?.defaultValue == "300")
    }

    /// Every proposal the model has written so far has no `value`. Absent is absent.
    @Test func aChatProposalWithoutAValueParsesAsBefore() throws {
        let proposal = try #require(ExtensionProposalData.parse(from: block(withoutValue)))
        #expect(proposal.value == nil)
    }

    /// The installed action carries the declaration, so A3 can fill the slot next time.
    @Test func aProposalWithAValueBecomesAnAdjustableAction() throws {
        let proposal = try #require(ExtensionProposalData.parse(from: block(withValue)))
        let action = AdapterActionProposalInstaller.action(from: proposal)
        #expect(action.takesValue)
        #expect(action.valueLabel == "seconds")
        #expect(action.valueDefault == "300")
        #expect(action.value(for: "minimise after 10 min") == "600")
    }

    @Test func aProposalWithoutAValueBecomesAnActionThatTakesNone() throws {
        let proposal = try #require(ExtensionProposalData.parse(from: block(withoutValue)))
        let action = AdapterActionProposalInstaller.action(from: proposal)
        #expect(!action.takesValue)
        #expect(action.valueDefault == nil)
    }

    // MARK: - WorkflowAuthor's reply

    private let authoredWithValue = """
        Here you go:
        {"name":"Minimise after a delay","summary":"Minimises the front window after a pause",
         "kind":"shell","script":"sleep {{value}}; open -a Finder","triggers":["minimise","delay"],
         "value":{"label":"seconds","default":"300"}}
        """

    private let authoredWithoutValue = """
        {"name":"Convert to Markdown","summary":"Turns the selection into Markdown",
         "kind":"shell","script":"pbpaste | textutil -stdin -stdout -convert html",
         "triggers":["markdown"]}
        """

    @MainActor @Test func anAuthoredReplyCanDeclareItsValue() throws {
        let proposal = try #require(WorkflowAuthor.proposal(
            fromReply: authoredWithValue, request: "minimise after 5 min",
            bundleID: "com.apple.finder", appName: "Finder"))
        #expect(proposal.valueLabel == "seconds")
        #expect(proposal.valueDefault == "300")
    }

    @MainActor @Test func anAuthoredReplyWithoutAValueIsExactlyAsBefore() throws {
        let proposal = try #require(WorkflowAuthor.proposal(
            fromReply: authoredWithoutValue, request: "convert this to markdown",
            bundleID: "com.microsoft.VSCode", appName: "Code"))
        #expect(proposal.valueLabel == nil)
        #expect(proposal.valueDefault == nil)
        #expect(proposal.name == "Convert to Markdown")
        #expect(proposal.triggers == ["markdown"])
    }

    /// A `value` with no label is no declaration: there is nothing to convert to, and a
    /// default without a unit is a number nobody can adjust.
    @MainActor @Test func aValueWithoutALabelIsNoValue() throws {
        let reply = authoredWithValue.replacingOccurrences(
            of: "\"label\":\"seconds\",", with: "")
        let proposal = try #require(WorkflowAuthor.proposal(
            fromReply: reply, request: "minimise after 5 min",
            bundleID: "com.apple.finder", appName: "Finder"))
        #expect(proposal.valueLabel == nil)
        #expect(proposal.valueDefault == nil)
    }

    /// What `save` writes is what the runtime reads.
    @MainActor @Test func aSavedProposalCarriesItsValue() throws {
        let proposal = try #require(WorkflowAuthor.proposal(
            fromReply: authoredWithValue, request: "minimise after 5 min",
            bundleID: "com.apple.finder", appName: "Finder"))
        let action = WorkflowAuthor.action(for: proposal)
        #expect(action.valueLabel == "seconds")
        #expect(action.valueDefault == "300")
        #expect(action.script == "sleep {{value}}; open -a Finder")
    }

    /// The model only writes `{{value}}` if it is told to. Both prompts say so.
    @MainActor @Test func theAuthoringPromptTeachesTheValue() {
        let prompt = WorkflowAuthor.prompt(request: "minimise after 5 min", appName: "Finder")
        #expect(prompt.contains("{{value}}"))
        #expect(prompt.contains("\"value\""))
    }

    // MARK: - A5: the confirmation says it adjusts
    //
    // An action that quietly takes a new number is a feature nobody uses, because nobody
    // is told it is there. The sentence that saves it is the one place the user is
    // certain to read.

    @Test func savingAnAdjustableActionSaysToSayADifferentNumber() {
        let text = AdapterActionProposalInstaller.confirmation(
            actionName: "Minimise after a delay", appName: "Finder",
            valueLabel: "seconds", valueDefault: "300")
        #expect(text.contains("Minimise after a delay"))
        #expect(text.contains("Finder"))
        // The unit and the number it was saved with, so "a different number" means
        // something concrete.
        #expect(text.contains("5 minutes") || text.contains("300 seconds"))
        #expect(text.lowercased().contains("different number"))
    }

    /// An action with nothing to adjust says exactly what it said before — no promise the
    /// action cannot keep.
    @Test func savingAnOrdinaryActionSaysWhatItAlwaysDid() {
        let plain = AdapterActionProposalInstaller.confirmation(
            actionName: "Clean Build Folder", appName: "Xcode")
        #expect(!plain.lowercased().contains("different number"))
        #expect(plain.contains("Clean Build Folder"))
    }

    /// The other authoring rung — "teach yourself to…" — says it too, in the text the user
    /// approves.
    @MainActor @Test func theApprovalOfAnAdjustableActionSaysItAdjusts() throws {
        let proposal = try #require(WorkflowAuthor.proposal(
            fromReply: authoredWithValue, request: "minimise after 5 min",
            bundleID: "com.apple.finder", appName: "Finder"))
        let text = WorkflowAuthor.approvalText(proposal)
        #expect(text.lowercased().contains("different number"))
    }

    @MainActor @Test func theApprovalOfAnOrdinaryActionIsUnchanged() throws {
        let proposal = try #require(WorkflowAuthor.proposal(
            fromReply: authoredWithoutValue, request: "convert this to markdown",
            bundleID: "com.microsoft.VSCode", appName: "Code"))
        #expect(!WorkflowAuthor.approvalText(proposal).lowercased().contains("different number"))
    }
}
