import Foundation
import Testing

@testable import Context_Dock

// MARK: - Task 17: the routing phrasebook
//
// FUTURE AGENTS: every sentence that fails an owner hand test goes in `phrasebook` below —
// the surface it was typed in, what the resolver found for it, and where it should have
// landed. Append; do not rewrite existing rows. A routing change is not done until every
// row here still lands where it says.
//
// Why this exists: in a Finder chat, "find my passport pdf" became "Use Find My · Edit →
// Copy". A deterministic pipeline matched words against app names and menu titles and took
// the turn before any model read the sentence. 16e patched the word lists; Task 17 made the
// rule that the shortcut may preempt the model only when the text IS a command. These rows
// are the owner's own sentences, and each one runs through the same function the Dock and
// the Corner call (`ScopedRoutePolicy.decide` from `offerScopedNativeAppAction`;
// `ScopedRoutePolicy.generalChatRoute` from General Chat).
//
// Route classes:
//   .exactCommand  — offered as a one-tap native action; the model is not asked.
//   .model         — the model takes the turn, with the scoped app's partly-matching
//                    commands as candidates.
//   .crossAppOffer — an exact command in another app the sentence named; offered with the
//                    "This needs X, not Y" consent prompt.
//   .none          — a question or a read; no action is considered.
//
// `found` is what the resolver hands the policy for that sentence — including the noise
// that caused the original bug (Find My's cached `Edit → Copy`). The resolver itself reads
// installed apps and menu caches, which an offline test host does not have; the decision
// is what these rows pin.

@MainActor
struct RoutingPhrasebookTests {

    enum Surface: String {
        case finderChat = "Finder chat"
        case safariChat = "Safari chat"
        case generalChat = "General Chat"
        case notesChat = "Notes chat"
        case mailChat = "Mail chat"
        case messagesChat = "Messages chat"

        var scopedApp: String? {
            switch self {
            case .finderChat: return "Finder"
            case .safariChat: return "Safari"
            case .notesChat: return "Notes"
            case .mailChat: return "Mail"
            case .messagesChat: return "Messages"
            case .generalChat: return nil
            }
        }
    }

    struct Phrase {
        let surface: Surface
        let sentence: String
        let found: [DoraXActionCandidate]
        let expected: ScopedRoutePolicy.RouteClass
    }

    // MARK: - Fixtures

    private static func menu(_ app: String, _ path: [String]) -> DoraXActionCandidate {
        var made = DoraXActionCandidate(
            id: "menu.\(app).\(path.joined(separator: "."))",
            title: path.last ?? "",
            appName: app,
            bundleID: "test.\(app)",
            source: .cachedMenu,
            route: .verifiedMenu,
            capabilityID: nil,
            requiredInputs: [],
            riskLevel: .low,
            confidence: 0.6,
            permissionKey: "generalAI.execute.menu",
            debugReason: "phrasebook")
        made.menuPath = path
        return made
    }

    private static func capability(
        _ app: String, _ id: String, _ title: String, inputs: [String: String] = [:]
    ) -> DoraXActionCandidate {
        var made = DoraXActionCandidate(
            id: "cap.\(id)",
            title: title,
            appName: app,
            bundleID: "test.\(app)",
            source: .appAdapter,
            route: .adapter,
            capabilityID: id,
            requiredInputs: Array(inputs.keys),
            riskLevel: .low,
            confidence: 0.7,
            permissionKey: "generalAI.execute.\(id)",
            debugReason: "phrasebook")
        made.inputValues = inputs
        return made
    }

    private static func launch(_ app: String) -> DoraXActionCandidate {
        DoraXActionCandidate(
            id: "launch.\(app)",
            title: "Open \(app)",
            appName: app,
            bundleID: "test.\(app)",
            source: .system,
            route: .appLaunch,
            capabilityID: nil,
            requiredInputs: [],
            riskLevel: .low,
            confidence: 0.9,
            permissionKey: "generalAI.execute.launch",
            debugReason: "phrasebook")
    }

    /// The noise behind the original report: Find My's persisted menu snapshot.
    private static let findMyCopy = menu("Find My", ["Edit", "Copy"])
    private static let shortcutsRun = menu("Shortcuts", ["Shortcut", "Run"])
    private static let finderFind = menu("Finder", ["File", "Find"])
    private static let notesCreate = capability("Notes", "notes.create", "Create Apple Note")
    private static let mailCreateDraft = capability("Mail", "mail.createDraft", "Create Mail Draft")
    private static let mailSearch = capability("Mail", "mail.search", "Search Mail")
    private static let messagesCompose = capability("Messages", "messages.compose", "Open a Message for Review")

    // MARK: - The phrasebook
    //
    // Append new rows at the end of the list. One row per (surface, sentence).

    static let phrasebook: [Phrase] = [
        // The reported sentence and its neighbours: a file search in Finder is the model's,
        // and Find My is never offered because nobody named it.
        Phrase(surface: .finderChat, sentence: "find my passport pdfs gokulakannan",
               found: [findMyCopy, finderFind], expected: .model),
        Phrase(surface: .finderChat, sentence: "find my passport pdf",
               found: [findMyCopy, finderFind], expected: .model),
        Phrase(surface: .finderChat, sentence: "where are my passport PDFs?",
               found: [findMyCopy, finderFind], expected: .none),
        Phrase(surface: .generalChat, sentence: "find my passport pdfs gokulakannan",
               found: [findMyCopy], expected: .model),

        // Status reads are questions.
        Phrase(surface: .generalChat, sentence: "is bluetooth on?",
               found: [], expected: .none),
        Phrase(surface: .finderChat, sentence: "is bluetooth on?",
               found: [], expected: .none),

        // System settings with a value. The Global Commands are named "Appearance" and
        // "Volume", so neither sentence IS a command title: the model calls them with the
        // value, rather than a one-tap button that cannot carry it.
        Phrase(surface: .generalChat, sentence: "turn dark mode off",
               found: [], expected: .model),
        Phrase(surface: .generalChat, sentence: "set volume to 30",
               found: [], expected: .model),

        // Bare commands in the scoped app.
        Phrase(surface: .finderChat, sentence: "copy",
               found: [menu("Finder", ["Edit", "Copy"]), findMyCopy], expected: .exactCommand),
        Phrase(surface: .finderChat, sentence: "new folder",
               found: [menu("Finder", ["File", "New Folder"]),
                       menu("Finder", ["File", "New Folder with Selection"])],
               expected: .exactCommand),
        Phrase(surface: .finderChat, sentence: "empty trash",
               found: [menu("Finder", ["Finder", "Empty Trash…"])], expected: .exactCommand),
        Phrase(surface: .safariChat, sentence: "copy",
               found: [menu("Safari", ["Edit", "Copy"])], expected: .exactCommand),
        Phrase(surface: .generalChat, sentence: "copy",
               found: [], expected: .model),

        // Naming the app is explicit.
        Phrase(surface: .finderChat, sentence: "open Find My",
               found: [launch("Find My"), findMyCopy], expected: .crossAppOffer),
        Phrase(surface: .safariChat, sentence: "open Find My",
               found: [launch("Find My")], expected: .crossAppOffer),
        Phrase(surface: .generalChat, sentence: "open Find My",
               found: [], expected: .model),

        // Ordinary words that are also app names: no jump to Notes or Photos.
        Phrase(surface: .finderChat, sentence: "take a note about the roof quote",
               found: [capability("Notes", "notes.create", "Create Apple Note",
                                  inputs: ["title": "roof quote"])],
               expected: .model),
        Phrase(surface: .safariChat, sentence: "take a note about the roof quote",
               found: [capability("Notes", "notes.create", "Create Apple Note",
                                  inputs: ["title": "roof quote"])],
               expected: .model),
        Phrase(surface: .generalChat, sentence: "take a note about the roof quote",
               found: [], expected: .model),
        Phrase(surface: .finderChat, sentence: "show photos of the beach",
               found: [launch("Photos")], expected: .none),

        // Page questions are reads.
        Phrase(surface: .safariChat, sentence: "summarize this page",
               found: [menu("Safari", ["File", "Share"])], expected: .none),
        Phrase(surface: .generalChat, sentence: "summarize this page",
               found: [], expected: .none),

        // 16d hand test: "shortcut" is a noun (the user's own shortcuts, run by run_shortcut),
        // not the Shortcuts app. Its menu's "Shortcut > Run" must never be offered for these.
        Phrase(surface: .generalChat, sentence: "run make pdf shortcut",
               found: [shortcutsRun], expected: .model),
        Phrase(surface: .generalChat, sentence: "run my make pdf shortcut",
               found: [shortcutsRun], expected: .model),
        Phrase(surface: .generalChat, sentence: "run the DayEnd shortcut",
               found: [shortcutsRun], expected: .model),
        Phrase(surface: .generalChat, sentence: "what shortcuts do I have",
               found: [], expected: .none),
        Phrase(surface: .finderChat, sentence: "run make pdf shortcut",
               found: [shortcutsRun], expected: .model),
        Phrase(surface: .finderChat, sentence: "run my make pdf shortcut",
               found: [shortcutsRun], expected: .model),
        Phrase(surface: .finderChat, sentence: "run the DayEnd shortcut",
               found: [shortcutsRun], expected: .model),
        Phrase(surface: .finderChat, sentence: "what shortcuts do I have",
               found: [], expected: .none),
        // A genuine app request still names the app.
        Phrase(surface: .finderChat, sentence: "open Shortcuts",
               found: [launch("Shortcuts")], expected: .crossAppOffer),

        // Issue 132: the old name-match route is gone. A sentence that merely CONTAINS a
        // shortcut's name (here "Make PDF") is not a request to run it: nothing is offered,
        // and no code but run_shortcut can run a shortcut. "run make pdf shortcut" itself is
        // the model's, which calls list_shortcuts then run_shortcut at High risk.
        Phrase(surface: .generalChat, sentence: "I need to make pdf copies of the invoices",
               found: [], expected: .model),
        Phrase(surface: .finderChat, sentence: "I need to make pdf copies of the invoices",
               found: [], expected: .model),
        Phrase(surface: .generalChat, sentence: "run make pdf shortcut",
               found: [], expected: .model),
        Phrase(surface: .generalChat, sentence: "open Shortcuts",
               found: [], expected: .model),

        // Issue 146 (owner, Corner Finder chat): "resume" is a folder name here — a résumé
        // folder — not a verb for any Finder command. Three near matches reached the model,
        // and it wrote `finder.copyFiles` as text. Nothing may be offered as the exact
        // command; the model gets the turn. The Dock and the Corner both call
        // `ScopedRoutePolicy.decide` from `offerScopedNativeAppAction`, so one row per
        // sentence covers both shells (Corner app chat IS the Dock's pipeline). With the
        // question mark the sentence is question-shaped and no action is even considered
        // (.none); without it the model takes the turn with the near matches as candidates.
        Phrase(surface: .finderChat, sentence: "can you resume 2026 folder for me",
               found: [capability("Finder", "finder.copyFiles", "Copy Finder Files"),
                       menu("Finder", ["Edit", "Copy"]),
                       menu("Finder", ["File", "Find"])],
               expected: .model),
        Phrase(surface: .finderChat, sentence: "can you resume 2026 folder for me?",
               found: [capability("Finder", "finder.copyFiles", "Copy Finder Files"),
                       menu("Finder", ["Edit", "Copy"]),
                       menu("Finder", ["File", "Find"])],
               expected: .none),

        // Issue 204 (P10, E12): the Notes keyword shortcut (`tryHandleNotesMCPQuery`) is gone.
        // It claimed any Notes-scope sentence containing "find", "search", "count", "link",
        // "url", "with " or "any ", before a model read it. Now no action is offered for any
        // of them: a question is answered from reads (.none); an imperative read goes to the
        // model with `notes.search` (.model; data lane, plan 2b). The answer's note rows come
        // from the capability. A write is the model's, through notes.create with its
        // approval card.
        Phrase(surface: .notesChat, sentence: "how many notes do I have?",
               found: [notesCreate], expected: .none),
        Phrase(surface: .notesChat, sentence: "find notes with links",
               found: [notesCreate], expected: .model),
        Phrase(surface: .notesChat, sentence: "any notes about the roof quote",
               found: [notesCreate], expected: .model),
        Phrase(surface: .notesChat, sentence: "search notes for passport",
               found: [notesCreate], expected: .model),
        Phrase(surface: .notesChat, sentence: "create a note about the roof quote",
               found: [notesCreate], expected: .model),

        // Issue 204 (P10, E12): the pre-model Menu Command shortcut (`MenuIntentRouter` /
        // `DockShortcut.menuCommand`) is retired. Menu commands route through the Task 17
        // ladder (`offerScopedNativeAppAction` → `ScopedRoutePolicy.decide`):
        // - Exact menu titles and explicit menu paths offer the command (.exactCommand).
        // - Token-overlapping sentences that `MenuIntentRouter` used to score ≥ 40 go to the
        //   model with the matching menu items in `modelCandidates` (.model).
        // - Question-shaped sentences about menus are answered as reads (.none).
        Phrase(surface: .finderChat, sentence: "minimize",
               found: [menu("Finder", ["Window", "Minimize"])], expected: .exactCommand),
        Phrase(surface: .finderChat, sentence: "new tab",
               found: [menu("Finder", ["File", "New Tab"])], expected: .exactCommand),
        Phrase(surface: .safariChat, sentence: "zoom in",
               found: [menu("Safari", ["View", "Zoom In"])], expected: .exactCommand),
        Phrase(surface: .finderChat, sentence: "File > New Folder",
               found: [menu("Finder", ["File", "New Folder"])], expected: .exactCommand),
        Phrase(surface: .finderChat, sentence: "copy the passport pdf to the desktop",
               found: [menu("Finder", ["Edit", "Copy"]), findMyCopy], expected: .model),
        Phrase(surface: .finderChat, sentence: "new folder for the tax documents",
               found: [menu("Finder", ["File", "New Folder"])], expected: .model),
        Phrase(surface: .safariChat, sentence: "export this document as a summary",
               found: [menu("Safari", ["File", "Export as PDF…"])], expected: .model),
        Phrase(surface: .safariChat, sentence: "how do I export as pdf?",
               found: [menu("Safari", ["File", "Export as PDF…"])], expected: .model),
        Phrase(surface: .finderChat, sentence: "where is the sidebar?",
               found: [menu("Finder", ["View", "Show Sidebar"])], expected: .none),

        // Issue 204 (P10, E12): the pre-model Mail Question shortcut and its attached-context gate
        // are retired. Questions in the Mail scope are answered from live Mail readers (.none);
        // imperative searches and draft requests go to the model with `mail.search`, `mail.read`,
        // `mail.unread`, `mail.currentMessage`, and `mail.createDraft` (.model).
        Phrase(surface: .mailChat, sentence: "any unread mail?",
               found: [mailCreateDraft], expected: .none),
        Phrase(surface: .mailChat, sentence: "is there any mail from sarah today?",
               found: [mailCreateDraft], expected: .none),
        Phrase(surface: .mailChat, sentence: "did i get mail from SBI yesterday?",
               found: [mailCreateDraft], expected: .none),
        Phrase(surface: .mailChat, sentence: "who sent this message?",
               found: [mailCreateDraft], expected: .none),
        Phrase(surface: .mailChat, sentence: "what's the subject line?",
               found: [mailCreateDraft], expected: .none),
        Phrase(surface: .mailChat, sentence: "find mail from SBI today",
               found: [mailCreateDraft], expected: .model),
        Phrase(surface: .mailChat, sentence: "any mail from sarah today",
               found: [mailCreateDraft], expected: .model),
        Phrase(surface: .mailChat, sentence: "draft an email to alex about the invoice",
               found: [mailCreateDraft], expected: .model),

        // Issue 204 (P10, E12): the pre-model Mailbox Search shortcut is retired. The search
        // commands it claimed ("search mail from SBI") are requests with a value, not a command
        // title, so the model takes them and calls `mail.search` with the sender / subject / query.
        Phrase(surface: .mailChat, sentence: "search mail from SBI",
               found: [mailSearch], expected: .model),
        Phrase(surface: .mailChat, sentence: "search for invoice",
               found: [mailSearch], expected: .model),
        Phrase(surface: .mailChat, sentence: "find mail from Gokula kannan J",
               found: [mailSearch], expected: .model),
        Phrase(surface: .mailChat, sentence: "look for emails from SBI",
               found: [mailSearch], expected: .model),
        Phrase(surface: .mailChat, sentence: "search my inbox for subject payslip",
               found: [mailSearch], expected: .model),
        Phrase(surface: .mailChat, sentence: "search mail for \"invoice and receipt\"",
               found: [mailSearch], expected: .model),

        // Issue 204 (P10, E12): the pre-model Messages shortcut (`DockShortcut.messages`) is
        // retired. Questions in the Messages scope are answered from live `chat.db` readers (.none);
        // compose/send and search requests go to the model with `messages.compose`, `messages.send`,
        // `messages.search`, `messages.recent`, and `messages.topContacts` (.model); exact menu
        // commands still offer the command (.exactCommand).
        Phrase(surface: .messagesChat, sentence: "what did Salman text me today?",
               found: [messagesCompose], expected: .none),
        Phrase(surface: .messagesChat, sentence: "who do I message most?",
               found: [messagesCompose], expected: .none),
        Phrase(surface: .messagesChat, sentence: "do I have any unread messages?",
               found: [messagesCompose], expected: .none),
        Phrase(surface: .messagesChat, sentence: "did Salman text me yesterday?",
               found: [messagesCompose], expected: .none),
        Phrase(surface: .messagesChat, sentence: "send \"hi\" to Salman",
               found: [messagesCompose], expected: .model),
        Phrase(surface: .messagesChat, sentence: "send I'm running late to Salman",
               found: [messagesCompose], expected: .model),
        Phrase(surface: .messagesChat, sentence: "text Salman I'm running late",
               found: [messagesCompose], expected: .model),
        Phrase(surface: .messagesChat, sentence: "find messages from Salman",
               found: [messagesCompose], expected: .model),
        Phrase(surface: .messagesChat, sentence: "New Message",
               found: [menu("Messages", ["File", "New Message"])], expected: .exactCommand),
    ]

    // MARK: - Running a row

    /// Which of the fixture apps the sentence names, judged by the same rule the resolver
    /// applies to every installed name (`isAppReference`). Offline stand-in for
    /// `namedInstalledApp`, which reads the machine's app catalogue.
    private static let knownApps = ["Find My", "Notes", "Photos", "Safari", "Finder", "Music", "Shortcuts", "Mail", "Messages"]

    static func namedApp(in sentence: String) -> String? {
        let lowered = sentence.lowercased()
        var best: (start: Int, name: String)?
        for app in knownApps {
            let phrase = app.lowercased()
            guard let range = lowered.range(of: phrase) else { continue }
            let start = lowered.distance(from: lowered.startIndex, to: range.lowerBound)
            guard GeneralAIActionResolver.isAppReference(
                in: lowered, original: sentence, phrase: phrase, start: start)
            else { continue }
            if best == nil || start < best!.start { best = (start, app) }
        }
        return best?.name
    }

    static func route(_ phrase: Phrase) -> ScopedRoutePolicy.Decision {
        guard let scoped = phrase.surface.scopedApp else {
            let exact = phrase.found.contains {
                ExactCommand.matches(query: phrase.sentence, candidate: $0)
            }
            return ScopedRoutePolicy.Decision(
                routeClass: ScopedRoutePolicy.generalChatRoute(
                    query: phrase.sentence, modelFirst: true, selectedAppHasExactAction: exact))
        }
        let named = namedApp(in: phrase.sentence).flatMap { $0 == scoped ? nil : $0 }
        return ScopedRoutePolicy.decide(
            query: phrase.sentence, scopedApp: scoped, namedApp: named,
            candidates: phrase.found)
    }

    // MARK: - Tests

    @Test func everyPhraseLandsWhereTheTableSays() {
        for phrase in Self.phrasebook {
            let decision = Self.route(phrase)
            #expect(
                decision.routeClass == phrase.expected,
                "\(phrase.surface.rawValue): \"\(phrase.sentence)\" → \(decision.routeClass), expected \(phrase.expected)")
        }
    }

    @Test func onlyAnOfferCarriesAnAction() {
        for phrase in Self.phrasebook {
            let decision = Self.route(phrase)
            switch decision.routeClass {
            case .exactCommand, .crossAppOffer:
                if phrase.surface.scopedApp != nil {
                    #expect(decision.offer != nil, "\"\(phrase.sentence)\"")
                }
            case .model, .none:
                #expect(
                    decision.offer == nil,
                    "\"\(phrase.sentence)\" offered \(decision.offer?.title ?? "")")
            }
        }
    }

    @Test func aScopedChatNeverHandsTheModelAnUnnamedApp() {
        // The model's candidates obey the same scope rule as the offer: Find My's Edit → Copy
        // must not reappear as a "suggestion" for a Finder file search.
        for phrase in Self.phrasebook {
            guard let scoped = phrase.surface.scopedApp else { continue }
            let named = Self.namedApp(in: phrase.sentence)
            for candidate in Self.route(phrase).modelCandidates {
                let app = candidate.appName ?? scoped
                #expect(
                    app == scoped || app == named,
                    "\"\(phrase.sentence)\" handed the model \(app) · \(candidate.title)")
            }
        }
    }

    // MARK: - The reported sentence, end to end

    @Test func theReportedSentenceOffersNothing() {
        let decision = ScopedRoutePolicy.decide(
            query: "find my passport pdf", scopedApp: "Finder", namedApp: nil,
            candidates: [Self.findMyCopy, Self.finderFind])
        #expect(decision.routeClass == .model)
        #expect(decision.offer == nil)
        #expect(decision.modelCandidates.map(\.title) == ["Find"])
    }

    @Test func theRealMatcherNamesNoAppInTheReportedSentences() {
        // Against the machine's own catalogue: nothing in these sentences names an app, so
        // no cross-app offer can be built for them whatever is installed.
        for sentence in ["find my passport pdf", "find my passport pdfs gokulakannan",
                         "take a note about the roof quote", "show photos of the beach"] {
            let named = GeneralAIActionResolver.shared.namedInstalledApp(in: sentence)
            #expect(
                named?.name != "Find My" && named?.name != "Notes" && named?.name != "Photos",
                "\"\(sentence)\" named \(named?.name ?? "")")
        }
    }

    // MARK: - 16d: shortcut is a noun

    @Test func shortcutNounSentencesNameNoApp() {
        for sentence in ["run make pdf shortcut", "run my make pdf shortcut",
                         "run the DayEnd shortcut", "what shortcuts do I have",
                         "Run My Make PDF Shortcut", "list my shortcuts", "run my shortcuts"] {
            let lowered = sentence.lowercased()
            for phrase in ["shortcut", "shortcuts"] {
                guard let range = lowered.range(of: phrase) else { continue }
                let start = lowered.distance(from: lowered.startIndex, to: range.lowerBound)
                #expect(
                    !GeneralAIActionResolver.isAppReference(
                        in: lowered, original: sentence, phrase: phrase, start: start),
                    "\"\(sentence)\" read \(phrase) as the app")
            }
            let named = GeneralAIActionResolver.shared.namedInstalledApps(in: sentence)
            #expect(!named.contains { $0.bundleId.lowercased() == "com.apple.shortcuts" },
                    "\"\(sentence)\" named the Shortcuts app")
        }
    }

    @Test func aGenuineAppRequestStillNamesShortcuts() {
        for (sentence, phrase) in [("open Shortcuts", "shortcuts"), ("open shortcuts app", "shortcuts"),
                                   ("launch the shortcuts app", "shortcuts"),
                                   ("open the shortcut app", "shortcut app"),
                                   ("shortcuts", "shortcuts")] {
            let lowered = sentence.lowercased()
            let start = lowered.distance(
                from: lowered.startIndex, to: lowered.range(of: phrase)!.lowerBound)
            #expect(
                GeneralAIActionResolver.isAppReference(
                    in: lowered, original: sentence, phrase: phrase, start: start),
                "\"\(sentence)\" should name the app")
        }
    }

    @Test func theAccessGateDoesNotAskToEnableShortcutsForARun() {
        for sentence in ["run make pdf shortcut", "run my make pdf shortcut",
                         "run the DayEnd shortcut", "what shortcuts do I have"] {
            let request = AppScopedChatService.appNeedingAccess(
                query: sentence, scope: .general, attachedAppNames: [])
            #expect(request?.bundleId.lowercased() != "com.apple.shortcuts",
                    "\"\(sentence)\" asked to enable the Shortcuts app")
        }
    }

    @Test func shortcutSentencesAreOfferedTheToolsInEveryChat() {
        for sentence in ["run make pdf shortcut", "run my make pdf shortcut",
                         "run the DayEnd shortcut", "what shortcuts do I have"] {
            let plan = FrontmostAppTaskPlan.make(
                query: sentence, bundleId: "com.apple.finder", appName: "Finder")
            #expect(plan.allowedToolNames.contains("run_shortcut"), "\(sentence)")
            #expect(plan.allowedToolNames.contains("list_shortcuts"), "\(sentence)")
        }
        // General Chat passes no allow-list: every registered tool is offered.
        #expect(AgentToolRegistry.shared.tool(named: "run_shortcut") != nil)
    }

    @Test func theModelIsToldWhatMatchedAndHowToRunIt() {
        let block = ScopedRoutePolicy.modelCandidatesBlock(
            [Self.finderFind, Self.capability("Finder", "finder.search", "Search Files")],
            scopedApp: "Finder")
        #expect(block.contains("run_menu_command(app: \"Finder\", path: \"File > Find\")"))
        #expect(block.contains("run_capability(capability_id: \"finder.search\")"))
        #expect(ScopedRoutePolicy.modelCandidatesBlock([], scopedApp: "Finder").isEmpty)
    }

    @Test func theAppsOwnToolBeatsItsMenuWhenBothAreExact() {
        let decision = ScopedRoutePolicy.decide(
            query: "new folder", scopedApp: "Finder", namedApp: nil,
            candidates: [
                Self.menu("Finder", ["File", "New Folder"]),
                Self.capability("Finder", "finder.newFolder", "New Folder"),
            ])
        #expect(decision.offer?.capabilityID == "finder.newFolder")
    }
}

// MARK: - Issue 177: Mail chat offers only routes that match the request

@MainActor
struct MailRouteChoiceTests {

    private static let mailCommands = [
        "Quit Mail", "Hide Mail", "Mail Help", "Get New Mail", "Mail Assistant Basics",
        "Mail — what this app is",
    ]

    @Test func quitMailMatchesOnlyTheQuitRoute() {
        let terms = ChatRouteResolver.contentTerms(query: "quit mail", appName: "Mail")
        #expect(terms == ["quit"])
        for title in Self.mailCommands {
            let matched = ChatRouteResolver.termsMatch(title, terms: terms)
            #expect(matched == (title == "Quit Mail"), "\"quit mail\" vs \(title)")
        }
        #expect(ChatRouteResolver.commandStronglyMatches("Quit Mail", terms: terms))
        for title in ["Hide Mail", "Mail Help", "Get New Mail"] {
            #expect(!ChatRouteResolver.commandStronglyMatches(title, terms: terms), "\(title)")
        }
    }

    @Test func quitMailRunsTheQuitRouteWithoutAsking() {
        func route(_ path: [String]) -> ChatRoute {
            ChatRoute(
                id: "menu:\(path.joined(separator: " ▸ "))", kind: .menuCommand,
                title: path.joined(separator: " ▸ "),
                payload: path.joined(separator: "\u{1}"), appName: "Mail",
                bundleId: "com.apple.mail", isReadOnly: false)
        }
        let only = [route(["Mail", "Quit Mail"])]
        #expect(ChatRouteResolver.soleExactRoute(only, query: "quit mail", appName: "Mail")?.title
                == "Mail ▸ Quit Mail")
        #expect(!ChatRouteResolver.shouldAsk(
            routes: only, bundleId: "com.apple.mail", query: "quit mail"))
        // Never a pick between the quit and its neighbours.
        let mixed = [route(["Mail", "Quit Mail"]), route(["Mail", "Hide Mail"])]
        #expect(ChatRouteResolver.soleExactRoute(mixed, query: "quit mail", appName: "Mail")?.title
                == "Mail ▸ Quit Mail")
        #expect(ChatRouteResolver.soleExactRoute(
            [route(["Mail", "Hide Mail"])], query: "quit mail", appName: "Mail") == nil)
    }

    @Test func openInMailNamesNoCommandSoNothingUnrelatedIsOffered() {
        for query in ["open in mail", "open in Mail", "open it in mail", "open mail"] {
            let terms = ChatRouteResolver.contentTerms(query: query, appName: "Mail")
            #expect(terms.isEmpty, "\"\(query)\" left \(terms)")
            for title in Self.mailCommands {
                #expect(!ChatRouteResolver.termsMatch(title, terms: terms), "\(query) → \(title)")
            }
        }
    }

    @Test func aRealCommandInTheSentenceSurvivesTheAppsName() {
        // Only the app's name goes; "open" stays, because "preferences" is a real command
        // word and the verb still helps match "Open Mail Preferences".
        #expect(ChatRouteResolver.contentTerms(query: "open mail preferences", appName: "Mail")
                == ["open", "preferences"])
        // Nothing but a pointing verb left: no command to match.
        #expect(ChatRouteResolver.contentTerms(query: "open in mail", appName: "Mail").isEmpty)
        // No app named: the sentence is left as it was.
        #expect(ChatRouteResolver.contentTerms(query: "open", appName: "Mail") == ["open"])
    }

    @Test func aTurnThatAsksWhichRouteRanNothing() {
        let choice = ActionChoice(id: "a", title: "A", routeLabel: "Menu", appName: "Mail")
        let answer = AppScopedChatService.Answer.asking(
            "Mail can do that more than one way. Which should I use?", choices: [choice])
        #expect(answer.isWaitingOnRouteChoice)
        #expect(answer.toolChips.isEmpty)
        #expect(answer.evidenceReceipts.isEmpty)
        #expect(answer.consoleOutput == nil)
        #expect(answer.rows.isEmpty)
        #expect(answer.files.isEmpty)
    }

    // The Corner and the chat window read their pick card through
    // `ChatClarification.offered(by:)`. A turn that ran a step must not also ask.
    private static let routeList =
        "Mail can do that more than one way. Which should I use?\n"
        + "1. Get New Mail\n2. Mail Assistant Basics\n3. Mail — what this app is"

    @Test func aTurnThatRanAStepOffersNoPickCard() {
        let ran = AIChatMessage(
            role: .assistant, content: "Mail quit. Verified.\n\n" + Self.routeList,
            mcpToolsRan: ["run_route(Mail ▸ Quit Mail)"])
        #expect(ChatClarification.offered(by: ran) == nil)
        let receipted = AIChatMessage(
            role: .assistant, content: Self.routeList,
            evidenceReceipts: [DoraXActionReceipt(
                command: "run_route(Mail ▸ Quit Mail)", output: "Verified", success: true)])
        #expect(ChatClarification.offered(by: receipted) == nil)
        var stepped = AIChatMessage(role: .assistant, content: Self.routeList)
        stepped.activity = [ActivityStep(kind: .tool, title: "Quit Mail")]
        #expect(ChatClarification.offered(by: stepped) == nil)
    }

    @Test func aTurnThatRanNothingStillOffersItsPickCard() {
        let asked = AIChatMessage(role: .assistant, content: Self.routeList)
        #expect(ChatClarification.offered(by: asked)?.options.count == 3)
        // The routing lookup is a search, not a step.
        let looked = AIChatMessage(
            role: .assistant, content: Self.routeList, mcpToolsRan: ["DoraX route lookup"])
        #expect(ChatClarification.offered(by: looked) != nil)
    }
}

// MARK: - What counts as the command itself

@MainActor
struct ExactCommandTests {

    @Test func theSentenceIsTheCommand() {
        let pairs: [(String, String)] = [
            ("copy", "Copy"),
            ("Copy.", "Copy"),
            ("new folder", "New Folder"),
            ("empty trash", "Empty Trash…"),
            ("empty my trash please", "Empty Trash…"),
            ("turn dark mode off", "Turn Off Dark Mode"),
            ("dark mode off", "Turn Off Dark Mode"),
            ("click New Tab", "New Tab"),
            ("run \"Show Sidebar\" in the view menu", "Show Sidebar"),
        ]
        for (sentence, title) in pairs {
            #expect(
                ExactCommand.matches(query: sentence, titles: [title]),
                "\"\(sentence)\" should be \(title)")
        }
    }

    @Test func aValueRidesAlongWithItsCommand() {
        #expect(ExactCommand.matches(query: "set volume to 30", titles: ["Set Volume"]))
        #expect(ExactCommand.matches(query: "set volume to 30%", titles: ["Set Volume"]))
        // A word is not a value.
        #expect(!ExactCommand.matches(query: "set volume to loud", titles: ["Set Volume"]))
    }

    @Test func theAppsNameIsNotPartOfTheCommand() {
        #expect(ExactCommand.matches(
            query: "new folder in Finder", titles: ["New Folder"], appNames: ["Finder"]))
        #expect(ExactCommand.matches(
            query: "open Find My", titles: ["Open Find My"], appNames: ["Finder", "Find My"]))
    }

    @Test func theMenuPathNamesTheCommand() {
        var candidate = DoraXActionCandidate(
            id: "m", title: "New Folder", appName: "Finder", bundleID: "com.apple.finder",
            source: .cachedMenu, route: .verifiedMenu, capabilityID: nil, requiredInputs: [],
            riskLevel: .low, confidence: 0.5, permissionKey: "k", debugReason: "")
        candidate.menuPath = ["File", "New Folder"]
        #expect(ExactCommand.matches(query: "File > New Folder", candidate: candidate))
        #expect(ExactCommand.matches(query: "File → New Folder", candidate: candidate))
    }

    @Test func overlapIsNotTheCommand() {
        let pairs: [(String, String)] = [
            ("find my passport pdf", "Find"),
            ("find my passport pdfs gokulakannan", "Find…"),
            ("copy the passport pdf to the desktop", "Copy"),
            ("take a note about the roof quote", "New Note"),
            ("show photos of the beach", "Show Photos"),
            ("new folder for the tax documents", "New Folder"),
            ("turn dark mode off", "Toggle Dark Mode"),
        ]
        for (sentence, title) in pairs {
            #expect(
                !ExactCommand.matches(query: sentence, titles: [title]),
                "\"\(sentence)\" is not \(title)")
        }
    }

    @Test func anEmptyTitleNeverMatches() {
        #expect(!ExactCommand.matches(query: "the", titles: ["The"]))
        #expect(!ExactCommand.matches(query: "", titles: [""]))
    }
}



// MARK: - Issue 204: Notes reads keep the shortcut's safety and its scope

@MainActor
struct NotesShortcutRetirementTests {

    /// The sentences the shortcut used to claim are still reads of the scope's own records,
    /// so the Notes chat grounds them in a fresh `notes.search` read.
    @Test func notesScopeSentencesAreFreshReads() {
        for sentence in ["how many notes do I have?", "find notes with links",
                         "any notes about the roof quote"] {
            #expect(ReadOnlyDataRouter.domain(for: sentence) == .notes, "\"\(sentence)\"")
        }
        let decision = AgentSourceAuthority.decide(
            query: "how many notes do i have?", scopeBundleId: "com.apple.Notes")
        #expect(decision.requiresFreshRead)
    }

    /// The shortcut redacted credentials from titles and snippets before they reached the
    /// transcript; the rows `notes.search` hands the card carry the same redaction.
    @Test func noteRowsRedactCredentials() {
        let redacted = NotePreviewRedaction.redact("deploy key ghp_abcdefghijklmnop1234 and password: hunter2")
        #expect(!redacted.contains("ghp_abcdefghijklmnop1234"))
        #expect(!redacted.contains("hunter2"))
        #expect(redacted.contains("[redacted]"))
        #expect(NotePreviewRedaction.redact("roof quote from Alex") == "roof quote from Alex")
    }

    /// Both directions of the find/search lane split (issue 204). "find notes with links." is
    /// a data read in an app that owns records: `notes.search`, and no menu or `operate_app`
    /// tool. A "find" that is a real interface action elsewhere stays an action.
    @Test func findIsADataReadInNotesAndAnActionInTheUI() {
        let notes = FrontmostAppTaskPlan.make(
            query: "find notes with links.", bundleId: "com.apple.Notes", appName: "Notes")
        #expect(notes.intent == .read)
        for tool in ["operate_app", "run_menu_command", "find_menu_command", "send_keys"] {
            #expect(!notes.allowedToolNames.contains(tool), "Notes find offered \(tool)")
        }
        // The same verb about the interface is the UI lane, even in Notes.
        let notesUI = FrontmostAppTaskPlan.make(
            query: "find the sidebar in the window", bundleId: "com.apple.Notes",
            appName: "Notes")
        #expect(notesUI.permitsUIAutomation)
        // A find in an app that owns no record set is untouched.
        for (query, bundle, app) in [
            ("find on this page", "com.apple.Safari", "Safari"),
            ("find my passport pdf", "com.apple.finder", "Finder"),
        ] {
            let plan = FrontmostAppTaskPlan.make(query: query, bundleId: bundle, appName: app)
            #expect(plan.permitsUIAutomation, "\"\(query)\" in \(app)")
        }
    }

    /// "find notes with links." is a read of Notes' own records: fresh read, and the prompt
    /// names the typed read tool instead of leaving the model to answer from the window.
    @Test func findInNotesIsAFreshRecordsRead() {
        let decision = AgentSourceAuthority.decide(
            query: "find notes with links.", scopeBundleId: "com.apple.Notes")
        #expect(decision.primary == .liveState)
        #expect(decision.requiresFreshRead)
        #expect(decision.promptRule.contains("notes.search"))
        // Not in a scope that owns no records, and not when the sentence is about the UI.
        #expect(AgentSourceAuthority.decide(
            query: "find notes with links.", scopeBundleId: "com.apple.finder").primary
            != .liveState)
        #expect(!ScopedRecordRead.matches(
            query: "find the sidebar in the window", bundleId: "com.apple.Notes"))
    }

    /// The pre-fetched Notes block is what a provider with no tools gets to read. "Notes with
    /// links" means notes containing URLs, so the search term is "http", not the word "links";
    /// and, like notes.search, the block never carries a credential.
    @Test func notesPrefetchSearchesForUrlsAndRedacts() {
        #expect(AppleLiveDataContext.noteSearchTerm(for: "find notes with links.") == "http")
        #expect(AppleLiveDataContext.noteSearchTerm(for: "any notes with urls") == "http")
        #expect(AppleLiveDataContext.noteSearchTerm(for: "find my bookmarks note") == "bookmarks")
        #expect(AppleLiveDataContext.noteSearchTerm(for: "show my notes").isEmpty)
        let block = AppleLiveDataContext.noteLines([
            ["title": "bank password: hunter2", "body": "key ghp_abcdefghijklmnop1234 end"],
            ["title": "roof quote", "body": "call Alex"],
        ])
        #expect(!block.contains("hunter2"))
        #expect(!block.contains("ghp_abcdefghijklmnop1234"))
        #expect(block.contains("roof quote: call Alex"))
    }

    /// A tool-less provider cannot call notes.count, so a total is pre-fetched for it.
    @Test func notesTotalIsPrefetchedForCountQuestions() {
        for q in ["how many notes do I have?", "count my notes", "what is the number of notes"] {
            #expect(AppleLiveDataContext.asksForNoteTotal(q), "\"\(q)\"")
        }
        for q in ["find notes with links.", "show my notes", "create a note"] {
            #expect(!AppleLiveDataContext.asksForNoteTotal(q), "\"\(q)\"")
        }
    }

    /// What the model reads is redacted too, not only the card rows (review of PR 314).
    @Test func modelFacingSearchOutputRedactsCredentials() {
        let entry = AppleNotesMCPCapabilities.searchEntry(
            id: "1", title: "bank password: hunter2", folder: "Notes", modified: "today",
            snippet: "deploy key ghp_abcdefghijklmnop1234")
        #expect(!entry.contains("hunter2"))
        #expect(!entry.contains("ghp_abcdefghijklmnop1234"))
        #expect(entry.contains("[redacted]"))
    }

    /// A total is not a search: the count is its own capability, registered and free.
    @Test func countIsItsOwnFreeCapability() {
        let count = CapabilityRegistry.shared.capability(id: "notes.count")
        #expect(count != nil)
        #expect(count?.riskLevel.requiresApproval == false)
    }
}

// MARK: - Issue 204: Menu Command shortcut retirement

@MainActor
struct MenuCommandShortcutRetirementTests {

    private static func menu(_ app: String, _ path: [String]) -> DoraXActionCandidate {
        var made = DoraXActionCandidate(
            id: "menu.\(app).\(path.joined(separator: "."))",
            title: path.last ?? "",
            appName: app,
            bundleID: "test.\(app)",
            source: .cachedMenu,
            route: .verifiedMenu,
            capabilityID: nil,
            requiredInputs: [],
            riskLevel: .low,
            confidence: 0.6,
            permissionKey: "generalAI.execute.menu",
            debugReason: "menu-retirement")
        made.menuPath = path
        return made
    }

    /// Token-overlapping requests that `MenuIntentRouter` previously scored >= 40 (because a
    /// single token > 2 chars equalled the menu title) no longer preempt the model: they route
    /// to `.model` with `offer == nil` and keep the menu item in `modelCandidates`.
    @Test func tokenOverlappingSentencesGoToTheModelWithCandidates() {
        let copyCandidate = Self.menu("Finder", ["Edit", "Copy"])
        let copyDecision = ScopedRoutePolicy.decide(
            query: "copy the passport pdf to the desktop",
            scopedApp: "Finder",
            namedApp: nil,
            candidates: [copyCandidate])
        #expect(copyDecision.routeClass == .model)
        #expect(copyDecision.offer == nil)
        #expect(copyDecision.modelCandidates.map(\.title) == ["Copy"])

        let newFolderCandidate = Self.menu("Finder", ["File", "New Folder"])
        let folderDecision = ScopedRoutePolicy.decide(
            query: "new folder for the tax documents",
            scopedApp: "Finder",
            namedApp: nil,
            candidates: [newFolderCandidate])
        #expect(folderDecision.routeClass == .model)
        #expect(folderDecision.offer == nil)
        #expect(folderDecision.modelCandidates.map(\.title) == ["New Folder"])
    }

    /// Exact menu commands and explicit menu paths still offer the command via `ScopedRoutePolicy`.
    @Test func exactMenuCommandsAreOfferedThroughTheLadder() {
        let newTab = Self.menu("Finder", ["File", "New Tab"])
        let titleDecision = ScopedRoutePolicy.decide(
            query: "New Tab",
            scopedApp: "Finder",
            namedApp: nil,
            candidates: [newTab])
        #expect(titleDecision.routeClass == .exactCommand)
        #expect(titleDecision.offer?.title == "New Tab")

        let minimize = Self.menu("Finder", ["Window", "Minimize"])
        let pathDecision = ScopedRoutePolicy.decide(
            query: "Window > Minimize",
            scopedApp: "Finder",
            namedApp: nil,
            candidates: [minimize])
        #expect(pathDecision.routeClass == .exactCommand)
        #expect(pathDecision.offer?.title == "Minimize")
    }

    /// `DockShortcut` no longer includes the retired `menuCommand` case.
    @Test func menuCommandShortcutIsRetiredFromDockShortcut() {
        #expect(!DockShortcut.allCases.map(\.rawValue).contains("menuCommand"))
    }
}

// MARK: - Issue 204: Mail Question shortcut retirement

@MainActor
struct MailQuestionShortcutRetirementTests {

    /// Questions that the retired Mail Question shortcut and its attached-context gate
    /// previously intercepted before the model now route to `.liveState` in `AgentSourceAuthority`
    /// (`requiresFreshRead == true`, `allowsMemoryEvidence == false`), while ordinary greetings in
    /// Mail scope stay `.conversation`.
    @Test func mailScopeQuestionsAreFreshLiveStateReads() {
        for sentence in [
            "any unread mail?",
            "is there any mail from sarah today?",
            "did i get mail from SBI yesterday?",
            "who sent this message?",
            "what's the subject line?",
            "do i have any attachments from sarah?",
        ] {
            let decision = AgentSourceAuthority.decide(
                query: sentence, scopeBundleId: "com.apple.mail")
            #expect(decision.primary == .liveState, "\"\(sentence)\"")
            #expect(decision.requiresFreshRead, "\"\(sentence)\"")
            #expect(!decision.allowsMemoryEvidence, "\"\(sentence)\"")
            #expect(decision.promptRule.contains("mail.search"))
        }

        let greeting = AgentSourceAuthority.decide(
            query: "hi hello?", scopeBundleId: "com.apple.mail")
        #expect(greeting.primary == .conversation)
    }

    /// Imperative record searches in Mail ("find mail from SBI today") are data-lane reads of
    /// Mail's records: `intent == .read`, `!permitsUIAutomation`, `RequestLane == .data`, and
    /// Mail's read tools (`search_mail`, `read_unread_mail`) are included.
    @Test func findInMailIsADataLaneRead() {
        let query = "find mail from SBI today"
        let plan = FrontmostAppTaskPlan.make(
            query: query, bundleId: "com.apple.mail", appName: "Mail")
        #expect(plan.intent == .read)
        #expect(!plan.permitsUIAutomation)
        #expect(RequestLane.decide(query) == .data)
        #expect(plan.allowedToolNames.contains("search_mail"))
        #expect(plan.allowedToolNames.contains("read_unread_mail"))
    }

    /// Mail's read capabilities (`mail.recent`, `mail.read`, `mail.search`, `mail.unread`,
    /// `mail.currentMessage`) are registered and free (`requiresApproval == false`).
    @Test func mailCapabilitiesAreRegisteredAndReadCapabilitiesAreFree() {
        for id in ["mail.recent", "mail.read", "mail.search", "mail.unread", "mail.currentMessage"] {
            let cap = CapabilityRegistry.shared.capability(id: id)
            #expect(cap != nil, "Missing capability \(id)")
            #expect(cap?.riskLevel.requiresApproval == false, "\(id) should not require approval")
        }
    }

    /// `DockShortcut` no longer includes the retired `mailQuestion` case, and `AppleLiveDataContext`
    /// pre-fetches inbox headers for Mail questions.
    @Test func mailQuestionShortcutIsRetiredFromDockShortcut() {
        #expect(!DockShortcut.allCases.map(\.rawValue).contains("mailQuestion"))
        #expect(AppleLiveDataContext.wantsMailContext("any unread mail?"))
        #expect(AppleLiveDataContext.wantsMailContext("what's the subject line?"))
        #expect(!AppleLiveDataContext.wantsMailContext("hi hello?"))
    }
}

// MARK: - Issue 204: Mailbox Search commands reach the model as data-lane Mail reads

@MainActor
struct MailboxSearchShortcutRetirementTests {

    /// Every kind of sentence the retired Mailbox Search shortcut took before the model.
    static let retiredCommands = [
        "search mail from SBI",
        "search for invoice",
        "Search mail for quarterly report",
        "find mail from Gokula kannan J",
        "look for emails from SBI",
        "look up mail from SBI",
        "search my inbox for subject payslip",
        "please search mail from SBI",
        // The Mail scope may already have stripped its own name from the sentence.
        "search from SBI",
        "search mail for \"invoice and receipt\"",
    ]

    /// A search command in Mail scope is a fresh read of Mail's records, never an answer from
    /// memory or conversation.
    @Test func searchCommandsAreFreshLiveStateReads() {
        for sentence in Self.retiredCommands {
            let decision = AgentSourceAuthority.decide(
                query: sentence, scopeBundleId: "com.apple.mail")
            #expect(decision.primary == .liveState, "\"\(sentence)\"")
            #expect(decision.requiresFreshRead, "\"\(sentence)\"")
            #expect(!decision.allowsMemoryEvidence, "\"\(sentence)\"")
        }
    }

    /// The plan is a data-lane read with Mail's search tool and no UI automation: Mail's
    /// window is never raised, clicked or typed into (owner, 2026-10-10).
    @Test func searchCommandsPlanAsDataLaneReads() {
        for sentence in Self.retiredCommands {
            let plan = FrontmostAppTaskPlan.make(
                query: sentence, bundleId: "com.apple.mail", appName: "Mail")
            #expect(plan.intent == .read, "\"\(sentence)\"")
            #expect(!plan.permitsUIAutomation, "\"\(sentence)\"")
            #expect(plan.complexity != .direct, "\"\(sentence)\" needs a tool round")
            #expect(plan.allowedToolNames.contains("search_mail"), "\"\(sentence)\"")
        }
    }

    /// The cross-app parser reads "search mail …" as a search *in* Mail and types the rest
    /// into Mail's search field. In Mail's own chat it must not take the turn — whether or not
    /// Global Context is active underneath, which it is inside an App Pet. Typed from Global
    /// Context, where the sentence named the app, it is cross-app as before.
    @Test func crossAppRoutingDoesNotClaimSearchCommands() {
        let handler = CrossAppNLHandler.shared
        for sentence in Self.retiredCommands {
            guard let intent = handler.parse(sentence.lowercased()) else { continue }
            #expect(
                !handler.claimsTurn(
                    intent, scopedBundleId: "com.apple.mail", scopeNamedByQuery: false),
                "\"\(sentence)\"")
            #expect(
                handler.claimsTurn(
                    intent, scopedBundleId: "com.apple.mail", scopeNamedByQuery: true),
                "\"\(sentence)\" from Global Context")
            // The App Pet's own app wins even when the sentence also named it.
            #expect(
                !handler.claimsTurn(
                    intent, scopedBundleId: "com.apple.mail", chatBundleId: "com.apple.mail",
                    scopeNamedByQuery: true),
                "\"\(sentence)\" in Mail's App Pet")
        }
        // A search of another app from Mail's chat, and any non-search intent, still claim.
        if let other = handler.parse("search notes tax return") {
            #expect(handler.claimsTurn(other, scopedBundleId: "com.apple.mail", scopeNamedByQuery: false))
            #expect(!handler.claimsTurn(other, scopedBundleId: "com.apple.Notes", scopeNamedByQuery: false))
        } else {
            Issue.record("search notes tax return should parse as a cross-app search")
        }
        if let send = handler.parse("send this to salman") {
            #expect(handler.claimsTurn(send, scopedBundleId: "com.apple.mail", scopeNamedByQuery: false))
        }
    }

    /// If a Mail search does go to Mail's search field (from Global Context), the field gets
    /// the name, not the literal words "from uel", which match nothing.
    @Test func aCrossAppMailSearchDropsTheWordFrom() {
        let handler = CrossAppNLHandler.shared
        #expect(handler.parse("search mail from uel")?.searchQuery == "uel")
        #expect(handler.parse("find mail from gokula kannan j")?.searchQuery == "gokula kannan j")
        #expect(handler.parse("search mail quarterly report")?.searchQuery == "quarterly report")
        #expect(handler.parse("search notes from last week")?.searchQuery == "from last week")
    }

    /// App Find runs before the cross-app parser and would drive Mail's Mailbox Search.
    @Test func aMailSearchInMailsOwnChatStaysInTheTranscript() {
        for sentence in ["search mail from uel", "look for emails from SBI", "search for invoice"] {
            #expect(
                AppleLiveDataContext.isInScopeMailSearch(sentence, scopedBundleId: "com.apple.mail"),
                "\"\(sentence)\"")
            #expect(
                !AppleLiveDataContext.isInScopeMailSearch(sentence, scopedBundleId: "com.apple.Notes"),
                "\"\(sentence)\"")
        }
        #expect(!AppleLiveDataContext.isInScopeMailSearch("find in this window", scopedBundleId: "com.apple.mail"))
    }

    /// A look-up verb is a record read in every record-set app, not only Mail, and a UI
    /// sentence with the same verb stays an action.
    @Test func lookUpVerbsAreRecordReads() {
        #expect(ScopedRecordRead.matches(query: "look for emails from SBI", bundleId: "com.apple.mail"))
        #expect(ScopedRecordRead.matches(query: "look up notes about tax", bundleId: "com.apple.Notes"))
        #expect(!ScopedRecordRead.matches(query: "look for the sidebar", bundleId: "com.apple.mail"))
        #expect(!ScopedRecordRead.matches(query: "look for mail from SBI and reply to it", bundleId: "com.apple.mail"))
    }

    @Test func mailboxSearchShortcutIsRetiredFromDockShortcut() {
        #expect(!DockShortcut.allCases.map(\.rawValue).contains("mailboxSearch"))
    }
}

// MARK: - Issue 204: Messages shortcut retirement

@MainActor
struct MessagesShortcutRetirementTests {

    /// Questions in the Messages scope route to `.liveState` in `AgentSourceAuthority`
    /// (`requiresFreshRead == true`, `allowsMemoryEvidence == false`), while ordinary greetings in
    /// Messages scope stay `.conversation`.
    @Test func messagesScopeQuestionsAreFreshLiveStateReads() {
        for sentence in [
            "what did Salman text me today?",
            "who do I message most?",
            "do I have any unread messages?",
            "did Salman text me yesterday?",
        ] {
            let decision = AgentSourceAuthority.decide(
                query: sentence, scopeBundleId: "com.apple.MobileSMS")
            #expect(decision.primary == .liveState, "\"\(sentence)\"")
            #expect(decision.requiresFreshRead, "\"\(sentence)\"")
            #expect(!decision.allowsMemoryEvidence, "\"\(sentence)\"")
            #expect(decision.promptRule.contains("messages.search"))
        }

        let greeting = AgentSourceAuthority.decide(
            query: "hi hello?", scopeBundleId: "com.apple.MobileSMS")
        #expect(greeting.primary == .conversation)
    }

    /// Outbound compose and send requests that the retired pre-model Messages shortcut
    /// previously intercepted without approval now route to `.action` in `AgentSourceAuthority`,
    /// plan as `.act` in `FrontmostAppTaskPlan` with `compose_message` / `send_message`, skip
    /// `CrossAppNLHandler` in Messages scope, and resolve `messages.compose` (`requiresApproval == true`)
    /// in `AppAdapterCapabilityCatalog`.
    @Test func messagesComposeAndSendRequestsAreGatedActions() {
        for sentence in [
            "send \"hi\" to Salman",
            "send I'm running late to Salman",
            "text Salman I'm running late",
        ] {
            let sourceDecision = AgentSourceAuthority.decide(
                query: sentence, scopeBundleId: "com.apple.MobileSMS")
            #expect(sourceDecision.primary == .action, "\"\(sentence)\"")
            #expect(sourceDecision.requiresFreshRead, "\"\(sentence)\"")
            #expect(!sourceDecision.allowsMemoryEvidence, "\"\(sentence)\"")

            let plan = FrontmostAppTaskPlan.make(
                query: sentence, bundleId: "com.apple.MobileSMS", appName: "Messages")
            #expect(plan.intent == .act, "\"\(sentence)\"")
            #expect(plan.allowedToolNames.contains("compose_message"), "\"\(sentence)\"")
            #expect(plan.allowedToolNames.contains("send_message"), "\"\(sentence)\"")

            #expect(
                DockCore.shouldSkipCrossAppMessagesRouting(
                    scopedBundleId: "com.apple.MobileSMS", rawScopedQuery: sentence),
                "\"\(sentence)\" should stay in the Messages ladder")

            let candidates = AppAdapterCapabilityCatalog.registeredCandidates(
                appName: "Messages", bundleID: "com.apple.MobileSMS", query: sentence)
            #expect(candidates.first?.capabilityID == "messages.compose", "\"\(sentence)\"")
            #expect(candidates.first?.riskLevel.requiresApproval == true, "\"\(sentence)\"")
            #expect(candidates.first?.inputValues["recipient"]?.lowercased().contains("salman") == true, "\"\(sentence)\"")
        }

        // Genuine cross-app contextual share payloads in Messages scope are not blocked.
        #expect(
            !DockCore.shouldSkipCrossAppMessagesRouting(
                scopedBundleId: "com.apple.MobileSMS", rawScopedQuery: "send this file to Salman"))
    }

    /// Imperative record searches in Messages ("find messages from Salman") are data-lane reads of
    /// Messages' records: `intent == .read`, `!permitsUIAutomation`, `RequestLane == .data`, and
    /// Messages' read tools (`search_messages`, `get_messages_conversations`) are included.
    @Test func findInMessagesIsADataLaneRead() {
        let query = "find messages from Salman"
        let plan = FrontmostAppTaskPlan.make(
            query: query, bundleId: "com.apple.MobileSMS", appName: "Messages")
        #expect(plan.intent == .read)
        #expect(!plan.permitsUIAutomation)
        #expect(RequestLane.decide(query) == .data)
        #expect(plan.allowedToolNames.contains("search_messages"))
        #expect(plan.allowedToolNames.contains("get_messages_conversations"))
        for tool in ["operate_app", "run_menu_command", "find_menu_command", "send_keys"] {
            #expect(!plan.allowedToolNames.contains(tool), "Messages find offered \(tool)")
        }

        let candidates = AppAdapterCapabilityCatalog.registeredCandidates(
            appName: "Messages", bundleID: "com.apple.MobileSMS", query: query)
        #expect(candidates.first?.capabilityID == "messages.search")
        #expect(candidates.first?.inputValues["query"] == "salman")
    }

    /// Messages read capabilities (`messages.recent`, `messages.search`, `messages.topContacts`)
    /// are free (`requiresApproval == false`), while outbound capabilities (`messages.compose`,
    /// `messages.send`) require approval (`requiresApproval == true`).
    @Test func messagesCapabilitiesRespectApprovalGates() {
        CapabilityRegistry.shared.refreshBuiltInMCPs()
        for id in ["messages.recent", "messages.search", "messages.topContacts"] {
            let cap = CapabilityRegistry.shared.capability(id: id)
            #expect(cap != nil, "Missing capability \(id)")
            #expect(cap?.riskLevel.requiresApproval == false, "\(id) should not require approval")
        }
        for id in ["messages.compose", "messages.send"] {
            let cap = CapabilityRegistry.shared.capability(id: id)
            #expect(cap != nil, "Missing capability \(id)")
            #expect(cap?.riskLevel.requiresApproval == true, "\(id) must require approval")
        }
    }

    /// `DockShortcut` no longer includes the retired `messages` case, and `ReadOnlyDataRouter`
    /// classifies "text me" questions as `.messages`.
    @Test func messagesShortcutIsRetiredFromDockShortcut() {
        #expect(!DockShortcut.allCases.map(\.rawValue).contains("messages"))
        #expect(ReadOnlyDataRouter.domain(for: "what did Salman text me today?") == .messages)
        #expect(ReadOnlyDataRouter.domain(for: "did Salman text me yesterday?") == .messages)
    }
}

// MARK: - Issue 204: App Find shortcut retirement

@MainActor
struct AppFindShortcutRetirementTests {

    /// Find, search, and photo sentences that the retired pre-model App Find shortcut would
    /// have intercepted and routed to `executeAppFindIntent` now reach the model: data-seeking
    /// queries route as `.data` through `RequestLane.decide` (unless mentioning a UI element like "window").
    @Test func appFindQueryRoutesAsData() {
        for sentence in [
            "find budget report",
            "search for the passport pdf",
            "look for the invoice",
            "photos of cats",
            "find \"budget\" in this app",
            "search for contracts in this document",
        ] {
            #expect(RequestLane.decide(sentence) == .data, "\"\(sentence)\"")
        }
        // A find request explicitly mentioning a window targets the UI lane
        #expect(RequestLane.decide("search for contracts in this window") == .ui)
    }

    /// `ScopedRoutePolicy` considers actions for find sentences (they are not questions), so
    /// the model still receives the scoped app's matching menu candidates alongside the query.
    @Test func scopedRoutePolicyConsidersActionsForFindQueries() {
        for sentence in ["find budget report", "search for the invoice"] {
            #expect(ScopedRoutePolicy.considersActions(sentence), "\"\(sentence)\"")
        }
    }

    /// `DockShortcut` no longer includes the retired `appFind` case.
    @Test func appFindShortcutIsRetiredFromDockShortcut() {
        #expect(!DockShortcut.allCases.map(\.rawValue).contains("appFind"))
    }
}

// MARK: - H6: get_today_events tool retirement

@MainActor
struct CalendarToolRetirementTests {

    /// Calendar queries route as `.data` — the model uses `find_capability` +
    /// `run_capability("calendar.todayEvents")` rather than a named tool.
    @Test func calendarQueriesRouteAsData() {
        for sentence in [
            "what's on my calendar today",
            "do I have any meetings today",
            "what are my events today",
            "show me today's calendar",
        ] {
            #expect(RequestLane.decide(sentence) == .data, "\"\(sentence)\"")
        }
    }

    /// `FrontmostAppTaskPlan` no longer injects `get_today_events` for Calendar turns;
    /// `find_capability` and `run_capability` are always present in the base tool set.
    @Test func calendarPlanOmitsRetiredTool() {
        let plan = FrontmostAppTaskPlan.make(
            query: "what are my events today",
            bundleId: "com.apple.iCal",
            appName: "Calendar"
        )
        #expect(!plan.allowedToolNames.contains("get_today_events"))
        #expect(plan.allowedToolNames.contains("find_capability"))
        #expect(plan.allowedToolNames.contains("run_capability"))
    }

    /// The `calendar.todayEvents` capability is registered and discoverable — the fallback
    /// path the model uses after the named tool is retired.
    @Test func calendarTodayEventsCapabilityExists() {
        CapabilityRegistry.shared.refreshBuiltInMCPs()
        let cap = CapabilityRegistry.shared.capability(id: "calendar.todayEvents")
        #expect(cap != nil, "calendar.todayEvents capability must be registered")
    }
}

// MARK: - H6: run_app_script retirement

/// Verifies that `run_app_script` is no longer offered after H6 tool-core trim.
/// App-profile scripts now execute via `run_synthesized_script` / learned skills.
struct AppScriptToolRetirementTests {

    /// A plan for an app that declares scripts must NOT include `run_app_script`;
    /// `run_synthesized_script` is always present for scoped app turns.
    @Test func runAppScriptIsAbsentFromAppScopedPlan() {
        let plan = FrontmostAppTaskPlan.make(
            query: "export this document as pdf",
            bundleId: "com.test.scriptableapp",
            appName: "ScriptableApp")
        #expect(!plan.allowedToolNames.contains("run_app_script"))
        #expect(plan.allowedToolNames.contains("run_synthesized_script"))
    }

    /// `run_app_script` is not in the OutboundGate's judged tool set.
    @Test func runAppScriptIsRemovedFromOutboundGate() {
        #expect(!OutboundGate.outboundTools.contains("run_app_script"))
    }

    /// The `{"app_script": ...}` JSON shortcut for tool-less providers no longer
    /// resolves to an invocation — a synthesized_script directive is used instead.
    @Test func appScriptJsonDirectiveIsRetired() {
        let invocation = AITypedInvocationResolver.invocation(
            from: #"{"app_script": {"name": "tabs-to-md.sh"}}"#)
        #expect(invocation == nil || invocation?.kind != .synthesizedScript)
        // The synthesized_script path still works for tool-less providers.
        let synth = AITypedInvocationResolver.invocation(
            from: #"{"synthesized_script": {"script": "tell application \"Safari\" to get URL of current tab of front window", "language": "applescript", "reason": "get current tab"}}"#)
        #expect(synth?.kind == .synthesizedScript)
    }
}

// MARK: - H6: read_attachment consolidated into read_file

/// Verifies that `read_attachment` is retired after H6 tool-core trim and that an attachment
/// question is answered by `read_file`.
@MainActor
struct ReadAttachmentToolRetirementTests {

    private func context(attachments: [URL]) -> AgentToolContext {
        var context = AgentToolContext(commandExecutor: { _, _, _ in (false, "", -1) })
        context.attachments = attachments
        return context
    }

    private func attachment(_ name: String, _ text: String) throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("dorax-h6-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(name)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// A turn with something attached is offered `read_file`, never the retired tool.
    @Test func attachmentQuestionsAreOfferedReadFileOnly() {
        for sentence in [
            "summarise this", "what does the attached file say",
            "convert this screenshot to markdown",
        ] {
            let plan = FrontmostAppTaskPlan.make(
                query: sentence, bundleId: "com.apple.Notes", appName: "Notes",
                hasAttachments: true)
            #expect(plan.allowedToolNames.contains("read_file"), "\"\(sentence)\"")
            #expect(!plan.allowedToolNames.contains("read_attachment"), "\"\(sentence)\"")
        }
    }

    @Test func readAttachmentIsRetiredEverywhere() {
        #expect(AgentToolRegistry.shared.tool(named: "read_attachment") == nil)
        #expect(!OutboundGate.localTools.contains("read_attachment"))
        #expect(!OutboundGate.readsPrivateData(toolName: "read_attachment", arguments: [:]))
    }

    /// "Summarise this" with one file attached: no path needed.
    @Test func readFileReadsTheOnlyAttachmentWithoutAPath() async throws {
        let url = try attachment("quarterly-notes.md", "Revenue rose nine percent.")
        let result = await AgentToolRegistry.shared.tool(named: "read_file")?
            .handler([:], context(attachments: [url]))
        #expect(result?.success == true)
        #expect(result?.output.contains("Revenue rose nine percent.") == true)
    }

    /// The model sees filenames, so a bare filename must reach the attachment.
    @Test func readFileFindsAnAttachmentByFilename() async throws {
        let first = try attachment("a.txt", "alpha")
        let second = try attachment("b.txt", "bravo")
        let result = await AgentToolRegistry.shared.tool(named: "read_file")?
            .handler(["path": "B.txt"], context(attachments: [first, second]))
        #expect(result?.success == true)
        #expect(result?.output.contains("bravo") == true)
    }

    /// Several attachments and no path: say which exist rather than pick one silently.
    @Test func readFileListsAttachmentsWhenTheChoiceIsAmbiguous() async throws {
        let first = try attachment("a.txt", "alpha")
        let second = try attachment("b.txt", "bravo")
        let result = await AgentToolRegistry.shared.tool(named: "read_file")?
            .handler([:], context(attachments: [first, second]))
        #expect(result?.success == false)
        #expect(result?.output.contains(first.path) == true)
        #expect(result?.output.contains(second.path) == true)
    }

    @Test func readFileSaysWhenNothingIsAttached() async {
        let result = await AgentToolRegistry.shared.tool(named: "read_file")?
            .handler([:], context(attachments: []))
        #expect(result?.success == false)
        #expect(result?.output.contains("Nothing is attached") == true)
    }

    /// A file the user attached by hand is readable even from a folder-scoped thread.
    @Test func anAttachmentIsReadableInsideAFolderThread() async throws {
        let url = try attachment("outside.txt", "handed over")
        var scoped = context(attachments: [url])
        scoped.chatScope = .folder(path: NSTemporaryDirectory() + "dorax-h6-scope")
        let result = await AgentToolRegistry.shared.tool(named: "read_file")?
            .handler(["path": url.path], scoped)
        #expect(result?.success == true)
    }

    /// General Chat names what was attached, so "this file" is not resolved against Finder.
    @Test func generalChatPromptNamesTheAttachedFiles() throws {
        let url = try attachment("named.txt", "x")
        let block = AppScopedChatService.attachmentsPromptBlock([url])
        #expect(block.contains(url.path))
        #expect(block.contains("not the Finder selection"))
        #expect(AppScopedChatService.attachmentsPromptBlock([]).isEmpty)
    }
}
