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
        #expect(!page.permitsUIAutomation)
        #expect(!page.allowedToolNames.contains("run_menu_command"))
        #expect(!page.allowedToolNames.contains("send_keys"))
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

    // MARK: - Issue 204: a find/search in a record-set app is a data read, not a UI action

    /// "find notes with links." began with a verb `ChatRouteResolver.isActionRequest` treats as
    /// a GUI command, so the turn was planned as an action: menu tools and `operate_app` were
    /// offered, the model drove the screen, and its "ambiguous" refusal came back as the answer.
    /// Notes owns a record set, so the sentence is a read: `notes.search`, no UI-lane tools
    /// (plan 2a rule 7: Computer Use is never the first choice for data).
    @Test("A find or search in Notes is a read and gets no UI-lane tools")
    func findInNotesIsADataRead() {
        for query in ["find notes with links.", "search notes for passport",
                      "list my notes about the roof"] {
            let plan = FrontmostAppTaskPlan.make(
                query: query, bundleId: "com.apple.Notes", appName: "Notes")
            #expect(plan.intent == .read, "\"\(query)\"")
            #expect(!plan.permitsUIAutomation, "\"\(query)\"")
            for tool in ["operate_app", "run_menu_command", "find_menu_command", "send_keys"] {
                #expect(!plan.allowedToolNames.contains(tool), "\"\(query)\" offered \(tool)")
            }
        }
    }

    @Test("Opening or changing in Notes stays an action")
    func notesActionsKeepTheirTools() {
        for query in ["create a note about the roof quote", "find the note and open it"] {
            let plan = FrontmostAppTaskPlan.make(
                query: query, bundleId: "com.apple.Notes", appName: "Notes")
            #expect(plan.permitsUIAutomation, "\"\(query)\"")
        }
    }

    @Test("A read-only question in Safari gets no menu or UI-execution tools (#357)")
    func askOnlyQuestionGetsNoMenuExecution() {
        // "open " is in the action words, so "tabs are open" planned as an action and
        // handed the model run_menu_command.
        let plan = FrontmostAppTaskPlan.make(
            query: "How many tabs are open in Safari?",
            bundleId: "com.apple.Safari", appName: "Safari")
        #expect(!plan.permitsUIAutomation)
        // The model still gets a tool-call opportunity: the MCP read tool stays offered, so
        // the tab count comes from safari-mcp rather than from a menu click.
        #expect(plan.intent == .read)
        #expect(plan.allowedToolNames.contains("run_mcp_tool"))
        #expect(plan.allowedToolNames.contains("read_page") == false)
        for tool in ["run_menu_command", "find_menu_command", "send_keys", "window_control", "operate_app"] {
            #expect(!plan.allowedToolNames.contains(tool), "\(tool) leaked into a read-only turn")
        }
    }

    @Test("An instruction that uses the same word still gets menu tools")
    func openInstructionKeepsMenuTools() {
        let plan = FrontmostAppTaskPlan.make(
            query: "open a new tab", bundleId: "com.apple.Safari", appName: "Safari")
        #expect(plan.permitsUIAutomation)
        #expect(plan.allowedToolNames.contains("run_menu_command"))
    }

    @Test("Finder find is unchanged: Finder owns no record set")
    func finderFindIsUnchanged() {
        let plan = FrontmostAppTaskPlan.make(
            query: "find my passport pdf", bundleId: "com.apple.finder", appName: "Finder")
        #expect(plan.permitsUIAutomation)
    }

    @Test("A records read in Notes gets a tool round, not the direct no-tools route")
    func notesRecordsReadIsBounded() {
        let plan = FrontmostAppTaskPlan.make(
            query: "find notes with links.", bundleId: "com.apple.Notes", appName: "Notes")
        #expect(plan.complexity == .bounded)
        let chat = FrontmostAppTaskPlan.make(
            query: "hello there", bundleId: "com.apple.Notes", appName: "Notes")
        #expect(chat.complexity == .direct)
    }
}
