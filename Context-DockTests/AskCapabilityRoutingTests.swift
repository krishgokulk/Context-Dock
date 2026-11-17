import Testing
import Foundation
@testable import Context_Dock

// Issue #55: "how many notes do i have?" via dorax_ask dispatched only against adapter
// actions. The Notes adapter's only action was "New Note", so a counting question
// created a blank note. The root cause: ChatRouteResolver.routes applied word-overlap
// matching even for question queries, and "notes" (the app name) was stripped from
// the query terms — leaving only "how", "many", "have", which match nothing in
// notes.count or notes.search.
//
// Fix: for question-shaped queries, all read-only CapabilityRegistry capabilities
// for the scoped bundle ID are included as candidate routes without term-matching.
// Action queries still require word overlap so the list stays focused.

@MainActor
struct AskCapabilityRoutingTests {

    private let notesBundleID = "com.apple.Notes"
    private let notesAppName = "Notes"

    private func registerNotes() {
        AppleNotesMCPCapabilities.register(in: CapabilityRegistry.shared)
    }

    // MARK: - Question queries include read-only capabilities without term-match

    /// "how many notes do i have?" contains no word that overlaps with "notes.count" or
    /// "Count Notes" once "notes" is removed as the app name. Before the fix this returned
    /// no capability routes and the turn fell through to the Notes adapter action (New Note).
    @Test func countQueryIncludesNotesCountCapability() async {
        registerNotes()
        let routes = await ChatRouteResolver.routes(
            for: "how many notes do i have?",
            bundleId: notesBundleID,
            appName: notesAppName)
        let capabilityIDs = routes.compactMap { route -> String? in
            guard route.payload.hasPrefix("notes.") else { return nil }
            return route.payload
        }
        #expect(
            capabilityIDs.contains("notes.count"),
            "notes.count must be in routes for a count question; got \(capabilityIDs)")
    }

    /// "do i have any notes with links?" has no term overlap with capability IDs or titles
    /// after "notes" is removed, but notes.search is a read-only capability for this scope
    /// and must be reachable.
    @Test func searchQueryIncludesNotesSearchCapability() async {
        registerNotes()
        let routes = await ChatRouteResolver.routes(
            for: "do i have any notes with links?",
            bundleId: notesBundleID,
            appName: notesAppName)
        let payloads = Set(routes.map(\.payload))
        #expect(
            payloads.contains("notes.search"),
            "notes.search must be in routes for a question; got \(payloads)")
    }

    /// All read-only Notes capabilities must be in the route list for a generic question.
    @Test func questionRoutesIncludeAllReadOnlyNotesCapabilities() async {
        registerNotes()
        let routes = await ChatRouteResolver.routes(
            for: "what do i have in notes?",
            bundleId: notesBundleID,
            appName: notesAppName)
        let capRoutes = routes.filter { $0.payload.hasPrefix("notes.") && $0.isReadOnly }
        #expect(
            !capRoutes.isEmpty,
            "at least one read-only Notes capability must appear for a generic question")
        // Every capability route that appears must be read-only (safe to dispatch unattended)
        for r in capRoutes {
            #expect(r.isReadOnly, "capability route \(r.payload) must be read-only")
        }
    }

    // MARK: - Unattended route resolves to notes.count for counting questions

    /// When routes are filtered to read-only (as the ask path does for question queries),
    /// notes.count is the only headless read that can answer a total-count question.
    /// unattendedRoute must pick it rather than returning nil.
    @Test func unattendedRoutePicksCountCapability() async {
        registerNotes()
        let allRoutes = await ChatRouteResolver.routes(
            for: "how many notes do i have?",
            bundleId: notesBundleID,
            appName: notesAppName)
        // Simulate the asksOnly filter in sendUntraced
        let permitted = allRoutes.filter { $0.isReadOnly && !$0.kind.takesTheScreen }
        let unattended = ChatRouteResolver.unattendedRoute(permitted)
        #expect(
            unattended != nil,
            "unattendedRoute must find at least one candidate for 'how many notes do i have?'")
    }

    // MARK: - Action queries still require term-match

    /// For an action request the word-overlap filter still applies, so capabilities whose
    /// title/id/synonyms don't match the action words are NOT added to the list. This keeps
    /// the route list tight and prevents every read capability from appearing as a candidate
    /// for a command like "create a new note".
    @Test func actionQueryDoesNotIncludeUnrelatedCapabilities() async {
        registerNotes()
        let routes = await ChatRouteResolver.routes(
            for: "create a new note",
            bundleId: notesBundleID,
            appName: notesAppName)
        // notes.count has no word overlap with "create" or "new" — it must not appear
        let countRoute = routes.first { $0.payload == "notes.count" }
        #expect(
            countRoute == nil,
            "notes.count must not appear as a route for an action request 'create a new note'")
    }

    // MARK: - Candidate conversion for capability routes

    /// A capability route converts to a candidate with capabilityID set, not adapterActionID.
    /// If capabilityID is nil the executor falls through to AppAdapterManager, which has no
    /// knowledge of CapabilityRegistry and fails with "Adapter route is missing its payload".
    @Test func capabilityRouteConvertsWithCapabilityID() throws {
        registerNotes()
        let route = ChatRoute(
            id: "capability:notes.count",
            kind: .adapterAction,
            title: "Count Notes",
            payload: "notes.count",
            appName: notesAppName,
            bundleId: notesBundleID,
            isReadOnly: true)
        let candidate = try #require(route.asCandidate())
        #expect(
            candidate.capabilityID == "notes.count",
            "capabilityID must be set so executeAdapterRoute dispatches to AIExecutionEngine")
        #expect(
            candidate.adapterActionID == nil,
            "adapterActionID must be nil so AppAdapterManager is not consulted")
    }
}
