import Testing
import Foundation
@testable import Context_Dock

// MARK: - A read-back that has already happened
//
// §9g gave the verified branches of run_capability and run_menu_command the sentence
// "This is the result — do not look for further evidence." In the very next run the model
// called verify_outcome on a path it had guessed anyway. The instruction was requested, not
// enforced, and what actually saved the answer was §9g's other half — an unreadable path
// now reports that it proves nothing.
//
// A typed read-back is the strongest evidence in the system: it read the thing back and
// said what it saw. Once that has happened there is nothing left for a guessed file check
// to establish, and everything for it to contradict.

@MainActor
struct SettledVerificationTests {

    @Test func verifyOutcomeIsRefusedOnceAReadBackHasSettledTheTurn() {
        #expect(AgentToolRegistry.isSupersededVerification(
            toolName: "verify_outcome",
            settledReadings: ["The reminder is in Reminders."]))
    }

    /// With nothing settled, verify_outcome is the right tool and must stay available —
    /// most writes have no typed verifier at all.
    @Test func verifyOutcomeIsAllowedWhenNothingHasBeenReadBack() {
        #expect(!AgentToolRegistry.isSupersededVerification(
            toolName: "verify_outcome", settledReadings: []))
    }

    /// Only that one tool is superseded. A verified write does not end the turn — the user
    /// may have asked for two things, and the second still needs doing.
    @Test func everyOtherToolKeepsWorkingAfterAReadBack() {
        let settled = ["The file is at /tmp/out.txt."]
        for tool in ["run_command", "run_capability", "run_menu_command", "read_file",
                     "spawn_worker", "search_items"] {
            #expect(!AgentToolRegistry.isSupersededVerification(
                toolName: tool, settledReadings: settled))
        }
    }

    /// The refusal has to hand back the reading itself. Told only "no", the model has lost
    /// both its tool and its evidence, and will report that it could not confirm the thing
    /// it just confirmed.
    @Test func theRefusalCarriesTheReadingThatSettledIt() {
        let reading = "I've added the reminder “buy milk”."
        let message = AgentToolRegistry.supersededVerificationMessage(
            settledReadings: [reading])
        #expect(message.contains(reading))
    }

    /// Several verified writes in one turn all belong in the refusal — reporting only the
    /// first would leave the model guessing about the rest.
    @Test func everyReadingThisTurnIsHandedBack() {
        let readings = ["The note exists in Notes.", "The reminder is in Reminders."]
        let message = AgentToolRegistry.supersededVerificationMessage(settledReadings: readings)
        for reading in readings { #expect(message.contains(reading)) }
    }
}
