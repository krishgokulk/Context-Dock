import Testing
@testable import Context_Dock

@Suite("Frontmost app task planning", .serialized)
@MainActor
struct FrontmostAppTaskPlanTests {
    @Test("Messages questions cannot acquire browser evidence or browser tools")
    func messagesIsolation() {
        let plan = FrontmostAppTaskPlan.make(
            query: "Which conversations mention the launch date?",
            bundleId: "com.apple.MobileSMS", appName: "Messages")

        #expect(plan.intent == .read)
        #expect(plan.allows(.scopedApp))
        #expect(!plan.allows(.browserPage))
        #expect(plan.allowedToolNames.contains("search_messages"))
        #expect(!plan.allowedToolNames.contains("read_page"))
        #expect(!plan.allowedToolNames.contains("run_command"))
        #expect(!plan.permitsUIAutomation)
        #expect(!plan.allowedToolNames.contains("run_menu_command"))
        #expect(!plan.allowedToolNames.contains("send_keys"))
    }

    @Test("Messages compose workflows may use UI automation")
    func messagesComposeMayUseUI() {
        let plan = FrontmostAppTaskPlan.make(
            query: "Draft a message to Alex saying I am on my way",
            bundleId: "com.apple.MobileSMS", appName: "Messages")

        #expect(plan.intent == .act || plan.intent == .workflow)
        #expect(plan.permitsUIAutomation)
    }

    @Test("A browser page request gets page evidence but an unrelated browser request does not")
    func browserEvidenceIsIntentGated() {
        let page = FrontmostAppTaskPlan.make(
            query: "Summarize this page",
            bundleId: "com.apple.Safari", appName: "Safari")
        let bookmarks = FrontmostAppTaskPlan.make(
            query: "List my bookmarks",
            bundleId: "com.apple.Safari", appName: "Safari")

        #expect(page.allows(.browserPage))
        #expect(page.allowedToolNames.contains("read_page"))
        #expect(!bookmarks.allows(.browserPage))
        #expect(!bookmarks.allowedToolNames.contains("read_page"))

        let followUp = FrontmostAppTaskPlan.make(
            query: "Are there any social links?",
            bundleId: "com.apple.Safari", appName: "Safari",
            priorConversation: "User: Summarize this page")
        #expect(followUp.allows(.browserPage))
    }

    @Test("Finder selection workflow keeps selection and mutation tools in scope")
    func finderSelectionWorkflow() {
        let plan = FrontmostAppTaskPlan.make(
            query: "Rename these files, then verify the new names",
            bundleId: "com.apple.finder", appName: "Finder", hasSelection: true)

        #expect(plan.intent == .workflow)
        #expect(plan.allows(.selection))
        #expect(plan.allowedToolNames.contains("read_selection"))
        #expect(plan.allowedToolNames.contains("run_capability"))
        #expect(plan.allowedToolNames.contains("verify_outcome"))
        #expect(!plan.allows(.browserPage))
    }

    @Test("Code workspace questions acquire workspace, not browser context")
    func codeWorkspaceIsolation() {
        let plan = FrontmostAppTaskPlan.make(
            query: "What branch is this project on?",
            bundleId: "com.microsoft.VSCode", appName: "Code")

        #expect(plan.allows(.workspace))
        #expect(!plan.allows(.browserPage))
    }

    @Test("Provider registry receives only the task-approved schemas")
    func providerSchemaBoundary() {
        let plan = FrontmostAppTaskPlan.make(
            query: "Search Messages for launch date",
            bundleId: "com.apple.MobileSMS", appName: "Messages")
        AgentToolRegistry.shared.prepareTurnBudget(
            query: plan.goal, provider: .openAI, allowedToolNames: plan.allowedToolNames)
        let names = AgentToolRegistry.shared.toolNamesAvailable(for: plan.goal)

        #expect(names.contains("search_messages"))
        #expect(!names.contains("read_page"))
        #expect(!names.contains("run_command"))

        AgentToolRegistry.shared.prepareTurnBudget(
            query: "", provider: .openAI, allowedToolNames: nil)
    }
}
