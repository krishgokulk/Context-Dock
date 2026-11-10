import Foundation
import Testing

@testable import Context_Dock

// Question shape says the sentence is asking something; mailbox subject says it is asking
// about mail. Keeping them separate lets the Mail scope answer ordinary conversation ("hi
// hello?", "how are you?", "what's 2+2?") directly while grounding real mailbox questions in
// live Mail readers (`mail.recent`, `mail.read`, `mail.search`, `mail.unread`,
// `mail.currentMessage`).

struct MailQuestionRouterTests {

    // MARK: - Ordinary conversation vs. mailbox questions

    /// A scope is still a chat. None of these wants the inbox read.
    @Test func ordinaryConversationIsNotAMailboxQuestion() {
        for query in ["hi hello?", "how are you?", "what's 2+2?", "can you help?", "?"] {
            #expect(
                !MailQuestionRouter.isMailboxQuestion(query),
                "\"\(query)\" is not about mail — the chat should answer it conversationally")
        }
    }

    // MARK: - Real mailbox questions route to live Mail readers

    @Test func mailboxQuestionsAreRecognised() {
        for query in [
            "any unread mail?",
            "who sent this message?",
            "what's the subject line?",
            "do i have any attachments from sarah?",
            "any drafts?",
        ] {
            #expect(
                MailQuestionRouter.isMailboxQuestion(query),
                "\"\(query)\" is a question about the mailbox")
        }
    }

    // MARK: - The two halves stay separate

    /// Question shape is about the sentence, not its subject. Keeping this true is what stops
    /// the two ideas collapsing back into one predicate.
    @Test func questionShapeAndMailboxSubjectAreIndependent() {
        #expect(MailQuestionRouter.isQuestionShaped("how are you?"))
        #expect(!MailQuestionRouter.mentionsMailbox("how are you?"))

        #expect(MailQuestionRouter.mentionsMailbox("delete this email"))
        #expect(!MailQuestionRouter.isQuestionShaped("delete this email"))

        #expect(!MailQuestionRouter.isQuestionShaped(""))
        #expect(!MailQuestionRouter.mentionsMailbox(""))
    }

    /// The prefixes the original predicate recognised, kept so extracting it did not quietly
    /// narrow what counts as a question.
    @Test func theOriginalQuestionPrefixesStillCount() {
        for query in ["any mail today", "show me unread", "is there any mail", "tell me who sent"]
        {
            #expect(MailQuestionRouter.isQuestionShaped(query), "\"\(query)\" is a question")
        }
    }
}
