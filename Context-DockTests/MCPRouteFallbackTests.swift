import Foundation
import Testing

@testable import Context_Dock

// Issue #45: "open a new tab" ranks the MCP `create_tab` tool first. When that route could not
// run — server down, call errored, the gate refused it — the Pet stopped on its error even
// though the granted `File ▸ New Tab` menu route would just work.
//
// `fallbackRoute` names the next runnable route after a failed MCP route. It must not turn a
// user's "no" into a second attempt, and must not turn a read into a write.
@MainActor
struct MCPRouteFallbackTests {

    private static let safari = "com.apple.Safari"

    private func route(
        _ kind: ChatRoute.Kind, _ title: String, readOnly: Bool = false
    ) -> ChatRoute {
        ChatRoute(
            id: "\(kind.rawValue):\(title)", kind: kind, title: title, payload: title,
            appName: "Safari", bundleId: Self.safari, isReadOnly: readOnly)
    }

    private var newTab: [ChatRoute] {
        [route(.mcpTool, "create_tab"), route(.menuCommand, "File ▸ New Tab")]
    }

    @Test func failedMCPWriteFallsThroughToTheGrantedMenuRoute() {
        let next = ChatRouteResolver.fallbackRoute(
            after: newTab[0],
            output: "MCP tool create_tab failed: not connected",
            in: newTab)
        #expect(next?.kind == .menuCommand)
        #expect(next?.title == "File ▸ New Tab")
    }

    @Test func aDeclinedApprovalIsNotRetriedAnotherWay() {
        let next = ChatRouteResolver.fallbackRoute(
            after: newTab[0],
            output: "MCP tool create_tab failed: \(MCPRuntime.userDeclinedPrefix) open a page in safari.",
            in: newTab)
        #expect(next == nil, "the user said no; a different route is not a way around it")
    }

    @Test func aCancelledExecutorCardIsNotRetriedAnotherWay() {
        // The executor's own approval card, not the browser gate's: its refusal text is
        // `Cancelled … — nothing was executed.` and carries `wasCancelled`, not the prefix.
        let cancelled = GeneralAIActionResult.cancelled(routeLabel: "create_tab")
        let next = ChatRouteResolver.fallbackRoute(
            after: newTab[0], output: cancelled.message, wasCancelled: cancelled.wasCancelled,
            in: newTab)
        #expect(next == nil, "cancelling the card is a no; the menu route must not ask again")
    }

    @Test func aReadNeverEscalatesToAWrite() {
        let routes = [
            route(.mcpTool, "list_tabs", readOnly: true), route(.menuCommand, "File ▸ New Tab"),
        ]
        let next = ChatRouteResolver.fallbackRoute(
            after: routes[0], output: "MCP tool list_tabs failed", in: routes)
        #expect(next == nil)
    }

    @Test func onlyRunnableKindsAreFallbacks() {
        let routes = [
            route(.mcpTool, "create_tab"), route(.skill, "Tab workflow"),
            route(.computerUse, "Press New Tab"), route(.model, "Answer"),
        ]
        #expect(
            ChatRouteResolver.fallbackRoute(after: routes[0], output: "failed", in: routes) == nil)
    }

    @Test func onlyAFailedMCPRouteFallsBack() {
        let menuFirst = [route(.menuCommand, "File ▸ New Tab"), route(.cli, "open -a Safari")]
        #expect(
            ChatRouteResolver.fallbackRoute(after: menuFirst[0], output: "failed", in: menuFirst)
                == nil)
    }

    // The ChatGPT turn's route list: both menu items share the words of "open new tab".
    @Test func thePlainFormWinsOverItsLongerSibling() {
        let routes = [
            route(.menuCommand, "File ▸ New Tab at End"), route(.menuCommand, "File ▸ New Tab"),
        ]
        #expect(ChatRouteResolver.plainestRoute(routes)?.title == "File ▸ New Tab")
    }

    @Test func unrelatedRoutesAreNeverPickedBetween() {
        let routes = [route(.menuCommand, "File ▸ New Tab"), route(.menuCommand, "File ▸ Open File")]
        #expect(ChatRouteResolver.plainestRoute(routes) == nil)
    }
}

@Suite("MCP read-tool hint")
struct MCPReadToolHintTests {
    @Test("A wrong tool name is answered with the server's real read tools (#357)")
    func hintNamesRealReadTools() {
        let hint = MCPToolSafety.readToolHint(
            available: ["close_tab", "list_tabs", "navigate_to_url", "get_page_content"])
        #expect(hint.contains("list_tabs"))
        #expect(hint.contains("get_page_content"))
        #expect(!hint.contains("close_tab"))
        #expect(!hint.contains("navigate_to_url"))
        #expect(MCPToolSafety.readToolHint(available: ["close_tab"]).isEmpty)
    }
}
