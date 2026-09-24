import Foundation
import Testing

@testable import Context_Dock

// The planner must not trap on data.
//
// Asking "save all opened tab links to one new note" crashed the app:
//
//     _NativeDictionary.merge(trappingOnDuplicates:)
//     Dictionary.init<A>(uniqueKeysWithValues:)
//     ChatPlanRunner.plan(query:routes:provider:apiKey:)
//
// Routes are resolved per app and concatenated, so the same route arrives twice whenever an
// app is in the list twice — ordinary now that a request naming two apps puts both in the
// conversation, and a combined chat can hold an app that is also the thread's own.
// `uniqueKeysWithValues` treats a duplicate key as a programming error; here it is data, and
// the two copies are equal.
//
// The lookup is built from the model's reply, so these tests hand `plan(fromReply:)` a reply
// rather than asking a model. The first version called `plan(query:…)` with no key, which
// still asked the provider service — a real model call on a developer's Mac, and a 120-second
// stall on CI — and only reached the lookup when a model happened to answer.

@MainActor
struct ChatPlanDuplicateRouteTests {

    private func route(_ id: String, app: String = "Notes") -> ChatRoute {
        ChatRoute(
            id: id, kind: .adapterAction, title: "New Note", payload: "new-note",
            appName: app, bundleId: "com.apple.Notes", isReadOnly: false)
    }

    private let twoStepReply = """
        {"plan":[{"id":"safari.tabs","purpose":"read the tabs","after":[]},
                 {"id":"notes.create","purpose":"write them down","after":[0]}],
         "summary":"Tabs into a note"}
        """

    @Test func duplicateRouteIDsDoNotCrashThePlanner() throws {
        let routes = [route("notes.create"), route("notes.create"), route("safari.tabs", app: "Safari")]
        let plan = try #require(ChatPlanRunner.plan(fromReply: twoStepReply, routes: routes))
        #expect(plan.steps.map(\.route.id) == ["safari.tabs", "notes.create"])
        #expect(plan.steps[1].dependsOn == [0])
    }

    @Test func aStepNamingAnUnofferedRouteRejectsThePlan() {
        let routes = [route("notes.create"), route("notes.create")]
        #expect(ChatPlanRunner.plan(fromReply: twoStepReply, routes: routes) == nil)
    }

    @Test func aSingleRouteIsStillNotAPlan() async {
        // Returns before any provider is asked: one route cannot be several steps.
        let plan = await ChatPlanRunner.plan(
            query: "make a note", routes: [route("notes.create")], provider: .openAI,
            apiKey: nil)
        #expect(plan == nil)
    }
}
