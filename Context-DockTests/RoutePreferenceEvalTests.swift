import Foundation
import Testing

@testable import Context_Dock

// Evals for which route wins when several could carry out a request.
//
// Asked to save a page into Notes, DoraX offered to click `Edit → Add Link…` in Notes — a
// menu item that is disabled unless a note is already open — while notes.append sat unused.
// It was not a ranking accident: the selection accepted a menu and a capability as equally
// good and took whichever the text matcher had put first, and "Add Link…" shares a word with
// "add".
//
// The order asserted here is the one ChatRouteResolver already documents: the app's own tools
// first, structured data next, inspectable commands after that, and driving the screen last —
// because that is the only route with a visible cost and the only one that fails when the app
// happens to be in the wrong state.

struct RoutePreferenceEvalTests {

    @Test func theAppsOwnToolOutranksItsMenuBar() {
        #expect(
            ChatRoute.Kind.adapterAction.rank < ChatRoute.Kind.menuCommand.rank,
            "a capability must be preferred over clicking the app's menu")
    }

    @Test func structuredDataOutranksTheScreen() {
        #expect(ChatRoute.Kind.mcpTool.rank < ChatRoute.Kind.menuCommand.rank)
        #expect(ChatRoute.Kind.cli.rank < ChatRoute.Kind.menuCommand.rank)
    }

    @Test func onlyTheMenuRouteTakesTheScreen() {
        // The property the ordering exists to protect: everything above the menu answers
        // without touching what the user is looking at.
        #expect(ChatRoute.Kind.menuCommand.takesTheScreen)
        #expect(!ChatRoute.Kind.adapterAction.takesTheScreen)
        #expect(!ChatRoute.Kind.mcpTool.takesTheScreen)
        #expect(!ChatRoute.Kind.cli.takesTheScreen)
    }

    @Test func answeringWithoutRunningAnythingIsTheLastResort() {
        // A model answering from memory ranks below every route that can check.
        for kind in [ChatRoute.Kind.adapterAction, .mcpTool, .cli, .menuCommand] {
            #expect(kind.rank < ChatRoute.Kind.model.rank)
        }
    }
}
