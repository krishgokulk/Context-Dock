import Foundation
import Testing

@testable import Context_Dock

// When a cached menu is evidence, and when it is a red herring.
//
// Observed in the corner chat: "how many notes do i have?" in Notes was answered with the
// contents of the Notes *menu* — About Notes, Accounts…, Close All Locked Notes, Hide Notes —
// from a snapshot observed 1700 minutes earlier. The count was never attempted.
//
// The cause is that an app's application menu carries the app's own name, so "notes" in the
// question scores a direct hit against the "Notes" menu root and wins. That menu answers
// nothing about the user's records: it is About, Settings, Hide and Quit.
//
// Two rules, because they fail differently. One is about which menu matched; the other is about
// a question no menu can answer however well it matched.

@MainActor
struct ObservedMenuEvidenceTests {

    private let notesMenus: [[String]] = [
        ["Notes", "About Notes"],
        ["Notes", "Settings…"],
        ["Notes", "Close All Locked Notes"],
        ["Notes", "Hide Notes"],
        ["File", "New Note"],
        ["View", "Show Folders"],
    ]

    // A real History menu is mostly visited pages. The commands in it — "Show All History",
    // "Clear History…" — are stripped by the existing actionPrefixes filter, so a fixture of
    // only those yields no evidence and would test nothing.
    private let safariMenus: [[String]] = [
        ["History", "Show All History"],
        ["History", "Clear History…"],
        ["History", "Anthropic — Claude"],
        ["History", "languagemodelbuilder.com"],
        ["View", "Show Toolbar"],
        ["Safari", "About Safari"],
    ]

    // MARK: - The app's own menu is not evidence about its records

    /// The reported bug. "Notes" matches the app menu, and the app menu is About/Settings/Hide.
    @Test func theApplicationMenuDoesNotAnswerAQuestionAboutTheAppsContents() {
        let evidence = AppScopedChatService.menuSnapshotEvidence(
            query: "how many notes do i have?", appName: "Notes", paths: notesMenus, age: nil)
        #expect(
            evidence == nil,
            "the Notes menu is About/Settings/Hide — it says nothing about how many notes exist")
    }

    /// Same shape in another app, so the fix is about application menus rather than one word.
    @Test func theSameHoldsForOtherAppsOwnMenus() {
        let evidence = AppScopedChatService.menuSnapshotEvidence(
            query: "what is in safari right now?", appName: "Safari", paths: safariMenus, age: nil)
        if case .some(let found) = evidence {
            #expect(
                found.root.lowercased() != "safari",
                "matched the Safari application menu, which is About/Settings/Hide")
        }
    }

    // MARK: - No menu can count records

    /// A menu is a list of commands. It cannot say how many notes, emails or reminders exist,
    /// however well its name matches — so a counting question never takes this path, and falls
    /// through to a reader that can actually count.
    @Test func countingQuestionsNeverComeFromAMenu() {
        for query in [
            "how many notes do i have?",
            "how many tabs are open?",
            "how many unread emails?",
        ] {
            let evidence = AppScopedChatService.menuSnapshotEvidence(
                query: query, appName: "Notes", paths: notesMenus, age: nil)
            #expect(evidence == nil, "\"\(query)\" needs a count, and a menu cannot count")
        }
    }

    // MARK: - What must keep working

    /// A question genuinely about the menu bar is what this evidence is for.
    @Test func aQuestionAboutTheMenuItselfStillAnswers() {
        let evidence = AppScopedChatService.menuSnapshotEvidence(
            query: "what's in the view menu?", appName: "Notes", paths: notesMenus, age: nil)
        #expect(evidence != nil, "this is a menu question and the menu is the right source")
        #expect(evidence?.root.lowercased() == "view")
    }

    /// The media/history expansion is the reason this evidence exists at all — "what did I watch
    /// before?" is answered from the History menu, and must survive.
    @Test func theHistoryExpansionStillAnswers() {
        let evidence = AppScopedChatService.menuSnapshotEvidence(
            query: "what did i watch before?", appName: "Safari", paths: safariMenus, age: nil)
        #expect(evidence != nil, "history questions are what this path is for")
        #expect(evidence?.root.lowercased() == "history")
    }
}
