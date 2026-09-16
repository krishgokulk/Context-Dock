import Foundation
import Testing

@testable import Context_Dock

// Evals for the tools that let the model go and look, and for the step labels the user reads
// while it does.
//
// The behaviour under test is mostly a refusal: a reading tool that cannot read must say so
// rather than describing what a file of that name usually contains. Those refusals are the
// whole safety story of handing the model free rein over reads.

@MainActor
struct ReadingToolEvalTests {

    private func tool(_ name: String) -> AgentTool? {
        AgentToolRegistry.shared.tool(named: name)
    }

    private var context: AgentToolContext {
        AgentToolContext(commandExecutor: { _, _, _ in (false, "", -1) })
    }

    @Test func theModelIsGivenAWayToRead() {
        // DoraX could run a shell command and click a menu, and could not read the web page
        // whose URL it was holding.
        for name in ["read_page", "read_url", "read_file", "read_selection"] {
            #expect(tool(name) != nil, "\(name) must be registered")
        }
    }

    @Test func readingToolsAreOfferedToEveryProvider() {
        // A tool the provider is never told about is a tool that does not exist.
        let schemas = AgentToolRegistry.shared.schemas(format: .anthropic)
        let names = schemas.compactMap { $0["name"] as? String }
        #expect(names.contains("read_page"))
        #expect(names.contains("read_file"))
    }

    @Test func aMissingFileIsReportedRatherThanImagined() async {
        let result = await tool("read_file")?.handler(
            ["path": "/tmp/definitely-not-here-\(UUID().uuidString).md"], context)
        #expect(result?.success == false)
        #expect(result?.output.contains("Do not guess") == true)
    }

    @Test func readFileRefusesOutsideAFolderThreadsBoundary() async {
        // A folder conversation is a boundary, not a starting point. Reading outside it is
        // the same trespass whether it happens through a capability or through this.
        var scoped = AgentToolContext(commandExecutor: { _, _, _ in (false, "", -1) })
        scoped.chatScope = .folder(path: NSTemporaryDirectory() + "dorax-eval-scope")
        let result = await tool("read_file")?.handler(
            ["path": "/etc/hosts"], scoped)
        #expect(result?.success == false)
        #expect(result?.output.contains("outside it") == true)
    }

    @Test func readURLRefusesAnythingThatIsNotAWebAddress() async {
        // file:// through the URL reader would be a way around the folder boundary above.
        for candidate in ["file:///etc/passwd", "not a url", "ftp://example.com"] {
            let result = await tool("read_url")?.handler(["url": candidate], context)
            #expect(result?.success == false, "\(candidate) must be refused")
        }
    }

    @Test func readPageRefusesWhenTheScopeIsNotABrowser() async {
        var scoped = AgentToolContext(commandExecutor: { _, _, _ in (false, "", -1) })
        scoped.chatScope = .app(bundleId: "com.apple.finder")
        let result = await tool("read_page")?.handler([:], scoped)
        #expect(result?.success == false)
        #expect(result?.output.contains("no page to read") == true)
    }

    @Test func readingToolsTakeNoApprovalArgument() {
        // The point of them is that they are dull. Anything requiring a decision from the
        // user would make the model hesitate to look, which is the behaviour being fixed.
        //
        // Asserted against the schema rather than the prose: the first version of this test
        // searched the description for the word "approval" and failed on read_file, whose
        // description says it needs *no* approval. A test that cannot tell a promise from
        // its opposite is worse than no test.
        for name in ["read_page", "read_url", "read_file", "read_selection"] {
            guard let tool = AgentToolRegistry.shared.tool(named: name) else {
                Issue.record("\(name) is not registered")
                continue
            }
            #expect(tool.properties["requires_approval"] == nil)
            #expect(!tool.required.contains("requires_approval"))
        }
    }
}

@MainActor
struct RouteToolEvalTests {

    @Test func theResolverIsOfferedToTheModelAsWellAsUsedOnIt() {
        #expect(AgentToolRegistry.shared.tool(named: "find_route") != nil)
        #expect(AgentToolRegistry.shared.tool(named: "run_route") != nil)
    }

    @Test func anInventedRouteIdRunsNothing() async {
        // The id has to come from find_route: re-resolving from a remembered id would run
        // whatever that id means now, against state that has drifted.
        let context = AgentToolContext(commandExecutor: { _, _, _ in (false, "", -1) })
        let result = await AgentToolRegistry.shared.tool(named: "run_route")?
            .handler(["route_id": "menu:Totally ▸ Invented"], context)
        #expect(result?.success == false)
        #expect(result?.output.contains("find_route") == true)
    }

    @Test func findRouteNeedsAnAppScope() async {
        var general = AgentToolContext(commandExecutor: { _, _, _ in (false, "", -1) })
        general.chatScope = .general
        let result = await AgentToolRegistry.shared.tool(named: "find_route")?
            .handler(["request": "export this"], general)
        #expect(result?.success == false)
        #expect(result?.output.contains("find_capability") == true)
    }
}

struct ToolStepLabelEvalTests {

    @Test func stepsReadInTheUsersLanguageNotOurs() {
        // `run_capability` is our vocabulary. The transcript is theirs.
        #expect(ScopedToolStep.label(for: "read_page") == "Reading the page…")
        #expect(ScopedToolStep.label(for: "run_command") == "Running a command…")
    }

    @Test func anExtensionsOwnToolKeepsTheNameItsAuthorChose() {
        #expect(ScopedToolStep.label(for: "deploy_staging") == "Deploy staging…")
    }
}

struct EffortFloorEvalTests {

    @Test func aPlainQuestionHasRoomToLookBeforeAnswering() {
        // Two rounds bought one tool call and an answer — which is why "what does this page
        // say" came back as "I don't have that" instead of reading the page first.
        #expect(TaskComplexityRoute.direct.maxToolIterations >= 4)
    }
}
