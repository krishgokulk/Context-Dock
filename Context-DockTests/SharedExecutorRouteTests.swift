import Testing
import Foundation
@testable import Context_Dock

// MARK: - Context Dock Chat through the shared executor
//
// Gate A's last row: every capability reaching one canonical executor. Context Dock Chat
// resolved its own routes and ran them itself, which cost it three things General AI has —
// an audit line, a task-run receipt, and a verified menu click — and let it claim outcomes
// it had not checked.
//
// The conversion is mechanical, and these tests pin the parts that are not. Each one exists
// because getting it wrong is silent: nothing crashes, the user is simply told something
// untrue, or is never asked a question they should have been asked.

@MainActor
struct SharedExecutorRouteTests {

    private func route(_ kind: ChatRoute.Kind, payload: String, readOnly: Bool = false) -> ChatRoute {
        ChatRoute(
            id: "test.\(kind.rawValue)",
            kind: kind,
            title: "Test \(kind.rawValue)",
            payload: payload,
            appName: "TestApp",
            bundleId: "com.example.testapp",
            isReadOnly: readOnly)
    }

    // MARK: - The conversion

    /// An adapter action carries its id in `payload`; the executor reads `adapterActionID`.
    /// Losing it in the conversion produces "Adapter route is missing its execution
    /// payload" — a failure the user sees as the app refusing a route it just offered.
    @Test func adapterActionCarriesItsActionID() throws {
        let candidate = try #require(route(.adapterAction, payload: "clean-cache").asCandidate())
        #expect(candidate.route == .adapter)
        #expect(candidate.adapterActionID == "clean-cache")
        #expect(candidate.bundleID == "com.example.testapp")
        // A capability id would send it down the CapabilityRegistry branch instead, where
        // "clean-cache" is not registered and never will be.
        #expect(candidate.capabilityID == nil)
    }

    /// Menu paths are joined on U+0001 in a ChatRoute and are an array in a candidate.
    /// Splitting on the wrong separator yields a one-element path that matches no menu.
    /// Menu commands run through the shared executor now that the destructive-menu consent
    /// moved with them — `AppAdapterManager.ensureMenuConsent` is reachable from both the
    /// executor's `.verifiedMenu` and `runMenuPath`, so neither path can skip the question.
    @Test func menuPathSplitsBackIntoItsComponents() throws {
        let candidate = try #require(
            route(.menuCommand, payload: "File\u{1}New Tab").asCandidate())
        #expect(candidate.route == .verifiedMenu)
        #expect(candidate.menuPath == ["File", "New Tab"])
    }

    /// MCP payloads are server and tool, in that order. Reversed, the runtime is asked for
    /// a tool on a server that does not exist and reports the tool as broken.
    @Test func mcpPayloadKeepsServerAndToolInOrder() throws {
        let candidate = try #require(
            route(.mcpTool, payload: "notes-server\u{1}search_notes").asCandidate())
        #expect(candidate.route == .mcp)
        #expect(candidate.inputValues["mcpServer"] == "notes-server")
        #expect(candidate.inputValues["mcpTool"] == "search_notes")
    }

    /// A malformed MCP payload must not become a candidate at all. Half a payload reaches
    /// the executor as a tool call with an empty name.
    @Test func incompleteMCPPayloadProducesNoCandidate() {
        #expect(route(.mcpTool, payload: "only-one-part").asCandidate() == nil)
    }

    /// Skill and model run nothing. If either produced a candidate, the executor would be
    /// handed a route with no mechanism.
    @Test func kindsThatRunNothingProduceNoCandidate() {
        #expect(route(.skill, payload: "x").asCandidate() == nil)
        #expect(route(.model, payload: "x").asCandidate() == nil)
    }

    /// The CLI route is deliberately NOT converted: `ChatRouteResolver` diverts commands
    /// that need a TTY into the thread's own terminal, and the shared executor has no such
    /// branch. Running one through `terminal.runCommand` is the recorded bug where a
    /// working terminal-browser became a two-and-a-half minute timeout.
    @Test func cliStaysOnItsOwnPath() {
        #expect(route(.cli, payload: "ls -la").asCandidate() == nil)
    }

    // MARK: - What the candidate tells the executor

    /// A read route must never be executed as a write. `operation` is what stops the
    /// executor treating a listing as a change.
    @Test func readOnlyRoutesAreMarkedAsReads() throws {
        let read = try #require(
            route(.mcpTool, payload: "s\u{1}list_items", readOnly: true).asCandidate())
        #expect(read.operation == .read)

        let write = try #require(
            route(.mcpTool, payload: "s\u{1}delete_item", readOnly: false).asCandidate())
        #expect(write.operation == .execute)
    }

    /// Risk drives the approval card's wording and the hard `.critical` block. A route that
    /// changes something is not low risk just because it came from a chat.
    @Test func writesAreNotFiledAsLowRisk() throws {
        let write = try #require(route(.adapterAction, payload: "delete-all").asCandidate())
        #expect(write.riskLevel != .low)

        let read = try #require(
            route(.adapterAction, payload: "list-all", readOnly: true).asCandidate())
        #expect(read.riskLevel == .low)
    }

    /// The user's own words are what an adapter action interpolates into its script.
    /// `ChatRouteResolver` passed `query:` and the shared executor did not, so an adapter
    /// whose script reads `{query}` would run against an empty string.
    @Test func theUsersQueryTravelsWithTheCandidate() throws {
        var candidate = try #require(route(.adapterAction, payload: "search").asCandidate())
        candidate.inputValues["query"] = "find my invoices"
        #expect(candidate.inputValues["query"] == "find my invoices")
    }

    /// Permission keys are per-route and per-app, never app-wide — a yes to one menu
    /// command is not a yes to every menu command in that app.
    @Test func permissionKeysAreScopedToTheExactRoute() throws {
        let a = try #require(route(.menuCommand, payload: "File\u{1}New Tab").asCandidate())
        let b = try #require(route(.menuCommand, payload: "File\u{1}Close Window").asCandidate())
        #expect(a.permissionKey != b.permissionKey)
        #expect(a.permissionKey.contains("com.example.testapp"))
    }

    // MARK: - Consent that must survive the move

    /// The reason `executeAdapterRoute` may switch off an adapter's own approval prompt is
    /// that the caller already put the same action in front of the user. A caller whose
    /// authority came from `AppAccessPolicy` has shown nothing — the adapter's consent is
    /// then the only thing between the model and the action, and suppressing it removes
    /// the user's last say.
    @Test func onlyAShownCardMaySuppressTheAdaptersOwnPrompt() {
        #expect(GeneralAIActionExecutor.suppressesAdapterPrompt(.granted(.approvalCard)))
        #expect(GeneralAIActionExecutor.suppressesAdapterPrompt(.granted(.userPickedButton)))

        #expect(!GeneralAIActionExecutor.suppressesAdapterPrompt(.granted(.accessPolicy)))
        #expect(!GeneralAIActionExecutor.suppressesAdapterPrompt(.ask))
    }
}
