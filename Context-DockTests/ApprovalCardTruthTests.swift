import Testing
import Foundation
@testable import Context_Dock

// MARK: - What an approval card is allowed to claim
//
// Asked "what's in my trash bin", the model called the Empty Trash capability with the
// explanation "List the contents of the trash bin", and the card printed that sentence
// under the real title in the same grey a description would use. Approving it emptied the
// trash. The card is the last gate before a destructive action, and the line a user
// actually reads on it was model-authored and unlabelled.

struct ApprovalCardTruthTests {

    /// A model's sentence always arrives introduced. Dropping the label is the regression
    /// that turns a quoted claim back into a description.
    @Test func anAssistantsReasonIsNeverPresentedAsDoraXsOwn() {
        let attribution = ApprovalRequest.Requester.assistant.attribution
        #expect(!attribution.isEmpty)
        #expect(attribution.lowercased().contains("assistant"))
    }

    /// An adapter action names the app it reaches. That is a fact DoraX knows, and it must
    /// not be introduced as though something claimed it.
    @Test func anAppTargetIsNotIntroducedAsAClaim() {
        let appAttribution = ApprovalRequest.Requester.connectedApp.attribution
        #expect(!appAttribution.isEmpty)
        #expect(!appAttribution.lowercased().contains("assistant"))
        #expect(appAttribution != ApprovalRequest.Requester.assistant.attribution)
    }

    /// The identity of what will run leads the factual block, ahead of any input. A Global
    /// Command's title is user-authored, so it can read as harmless while the id cannot.
    @Test func theCapabilityIdLeadsTheFactualBlock() {
        let body = ApprovalRequest.capabilityBody(
            capabilityID: "globalcmd.empty-trash",
            inputs: ["value": "", "target": "Finder"])
        #expect(body.hasPrefix("globalcmd.empty-trash"))
    }

    /// Present even when there is nothing else to show. Empty Trash takes no input, so
    /// without this the card carried no verifiable detail at all.
    @Test func theIdShowsEvenWithNoInputs() {
        let body = ApprovalRequest.capabilityBody(
            capabilityID: "globalcmd.empty-trash", inputs: [:])
        #expect(body == "globalcmd.empty-trash")
    }

    /// Inputs are ordered so the same plan always renders the same card — a block that
    /// reshuffles between draws is one a user stops reading.
    @Test func inputsRenderInAStableOrder() {
        let inputs = ["zebra": "1", "alpha": "2", "middle": "3"]
        let first = ApprovalRequest.capabilityBody(capabilityID: "x.y", inputs: inputs)
        let second = ApprovalRequest.capabilityBody(capabilityID: "x.y", inputs: inputs)
        #expect(first == second)
        #expect(first == "x.y\nalpha: 2\nmiddle: 3\nzebra: 1")
    }

    @Test @MainActor
    func rephrasingAnExplanationDoesNotCreateASecondCapabilityAction() {
        let first = AgentToolRegistry.callSignature(
            name: "run_capability",
            arguments: [
                "capability_id": "reminders.create",
                "input": ["title": "DoraX Agent Eval"],
                "explanation": "Create the reminder",
            ])
        let retry = AgentToolRegistry.callSignature(
            name: "run_capability",
            arguments: [
                "capability_id": "reminders.create",
                "input": ["title": "DoraX Agent Eval"],
                "explanation": "Add it for the user",
            ])
        #expect(first == retry)
    }
}
