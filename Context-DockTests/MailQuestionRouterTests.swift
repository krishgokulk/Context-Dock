import Foundation
import Testing

@testable import Context_Dock

// The Mail scope replied to "hi hello?" with "Attach Mail context with the + button first,
// then ask again." Seen in the running app, not in any test — the predicate lived on
// LauncherView, which cannot be instantiated, so nothing could reach it.
//
// One line caused it: `if rawScopedQuery.contains("?") { return true }`. Every question was a
// mail question.

struct MailQuestionRouterTests {

    // MARK: - The reported bug

    /// A scope is still a chat. None of these wants the inbox read, and refusing to answer
    /// them until the user attaches a mailbox is the app declining to talk.
    @Test func ordinaryConversationDoesNotDemandAMailbox() {
        for query in ["hi hello?", "how are you?", "what's 2+2?", "can you help?", "?"] {
            #expect(
                !MailQuestionRouter.needsAttachedMailContext(
                    query: query, isMailContextAttached: false),
                "\"\(query)\" is not about mail — the chat should just answer it")
        }
    }

    // MARK: - Real mailbox questions still ask for context

    /// The prompt exists for a reason: answering these without the mailbox attached means
    /// guessing at someone's inbox.
    @Test func mailboxQuestionsStillAskForContext() {
        for query in [
            "any unread mail?",
            "who sent this message?",
            "what's the subject line?",
            "do i have any attachments from sarah?",
            "any drafts?",
        ] {
            #expect(
                MailQuestionRouter.needsAttachedMailContext(
                    query: query, isMailContextAttached: false),
                "\"\(query)\" is about the mailbox and needs it attached")
        }
    }

    /// Once the mailbox is attached the prompt must never appear again, whatever is asked.
    @Test func nothingAsksTwiceOnceContextIsAttached() {
        for query in ["any unread mail?", "hi hello?", "who sent this?"] {
            #expect(
                !MailQuestionRouter.needsAttachedMailContext(
                    query: query, isMailContextAttached: true))
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
