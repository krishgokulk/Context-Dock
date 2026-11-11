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
