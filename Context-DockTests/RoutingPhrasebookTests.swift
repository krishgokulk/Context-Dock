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

        var scopedApp: String? {
            switch self {
            case .finderChat: return "Finder"
            case .safariChat: return "Safari"
            case .notesChat: return "Notes"
            case .mailChat: return "Mail"
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
    ]

    // MARK: - Running a row

    /// Which of the fixture apps the sentence names, judged by the same rule the resolver
    /// applies to every installed name (`isAppReference`). Offline stand-in for
    /// `namedInstalledApp`, which reads the machine's app catalogue.
    private static let knownApps = ["Find My", "Notes", "Photos", "Safari", "Finder", "Music", "Shortcuts", "Mail"]

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

// MARK: - Mail's Mailbox Search shortcut (issue #195)

/// The Mail scope runs Edit › Find › Mailbox Search before any model reads the sentence.
/// "check my recent mail from Gokula kannan J and do what it says" clicked it and typed
/// the leftovers, because the word "from" made it a sender search. Task 17's rule applies
/// here too: the shortcut claims the turn only when the sentence IS the search command and
/// its value; everything else goes to the model, which has `mail.search` and `mail.read`.
@MainActor
struct MailboxSearchCommandTests {

    @Test func theOwnersSentenceGoesToTheModel() {
        #expect(
            MailboxSearchCommand.claims(
                "check my recent mail from Gokula kannan J and do what it says") == nil)
    }

    @Test func aBareSenderSearchIsTheCommand() {
        let parsed = MailboxSearchCommand.claims("search mail from SBI")
        #expect(parsed == MailboxSearchCommand.Parsed(term: "SBI", field: .sender))
    }

    @Test func aDateOrASecondClauseMakesItARequest() {
        let sentences = [
            "find mail from SBI today",
            "find my recent mail from SBI",
            "search mail from SBI and summarize it",
            "search mail from Gokula kannan J and do what it says",
            "find the latest email from SBI",
            "search mail from SBI about the loan",
            "find unread mail from SBI",
            "look for mail from SBI this week",
        ]
        for sentence in sentences {
            #expect(MailboxSearchCommand.claims(sentence) == nil, "\"\(sentence)\" is a request")
        }
    }

    @Test func theSearchCommandAndItsValue() {
        let cases: [(String, MailboxSearchCommand.Parsed)] = [
            ("search for invoice", .init(term: "invoice", field: .any)),
            ("Search mail for quarterly report", .init(term: "quarterly report", field: .any)),
            ("find mail from Gokula kannan J", .init(term: "Gokula kannan J", field: .sender)),
            ("look for emails from SBI", .init(term: "SBI", field: .sender)),
            ("search my inbox for subject payslip", .init(term: "payslip", field: .subject)),
            ("please search mail from SBI", .init(term: "SBI", field: .sender)),
            // The Mail scope may already have stripped its own name from the sentence.
            ("search from SBI", .init(term: "SBI", field: .sender)),
            ("search mail for \"invoice and receipt\"", .init(term: "invoice and receipt", field: .any)),
        ]
        for (sentence, expected) in cases {
            #expect(MailboxSearchCommand.claims(sentence) == expected, "\"\(sentence)\"")
        }
    }

    @Test func noVerbOrNoValueIsNotTheCommand() {
        let sentences = [
            "mail from SBI",
            "show mail from SBI",
            "check mail from SBI",
            "search mail",
            "find",
            "is there mail from SBI?",
            "can you search mail from SBI",
            "search mail from a sender whose name I forget",
        ]
        for sentence in sentences {
            #expect(MailboxSearchCommand.claims(sentence) == nil, "\"\(sentence)\"")
        }
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
