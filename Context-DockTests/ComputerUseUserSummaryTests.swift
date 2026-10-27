import Foundation
import Testing

@testable import Context_Dock

// #316: a turn must never end with a tool's model-facing `output` as the user-facing answer.
//
// `operate_app`'s result text is written FOR THE MODEL throughout — it carries next-step
// instructions ("run find_route first", "do not invent an outcome") that steer the tool loop.
// The `.operateApp` directive path (DockCore+AIChat) surfaces such a result as the turn's final
// message, so it must show `userSummary`, never `output`. These tests pin that split on the
// branch the owner actually hit (ambiguous) plus the generic surfacing rule, without needing a
// live app or model.
@MainActor
struct ComputerUseUserSummaryTests {

    private static let modelOnlyPhrases = [
        "find_route", "find_menu_command", "Do not ask", "do not press",
        "Do not press", "do not invent",
    ]

    @Test
    func ambiguousResultKeepsModelGuidanceInOutput() {
        // The loop still needs the guidance that sends the model back to find_route.
        let result = ComputerUseRunner.ambiguousResult(
            appName: "Mail", target: "archive",
            optionDisplays: ["Message ▸ Archive", "Mailbox ▸ Archive All"])
        #expect(result.success == false)
        #expect(result.output.contains("find_route"))
    }

    @Test
    func ambiguousUserSummaryIsPlainAndCarriesNoModelInstructions() {
        let result = ComputerUseRunner.ambiguousResult(
            appName: "Mail", target: "archive",
            optionDisplays: ["Message ▸ Archive", "Mailbox ▸ Archive All"])
        let summary = try? #require(result.userSummary)
        guard let summary else { return }
        #expect(!summary.isEmpty)
        // It names the app and the options the user must choose between…
        #expect(summary.contains("Mail"))
        #expect(summary.contains("Message ▸ Archive"))
        // …and none of the model-only instruction text leaks into it.
        for phrase in Self.modelOnlyPhrases {
            #expect(!summary.contains(phrase), "user summary leaked model phrase: \(phrase)")
        }
    }

    @Test
    func userFacingAnswerPrefersSummaryNeverRawOutput() {
        let result = ComputerUseRunner.ambiguousResult(
            appName: "Mail", target: "archive",
            optionDisplays: ["Message ▸ Archive", "Mailbox ▸ Archive All"])
        let shown = result.userFacingAnswer(fallback: "DoraX couldn't carry that out.")
        #expect(shown == result.userSummary)
        #expect(shown != result.output)
        for phrase in Self.modelOnlyPhrases {
            #expect(!shown.contains(phrase))
        }
    }

    @Test
    func userFacingAnswerUsesFallbackNotOutputWhenNoSummary() {
        // A result with no userSummary must fall back to the caller's plain line, never to the
        // model-facing output.
        let bare = AgentToolResult(
            success: false,
            output: "Do not press anything. Run find_route first.",
            displayCommand: "operate_app(x)")
        let fallback = "DoraX couldn't carry that out in Mail."
        #expect(bare.userFacingAnswer(fallback: fallback) == fallback)
    }
}
