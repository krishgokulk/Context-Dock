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

        var scopedApp: String? {
            switch self {
            case .finderChat: return "Finder"
            case .safariChat: return "Safari"
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
        // sentence covers both shells (Corner app chat IS the Dock's pipeline).
        Phrase(surface: .finderChat, sentence: "can you resume 2026 folder for me?",
               found: [capability("Finder", "finder.copyFiles", "Copy Finder Files"),
                       menu("Finder", ["Edit", "Copy"]),
                       menu("Finder", ["File", "Find"])],
               expected: .model),
        Phrase(surface: .finderChat, sentence: "can you resume 2026 folder for me?",
               found: [], expected: .model),
    ]

    // MARK: - Running a row

    /// Which of the fixture apps the sentence names, judged by the same rule the resolver
    /// applies to every installed name (`isAppReference`). Offline stand-in for
    /// `namedInstalledApp`, which reads the machine's app catalogue.
    private static let knownApps = ["Find My", "Notes", "Photos", "Safari", "Finder", "Music", "Shortcuts"]

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
