import Testing
import Foundation
@testable import Context_Dock

// MARK: - Context Dock Chat route authority
//
// Context Dock Chat resolved its own routes and ran them without consulting
// AppAccessPolicy, so a chat scoped to an app the user had granted nothing beyond
// "I know it is installed" could still reach that app's MCP tools. These cover the
// mapping that lets this path ask the question, and the answers it must get.

@MainActor
struct ContextDockChatAuthorityTests {

    /// Every kind that runs something has to name its mechanism, or the gate has nothing to
    /// check and the guard silently lets it through.
    @Test func everyExecutingKindNamesItsMechanism() {
        #expect(ChatRoute.Kind.cli.executionRoute == .cli)
        #expect(ChatRoute.Kind.adapterAction.executionRoute == .adapter)
        #expect(ChatRoute.Kind.menuCommand.executionRoute == .verifiedMenu)
        #expect(ChatRoute.Kind.mcpTool.executionRoute == .mcp)
    }

    /// Skill steers the model and model answers from nothing. Neither executes, so neither
    /// has a mechanism to gate — and both must stay nil rather than borrow one.
    @Test func kindsThatRunNothingHaveNoMechanism() {
        #expect(ChatRoute.Kind.skill.executionRoute == nil)
        #expect(ChatRoute.Kind.model.executionRoute == nil)
    }

    /// The distinction menuOnly exists to draw: a menu command is public and observable, an
    /// MCP tool or an adapter CLI reads state the user never opened for us.
    @Test func menuOnlyPermitsTheMenuAndNothingElse() {
        #expect(AppAccessPolicy.allows(.verifiedMenu, at: .menuOnly))
        #expect(AppAccessPolicy.allows(.appLaunch, at: .menuOnly))
        #expect(AppAccessPolicy.allows(.keyboardShortcut, at: .menuOnly))

        #expect(!AppAccessPolicy.allows(.mcp, at: .menuOnly))
        #expect(!AppAccessPolicy.allows(.adapter, at: .menuOnly))
        #expect(!AppAccessPolicy.allows(.cli, at: .menuOnly))
        #expect(!AppAccessPolicy.allows(.api, at: .menuOnly))
        #expect(!AppAccessPolicy.allows(.automation, at: .menuOnly))
        #expect(!AppAccessPolicy.allows(.axFallback, at: .menuOnly))
    }

    @Test func awarenessPermitsOnlyLaunching() {
        #expect(AppAccessPolicy.allows(.appLaunch, at: .awareness))
        for route: DoraXActionCandidate.ExecutionRoute in
            [.verifiedMenu, .keyboardShortcut, .mcp, .adapter, .cli, .api, .automation, .axFallback]
        {
            #expect(!AppAccessPolicy.allows(route, at: .awareness))
        }
    }

    @Test func adapterPermitsEverything() {
        for route: DoraXActionCandidate.ExecutionRoute in
            [.appLaunch, .verifiedMenu, .keyboardShortcut, .mcp, .adapter, .cli, .api,
             .automation, .axFallback, .shortcutRunner]
        {
            #expect(AppAccessPolicy.allows(route, at: .adapter))
        }
    }

    /// Every kind Context Dock Chat can run maps onto a route the policy actually has an
    /// opinion about. A mechanism the gate does not recognise would be waved through.
    @Test func everyChatRouteMechanismIsGatedAtMenuOnly() {
        let executing: [ChatRoute.Kind] = [.cli, .adapterAction, .menuCommand, .mcpTool]
        for kind in executing {
            let mechanism = try! #require(kind.executionRoute)
            // Nothing is universally allowed at menuOnly except the menu itself; the point
            // is that each one has a defined answer rather than falling off the end.
            let allowed = AppAccessPolicy.allows(mechanism, at: .menuOnly)
            #expect(allowed == (mechanism == .verifiedMenu))
        }
    }
}
