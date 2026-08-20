import Testing
import Foundation
@testable import Context_Dock

// MARK: - What may be written into the user's note
//
// `show me my saved notes` returned, among five:
//
//   3. "I can't see or access your current Safari page — I only work with your notes
//      here, not the web or other apps."
//
// A refusal DoraX produced, filed as something the user wrote, and retrieved later as if
// they had. On disk beside it: "⚠️ AI error: Configure a Shortcut in AI Settings first."
//
// The Notepad's ask-AI action appends the model's reply into the note text and persists
// it, errors included, and the memory mirror then files that as the user's own note. The
// QuickNote model already states the invariant this broke — chatMessages exists so "an AI
// answer never overwrites or pollutes the editable note".
//
// This is the discriminator. It runs only on assistant replies, never on text the user
// typed, so the question is narrow: is this note content, or is it the assistant talking
// about itself?

struct AssistantNoteReplyTests {

    // MARK: - Not note content

    /// The exact text that was found on disk, filed as a user note.
    @Test func theRefusalThatStartedThis() {
        #expect(!AssistantNoteReply.isNoteContent(
            "I can't see or access your current Safari page — I only work with your notes "
                + "here, not the web or other apps."))
    }

    @Test func theOtherOneOnDisk() {
        #expect(!AssistantNoteReply.isNoteContent(
            "I cannot undo actions or run commands. I can help you clear this note or write "
                + "something new if you would like."))
    }

    /// An error is not a note. This one was persisted with a screenshot attached to it.
    @Test func errorsAreNeverNoteContent() {
        #expect(!AssistantNoteReply.isNoteContent(
            "⚠️ AI error: Configure a Shortcut in AI Settings first."))
        #expect(!AssistantNoteReply.isNoteContent(
            "⚠️ AI error: The network connection was lost."))
    }

    @Test func apologiesAreNotNoteContent() {
        #expect(!AssistantNoteReply.isNoteContent(
            "I'm sorry, but I'm unable to access that file."))
        #expect(!AssistantNoteReply.isNoteContent(
            "Sorry — I don't have access to your calendar from here."))
    }

    /// Nothing at all is not a note either. Two `(empty)` entries were in the listing.
    @Test func emptyRepliesAreNotNoteContent() {
        #expect(!AssistantNoteReply.isNoteContent(""))
        #expect(!AssistantNoteReply.isNoteContent("   \n\t  "))
    }

    // MARK: - Note content

    /// The whole point of the feature: the model writes the note.
    @Test func aWrittenNoteIsNoteContent() {
        #expect(AssistantNoteReply.isNoteContent(
            "Standup notes: shipped the approval refactor, reviewing menu verification "
                + "next, blocked on the permissions prompt."))
        #expect(AssistantNoteReply.isNoteContent("Milk, eggs, coffee beans, olive oil."))
    }

    /// The discriminator is first person plus an *ability* verb, not first person alone.
    /// A note the model wrote in the user's voice is still their note — dropping it would
    /// silently lose work the feature was asked to do.
    @Test func firstPersonAloneIsNotARefusal() {
        #expect(AssistantNoteReply.isNoteContent(
            "I can't stop thinking about the launch date. Need to decide by Friday."))
        #expect(AssistantNoteReply.isNoteContent(
            "I don't want to ship this until the menu path is verified."))
    }

    /// A long note that happens to mention what it cannot do is still a note. Only a reply
    /// that is *about* the assistant's own limits, from the start, is rejected.
    @Test func aNoteMentioningLimitsIsStillANote() {
        #expect(AssistantNoteReply.isNoteContent(
            "Meeting summary. Three decisions were taken. The API cannot access the "
                + "billing system, so reconciliation stays manual until Q3. Owner: Priya."))
    }
}
