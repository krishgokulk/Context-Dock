import Foundation
import Testing

@testable import Context_Dock

// Issue #42: the Safari Pet over-asked "which should I use?" on actions that have an obvious
// default route.
//
// `shouldAsk` prompted whenever more than one route existed, at least one of them a write, and
// the user had not already taught a preference for the app — regardless of whether the ranking
// already named a clear primary. "open a new tab in Safari" resolves to the app's own new-tab
// action AND the `File ▸ New Tab` menu click; both are writes and neither was learned, so the
// Pet stopped to ask instead of just taking ⌘T.
//
// The fix: act by default. Ask only when the top two routes are genuinely tied — same rank and
// same risk, no clear winner. A clear primary (a route that outranks the runner-up) runs. This
// is the app-scoped twin of the General AI path's `confidence < 0.7` gate; deterministic
// ranking stands in for confidence. The learned-preference bypass is unchanged.

struct AppChatOverAskDefaultRouteTests {

    private static let safari = "com.apple.Safari"

    private func route(
        _ kind: ChatRoute.Kind, _ title: String, readOnly: Bool = false
    ) -> ChatRoute {
        ChatRoute(
            id: "\(kind.rawValue):\(title)", kind: kind, title: title, payload: title,
            appName: "Safari", bundleId: Self.safari, isReadOnly: readOnly)
    }

    // The resolver returns routes already ordered by `kind.rank`; model the primary first.
    private var newTabRoutes: [ChatRoute] {
        [route(.adapterAction, "New Tab"), route(.menuCommand, "File ▸ New Tab")]
    }

    @Test func openNewTabRunsTheClearPrimaryWithoutAsking() {
        let routes = newTabRoutes
        ChatRoutePreferenceStore.forget(bundleId: Self.safari)
        defer { ChatRoutePreferenceStore.forget(bundleId: Self.safari) }

        #expect(
            !ChatRouteResolver.shouldAsk(
                routes: routes, bundleId: Self.safari, query: "open a new tab in Safari"),
            "an action with an obvious default route must not stop to ask")
        let primary = ChatRouteResolver.clearPrimaryRoute(routes)
        #expect(primary?.kind == .adapterAction, "the app's own action outranks the menu click")
    }

    @Test func genuinelyTiedRoutesStillAsk() {
        // Two menu commands, same rank and same risk: no route is obviously right, so the
        // user still makes the call.
        let routes = [
            route(.menuCommand, "File ▸ New Tab"),
            route(.menuCommand, "File ▸ New Private Tab"),
        ]
        ChatRoutePreferenceStore.forget(bundleId: Self.safari)
        defer { ChatRoutePreferenceStore.forget(bundleId: Self.safari) }

        #expect(ChatRouteResolver.clearPrimaryRoute(routes) == nil, "tied routes name no primary")
        #expect(
            ChatRouteResolver.shouldAsk(
                routes: routes, bundleId: Self.safari, query: "open a new tab in Safari"),
            "equal-risk, equal-rank routes with no clear winner still ask")
    }

    @Test func aLearnedPreferenceStillShortCircuits() {
        // Even a genuinely tied set does not ask once the user has taught a pick for the app.
        let routes = [
            route(.menuCommand, "File ▸ New Tab"),
            route(.menuCommand, "File ▸ New Private Tab"),
        ]
        ChatRoutePreferenceStore.remember(
            .menuCommand, bundleId: Self.safari, query: "open a new tab in Safari")
        defer { ChatRoutePreferenceStore.forget(bundleId: Self.safari) }

        #expect(
            !ChatRouteResolver.shouldAsk(
                routes: routes, bundleId: Self.safari, query: "open a new tab in Safari"),
            "a learned preference answers the question before it is asked")
    }

    @Test func aReadOnlyRouteSetNeverAsks() {
        // The point of asking is the call on consequence; there is none to weigh among reads.
        let routes = [
            route(.mcpTool, "List Tabs", readOnly: true),
            route(.cli, "safari tabs", readOnly: true),
        ]
        ChatRoutePreferenceStore.forget(bundleId: Self.safari)
        defer { ChatRoutePreferenceStore.forget(bundleId: Self.safari) }

        #expect(
            !ChatRouteResolver.shouldAsk(
                routes: routes, bundleId: Self.safari, query: "list the open tabs"))
    }

    @Test func oneRouteIsItsOwnPrimary() {
        let routes = [route(.adapterAction, "New Tab")]
        #expect(ChatRouteResolver.clearPrimaryRoute(routes)?.title == "New Tab")
    }

    @Test func noRoutesHaveNoPrimary() {
        #expect(ChatRouteResolver.clearPrimaryRoute([]) == nil)
    }
}
