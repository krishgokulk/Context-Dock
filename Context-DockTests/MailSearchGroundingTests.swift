import Testing

@testable import Context_Dock

/// A provider with no tool protocol cannot call `search_mail`. Asked "look for emails from SBI"
/// it was handed the twelve newest inbox headers, none from SBI, and answered that a full
/// search "wasn't readable". The search now runs before the model and its matches are in the
/// prompt, and a bare `query` matches the sender as well as the subject.
@MainActor
struct MailSearchGroundingTests {

    @Test func aSenderIsTheWordsAfterFrom() {
        let cases: [(String, String, String)] = [
            ("look for emails from SBI", "sbi", ""),
            ("any mails from uel?", "uel", ""),
            ("search mail from uel", "uel", ""),
            ("search from SBI", "sbi", ""),
            ("is there any mail from sarah today?", "sarah", "today"),
            ("did i get mail from SBI yesterday?", "sbi", "yesterday"),
            ("do i have any attachments from sarah?", "sarah", ""),
            ("check my recent mail from Gokula kannan J and do what it says", "gokula kannan", ""),
            ("any mail from sarah@example.com?", "sarah@example.com", ""),
        ]
        for (sentence, sender, day) in cases {
            let intent = AppleLiveDataContext.mailSearchIntent(for: sentence)
            #expect(intent?.sender == sender, "\"\(sentence)\"")
            #expect(intent?.term == "", "\"\(sentence)\"")
            #expect(intent?.day == day, "\"\(sentence)\"")
        }
    }

    @Test func aLookUpNamesATermThatMayBeSenderOrSubject() {
        let cases: [(String, String)] = [
            ("search for invoice", "invoice"),
            ("Search mail for quarterly report", "quarterly report"),
            ("look up emails about the loan", "loan"),
            ("find mail about payslip", "payslip"),
        ]
        for (sentence, term) in cases {
            let intent = AppleLiveDataContext.mailSearchIntent(for: sentence)
            #expect(intent?.term == term, "\"\(sentence)\"")
            #expect(intent?.sender == "", "\"\(sentence)\"")
        }
    }

    /// No term means the recent inbox, as before. A write is never a search.
    @Test func aSentenceWithNoTermIsNotASearch() {
        for sentence in [
            "any unread mail?", "who sent this message?", "what's the subject line?",
            "show my inbox", "how many emails did i get this morning?", "search mail",
            "draft an email to alex about the invoice",
            "reply to the mail from sarah",
            "search mail from a sender whose name i forget but who wrote last spring",
            // "from" followed by a date is not a sender.
            "any mail from monday", "mail from january", "mail from earlier",
            // A long or vague term matches no header word for word.
            "find the email about the train tickets to paris",
            "how about the mail i got",
            // Look-up verbs are whole words.
            "my research mail", "the playlist email",
        ] {
            #expect(AppleLiveDataContext.mailSearchIntent(for: sentence) == nil, "\"\(sentence)\"")
        }
    }

    @Test func aBareQuerySearchesSenderAndSubject() {
        var filters = MailAutomation.searchFilters(query: "SBI", sender: "", subject: "")
        #expect(filters.any == "SBI")
        #expect(filters.sender.isEmpty && filters.subject.isEmpty)

        filters = MailAutomation.searchFilters(query: "from SBI", sender: "", subject: "")
        #expect(filters.sender == "SBI")
        #expect(filters.any.isEmpty)

        // An explicit field wins; the query adds nothing to it.
        filters = MailAutomation.searchFilters(query: "SBI", sender: "", subject: "loan")
        #expect(filters.subject == "loan")
        #expect(filters.any.isEmpty && filters.sender.isEmpty)
    }

    /// The scoped route passes the user's whole sentence as `query`. It must be read as a
    /// sentence, not searched for verbatim.
    @Test func aSentenceInTheQueryInputIsReadNotSearchedVerbatim() {
        var filters = AppleLiveDataContext.mailSearchFilters(
            query: "search mail from uel", sender: "", subject: "", day: "")
        #expect(filters.sender == "uel" && filters.any.isEmpty && filters.subject.isEmpty)

        filters = AppleLiveDataContext.mailSearchFilters(
            query: "did i get mail from SBI yesterday?", sender: "", subject: "", day: "")
        #expect(filters.sender == "sbi" && filters.day == "yesterday")

        // A bare term is still a term, and an explicit field still wins.
        filters = AppleLiveDataContext.mailSearchFilters(
            query: "SBI", sender: "", subject: "", day: "today")
        #expect(filters.any == "SBI" && filters.day == "today")
        filters = AppleLiveDataContext.mailSearchFilters(
            query: "search mail from uel", sender: "alumni", subject: "", day: "")
        #expect(filters.sender == "alumni" && filters.any.isEmpty)
    }

    /// "any mails from uel?" shares only "from" with Mail's read-the-newest-message route.
    @Test func aGlueWordIsNotASharedWord() {
        let terms = ChatRouteResolver.contentTerms(query: "any mails from uel?", appName: "Mail")
        #expect(!ChatRouteResolver.termsMatch(
            "Read an email's full body (the latest one, or by id from mail.recent)", terms: terms))
        #expect(ChatRouteResolver.termsMatch(
            "Search Mail", terms: ChatRouteResolver.contentTerms(query: "search from uel", appName: "Mail")))
        // A command that takes the screen still counts "from": one shared word is not enough.
        #expect(!ChatRouteResolver.commandStronglyMatches(
            "Remove from Sidebar", terms: ["remove", "the", "attachment"]))
    }

    @Test func theMailFilterMatchesEitherFieldForABareTerm() {
        let either = MailAutomation.whoseClause(
            hasSender: false, hasSubject: false, hasAny: true, unreadOnly: false,
            wantsToday: false, wantsYesterday: false)
        #expect(either == "(sender contains anyFilter or subject contains anyFilter)")

        let both = MailAutomation.whoseClause(
            hasSender: true, hasSubject: false, hasAny: false, unreadOnly: true,
            wantsToday: false, wantsYesterday: false)
        #expect(both == "sender contains senderFilter and read status is false")

        let none = MailAutomation.whoseClause(
            hasSender: false, hasSubject: false, hasAny: false, unreadOnly: false,
            wantsToday: false, wantsYesterday: false)
        #expect(none == "read status is true or read status is false")
    }

    /// Lines now end with the message id (so `mail.read` can open a match); the parser that
    /// feeds the suggestion pill must still read the fields before it.
    @Test func snapshotLinesWithAnIdStillParse() {
        let summary = """
            Mailbox: Inbox
            - Your statement | From: SBI <alerts@sbi.example> | Monday, 9 November 2026 | Read: false | Id: 4812
            - Old line | From: A <a@example.com> | Sunday | Read: true
            """
        let snapshot = MailAutomation.parseSnapshot(summary)
        #expect(snapshot?.mailboxName == "Inbox")
        #expect(snapshot?.messages.count == 2)
        #expect(snapshot?.messages.first?.subject == "Your statement")
        #expect(snapshot?.messages.first?.isRead == false)
        #expect(snapshot?.messages.last?.isRead == true)
        #expect(MailAutomation.parseSnapshot("Mailbox: Inbox\nNo matching messages found.")?.messages.isEmpty == true)
        #expect(MailAutomation.parseSnapshot("Mailbox: Inbox\nMail context could not be read.") == nil)
    }

    @Test func theMatchesBlockNamesTheTermAndSaysWhenNothingMatched() {
        let found = AppleLiveDataContext.mailSearchBlock(
            label: "sbi",
            summary: "Mailbox: Inbox\n- Your statement | From: SBI | Monday | Read: false | Id: 4812")
        #expect(found?.contains("## Mail — search matches for \"sbi\"") == true)
        #expect(found?.contains("Your statement") == true)
        #expect(found?.contains("BEGIN UNTRUSTED") == true)

        let empty = AppleLiveDataContext.mailSearchBlock(
            label: "uel", summary: "Mailbox: Inbox\nNo matching messages found.")
        #expect(empty?.contains("no messages match \"uel\"") == true)

        // An unreadable mailbox is not "no matches": say nothing and fall back to the inbox.
        #expect(AppleLiveDataContext.mailSearchBlock(
            label: "uel", summary: "Mailbox: Inbox\nMail context could not be read.") == nil)
    }
}
