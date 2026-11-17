import Testing
import Foundation
@testable import Context_Dock

// Issue #52: "how many notes do i have?" must return the live count from Notes.app,
// not a stale or partial count from the metadata index.
//
// The routing chain:
//   notes.count executor
//     → AppleNotesMCPServer.noteCount()
//       → AppleNotesExecutionService.noteCount()   (primary: one Apple Event)
//         fallback: AppleNotesMetadataIndex.cachedCount (only if the script fails and cache > 0)
//
// These tests verify the structural contract without requiring a live Notes.app.

@MainActor
struct NotesCountRoutingTests {

    // MARK: - Registration

    @Test func notesCountCapabilityIsRegistered() {
        let registry = CapabilityRegistry.shared
        AppleNotesMCPCapabilities.register(in: registry)

        let cap = registry.capability(id: "notes.count")
        #expect(cap != nil, "notes.count must be registered so the model can call it")
        #expect(cap?.appBundleID == "com.apple.Notes")
    }

    @Test func notesCountIsLowRisk() {
        let registry = CapabilityRegistry.shared
        AppleNotesMCPCapabilities.register(in: registry)

        guard let cap = registry.capability(id: "notes.count") else {
            Issue.record("notes.count not registered"); return
        }
        // Count is a single-event read with no body access.
        // .medium here would add an unnecessary approval dialog to every count query.
        #expect(
            !cap.riskLevel.requiresApproval,
            "notes.count reads nothing sensitive; requiring approval would block 'how many notes?'"
        )
    }

    // MARK: - Count ≠ search

    /// The fix for #52 is that "how many notes?" reaches notes.count, not notes.search.
    /// notes.search requires a query term, returns a bounded page of matches, and reads
    /// from the metadata index — none of which is what a simple total needs.
    @Test func notesCountAndSearchAreDistinctCapabilities() {
        let registry = CapabilityRegistry.shared
        AppleNotesMCPCapabilities.register(in: registry)

        let count = registry.capability(id: "notes.count")
        let search = registry.capability(id: "notes.search")
        #expect(count != nil, "notes.count must exist as a first-class capability")
        #expect(search != nil, "notes.search must still exist alongside it")
        // Structural: count has no input fields; search requires 'query'.
        // A model that cannot call notes.count falls back to notes.search with a blank query,
        // which returns a bounded page and an incorrect total — the original bug.
        #expect(
            count?.inputSchema.fields.isEmpty == true,
            "notes.count takes no inputs — it is always a total, never a filtered page"
        )
    }

}
