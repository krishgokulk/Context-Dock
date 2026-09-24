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

struct ChatPlanDuplicateRouteTests {

    private func route(_ id: String, app: String = "Notes") -> ChatRoute {
        ChatRoute(
            id: id, kind: .adapterAction, title: "New Note", payload: "new-note",
            appName: app, bundleId: "com.apple.Notes", isReadOnly: false)
    }

    @MainActor
    @Test func duplicateRouteIDsDoNotCrashThePlanner() async {
        // No API key, so planning returns nil rather than calling a model — the crash was in
        // building the lookup, which happens before any of that.
        let routes = [route("notes.create"), route("notes.create"), route("safari.tabs")]
        let plan = await ChatPlanRunner.plan(
            query: "save all opened tab links to one new note",
            routes: routes, provider: .openAI, apiKey: nil)
        // The assertion is that this returned at all.
        #expect(plan == nil || plan?.steps.isEmpty == false)
    }

    @MainActor
    @Test func aSingleRouteIsStillNotAPlan() async {
        let plan = await ChatPlanRunner.plan(
            query: "make a note", routes: [route("notes.create")], provider: .openAI,
            apiKey: nil)
        #expect(plan == nil)
    }
}
