import Testing
import Foundation
@testable import Context_Dock

// MARK: - A call is never an answer
//
// Every assistant bubble passes through this test, and what it catches gets replaced with
// an honest sentence instead of shown. It missed one shape: asked to empty the trash, the
// model replied with `{"trash_bin_action": {"action": "empty"}}` — no `_call` suffix, no
// dotted id — and the user was shown the JSON as the reply.
//
// The risk on the other side is a real answer being swallowed. "Show me that as JSON" is a
// request with a genuine one-object reply, and turning it into "I couldn't carry it out"
// would be this guard breaking the feature it protects.

struct ProtocolOnlyAnswerTests {

    // MARK: The shapes that are calls

    @Test func theShapeThatWasShownToTheUser() {
        #expect(ChatAnswerSanitizer.isProtocolOnly(#"{"trash_bin_action":{"action":"empty"}}"#))
    }

    @Test func envelopesTheProtocolDefines() {
        #expect(ChatAnswerSanitizer.isProtocolOnly(#"{"mcp_call":{"tool":"x"}}"#))
        #expect(ChatAnswerSanitizer.isProtocolOnly(#"{"capability_call":{"capability":"finder.trash"}}"#))
    }

    @Test func aCapabilityIdUsedAsTheKey() {
        #expect(ChatAnswerSanitizer.isProtocolOnly(#"{"globalcmd.empty-trash":{}}"#))
    }

    /// The model invents these faster than they can be enumerated, so the test is the
    /// naming rather than a list: a word in the key that describes doing something.
    @Test func inventedNamesNobodyHasTaughtIt() {
        for blob in [
            #"{"system_command":{"name":"sleep"}}"#,
            #"{"runTool":{"id":"x"}}"#,
            #"{"perform_operation":{"kind":"delete"}}"#,
            #"{"execute":{"what":"anything"}}"#,
        ] {
            #expect(ChatAnswerSanitizer.isProtocolOnly(blob), "should be caught: \(blob)")
        }
    }

    @Test func fencedJsonIsJudgedOnItsContents() {
        #expect(ChatAnswerSanitizer.isProtocolOnly("```json\n{\"trash_bin_action\":{\"action\":\"empty\"}}\n```"))
    }

    // MARK: The shapes that are answers

    /// The example the original guard was written around. Still an answer.
    @Test func aPlainObjectOfFactsIsAnAnswer() {
        #expect(!ChatAnswerSanitizer.isProtocolOnly(#"{"name":"x","port":8080}"#))
    }

    /// Nested, single-key, and entirely legitimate — the key names a thing, not an act.
    @Test func nestedConfigurationIsAnAnswer() {
        #expect(!ChatAnswerSanitizer.isProtocolOnly(#"{"server":{"port":8080,"host":"local"}}"#))
        #expect(!ChatAnswerSanitizer.isProtocolOnly(#"{"user":{"name":"Gokul"}}"#))
    }

    @Test func proseIsAlwaysAnAnswer() {
        #expect(!ChatAnswerSanitizer.isProtocolOnly("The trash bin has been emptied."))
        #expect(!ChatAnswerSanitizer.isProtocolOnly(""))
    }

    /// Prose that merely mentions a call is a person being told something, not a call. Only
    /// a message that is nothing but the object counts.
    @Test func jsonInsideAnExplanationIsNotACall() {
        #expect(!ChatAnswerSanitizer.isProtocolOnly(
            #"To run it, reply with {"capability_call": {"capability": "x"}} and nothing else."#))
    }
}
