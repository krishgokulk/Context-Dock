import Foundation
import Testing

@testable import Context_Dock

/// A clarifying question should be answerable by pointing, not by typing "1".
///
/// The model already asks well — "update" produced three real options — but it asks in
/// prose, so the only way to answer was to retype a number and hope the next turn
/// remembered what it stood for. This reads the question it actually asked.
@Suite("Chat clarification")
struct ChatClarificationTests {
    /// Verbatim from a real turn, VS Code frontmost.
    private let ambiguousUpdate = """
        "update" ambiguous. Which?

        1. **VS Code update** — running 1.135.0. No update-check route linked here.
        2. **Project update** — status of Context-Dock work.
        3. **Memory update** — change something stored about you.

        Pick one.
        """

    @Test func readsTheQuestionAndItsOptions() throws {
        let clarification = try #require(ChatClarification.parse(ambiguousUpdate))
        #expect(clarification.question == "\"update\" ambiguous. Which?")
        #expect(clarification.options.count == 3)
        #expect(clarification.options.map(\.index) == [1, 2, 3])
    }

    /// Bold markers are the model's emphasis, not part of the choice.
    @Test func optionLabelsAreReadableOnARow() throws {
        let clarification = try #require(ChatClarification.parse(ambiguousUpdate))
        let first = try #require(clarification.options.first)
        #expect(first.label.hasPrefix("VS Code update"))
        #expect(!first.label.contains("**"))
    }

    @Test func acceptsParenthesisedNumbering() throws {
        let text = """
            Which one should I open?

            1) Inbox
            2) Sent
            """
        let clarification = try #require(ChatClarification.parse(text))
        #expect(clarification.options.map(\.label) == ["Inbox", "Sent"])
    }

    /// A list of steps is not a question. Turning every enumeration into a picker would put
    /// buttons under answers nobody was asked to choose between.
    @Test func aListThatAnswersRatherThanAsksIsNotAPicker() {
        let text = """
            Here is what I did.

            1. Read the window title
            2. Checked the linked CLI
            3. Answered from the live context
            """
        #expect(ChatClarification.parse(text) == nil)
    }

    @Test func oneOptionIsNotAChoice() {
        let text = """
            Should I continue?

            1. Yes
            """
        #expect(ChatClarification.parse(text) == nil)
    }

    @Test func proseWithoutOptionsIsNotAPicker() {
        #expect(ChatClarification.parse("Yes. You run 1.135.0, one version behind.") == nil)
    }

    /// The question is the line that asks, not whatever happened to precede the list.
    @Test func theQuestionIsTheLineThatAsks() throws {
        let text = """
            I read the window title and the linked tools.

            Want me to open the compose window in Mail?

            1. Yes, open it
            2. No, just leave the draft
            """
        let clarification = try #require(ChatClarification.parse(text))
        #expect(clarification.question == "Want me to open the compose window in Mail?")
    }

    /// Answering by pointing has to say the same thing typing would have said, or the next
    /// turn resolves a number against a list it can no longer see.
    @Test func choosingSendsTheOptionInFullNotItsNumber() throws {
        let clarification = try #require(ChatClarification.parse(ambiguousUpdate))
        let reply = clarification.reply(for: try #require(clarification.options.first))
        #expect(reply.hasPrefix("VS Code update"))
        #expect(!reply.trimmingCharacters(in: .whitespaces).isEmpty)
    }
}
