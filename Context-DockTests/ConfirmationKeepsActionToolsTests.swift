import Foundation
import Testing

@testable import Context_Dock

/// Agreeing to an action must not disarm it.
///
/// Questions get readers, not controls — a model shown a tool treats it as available — so a
/// query that only asks has the action tools removed from its schema. "Sure" asks nothing,
/// which made it look like a question, so agreeing to "Claude ▸ Check for Updates… Run it?"
/// removed run_menu_command for that very turn. The model then reported, correctly, that it
/// had no menu tool: the offer was disarmed by its acceptance.
@MainActor
@Suite("Confirmation keeps action tools")
struct ConfirmationKeepsActionToolsTests {
    private let actionTools: Set<String> = [
        "run_command", "run_menu_command", "run_adapter_action", "compose_message",
    ]

    @Test(arguments: ["sure", "yes", "go ahead", "ok", "do it"])
    func agreeingKeepsTheToolsTheOfferNeeded(reply: String) {
        let available = AgentToolRegistry.shared.toolNamesAvailable(for: reply)
        #expect(!available.isDisjoint(with: actionTools))
    }

    /// The plan is where the menu tool is granted, and it read only the newest words: "sure"
    /// has no action verb, so run_menu_command was withheld from the turn that had just been
    /// approved. It now inherits the intent of the request it agreed to.
    @Test func agreeingInheritsTheActionItAgreedTo() {
        let plan = FrontmostAppTaskPlan.make(
            query: "sure",
            bundleId: "com.anthropic.claudefordesktop",
            appName: "Claude",
            previousUserRequests: ["like to update the app"])
        #expect(plan.allowedToolNames.contains("run_menu_command"))
    }

    /// And a plain question still does not get one, whatever came before it.
    @Test func aQuestionAfterAnActionDoesNotInheritIt() {
        let plan = FrontmostAppTaskPlan.make(
            query: "what version am I on",
            bundleId: "com.anthropic.claudefordesktop",
            appName: "Claude",
            previousUserRequests: ["open the updates window"])
        #expect(!plan.allowedToolNames.contains("run_menu_command"))
    }

    /// The rule it must not break: a real question still gets readers only.
    @Test(arguments: ["what version am I on", "how do I open a file here"])
    func aQuestionStillGetsReadersOnly(query: String) {
        let available = AgentToolRegistry.shared.toolNamesAvailable(for: query)
        #expect(available.isDisjoint(with: actionTools))
    }
}

/// The turn that started it: "like to update the app", with the app in front.
@MainActor
@Suite("Asking an app to update is an action")
struct UpdateRequestIsActionTests {
    @Test func thePlanGrantsTheMenuTool() {
        let plan = FrontmostAppTaskPlan.make(
            query: "like to update the app",
            bundleId: "com.anthropic.claudefordesktop",
            appName: "Claude")
        #expect(plan.allowedToolNames.contains("run_menu_command"))
    }

    /// The second gate, and the one the plan cannot see: a query that only asks has its
    /// action tools removed after the plan has granted them.
    @Test func theToolFilterKeepsIt() {
        let available = AgentToolRegistry.shared.toolNamesAvailable(for: "like to update the app")
        #expect(available.contains("run_menu_command"))
    }
}

/// Does the prompt for Claude actually name the menu tool and the command?
@MainActor
@Suite("Menu tool reaches the prompt")
struct MenuToolPromptTests {
    @Test func claudeIdentityBlockOffersTheMenuTool() {
        let block = ScopedAppPromptBuilder.appIdentityBlock(
            bundleId: "com.anthropic.claudefordesktop",
            appName: "Claude",
            query: "like to update the app")
        #expect(block.contains("run_menu_command"))
        #expect(block.lowercased().contains("check for updates"))
    }
}
