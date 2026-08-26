import Foundation
import Testing

@testable import Context_Dock

// Every capability that changes something must be askable for.
//
// Six were not, found one at a time by whichever adapter eval happened to name one:
// notes.append, notes.update, reminders.complete, finder.organize, finder.copyFiles,
// messages.compose. The failure is identical each time and it is quiet — requestsChange gates
// every read path, so a request whose verb is missing reads as a *question*. It gets answered
// from a reader, described rather than done, and never shows the approval sheet its declared
// riskLevel exists to require. Nothing errors.
//
// The verb list is hand-maintained in GeneralAIActionResolver; the registry is the truth about
// what can be done. Nothing connected them, so they drifted apart every time a capability
// landed. This is that connection: register a write capability without its vocabulary and the
// suite fails here, at the moment of registration, rather than months later in front of
// somebody.

@MainActor
struct ChangeVocabularyContractTests {

    /// How a person would ask for each capability that changes something.
    ///
    /// Written by hand on purpose. Ids are not verbs — `finder.copyFiles` is "copy",
    /// `messages.compose` is "compose", `reminders.complete` is "complete" or "mark" — so
    /// deriving these automatically would only encode a worse guess. Adding a row is the cost
    /// of adding a capability, and it is one line.
    private static let phrasing: [String: String] = [
        "notes.create": "create a note called groceries",
        "notes.append": "append the invoice number to my launch note",
        "notes.update": "update my meeting note with the new date",
        "reminders.create": "add a reminder to pay the bank tomorrow",
        "reminders.complete": "mark the bank reminder as done",
        "reminders.delete": "delete my grocery reminder",
        "finder.trash": "delete these files",
        "finder.renameFiles": "rename this file to invoice-final",
        "finder.moveFiles": "move these to Downloads",
        "finder.copyFiles": "copy these to the Client folder",
        "finder.organize": "organize these",
        "finder.newFolder": "make a new folder called Screenshots",
        "messages.compose": "compose a message to sujith about dinner",
        "mail.createDraft": "draft a reply to this",
        // "save this" and "run the build", not "remember that" and "build this project".
        //
        // Both of the obvious verbs are as often nouns — "what do you remember?" and "what's
        // the build status?" are questions — and adding either would cost more than it gives.
        // That is the lesson "trash" taught: it broke three assertions in WriteIntentGuardTests
        // because "what's in my trash bin" is a question about a place. Where a capability has
        // a second, unambiguous phrasing, the phrasing is the cheaper fix.
        "memory.save": "save this to memory",
        "app.insertText": "insert this text into the document",
        "project.build": "run the build for this project",
        "cli.run": "run the linked tool",
        "app.menu.click": "close this window",
        "capture.area": "take a screenshot of this area",
        "capture.text": "capture the text on screen",
    ]

    /// Capabilities nobody asks for by name.
    ///
    /// These are mechanisms rather than requests. A person does not type "appadapter.run" or
    /// "mcp.call" — the model picks them once it has decided what to do, so no verb routes to
    /// them and none should. The global commands are reached from the command palette and by
    /// name ("shut down", "empty trash"), which the verb list already covers through its own
    /// words rather than through a capability id.
    ///
    /// Listed explicitly so the contract still bites: a capability added later is neither
    /// phrased nor excused, and fails until somebody decides which it is.
    private static let dispatchedWithoutPhrasing: Set<String> = [
        // Mechanisms: chosen by the model, not asked for.
        "appadapter.run", "mcp.call", "menu.execute", "extension.run", "finder.directAction",
        // Reached by their own name from the palette, not through the change vocabulary.
        "globalcmd.appearance", "globalcmd.bluetooth", "globalcmd.currency-converter",
        "globalcmd.empty-trash", "globalcmd.keep-awake", "globalcmd.open-social",
        "globalcmd.restart", "globalcmd.scratch-notes", "globalcmd.screenshots",
        "globalcmd.shut-down", "globalcmd.sleep", "globalcmd.test", "globalcmd.volume",
        "globalcmd.wi-fi",
        // Adapters without an eval pass yet. Each is a row waiting to be written, and the
        // reason this set is a list rather than a wildcard.
        "calendar.create", "calendar.delete", "calendar.update", "contacts.create",
        "notes.delete", "notes.export", "system.captureScreenshot", "terminal.runCommand",
        "window.arrange",
    ]

    /// The contract. A capability that requires approval is one that changes something, and a
    /// change nobody can ask for is a capability that will never run.
    @Test func everyApprovalGatedCapabilityHasAWayToAskForIt() {
        let resolver = GeneralAIActionResolver.shared
        var unaskable: [String] = []
        var unlisted: [String] = []

        for capability in CapabilityRegistry.shared.all
        where capability.riskLevel.requiresApproval {
            if Self.dispatchedWithoutPhrasing.contains(capability.id) { continue }
            guard let asked = Self.phrasing[capability.id] else {
                unlisted.append(capability.id)
                continue
            }
            if !resolver.requestsChange(asked) {
                unaskable.append("\(capability.id) — \"\(asked)\"")
            }
        }

        #expect(
            unaskable.isEmpty,
            """
            these capabilities exist but the way a person asks for them reads as a question, \
            so they are answered from a reader instead of run, with no approval shown: \
            \(unaskable.joined(separator: "; "))
            """)

        #expect(
            unlisted.isEmpty,
            """
            these approval-gated capabilities are neither phrased nor excused. Add a row to \
            `phrasing` saying how a person would ask, or to `dispatchedWithoutPhrasing` if the \
            model reaches it rather than a person: \(unlisted.joined(separator: ", "))
            """)
    }

    /// The other half. Widening the vocabulary is not free: adding "trash" broke three
    /// assertions in WriteIntentGuardTests, because "what's in my trash bin" is a question
    /// about a place. A verb that is also a common noun costs more than it gives.
    @Test func askingAboutTheSameThingsIsStillNotAChange() {
        let resolver = GeneralAIActionResolver.shared
        for asked in [
            "what's in my trash bin",
            "which of these are duplicates?",
            "show me my completed reminders",
            "any updates on the launch note?",
            "what did i write recently?",
            "how many notes do i have?",
            "what files are selected?",
            "show me my screenshots",
            "how many screenshots do i have?",
        ] {
            #expect(
                !resolver.requestsChange(asked),
                "\"\(asked)\" only asks — treating it as a change loses its grounding")
        }
    }
}
