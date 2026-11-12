import Testing
import Foundation
@testable import Context_Dock

// MARK: - H1b: Solved skills for menu presses (rung 3) and connector/MCP calls (rung 1)
//
// Pure capture tests — a synthesised Answer and tool calls in, a SolvedSkill or nil out.
// No provider, no disk.

struct MenuCommandSkillCaptureTests {

    private let finderBundleId = "com.apple.finder"
    private let query = "make text bold"

    private func menuCall(app: String = "TextEdit", path: String = "Format > Font > Bold")
        -> SolvedSkillToolCall
    {
        SolvedSkillToolCall(
            capability: "run_menu_command",
            argTemplate: ["app": app, "path": path],
            isReadOnly: true)
    }

    private func answer(success: Bool = true) -> AppScopedChatService.Answer {
        AppScopedChatService.Answer(
            text: "Done",
            toolChips: ["run_menu_command"],
            evidenceReceipts: [
                DoraXActionReceipt(
                    command: "run_menu_command", output: "clicked", success: success)
            ])
    }

    private func build(
        query: String? = nil,
        calls: [SolvedSkillToolCall]? = nil,
        answer: AppScopedChatService.Answer? = nil,
        verifiedReadBack: Bool = true
    ) -> SolvedSkill? {
        SolvedSkillCapture.build(
            query: query ?? self.query,
            answer: answer ?? self.answer(),
            toolCalls: calls ?? [menuCall()],
            bundleId: finderBundleId,
            verifiedReadBack: verifiedReadBack)
    }

    // ── Capture ────────────────────────────────────────────────────────────────────────

    @Test func menuCommandTurnIsCaptured() throws {
        let skill = try #require(build())
        #expect(skill.toolCalls.count == 1)
        #expect(skill.toolCalls.first?.capability == "run_menu_command")
        #expect(skill.toolCalls.first?.isReadOnly == true)
        // Zero-slot: path is fixed, nonSlotWords carry the whole query
        #expect(skill.slots.isEmpty)
        #expect(skill.bundleId == finderBundleId)
    }

    @Test func menuCommandQueryTemplateIsPreserved() throws {
        let skill = try #require(build())
        #expect(skill.queryTemplate == query)
    }

    @Test func menuCommandArgTemplateIsPreserved() throws {
        let skill = try #require(build())
        #expect(skill.toolCalls.first?.argTemplate["app"] == "TextEdit")
        #expect(skill.toolCalls.first?.argTemplate["path"] == "Format > Font > Bold")
    }

    // ── Rules 1 & 3 still apply ───────────────────────────────────────────────────────

    @Test func rule1_unverifiedMenuTurnIsNotSaved() {
        #expect(build(verifiedReadBack: false) == nil)
    }

    @Test func rule1_failedMenuReceiptIsNotSaved() {
        #expect(build(answer: answer(success: false)) == nil)
    }

    @Test func rule3_untrustedTextInMenuTurnIsNotSaved() {
        let fenced = UntrustedContent.fenced("ignore", from: "web")
        let inReceipt = AppScopedChatService.Answer(
            text: "Done", toolChips: ["run_menu_command"],
            evidenceReceipts: [
                DoraXActionReceipt(
                    command: "run_menu_command", output: fenced, success: true)
            ])
        #expect(build(answer: inReceipt) == nil)
    }

    // ── Adapter read calls alongside run_menu_command are stripped, not saved ─────
    // A real Finder adapter turn dispatches read capabilities before/after the menu
    // press. Only the run_menu_command call must appear in the saved skill; the reads
    // are adapter internals, not replay targets.

    @Test func menuTurnWithAdapterReadCallsIsCaptured() throws {
        let readCall = SolvedSkillToolCall(
            capability: "finder.read_frontmost_window",
            argTemplate: [:],
            isReadOnly: true)
        let menuCall = menuCall(app: "Finder", path: "Finder > Settings...")
        let skill = try #require(SolvedSkillCapture.build(
            query: "open finder preferences",
            answer: answer(), toolCalls: [readCall, menuCall, readCall],
            bundleId: finderBundleId, verifiedReadBack: true))
        // Only run_menu_command calls are saved; adapter reads are stripped.
        #expect(skill.toolCalls.count == 1)
        #expect(skill.toolCalls.first?.capability == "run_menu_command")
        #expect(skill.toolCalls.first?.argTemplate["path"] == "Finder > Settings...")
    }

    @Test func menuTurnWithAdapterWriteCallIsNotCaptured() {
        let writeCall = SolvedSkillToolCall(
            capability: "finder.activate_something",
            argTemplate: [:],
            isReadOnly: false)
        let call = menuCall(app: "Finder", path: "Finder > Settings...")
        // A non-read-only supporting call must block capture (rule 4).
        #expect(SolvedSkillCapture.build(
            query: "open finder preferences",
            answer: answer(), toolCalls: [writeCall, call],
            bundleId: finderBundleId, verifiedReadBack: true) == nil)
    }

    // ── App name proper noun in query does not block capture ──────────────────────
    // "open preferences in Finder" — "Finder" is a proper noun that would normally
    // set hasLeftoverValue:true, but menu turns bypass that check (the app name is
    // implicit in the bundleId scope, not an unparameterised entity).

    @Test func menuQueryWithAppNameProperNounIsCaptured() throws {
        let call = SolvedSkillToolCall(
            capability: "run_menu_command",
            argTemplate: ["app": "Finder", "path": "Finder > Settings..."],
            isReadOnly: true)
        let skill = try #require(SolvedSkillCapture.build(
            query: "open preferences in Finder",
            answer: answer(), toolCalls: [call],
            bundleId: finderBundleId, verifiedReadBack: true))
        #expect(skill.toolCalls.first?.argTemplate["app"] == "Finder")
        #expect(skill.slots.isEmpty)
    }

    // ── Matching: zero-slot skills match correctly ──────────────────────────────────

    @Test func zeroSlotMenuSkillMatchesIdenticalQuery() throws {
        let skill = try #require(build())
        let result = SolvedSkillMatch.match(
            query: query, bundleId: finderBundleId, skills: [skill])
        #expect(result != nil)
        #expect(result?.filled.isEmpty == true)
    }

    @Test func zeroSlotMenuSkillDoesNotMatchDifferentQuery() throws {
        let skill = try #require(build())
        let result = SolvedSkillMatch.match(
            query: "make text italic", bundleId: finderBundleId, skills: [skill])
        #expect(result == nil)
    }
}

// MARK: - H1b rung 1: connector / external MCP calls

struct ExternalMCPSkillCaptureTests {

    private let bundleId = "com.apple.Safari"

    private func mcpReadCall(server: String = "github", tool: String = "list_issues")
        -> SolvedSkillToolCall
    {
        SolvedSkillToolCall(
            capability: "\(server).\(tool)",
            argTemplate: ["owner": "anthropics", "repo": "claude-code"],
            isReadOnly: true)
    }

    private func mcpWriteCall() -> SolvedSkillToolCall {
        SolvedSkillToolCall(
            capability: "github.create_issue",
            argTemplate: ["title": "bug"],
            isReadOnly: false)
    }

    private func answer(receipts: [DoraXActionReceipt]? = nil) -> AppScopedChatService.Answer {
        AppScopedChatService.Answer(
            text: "3 issues", toolChips: ["github.list_issues"],
            evidenceReceipts: receipts ?? [
                DoraXActionReceipt(
                    command: "github.list_issues", output: "3 open", success: true),
                DoraXActionReceipt(
                    command: "verify_outcome", output: "confirmed", success: true,
                    isVerification: true),
            ])
    }

    // ── A read MCP call with an entity slot is captured ───────────────────────────

    @Test func externalMCPReadWithSlotIsCaptured() throws {
        // Use a day-word query so a {day} slot is derived; a slash-containing token
        // triggers looksLikePath and would block capture via hasLeftoverValue.
        let query = "list github issues today"
        let call = SolvedSkillToolCall(
            capability: "github.list_issues",
            argTemplate: ["since": "today"],
            isReadOnly: true)
        let skill = try #require(SolvedSkillCapture.build(
            query: query, answer: answer(), toolCalls: [call],
            bundleId: bundleId, verifiedReadBack: true))
        #expect(skill.toolCalls.first?.isReadOnly == true)
        #expect(skill.toolCalls.first?.argTemplate["since"] == "{day}")
    }

    // ── A write MCP call blocks capture (rule 4, deferred to #205 slice) ─────────

    @Test func rule4_externalMCPWriteIsNotAutoSaved() {
        let query = "create an issue in anthropics/claude-code"
        let call = mcpWriteCall()
        let ans = AppScopedChatService.Answer(
            text: "Created", toolChips: ["github.create_issue"],
            evidenceReceipts: [
                DoraXActionReceipt(command: "github.create_issue", output: "#42", success: true),
                DoraXActionReceipt(
                    command: "verify_outcome", output: "ok", success: true, isVerification: true),
            ])
        let skill = SolvedSkillCapture.build(
            query: query, answer: ans, toolCalls: [call],
            bundleId: bundleId, verifiedReadBack: true)
        #expect(skill == nil)
    }
}

// MARK: - H1b follow-up: the two runtime gaps left by PR #428
//
// 1. An external `run_mcp_tool` read never reached the collector — `run_mcp_tool` is a plumbing
//    tool, and the plumbing guard returned before the external branch.
// 2. A saved `run_menu_command` / `server.tool` call replayed through the capability registry,
//    where neither is a capability, so every replay threw `unknownCapability`.

@MainActor
struct ExternalMCPCollectorRecordingTests {

    private func scope(_ name: String) -> GeneralChatScope {
        .app(bundleId: "test.h1b.collector.\(name)")
    }

    @Test func externalReadReachesTheCollector() {
        let scope = scope("plain")
        SolvedSkillToolCallCollector.shared.begin(scope: scope)
        AgentToolRegistry.noteForSolvedSkill(
            name: "run_mcp_tool",
            arguments: [
                "server": "github", "tool": "list_issues",
                "arguments": ["owner": "anthropics", "state": "open"],
            ],
            verifiedReadBack: true, scope: scope)

        let calls = SolvedSkillToolCallCollector.shared.take(scope: scope)
        #expect(calls == [
            SolvedSkillToolCall(
                capability: "github.list_issues",
                argTemplate: ["owner": "anthropics", "state": "open"],
                isReadOnly: true)
        ])
    }

    /// The Anthropic streaming path hands values over wrapped in `AIProviderAnyCodable`.
    @Test func externalReadWithWrappedArgumentsReachesTheCollector() throws {
        let scope = scope("wrapped")
        let json = #"{"server":"github","tool":"list_issues","arguments":{"owner":"anthropics"}}"#
        let wrapped = try JSONDecoder().decode(
            [String: AIProviderAnyCodable].self, from: Data(json.utf8))
        SolvedSkillToolCallCollector.shared.begin(scope: scope)
        AgentToolRegistry.noteForSolvedSkill(
            name: "run_mcp_tool", arguments: wrapped, verifiedReadBack: true, scope: scope)

        let calls = SolvedSkillToolCallCollector.shared.take(scope: scope)
        #expect(calls.map(\.capability) == ["github.list_issues"])
        #expect(calls.first?.argTemplate == ["owner": "anthropics"])
        #expect(calls.first?.isReadOnly == true)
    }

    @Test func externalWriteIsRecordedAsNotReadOnly() {
        let scope = scope("write")
        SolvedSkillToolCallCollector.shared.begin(scope: scope)
        AgentToolRegistry.noteForSolvedSkill(
            name: "run_mcp_tool",
            arguments: ["server": "github", "tool": "create_issue", "arguments": ["title": "x"]],
            verifiedReadBack: false, scope: scope)
        #expect(SolvedSkillToolCallCollector.shared.take(scope: scope).first?.isReadOnly == false)
    }

    /// DoraX's own tools re-dispatch inside the server; only its capability and menu calls are
    /// recorded from the outer call, the rest stay plumbing.
    @Test func otherDoraXToolsStayPlumbing() {
        let scope = scope("dorax")
        SolvedSkillToolCallCollector.shared.begin(scope: scope)
        AgentToolRegistry.noteForSolvedSkill(
            name: "run_mcp_tool",
            arguments: ["server": "dorax", "tool": "dorax_frontmost_app", "arguments": [:]],
            verifiedReadBack: true, scope: scope)
        #expect(SolvedSkillToolCallCollector.shared.take(scope: scope).isEmpty)
    }
}

@MainActor
struct SolvedSkillReplayRoutingTests {

    private let bundleId = "test.h1b.replay"
    private var scope: GeneralChatScope { .app(bundleId: bundleId) }

    // ── Route choice (pure) ──────────────────────────────────────────────────────────

    @Test func routeChoice() {
        #expect(SolvedSkillMatch.replayRoute(for: "run_menu_command", isRegistered: false)
            == .menuCommand)
        #expect(SolvedSkillMatch.replayRoute(for: "mail.search", isRegistered: true)
            == .capability)
        #expect(SolvedSkillMatch.replayRoute(for: "github.list_issues", isRegistered: false)
            == .mcpTool(server: "github", tool: "list_issues"))
        #expect(SolvedSkillMatch.replayRoute(for: "list_issues", isRegistered: false)
            == .mcpTool(server: "", tool: "list_issues"))
    }

    // ── Replay ───────────────────────────────────────────────────────────────────────

    /// Records what the replay asked for, in place of the approval card and the tool handlers.
    @MainActor
    private final class Spy {
        var approvals: [String] = []
        var tools: [(name: String, arguments: [String: Any])] = []
        var approve = true
        var linked = true

        var environment: SolvedSkillMatch.ReplayEnvironment {
            SolvedSkillMatch.ReplayEnvironment(
                isRegistered: { _ in false },
                mcpToolIsLinked: { _, _ in self.linked },
                approve: { plan, _, _ in
                    self.approvals.append(plan.capability)
                    return self.approve
                },
                runTool: { name, arguments, _ in
                    self.tools.append((name, arguments))
                    var result = AgentToolResult(
                        success: true, output: "tool output", displayCommand: name)
                    result.verifiedByReadBack = "read back"
                    return result
                })
        }
    }

    private func skill(_ call: SolvedSkillToolCall) -> SolvedSkill {
        SolvedSkill(
            queryTemplate: "q", nonSlotWords: ["q"], slots: [], toolCalls: [call],
            bundleId: bundleId)
    }

    @Test func menuSkillReplaysThroughTheMenuTool() async throws {
        let spy = Spy()
        let call = SolvedSkillToolCall(
            capability: "run_menu_command",
            argTemplate: ["app": "Finder", "path": "Finder > Settings..."], isReadOnly: true)
        let answer = try #require(await SolvedSkillMatch.run(
            skill(call), filled: [:], scope: scope, environment: spy.environment))

        #expect(spy.tools.map(\.name) == ["run_menu_command"])
        #expect(spy.tools.first?.arguments["app"] as? String == "Finder")
        #expect(spy.tools.first?.arguments["path"] as? String == "Finder > Settings...")
        // The menu tool raises its own plan card; a second card here would ask twice.
        #expect(spy.approvals.isEmpty)
        // The read-back, never the tool's model-facing output (#316).
        #expect(answer.text == "read back")
        #expect(answer.toolChips == ["run_menu_command"])
    }

    @Test func externalMCPSkillAsksThenReplaysThroughTheMCPTool() async throws {
        let spy = Spy()
        let call = SolvedSkillToolCall(
            capability: "github.list_issues", argTemplate: ["since": "{day}"], isReadOnly: true)
        let answer = try #require(await SolvedSkillMatch.run(
            skill(call), filled: ["day": "today"], scope: scope, environment: spy.environment))

        #expect(spy.approvals == ["github.list_issues"])
        #expect(spy.tools.map(\.name) == ["run_mcp_tool"])
        let arguments = try #require(spy.tools.first?.arguments)
        #expect(arguments["server"] as? String == "github")
        #expect(arguments["tool"] as? String == "list_issues")
        #expect(arguments["arguments"] as? [String: String] == ["since": "today"])
        #expect(answer.text == "tool output")
    }

    @Test func declinedMCPReplayRunsNothing() async {
        let spy = Spy()
        spy.approve = false
        let call = SolvedSkillToolCall(
            capability: "github.list_issues", argTemplate: [:], isReadOnly: true)
        let answer = await SolvedSkillMatch.run(
            skill(call), filled: [:], scope: scope, environment: spy.environment)
        #expect(answer == nil)
        #expect(spy.tools.isEmpty)
    }

    /// A stale id, or a server since unlinked: no card for a call that cannot run.
    @Test func unlinkedMCPToolNeitherAsksNorRuns() async {
        let spy = Spy()
        spy.linked = false
        let call = SolvedSkillToolCall(
            capability: "github.list_issues", argTemplate: [:], isReadOnly: true)
        let answer = await SolvedSkillMatch.run(
            skill(call), filled: [:], scope: scope, environment: spy.environment)
        #expect(answer == nil)
        #expect(spy.approvals.isEmpty)
        #expect(spy.tools.isEmpty)
    }

    @Test func writeMCPToolIsNeverReplayed() async {
        let spy = Spy()
        let call = SolvedSkillToolCall(
            capability: "github.create_issue", argTemplate: [:], isReadOnly: true)
        let answer = await SolvedSkillMatch.run(
            skill(call), filled: [:], scope: scope, environment: spy.environment)
        #expect(answer == nil)
        #expect(spy.approvals.isEmpty)
        #expect(spy.tools.isEmpty)
    }

    // ── Cards ────────────────────────────────────────────────────────────────────────

    private func fileRow() -> ChatResultRow {
        let url = URL(fileURLWithPath: "/tmp/h1b-replay.txt")
        return ChatResultRow(kind: .file, id: url.path, title: "h1b-replay.txt", url: url)
    }

    /// What a replayed call read is handed back as rows, so the answer gets its cards.
    @Test func replayCarriesTheRowsItsCallsProduced() async throws {
        let spy = Spy()
        var environment = spy.environment
        let row = fileRow()
        let scope = scope
        environment.runTool = { name, _, _ in
            ChatResultRowCollector.shared.add([row], scope: scope)
            return AgentToolResult(success: true, output: "ok", displayCommand: name)
        }
        // A row left by an earlier turn must not ride along.
        ChatResultRowCollector.shared.add(
            [ChatResultRow(kind: .link, id: "stale", title: "stale")], scope: scope)
        let call = SolvedSkillToolCall(
            capability: "run_menu_command", argTemplate: ["app": "Finder", "path": "x"],
            isReadOnly: true)
        let answer = try #require(await SolvedSkillMatch.run(
            skill(call), filled: [:], scope: scope, environment: environment))
        #expect(answer.rows == [row])
        // Answered from the records, not from the call's model-facing listing.
        #expect(answer.text == "1 result\n\n- **h1b-replay.txt**")
    }

    /// A replay that fails hands the turn to the model; its rows must not follow.
    @Test func failedReplayLeavesNoRowsBehind() async {
        let spy = Spy()
        var environment = spy.environment
        let row = fileRow()
        let scope = scope
        environment.runTool = { name, _, _ in
            ChatResultRowCollector.shared.add([row], scope: scope)
            return AgentToolResult(success: false, output: "no", displayCommand: name)
        }
        let call = SolvedSkillToolCall(
            capability: "run_menu_command", argTemplate: [:], isReadOnly: true)
        let answer = await SolvedSkillMatch.run(
            skill(call), filled: [:], scope: scope, environment: environment)
        #expect(answer == nil)
        #expect(ChatResultRowCollector.shared.take(scope: scope).isEmpty)
    }
}

// MARK: - Replay wording

struct SolvedSkillReplyWordingTests {

    @Test func mailListingIsLaidOutForAPerson() {
        let raw = """
            Mailbox: All Mailboxes
            - Team offsite agenda | From: Example Sender <sender@example.com> | Wednesday, 11 November 2026 at 16:05:17 | Read: false | Mailbox: All Mail
            - Invoice | From: billing@example.com | Tuesday, 10 November 2026 at 09:30:00 | Read: true | Id: 42
            """
        #expect(SolvedSkillMatch.plainReply(for: raw) == """
            2 messages in All Mailboxes

            - **Team offsite agenda**
              Example Sender · Wednesday, 11 November 2026 at 16:05 · unread
            - **Invoice**
              billing@example.com · Tuesday, 10 November 2026 at 09:30
            """)
    }

    @Test func emptyMailListingSaysSo() {
        #expect(SolvedSkillMatch.plainReply(
            for: "Mailbox: Inbox\nNo matching messages found.") == "No matching messages.")
    }

    /// Titles and containers, so the answer still says something once its cards are gone.
    @Test func recordsBecomeAShortTitledList() {
        let rows = (1...12).map {
            ChatResultRow(
                kind: .note, id: "n\($0)", title: "Note \($0)", subtitle: $0 == 1 ? "Work" : "")
        }
        let reply = SolvedSkillMatch.plainReply(rows: rows)
        #expect(reply.hasPrefix("12 results\n\n- **Note 1** — Work\n- **Note 2**\n"))
        #expect(reply.hasSuffix("- **Note 10**\n- and 2 more"))
    }

    @Test func anythingElseIsPassedThrough() {
        #expect(SolvedSkillMatch.plainReply(for: "3 open issues") == "3 open issues")
        #expect(SolvedSkillMatch.plainReply(for: "") == "")
    }
}
