import Testing
import Foundation
@testable import Context_Dock

// MARK: - What the user granted outranks what happens to be installed
//
// Step 4 of docs/architecture/APP_KNOWLEDGE_SKILLS.md.
//
// "find my bookmarks note and summarise that" resolved to the Find My application,
// because resolveTargetApp scans every app on the disk for its name and ranks
// leftmost-first. Find My was never a capability — it is a file in /Applications, and it
// beat the word "note" purely by standing earlier in the sentence.
//
// The tier already exists and is already Comparable: AppAccessLevel. `awareness` means
// "installed, maybe running, nothing more". `adapter` means the user added it. Ranking by
// that before position is the whole fix, and it does not break launching an app by name —
// a bare installed app still wins when nothing better is named.

@MainActor
struct CapabilityRankedAppMatchTests {

    private func outranks(
        _ lhs: (AppAccessLevel, Int, Int, String),
        _ rhs: (AppAccessLevel, Int, Int, String)
    ) -> Bool {
        GeneralAIActionResolver.matchOutranks(
            lhsLevel: lhs.0, lhsStart: lhs.1, lhsLength: lhs.2, lhsName: lhs.3,
            rhsLevel: rhs.0, rhsStart: rhs.1, rhsLength: rhs.2, rhsName: rhs.3)
    }

    // MARK: - Authority first

    /// The sentence from the report, in miniature: "find my" at position 0 with no adapter,
    /// against an app the user actually added, further along.
    @Test func aGrantedAppBeatsABareInstalledOneEarlierInTheSentence() {
        #expect(outranks(
            (.adapter, 8, 5, "Notes"),
            (.awareness, 0, 7, "Find My")))
        #expect(!outranks(
            (.awareness, 0, 7, "Find My"),
            (.adapter, 8, 5, "Notes")))
    }

    /// A cached menu bar is a real handle on an app, and beats knowing it merely exists.
    @Test func menuOnlyBeatsAwareness() {
        #expect(outranks(
            (.menuOnly, 20, 4, "Mail"),
            (.awareness, 0, 6, "Safari")))
    }

    @Test func adapterBeatsMenuOnly() {
        #expect(outranks(
            (.adapter, 30, 4, "Code"),
            (.menuOnly, 0, 6, "Safari")))
    }

    // MARK: - Existing behaviour, preserved

    /// Within the same tier the old rules stand: people name the target before qualifying
    /// it, so the leftmost name is the subject.
    @Test func withinATierTheLeftmostNameStillWins() {
        #expect(outranks(
            (.adapter, 0, 7, "Ghostty"),
            (.adapter, 8, 8, "Terminal")))
    }

    /// Length only breaks ties at the same position — this is what keeps "vs code" from
    /// being read as "code".
    @Test func atTheSamePositionTheLongerNameWins() {
        #expect(outranks(
            (.adapter, 0, 7, "VS Code"),
            (.adapter, 0, 4, "Code")))
    }

    /// Stable, so the same sentence always resolves the same way.
    @Test func tiesResolveByNameSoRankingIsStable() {
        #expect(outranks(
            (.awareness, 0, 4, "Alpha"),
            (.awareness, 0, 4, "Beta")))
        #expect(!outranks(
            (.awareness, 0, 4, "Beta"),
            (.awareness, 0, 4, "Alpha")))
    }

    /// Launching by name must keep working. With nothing granted anywhere in the sentence,
    /// a bare installed app is still a legitimate answer.
    @Test func aBareInstalledAppStillWinsWhenNothingBetterIsNamed() {
        #expect(outranks(
            (.awareness, 0, 7, "Ghostty"),
            (.awareness, 12, 4, "Mail")))
    }
}
