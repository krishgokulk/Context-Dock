import Foundation
import Testing

@testable import Context_Dock

// MARK: - H4: Menu lane routing phrasebook
//
// Verifies §6–7 of docs/superpowers/specs/2026-11-09-agent-harness-model.md:
//   - Data requests don't get a menu-first instruction when a direct/script route exists.
//   - UI-lane requests (interface commands) get a menu-first instruction.
//   - The route instruction is emitted without reading the live menu snapshot.
//
// Append rows as new phrases are found to fail in hand tests. Do not rewrite existing rows.

struct MenuLaneRoutingTests {

    struct Phrase {
        let sentence: String
        let expectedLane: RequestLane
        let instructionContains: String
    }

    private static let phrasebook: [Phrase] = [
        // --- UI-lane: interface requests → menu-first ---
        Phrase(sentence: "show the sidebar",
               expectedLane: .ui, instructionContains: "run_menu_command"),
        Phrase(sentence: "split view",
               expectedLane: .ui, instructionContains: "run_menu_command"),
        Phrase(sentence: "toggle dark mode",
               expectedLane: .ui, instructionContains: "run_menu_command"),
        Phrase(sentence: "minimise the window",
               expectedLane: .ui, instructionContains: "run_menu_command"),
        Phrase(sentence: "open preferences",
               expectedLane: .ui, instructionContains: "run_menu_command"),
        Phrase(sentence: "hide the mailbox list",
               expectedLane: .ui, instructionContains: "run_menu_command"),

        // --- Data-lane: data requests → direct/script preferred, no menu push ---
        Phrase(sentence: "how many bookmarks are in Safari?",
               expectedLane: .data, instructionContains: "direct capabilities"),
        Phrase(sentence: "find notes with links",
               expectedLane: .data, instructionContains: "direct capabilities"),
        Phrase(sentence: "list my unread emails",
               expectedLane: .data, instructionContains: "direct capabilities"),
        Phrase(sentence: "search for the passport PDF",
               expectedLane: .data, instructionContains: "direct capabilities"),
        Phrase(sentence: "summarise this document",
               expectedLane: .data, instructionContains: "direct capabilities"),
        Phrase(sentence: "convert this to Word",
               expectedLane: .data, instructionContains: "direct capabilities"),
    ]

    @Test("RequestLane classifies every phrase to the expected lane")
    func laneDecision() {
        for phrase in Self.phrasebook {
            let lane = RequestLane.decide(phrase.sentence)
            #expect(
                lane == phrase.expectedLane,
                "'\(phrase.sentence)' → expected .\(phrase.expectedLane) but got .\(lane)"
            )
        }
    }

    @Test("menuRouteInstruction contains the expected routing keyword for each phrase")
    func routeInstruction() {
        for phrase in Self.phrasebook {
            let instruction = RequestLane.menuRouteInstruction(for: phrase.sentence)
            #expect(
                instruction.contains(phrase.instructionContains),
                "'\(phrase.sentence)' → instruction '\(instruction)' should contain '\(phrase.instructionContains)'"
            )
        }
    }

    @Test("UI-lane instruction does not tell the model to prefer direct capabilities")
    func uiLaneDoesNotSayDirectCapabilities() {
        for phrase in Self.phrasebook where phrase.expectedLane == .ui {
            let instruction = RequestLane.menuRouteInstruction(for: phrase.sentence)
            #expect(
                !instruction.contains("direct capabilities"),
                "UI-lane phrase '\(phrase.sentence)' should not get direct-capabilities instruction"
            )
        }
    }

    @Test("Data-lane instruction does not tell the model to prefer run_menu_command")
    func dataLaneDoesNotSayRunMenuCommand() {
        for phrase in Self.phrasebook where phrase.expectedLane == .data {
            let instruction = RequestLane.menuRouteInstruction(for: phrase.sentence)
            #expect(
                !instruction.lowercased().contains("prefer run_menu_command"),
                "Data-lane phrase '\(phrase.sentence)' should not get menu-first instruction"
            )
        }
    }
}
