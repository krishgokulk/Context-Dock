import Foundation
import Testing

@testable import Context_Dock

/// An app's own name is not a useful trigger on that app's own actions.
///
/// From a real turn: asked "new chat on claude" in the Claude scope, the app opened
/// `https://docs.anthropic.com/en/docs/mcp` and then said the page had nothing about a new
/// chat in it. Both seeded Claude actions listed `claude` as a trigger, the query contained
/// the word, and `actionQuery.contains(trigger)` scored it 78 — a strong match earned entirely
/// by the app's name being in a sentence about that app.
@Suite("App-name triggers")
struct AppNameTriggerTests {
    @Test func theAppsOwnNameIsNotATrigger() {
        let kept = L2AppActionRouter.meaningfulTriggers(
            ["claude", "mcp", "tools", "setup"], forAppNamed: "Claude")

        #expect(kept == ["mcp", "tools", "setup"])
    }

    @Test func caseAndSpacingDoNotSmuggleItBackIn() {
        #expect(
            L2AppActionRouter.meaningfulTriggers(["  CLAUDE ", "mcp"], forAppNamed: "claude")
                == ["mcp"])
    }

    /// A multi-word app name has no useful single word either: in the Claude Code scope,
    /// "code" matches every sentence about it.
    @Test func eachWordOfAMultiWordNameGoesToo() {
        let kept = L2AppActionRouter.meaningfulTriggers(
            ["claude", "code", "cli", "docs"], forAppNamed: "Claude Code")

        #expect(kept == ["cli", "docs"])
    }

    /// The filter is narrow on purpose. A trigger that merely contains the name, or shares a
    /// prefix with it, still says something the name alone does not.
    @Test func onlyTheNameItselfIsDropped() {
        let kept = L2AppActionRouter.meaningfulTriggers(
            ["claudecode", "claude-cli", "mcp"], forAppNamed: "Claude")

        #expect(kept == ["claudecode", "claude-cli", "mcp"])
    }

    @Test func anAppWithNoNameKeepsEverything() {
        #expect(
            L2AppActionRouter.meaningfulTriggers(["claude", "mcp"], forAppNamed: "")
                == ["claude", "mcp"])
    }

    /// The seeds that produced the bug. Their own name is gone; everything that identifies
    /// what the action *does* remains.
    @Test func theSeededClaudeActionsNoLongerAnswerToTheirOwnAppName() {
        let starters = AdapterStarterActions.starters(
            for: "com.anthropic.claudefordesktop", appName: "Claude")
        #expect(!starters.isEmpty)
        for action in starters {
            let lowered = action.triggers.map { String($0).lowercased() }
            #expect(!lowered.contains("claude"), "\(action.id) still answers to 'claude'")
        }
    }
}
