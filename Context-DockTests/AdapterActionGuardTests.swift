import Foundation
import Testing

@testable import Context_Dock

// An adapter action is an action, and two things must never reach one.
//
// Found by pointing dorax_ask at the app and asking "how many notes do i have?". DoraX reached
// the Notes adapter's only action — New Note — and created a blank note on the user's Mac. The
// unattended run reported no approvals at all, because an adapter action whose requiresApproval
// is false runs immediately and never touches AICapabilityApprovalCenter.
//
// Two separate holes, each enough on its own:
//
//   1. Nobody at the keyboard, and a write ran anyway.
//   2. A counting question ran a write, because that write was the only route the adapter
//      offered. AgentToolRegistry already strips run_adapter_action from a query that only
//      asks; this path had no such guard.
//
// These assert the decision, never the execution. Two earlier versions of this file called
// `execute`: the first clicked File ▸ New Note for real and created blank notes while testing
// the fix for creating blank notes; the second used an impossible menu path but still reached
// runChain, which activates an app, which writes to the turn log and failed
// DoraXTurnLogTests/nothingIsWrittenUnlessItIsSwitchedOn. A test for a decision must not
// perform the thing it is deciding about.

@MainActor
struct AdapterActionGuardTests {

    private func menuAction(
        requiresApproval: Bool = false, isDestructive: Bool = false
    ) -> AdapterAction {
        AdapterAction(
            id: "starter.notes.new", name: "New Note", icon: "square.and.pencil",
            description: "Create a new note", type: .menubar,
            menuPath: ["File", "New Note"],
            requiresApproval: requiresApproval, isDestructive: isDestructive)
    }

    /// Spotify's current-track shape: an action that reads rather than commands.
    private var readingAction: AdapterAction {
        AdapterAction(
            id: "spotify.currentTrack", name: "Current Track", icon: "music.note",
            description: "What is playing", type: .applescript,
            script: "return \"nothing\"", requiresApproval: false, isDestructive: false)
    }

    private func refusal(
        _ action: AdapterAction, _ query: String, unattended: Bool = false
    ) -> String? {
        AppAdapterManager.refusalReason(for: action, query: query, unattended: unattended)
    }

    // MARK: - Unattended

    /// The safety promise dorax_ask makes. It was untrue for exactly this path.
    @Test func nothingRunsWhileUnattended() {
        let reason = refusal(menuAction(), "make a new note", unattended: true)
        #expect(reason?.lowercased().contains("unattended") == true)
    }

    /// Even a reader is refused unattended. The point is not which action it is — nobody is
    /// there to see what it did, so nothing runs.
    @Test func evenAReaderIsRefusedUnattended() {
        #expect(refusal(readingAction, "what's playing?", unattended: true) != nil)
    }

    // MARK: - A question is not an instruction

    /// The reported case, and its shape: a read that had only a write available.
    @Test func aQuestionNeverClicksAMenu() {
        for query in [
            "how many notes do i have?",
            "what's in this note?",
            "show me my notes",
        ] {
            #expect(
                refusal(menuAction(), query)?.contains("asks a question") == true,
                "\"\(query)\" only asks, and New Note changes something")
        }
    }

    /// An instruction must still get through.
    @Test func anInstructionIsNotRefused() {
        #expect(refusal(menuAction(), "create a new note") == nil)
        #expect(refusal(menuAction(), "make a new note") == nil)
    }

    /// A dock pill or menu click passes no query — the user pressing the thing themselves.
    @Test func pressingItYourselfPassesNoQuery() {
        #expect(refusal(menuAction(), "") == nil)
        #expect(refusal(menuAction(), "   ") == nil)
    }

    // MARK: - Not every action commands the app

    /// The narrowing that keeps "what's playing?" working. Refusing every action for every
    /// question would break the one question whose only good route is an action.
    @Test func aReadingActionStillAnswersAQuestion() {
        #expect(
            refusal(readingAction, "what's playing?") == nil,
            "an AppleScript reader is not a command, and this question has no other route")
        #expect(refusal(readingAction, "what song is this?") == nil)
    }

    /// Declared-dangerous actions are refused for a question whatever their type — a question
    /// is not a reason to run one.
    @Test func aDangerousActionIsRefusedForAQuestionEvenIfItReads() {
        let destructive = AdapterAction(
            id: "spotify.wipe", name: "Clear Queue", icon: "trash",
            description: "Clears the queue", type: .applescript,
            script: "return \"\"", requiresApproval: false, isDestructive: true)
        #expect(refusal(destructive, "what's playing?") != nil)

        let gated = AdapterAction(
            id: "spotify.gated", name: "Something Gated", icon: "lock",
            description: "Asks first", type: .applescript,
            script: "return \"\"", requiresApproval: true, isDestructive: false)
        #expect(refusal(gated, "what's playing?") != nil)
    }
}
