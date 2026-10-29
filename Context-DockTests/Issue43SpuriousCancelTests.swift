import Foundation
import Testing

@testable import Context_Dock

// Issue #43: the Safari Pet showed "Cancelled — nothing was executed." for a benign menu
// action ("open a new tab in Safari"), the false sibling of the #42 over-ask.
//
// #42 made the Pet act by default on a clear primary route, but the click still went through
// the execution-approval gate as `.ask`: `executionApproval(for:)` granted only read-only
// routes and sent every `.menuCommand` to the card. A surface that does not render that card
// lets the request sit to its 60-second expiry and return `.cancelled`, so a reversible click
// like New Tab reported a cancel it never earned.
//
// Two fixes, both tested here:
//   1. Risk-gate the card. A menu command that neither destroys local state nor reaches
//      another person is authorised by the app's menu-control access and runs without a card;
//      deletes, sends and anything irreversible keep it. The destructive/outbound set is the
//      one `AppMenuConsentStore` already gates unattended runs by — no new classification.
//   2. Clear stale pending choices. A superseded "which should I use?" card could be tapped in
//      a later turn and re-enter the executor as `.ask` → cancel; a pick consumes the set and
//      a new turn supersedes it.

// `executionApproval`, `requiresPrompt` and `isDestructiveMenuCommand` are main-actor-isolated
// (the resolver reads main-actor stores), so the suite is too — otherwise the synchronous
// `@Test` calls don't compile. This exact isolation red-flagged #42's first test pass.
@MainActor
struct Issue43ExecutionApprovalRiskGateTests {

    private static let safari = "com.apple.Safari"

    /// A menu-command route whose payload is the path, joined the way the resolver joins it.
    private func menuRoute(_ path: [String], readOnly: Bool = false) -> ChatRoute {
        ChatRoute(
            id: "menu:\(path.joined(separator: " ▸ "))",
            kind: .menuCommand,
            title: path.joined(separator: " ▸ "),
            payload: path.joined(separator: "\u{1}"),
            appName: "Safari",
            bundleId: Self.safari,
            isReadOnly: readOnly)
    }

    private func freshKey() -> String { "test.issue43.\(UUID().uuidString)" }

    // MARK: - Benign menu commands run without a card

    @Test func newTabIsGrantedAndNeverPrompts() {
        let route = menuRoute(["File", "New Tab"])
        #expect(!route.isDestructiveMenuCommand, "New Tab destroys nothing and reaches no one")
        let approval = ChatRouteResolver.executionApproval(for: route)
        #expect(
            approval == .granted(.accessPolicy),
            "a reversible menu click is what menu-control access is for — no execution card")
        // The gate the executor actually runs: a granted route never prompts, so the request
        // cannot sit to its expiry and come back cancelled (#43).
        #expect(!GeneralAIActionExecutor.requiresPrompt(approval, permissionKey: freshKey()))
    }

    @Test func aViewToggleIsAlsoGranted() {
        let approval = ChatRouteResolver.executionApproval(for: menuRoute(["View", "Zoom In"]))
        #expect(approval == .granted(.accessPolicy))
    }

    // MARK: - Destructive and outbound menu commands still ask (security-critical)

    @Test func deleteStillRaisesTheCard() {
        let route = menuRoute(["Edit", "Delete Note"])
        #expect(route.isDestructiveMenuCommand, "deleting local state must stay gated")
        let approval = ChatRouteResolver.executionApproval(for: route)
        #expect(approval == .ask, "a destructive menu command keeps its execution card")
        #expect(
            GeneralAIActionExecutor.requiresPrompt(approval, permissionKey: freshKey()),
            "with no standing grant the card is owed before anything deletes")
    }

    @Test func sendStillRaisesTheCard() {
        // Outbound: putting something in front of another person is observable, not reversible.
        let route = menuRoute(["Message", "Send"])
        #expect(route.isDestructiveMenuCommand)
        #expect(ChatRouteResolver.executionApproval(for: route) == .ask)
    }

    @Test func quitStillRaisesTheCard() {
        let route = menuRoute(["Safari", "Quit Safari"])
        #expect(route.isDestructiveMenuCommand)
        #expect(ChatRouteResolver.executionApproval(for: route) == .ask)
    }

    /// A still-declined destructive action must report the (correct, non-error) cancel — the
    /// gate did not disappear, it only stopped firing for benign clicks.
    @Test func aDeclinedDestructiveActionIsACancelNotAFailure() {
        let cancelled = GeneralAIActionResult.cancelled(routeLabel: "Delete Note")
        #expect(cancelled.wasCancelled)
        #expect(!cancelled.success)
    }

    // MARK: - The fix does not blanket-suppress the card

    @Test func mcpToolWritesStillAsk() {
        // MCP writes have no later gate and no destructive classification to read, so the
        // card stays: the fix is scoped to menu commands.
        let route = ChatRoute(
            id: "mcp:server:do_thing", kind: .mcpTool, title: "do thing",
            payload: "server\u{1}do_thing", appName: "Safari", bundleId: Self.safari,
            isReadOnly: false)
        #expect(ChatRouteResolver.executionApproval(for: route) == .ask)
    }

    @Test func readOnlyRoutesAreGrantedAsBefore() {
        let route = menuRoute(["View", "Show All Tabs"], readOnly: true)
        #expect(ChatRouteResolver.executionApproval(for: route) == .granted(.accessPolicy))
    }

    @Test func destructivenessIsAMenuOnlyQuestion() {
        // The classifier is about menu paths; a non-menu kind has no path to read.
        let adapter = ChatRoute(
            id: "adapter:new-tab", kind: .adapterAction, title: "New Tab", payload: "new-tab",
            appName: "Safari", bundleId: Self.safari, isReadOnly: false)
        #expect(!adapter.isDestructiveMenuCommand)
    }
}

// The pending-route store is a main-actor static shared across the process, so this suite is
// main-actor too and every test scopes to a unique bundle id — no seeded set can leak into
// another test's reads, however the runner schedules them.
@MainActor
struct Issue43PendingRouteClearingTests {

    private func uniqueScope() -> GeneralChatScope {
        .app(bundleId: "test.issue43.\(UUID().uuidString)")
    }

    private func route(_ title: String) -> ChatRoute {
        ChatRoute(
            id: "menu:\(title)", kind: .menuCommand, title: title, payload: title,
            appName: "App", bundleId: "test.issue43", isReadOnly: false)
    }

    /// A pick consumes the choices, and `runChosenRoute` clears the same set this exercises —
    /// it really executes, so the clearing is tested on the primitive both it and a new turn
    /// (`sendUntraced`) call.
    @Test func clearingDropsTheScopesPendingChoices() {
        let scope = uniqueScope()
        defer { AppScopedChatService.clearPendingRoutes(scope: scope) }

        AppScopedChatService.rememberPendingRoutes(
            [route("File ▸ New Tab"), route("File ▸ New Private Tab")], scope: scope)
        #expect(
            !AppScopedChatService.pendingRouteIDs(for: scope).isEmpty,
            "a question with choices leaves a pending set to tap")

        AppScopedChatService.clearPendingRoutes(scope: scope)
        #expect(
            AppScopedChatService.pendingRouteIDs(for: scope).isEmpty,
            "once consumed or superseded, no card is left to re-run a stale route (#43)")
    }

    @Test func clearingIsScopedToOneThread() {
        let kept = uniqueScope()
        let dropped = uniqueScope()
        defer {
            AppScopedChatService.clearPendingRoutes(scope: kept)
            AppScopedChatService.clearPendingRoutes(scope: dropped)
        }

        AppScopedChatService.rememberPendingRoutes([route("File ▸ New Tab")], scope: dropped)
        AppScopedChatService.rememberPendingRoutes([route("Message ▸ Reply")], scope: kept)

        AppScopedChatService.clearPendingRoutes(scope: dropped)
        #expect(AppScopedChatService.pendingRouteIDs(for: dropped).isEmpty)
        #expect(
            !AppScopedChatService.pendingRouteIDs(for: kept).isEmpty,
            "clearing one thread's choices must not touch another's")
    }
}
