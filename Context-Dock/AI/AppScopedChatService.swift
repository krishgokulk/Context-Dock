// AppScopedChatService.swift
// Context-Dock
//
// One request path for a conversation scoped to an app or a CLI tool, wherever it is
// being held — the dock's frontmost/scoped chat or the chat window's thread.
//
// The window used to ask the provider with `sendMessage` and no grounding at all, so the
// same question answered well in the dock and badly in the window. The difference was
// never the surface: it was that the dock assembled the app's adapters, cached menu
// commands, MCP tools and linked CLIs into the prompt, and gave the model tools to run,
// while the window sent the bare question. That assembly lives here now.

import AppKit
import Foundation
import OSLog

@MainActor
enum AppScopedChatService {

    /// Stage markers for a scoped send. A stall in this path is invisible from the UI —
    /// the thread just says "Thinking…" — so each stage is logged and readable with
    /// `log show --predicate 'subsystem == "com.krishgokul.ContextDock"'`.
    private static let log = Logger(
        subsystem: "com.krishgokul.ContextDock", category: "AppScopedChat")

    struct Answer {
        let text: String
        /// What actually ran, for the receipt chips — derived from execution, never from
        /// words in the question.
        let toolChips: [String]
        /// Set when the question is about an app this chat may not read. The surface shows
        /// it as a one-tap "Enable <app> for this chat" button.
        var enableApp: EnableAppRequest? = nil
        /// Set when several routes could carry out the request and they differ in
        /// consequence. The surface shows them as pick-one buttons.
        var routeChoices: [ActionChoice] = []
        /// Raw output of a route that ran, for the Console panel.
        var consoleOutput: String? = nil
        /// Files the answer named that exist on disk, so the surface can offer them
        /// instead of leaving a path in a paragraph for the user to retype.
        var files: [URL] = []
        /// Typed proof of what ran and what was freshly read back. The Console keeps the
        /// complete log; these receipts make the important outcome visible in the message.
        var evidenceReceipts: [DoraXActionReceipt] = []
        /// A second model's read of whether the answer satisfies the request, on the
        /// subjective work where that is a real question. The dock has shown this since it
        /// was written; the window had no way to receive it.
        var subjectiveEvaluation: SubjectiveEvaluation? = nil
    }

    /// Paths an answer mentions, kept only when they are real.
    ///
    /// A file chat's answer is usually about files, and it names them: "there is one PDF:
    /// /Users/…/Resume.pdf". Left as prose that is a path to select and paste somewhere;
    /// as a row it is a thing to open. Existence is checked because a model naming a file
    /// is not evidence one is there, and a row that opens onto nothing is worse than a
    /// sentence.
    static func mentionedFiles(in text: String, limit: Int = 8) -> [URL] {
        let pattern = #"(/Users/[^\s"'`,;:()\[\]]+|~/[^\s"'`,;:()\[\]]+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        var found: [URL] = []
        var seen = Set<String>()
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let range = Range(match.range(at: 1), in: text) else { continue }
            // Trailing punctuation belongs to the sentence, not to the path.
            let raw = String(text[range])
                .trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?)"))
            let expanded = (raw as NSString).expandingTildeInPath
            guard FileManager.default.fileExists(atPath: expanded),
                seen.insert(expanded).inserted
            else { continue }
            found.append(URL(fileURLWithPath: expanded))
            if found.count >= limit { break }
        }
        return found
    }

    /// Routes offered for the last question, by choice id, so a pick can be executed
    /// without re-resolving (and without the resolution having drifted in between).
    ///
    /// Kept per thread. As one flat dictionary it was shared by every open conversation:
    /// asking a question in one thread overwrote the choices another thread was still
    /// showing, so tapping a button in the older thread ran the newer thread's route —
    /// against a different app, with the older thread's question as its purpose.
    private static var pendingRoutesByScope: [String: [String: ChatRoute]] = [:]

    private static func rememberPendingRoutes(_ routes: [ChatRoute], scope: GeneralChatScope) {
        pendingRoutesByScope[scope.storageKey] = Dictionary(
            uniqueKeysWithValues: routes.map { ($0.id, $0) })
    }

    /// Runs a route the user picked, then has the model phrase the result. The output is
    /// returned verbatim as well, because a receipt the user can read beats a summary they
    /// have to trust.
    static func runChosenRoute(
        _ choiceID: String, query: String, history: [ChatMessage], scope: GeneralChatScope
    ) async -> Answer {
        guard let route = pendingRoutesByScope[scope.storageKey]?[choiceID] else {
            return Answer(text: "That route is no longer available.", toolChips: [])
        }
        ChatRoutePreferenceStore.remember(
            route.kind, bundleId: route.bundleId, query: query)
        // A picked route arrives from the surface without the turn that produced it, so
        // this one runs in the route's own app scope. Only a skill route re-enters `send`,
        // and a picked skill is already the user naming what they want.
        return await execute(
            route: route, query: query, history: history,
            scope: .app(bundleId: route.bundleId), appName: route.appName)
    }

    /// Runs one resolved route and phrases the result.
    ///
    /// Everything the turn was asked with is carried through, because a skill route
    /// re-enters `send` — and re-entering with only the query dropped the selection, the
    /// attachments, the extra apps AND the conversation's own scope. "Explain about these
    /// files" in a Finder thread matched the spotlight-search skill, came back through here
    /// with nothing attached, and answered "I don't have context on which specific files".
    /// A folder thread lost more: the scope became .app(Finder), so the folder listing went
    /// with it and it answered "I currently do not have information about your folder"
    /// about a folder it had summarised a minute earlier.
    private static func execute(
        route: ChatRoute, query: String, history: [ChatMessage],
        scope: GeneralChatScope, appName: String,
        attachments: [URL] = [], extraAppNames: [String] = [], finderSelection: [URL] = []
    ) async -> Answer {
        // A skill is instructions, not a command: it is carried out by answering with the
        // user's own workflow foregrounded, in the scope it was written for.
        if route.kind == .skill {
            let instructions = SkillStore.shared.skills(for: route.bundleId)
                .first { $0.id == route.payload }
                .map { "## Skill: \($0.name)\n\($0.instructions)" } ?? ""
            ChatConsoleLog.shared.append(
                .tool, title: "skill · \(route.title)", output: instructions,
                success: !instructions.isEmpty,
                scope: scope)
            // The thread's own scope, not the route's app: a skill belonging to Finder
            // does not turn a folder conversation into a Finder one.
            let answer = try? await send(
                scope: scope,
                appName: appName,
                query: query,
                history: history,
                attachments: attachments,
                extraAppNames: extraAppNames,
                finderSelection: finderSelection,
                skillOverride: instructions)
            return answer
                ?? Answer(text: "Couldn't apply \(route.title).", toolChips: [])
        }

        log.notice("route: \(route.kind.rawValue, privacy: .public) \(route.title, privacy: .public)")
        // The console belongs to the conversation, not to the app the route came from.
        // Logging under the route's app sent the receipt to a thread the user was not
        // looking at: "tailscale status" answered "check the Terminal panel for the
        // details" while the panel under the question read "Nothing has run in this thread
        // yet". The app scope is still what state is resolved against — that is about the
        // app — but what ran is reported where it was asked.
        let routeScope = GeneralChatScope.app(bundleId: route.bundleId)

        // The same gate General AI passes through, on the path that never asked it. A CLI
        // route names a tool rather than an app — its bundleId is a `cli://` placeholder —
        // so there is no app authority to consult and nothing to gate on here.
        if let mechanism = route.kind.executionRoute, !route.bundleId.hasPrefix("cli://") {
            let level = AppAccessPolicy.level(for: route.bundleId)
            guard AppAccessPolicy.allows(mechanism, at: level) else {
                let explanation = AppAccessPolicy.explanation(
                    for: route.appName, level: level, wantedRead: route.isReadOnly)
                ChatConsoleLog.shared.append(
                    .note, title: "blocked · \(route.title)", output: explanation,
                    success: false, scope: scope)
                return Answer(
                    text: explanation,
                    toolChips: ["\(route.kind.rawValue) · blocked"],
                    evidenceReceipts: [DoraXActionReceipt(
                        command: "authority(\(route.appName), \(mechanism.rawValue))",
                        output: explanation,
                        success: false)])
            }
        }

        // Taken before the click, because a menu outcome is a difference and there is no
        // difference to read once the app has already drawn it.
        let menuStateBefore: MenuOutcomeVerifier.Snapshot? =
            route.kind == .menuCommand && !route.isReadOnly
            ? MenuOutcomeVerifier.snapshot(bundleID: route.bundleId)
            : nil

        let rowID = ChatConsoleLog.shared.begin(.route, title: route.title, scope: scope)
        let result = await ChatRouteResolver.run(route, query: query)
        ChatConsoleLog.shared.finish(
            rowID,
            output: result.output.isEmpty
                ? (result.success ? "(no output)" : "(failed, no output)") : result.output,
            success: result.success,
            scope: scope)

        let settings = AppSettings.shared
        let provider = settings.selectedAIProvider
        let rawKey = provider.requiresAPIKey ? settings.getAPIKey(for: provider) : ""
        // What used to happen here: re-read the app into prose, hand it to the model, and
        // record a receipt with success: true regardless of what the reading said. A Context
        // Dock action that silently failed showed a green tick, because nothing on this path
        // could return anything but pass.
        //
        // The state block is still read — it is genuinely useful to the model — but it is
        // context now, not the verdict. The verdict comes from a verifier or admits there
        // isn't one.
        var status: VerificationStatus = .notApplicable
        var verificationEvidence: String?
        var verification: String?
        if result.success, !route.isReadOnly {
            try? await Task.sleep(nanoseconds: 400_000_000)  // let the app settle
            if let before = menuStateBefore,
                let outcome = MenuOutcomeVerifier.compare(
                    before: before,
                    appName: route.appName,
                    path: route.payload.split(separator: "\u{1}").map(String.init))
            {
                status = outcome.verified ? .verified : .unverified
                verificationEvidence = outcome.message
            }
            verification = ContextResolver
                .resolve(scope: routeScope, appName: route.appName)
                .promptBlock()
            if let verification {
                ChatConsoleLog.shared.append(
                    .note,
                    title: "\(route.appName) state afterwards",
                    output: verification,
                    success: true,
                    scope: scope)
            }
            if let verificationEvidence {
                ChatConsoleLog.shared.append(
                    .note,
                    title: "verification · \(status.chipLabel)",
                    output: verificationEvidence,
                    success: status.claimsSuccess,
                    scope: scope)
            }
        }

        // What the model may assert. It used to be told "It succeeded" on every route that
        // ran, including the ones nothing had checked.
        let outcomeSentence: String
        switch status {
        case .verified: outcomeSentence = "It succeeded and was verified."
        case .notApplicable: outcomeSentence = "The executor reported success; nothing independent checked it."
        case .unverified: outcomeSentence = "It ran, but the check could not confirm it took effect — say so."
        case .contradicted: outcomeSentence = "The check showed it did not take effect — say so."
        }

        let phrased: String
        if !result.success {
            // Say what happened rather than handing the model an empty result to narrate.
            // A denied command answered as "the current page information is unavailable"
            // told the user nothing about the denial that caused it.
            let reason = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
            phrased = reason.isEmpty
                ? "`\(route.title)` didn't run."
                : "`\(route.title)` didn't run — \(reason)"
        } else if actionOutputIsTrivial(result.output) {
            // An executor that says "Done" and nothing else has reported an outcome, not
            // produced a result. Handing that to the model as output to answer from is what
            // made "open journal about window" — a request the app had just carried out —
            // come back as "the About Journal window is not currently readable, so I cannot
            // provide details about it": an apology for a task nobody set.
            phrased = status.claimsSuccess || status == .notApplicable
                ? "Done — \(route.title)."
                : "Ran \(route.title), but I couldn't confirm it took effect."
                    + (verificationEvidence.map { " \($0)" } ?? "")
        } else if !route.isReadOnly {
            // An action is reported, not answered. The user asked for something to happen;
            // the answer says whether it did, and the state block stays in the Console
            // where it is evidence rather than subject matter.
            phrased =
                (try? await AIProviderService.shared.sendMessage(
                    "Ran `\(route.title)` for \(route.appName). \(outcomeSentence) Output:\n\n"
                        + result.output.prefix(2_000)
                        + "\n\nTell the user in one sentence what was done. Do not answer "
                        + "any other question, do not describe the app's state, and do not "
                        + "apologise for information you were not asked for.",
                    context: .appFocused(name: route.appName, bundleID: route.bundleId),
                    provider: provider,
                    apiKey: rawKey.isEmpty ? nil : rawKey,
                    conversationHistory: history,
                    surfaceScoped: true))
                .map(ChatAnswerSanitizer.clean)
                ?? "Done — \(route.title)."
        } else {
            // The model turns output into an answer; it never invents one, because the
            // output is right there beside it in the Console.
            phrased =
                (try? await AIProviderService.shared.sendMessage(
                    "Ran `\(route.title)` for \(route.appName). Output:\n\n"
                        + result.output.prefix(6_000)
                        + (verification.map { "\n\nState afterwards:\n\($0)" } ?? "")
                        + "\n\nAnswer the user's question from this output only: \(query)",
                    context: .appFocused(name: route.appName, bundleID: route.bundleId),
                    provider: provider,
                    apiKey: rawKey.isEmpty ? nil : rawKey,
                    conversationHistory: history,
                    surfaceScoped: true))
                .map(ChatAnswerSanitizer.clean)
                ?? result.output
        }
        var receipts = [DoraXActionReceipt(
            command: "route(\(route.kind.rawValue), \(route.title))",
            output: result.output.isEmpty
                ? (result.success ? "Executor confirmed success." : "Executor returned no output.")
                : result.output,
            success: result.success)]
        // A verification receipt is only written when something was verified. The app-state
        // block is evidence the model reads, not proof the action landed, and recording it
        // as a passing verification is how a silent failure drew a green tick.
        if let verificationEvidence {
            receipts.append(DoraXActionReceipt(
                command: "verify_menu_outcome(\(route.appName))",
                output: verificationEvidence,
                success: status.claimsSuccess,
                isVerification: true))
        }
        if let verification {
            receipts.append(DoraXActionReceipt(
                command: "read_app_state(\(route.appName))",
                output: verification,
                success: true))
        }
        return Answer(
            text: phrased,
            toolChips: route.isReadOnly || status == .notApplicable
                ? ["\(route.kind.rawValue) · \(route.title)"]
                : ["\(route.kind.rawValue) · \(route.title)", status.chipLabel],
            consoleOutput: result.output.isEmpty ? nil : result.output,
            evidenceReceipts: receipts)
    }

    /// Adds a plural form of every word alongside the original, so a query written in the
    /// singular still matches an app whose name is plural.
    private static func pluralised(_ query: String) -> String {
        query
            .split(separator: " ")
            .map { word -> String in
                let text = String(word)
                guard text.count > 3, !text.hasSuffix("s") else { return text }
                return "\(text) \(text)s"
            }
            .joined(separator: " ")
    }

    /// The app named in a question that this chat has no access to, if any.
    ///
    /// Selection is the access boundary: General Chat reads only the apps the user chose,
    /// so a question about an app outside that set is answered by asking, not by reaching
    /// into it. The dock has always done this; the window went straight to the model, which
    /// then tried tools it had no grant for and reported a failure the user could not act on.
    static func appNeedingAccess(
        query: String, scope: GeneralChatScope, attachedAppNames: [String]
    ) -> EnableAppRequest? {
        guard scope.isGeneralChat else { return nil }
        // "do i have any reminder today" names Reminders, but the resolver matches whole
        // words against app names, so the singular missed and the question fell through to
        // a model with no access and no explanation. Try the plural too.
        let named =
            GeneralAIActionResolver.shared.namedInstalledApp(in: query)
            ?? GeneralAIActionResolver.shared.namedInstalledApp(in: pluralised(query))
        guard let named else { return nil }
        // Match on the name first. Resolving an attached name to a bundle id depends on
        // the app running or on a warmed installed-apps cache, and when neither held, an
        // app the user had just enabled looked unattached — so the gate asked again, and
        // again, with the Enable button doing nothing each time.
        if attachedAppNames.contains(where: {
            $0.caseInsensitiveCompare(named.name) == .orderedSame
        }) { return nil }

        let attachedBundleIDs = Set(
            attachedAppNames.compactMap { name -> String? in
                NSWorkspace.shared.runningApplications
                    .first { $0.localizedName == name }?.bundleIdentifier
                    ?? InstalledApplicationsCatalog.cachedInstalledApps()
                    .first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.bundleId
            }.map { $0.lowercased() })
        guard !attachedBundleIDs.contains(named.bundleId.lowercased()) else { return nil }
        return EnableAppRequest(name: named.name, bundleId: named.bundleId, query: query)
    }

    /// Runs `operation` on a detached task and gives up on it after `seconds`.
    ///
    /// Detached and nonisolated on purpose. When this helper was a method on a @MainActor
    /// type, both the work and the timer inherited that isolation, so the timer could not
    /// be scheduled while the work held the actor — the cap never fired, and a stalled MCP
    /// handshake took the whole turn down with it.
    nonisolated static func withTimeout<T: Sendable>(
        seconds: Double,
        fallback: T,
        label: String = "prompt section",
        operation: @escaping @Sendable () async -> T
    ) async -> T {
        // The group version of this abandoned nothing: see AsyncTimeout for why a turn
        // could sit past its own deadline.
        await AsyncTimeout.run(
            seconds: seconds, fallback: fallback, label: label, operation: operation)
    }

    // MARK: - Shared context blocks

    /// Image files a provider can be shown directly. Capped: a folder of forty photos sent
    /// as vision blocks is a very expensive way to answer one question, and the first few
    /// are what "these" almost always means.
    static func selectedImages(in selection: [URL], limit: Int = 6) -> [URL] {
        let imageTypes: Set<String> = [
            "png", "jpg", "jpeg", "heic", "heif", "gif", "tiff", "bmp", "webp",
        ]
        return selection
            .filter { imageTypes.contains($0.pathExtension.lowercased()) }
            .prefix(limit)
            .map { $0 }
    }

    /// What the user is pointing at, named in full.
    ///
    /// A count alone ("3 files selected") leaves the model to ask which — and the whole
    /// value of a selection is that the user has already said. Capped, because a selection
    /// of two hundred files is a scope, not a list.
    static func selectionBlock(_ selection: [URL]) -> String? {
        guard !selection.isEmpty else { return nil }
        let shown = selection.prefix(30)
        var lines = [
            "SELECTED IN FINDER RIGHT NOW (\(selection.count) item\(selection.count == 1 ? "" : "s"))"
        ]
        lines += shown.map { "- \($0.path)" }
        if selection.count > shown.count {
            lines.append("…and \(selection.count - shown.count) more.")
        }
        lines.append(
            "\"these\", \"them\", \"the selected files\" and \"this one\" mean exactly these "
                + "paths. Act on them rather than searching for something similar.")
        return lines.joined(separator: "\n")
    }

    /// Today's date and time, in the model's prompt. A chat that cannot resolve "today"
    /// answers calendar and reminder questions against nothing.
    static func dateTimeBlock() -> String {
        let now = Date()
        let formatter = DateFormatter()
        formatter.dateStyle = .full
        formatter.timeStyle = .medium
        let localDateTime = formatter.string(from: now)
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.timeZone = .current
        let isoDateTime = isoFormatter.string(from: now)

        return """
            CURRENT DATE & TIME:
            - Local: \(localDateTime)
            - ISO 8601: \(isoDateTime)
            - Time Zone: \(TimeZone.current.identifier)
            Use this exact date/time for relative time references like today, yesterday, tomorrow, recent, and this week.
            """
    }

    /// What the app has open right now, read from its own accessibility element rather
    /// than from whichever app the last global snapshot belongs to.
    nonisolated static func liveWindowFacts(bundleID: String) -> String? {
        guard let running = NSRunningApplication
            .runningApplications(withBundleIdentifier: bundleID).first,
            running.processIdentifier > 0
        else { return nil }

        let appElement = AXUIElementCreateApplication(running.processIdentifier)
        AXUIElementSetMessagingTimeout(appElement, 1.0)

        func string(_ element: AXUIElement, _ attribute: String) -> String? {
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success
            else { return nil }
            if let text = value as? String {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : trimmed
            }
            return nil
        }

        var lines: [String] = []

        var focused: CFTypeRef?
        if AXUIElementCopyAttributeValue(
            appElement, kAXFocusedWindowAttribute as CFString, &focused) == .success,
            let window = focused as! AXUIElement?
        {
            if let title = string(window, kAXTitleAttribute as String) {
                lines.append("Front window title: \(title)")
            }
            if let document = string(window, kAXDocumentAttribute as String) {
                lines.append("Open document: \(URL(string: document)?.path ?? document)")
            }
        }

        var windowsValue: CFTypeRef?
        if AXUIElementCopyAttributeValue(
            appElement, kAXWindowsAttribute as CFString, &windowsValue) == .success,
            let windows = windowsValue as? [AXUIElement], !windows.isEmpty
        {
            let titles = windows.prefix(8).compactMap { string($0, kAXTitleAttribute as String) }
            if titles.count > 1 {
                lines.append("Open windows (\(windows.count)): " + titles.joined(separator: ", "))
            }
        }

        guard !lines.isEmpty else { return nil }
        return "Live window state (read just now, factual):\n" + lines.joined(separator: "\n")
    }

    /// The page a browser scope is currently on. "What page am I on?" is answerable from
    /// the browser itself; without this the window had the app's capability list and no
    /// idea what was open in it, so it offered to reload a page it could not name.
    static func browserPageFacts(bundleID: String) -> String? {
        guard ScopedAppPromptBuilder.isBrowserBundle(bundleID) else { return nil }
        let detector = ContextDetector.shared
        switch bundleID {
        case "com.apple.Safari":
            if let page = detector.getSafariPageContextForAI() {
                return "Current page (read just now, factual):\n\(page)"
            }
            if let page = detector.getSafariContext() {
                return "Current page (read just now, factual):\nTitle: \(page.title)\nURL: \(page.url)"
            }
        case "com.google.Chrome":
            if let page = detector.getChromeContext() {
                return "Current page (read just now, factual):\nTitle: \(page.title)\nURL: \(page.url)"
            }
        case "company.thebrowser.Browser":
            if let page = detector.getArcContext() {
                return "Current page (read just now, factual):\nTitle: \(page.title)\nURL: \(page.url)"
            }
        default:
            break
        }
        return nil
    }

    /// Recent history for a browser scope, and an honest account of where it came from.
    ///
    /// The library reads Safari's History.db directly, which needs Full Disk Access. Without
    /// it the read returns nothing and the answer became "no visits in that time range" —
    /// which is false, and unfixable by the user because nothing said what was wrong. The
    /// app's own History menu is already cached, so it stands in when the database cannot
    /// be read.
    static func browserHistoryFacts(bundleID: String, appName: String) -> String? {
        guard ScopedAppPromptBuilder.isBrowserBundle(bundleID) else { return nil }

        let menuItems = AppMenuCapabilityCache.shared.menuItems(
            bundleIdentifier: bundleID, appName: appName, query: "History", maxResults: 40)
        let historyEntries = menuItems
            .filter { $0.isLeaf && $0.path.first == "History" }
            .map { $0.path.last ?? "" }
            .filter { title in
                !title.isEmpty
                    && !["Show Personal History", "Back", "Forward", "Home", "Clear History…",
                         "Reopen Last Closed Window", "Reopen All Windows from Last Session",
                         "Return to Search Results"].contains(title)
            }

        var lines: [String] = []
        if !historyEntries.isEmpty {
            let age = AppMenuCapabilityCache.shared.snapshotAge(bundleIdentifier: bundleID)
            let readWhen = age.map { "read \(Int($0 / 60)) min ago" } ?? "from the menu cache"
            lines.append("## \(appName) — History menu (\(readWhen), factual)")
            lines.append(
                "These are the entries in \(appName)'s own History menu. They are real visits, "
                + "in most-recent-first order, though the menu carries no timestamps.")
            lines += historyEntries.prefix(25).map { "- \($0)" }
        }

        // Say when the fuller source is unavailable, so an incomplete answer is not
        // mistaken for an empty history.
        if bundleID == "com.apple.Safari" {
            let dbPath = NSHomeDirectory() + "/Library/Safari/History.db"
            if !FileManager.default.isReadableFile(atPath: dbPath) {
                lines.append(
                    "Safari's full history database is not readable — DoraX needs Full Disk "
                    + "Access in System Settings → Privacy & Security to read dated history. "
                    + "Say that plainly if the user asks about a date range; do not report "
                    + "an empty history.")
            }
        }

        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    // MARK: - Request

    /// Asks the provider about an app or CLI scope with the grounding above, and lets it
    /// run what it finds. Commands still go through TerminalCommandExecutor, so approval
    /// behaves exactly as it does in the dock — a different window is not a reason to
    /// lower a gate.
    static func send(
        scope: GeneralChatScope,
        appName: String,
        query: String,
        history: [ChatMessage],
        attachments: [URL] = [],
        extraAppNames: [String] = [],
        /// What was highlighted in Finder when the question was asked, already narrowed to
        /// this scope by the caller. Empty means the scope itself is the subject.
        finderSelection: [URL] = [],
        /// A skill the user chose for this request. Present means the route decision is
        /// already made, so the picker is skipped rather than asked again.
        skillOverride: String? = nil,
        /// Called while the provider writes, when it supports streaming.
        ///
        /// Text arriving before a `toolCallStarted` is narration the model wrote on its way
        /// to using a tool; the answer that replaces it comes from the round *after* the
        /// tools ran. A surface showing these should clear what it has drawn when a tool
        /// call starts, or the finished answer will appear underneath a sentence that was
        /// only ever the model thinking out loud.
        onStream: (@Sendable (AIProviderStreamEvent) -> Void)? = nil,
        /// What the turn is doing right now, in words a person can read: "Running mole
        /// scan…", "Verifying the result…". A surface with a status line shows these; one
        /// without passes nil and loses nothing.
        onStatus: ((String) -> Void)? = nil
    ) async throws -> Answer {
        let settings = AppSettings.shared
        let provider = settings.selectedAIProvider
        let rawKey = provider.requiresAPIKey ? settings.getAPIKey(for: provider) : ""
        let apiKey: String? = rawKey.isEmpty ? nil : rawKey

        log.notice("send start scope=\(scope.storageKey, privacy: .public) provider=\(provider.rawValue, privacy: .public)")

        // Ask before reaching. This also runs before any tool or capability work, so a
        // question about an app outside the chat's scope can never stall on a tool it was
        // never allowed to use.
        if let request = appNeedingAccess(
            query: query, scope: scope, attachedAppNames: extraAppNames)
        {
            log.notice("stage: access gate — \(request.bundleId, privacy: .public)")
            return Answer(
                text:
                    "**\(request.name)** isn't in this chat's scope yet. General Chat only reads "
                    + "the apps you choose, so you stay in control — enable it below to let me "
                    + "answer about \(request.name).",
                toolChips: [],
                enableApp: request)
        }
        // "test it", "save that as X", "run X" are about the user's own project rather than
        // about an app's capabilities, so they are recognised before route resolution —
        // there is no menu item or MCP tool that means "build what I'm working on".
        if let intent = WorkbenchIntent.intent(in: query) {
            log.notice("stage: workbench intent")
            let outcome = await WorkbenchIntent.handle(intent, scope: scope)
            return Answer(text: outcome.text, toolChips: outcome.chips)
        }
        // A question aimed at Claude Code runs Claude Code. It is the only route here that
        // can read the user's repository — files, branch, CLAUDE.md — so answering it from
        // the chat's own model would answer about code in general, and printing a command
        // for the user to run themselves is not answering at all.
        if ClaudeCodeBridge.shouldHandle(query) {
            log.notice("stage: claude code bridge")
            let result = await ClaudeCodeBridge.shared.ask(
                query: query, scope: scope, attachments: attachments,
                onProgress: { activity in
                    ChatConsoleLog.shared.append(
                        .note, title: "claude code", output: activity, success: true,
                        scope: scope)
                })
            return Answer(
                text: result.text,
                toolChips: result.toolsRan.map { "\($0) via Claude Code" },
                consoleOutput: result.transcript.isEmpty ? nil : result.transcript)
        }

        // A request that spans apps gets a plan rather than a route. Candidates are
        // resolved across every app this chat may touch, so the ordering the model does is
        // ordering of real capabilities — not an improvisation it then narrates.
        if ChatRouteResolver.isActionRequest(query) {
            var crossAppRoutes: [ChatRoute] = []
            var scopeApps: [(String, String)] = []
            if case .app(let bundleId) = scope { scopeApps.append((bundleId, appName)) }
            // A folder thread's actions are Finder's — the same mapping its capabilities
            // and routes already use.
            if scope.folderURL != nil {
                scopeApps.append((ChatAppDirectory.finderBundleID, "Finder"))
            }
            for name in extraAppNames {
                let bundleId =
                    NSWorkspace.shared.runningApplications
                    .first { $0.localizedName == name }?.bundleIdentifier
                    ?? InstalledApplicationsCatalog.cachedInstalledApps()
                    .first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.bundleId
                if let bundleId { scopeApps.append((bundleId, name)) }
            }

            // Planning used to require two or more apps in the thread, which meant "find
            // the newest export and open it" — two steps in one app — was answered as a
            // single route and quietly did half the job. Several steps is a property of
            // the request, not of how many apps happen to be attached, and the classifier
            // already decides that. Two apps still qualifies on its own, so a combined
            // chat behaves exactly as before.
            let intent = AIRequestClassifier.shared.classify(
                query: query,
                hasExplicitContext: !attachments.isEmpty || !finderSelection.isEmpty)
            let mayNeedPlan = intent.requiresPlanning || scopeApps.count > 1

            if !scopeApps.isEmpty, mayNeedPlan {
                for (bundleId, name) in scopeApps {
                    crossAppRoutes += await ChatRouteResolver.routes(
                        for: query, bundleId: bundleId, appName: name)
                }
                if crossAppRoutes.count > 1,
                    let plan = await ChatPlanRunner.plan(
                        query: query, routes: crossAppRoutes,
                        provider: provider, apiKey: apiKey)
                {
                    log.notice("stage: plan of \(plan.steps.count, privacy: .public) steps")
                    // The thread's own apps, and only those. Routes were resolved from this
                    // set, so a step outside it means the plan drifted from what was
                    // offered — checked per step rather than trusted once.
                    let results = await ChatPlanRunner.run(
                        plan, query: query,
                        authorizedBundleIds: Set(scopeApps.map { $0.0.lowercased() }))
                    let receipt = ChatPlanRunner.receipt(plan, results: results)
                    let allSucceeded = ChatPlanRunner.fullyConfirmed(plan, results: results)
                    // Only a plan that ran end to end is offerable as a recipe. Keeping a
                    // partial one would let "save that as X" preserve a sequence that has
                    // never worked, under a name implying it has.
                    if allSucceeded {
                        WorkbenchIntent.rememberSuccessfulPlan(plan, query: query)
                    }
                    // "Nothing after the failed step was attempted" was appended whenever
                    // the plan was not fully confirmed — including when every step ran and
                    // none failed, and one merely changed nothing observable. It reported
                    // abandoned work that did not exist. The receipt already names what was
                    // skipped, and only when something was.
                    let stoppedEarly = results.count < plan.steps.count
                    return Answer(
                        text: (allSucceeded ? "\(plan.summary)\n\n" : "")
                            + receipt
                            + (stoppedEarly
                                ? "\n\nNothing after that step was attempted."
                                : ""),
                        toolChips: results.map { "\($0.step.route.kind.rawValue) · \($0.step.route.title)" })
                }
            }
        }

        // Which routes could actually carry this out, resolved before the model is asked
        // anything. Asking the user which to use is only worth it when they differ in
        // consequence — that check is in the resolver.
        // A folder thread routes through Finder: "new folder here", "open this" are Finder
        // work aimed at one directory, and a thread that can list files but not act on
        // them is half a file chat.
        let routingBundleId: String? = {
            switch scope {
            case .app(let bundleId): return bundleId
            case .folder: return ChatAppDirectory.finderBundleID
            default: return nil
            }
        }()
        if let bundleId = routingBundleId, skillOverride == nil {
            // The routes belong to Finder even when the thread is named after a folder —
            // "Invoices can do that more than one way" names the wrong thing.
            let routingAppName =
                bundleId == ChatAppDirectory.finderBundleID && scope.folderURL != nil
                ? "Finder" : appName
            let routes = await ChatRouteResolver.routes(
                for: query, bundleId: bundleId, appName: routingAppName)
            if ChatRouteResolver.shouldAsk(routes: routes, bundleId: bundleId, query: query) {
                rememberPendingRoutes(routes, scope: scope)
                log.notice("stage: asking which route (\(routes.count, privacy: .public))")
                return Answer(
                    text:
                        "\(routingAppName) can do that more than one way. Which should I use?",
                    toolChips: [],
                    routeChoices: routes.map(\.asActionChoice))
            }
            // Already answered for this app and this kind of request: take that route
            // without asking again.
            if let preferred = ChatRoutePreferenceStore.preferredKind(
                bundleId: bundleId, query: query),
                let route = routes.first(where: { $0.kind == preferred })
            {
                return await execute(
                    route: route, query: query, history: history, scope: scope,
                    appName: appName, attachments: attachments,
                    extraAppNames: extraAppNames, finderSelection: finderSelection)
            }
            // Deterministic before probabilistic: a read the app can answer itself beats
            // sending the question to a model with a catalogue and hoping it picks well.
            if let route = ChatRouteResolver.unattendedRoute(routes) {
                log.notice("stage: unattended route \(route.kind.rawValue, privacy: .public)")
                return await execute(
                    route: route, query: query, history: history, scope: scope,
                    appName: appName, attachments: attachments,
                    extraAppNames: extraAppNames, finderSelection: finderSelection)
            }
        }

        if case .cli(let command) = scope {
            let routes = ChatRouteResolver.cliRoutes(for: query, command: command)
            if ChatRouteResolver.shouldAsk(
                routes: routes, bundleId: "cli://\(command)", query: query)
            {
                rememberPendingRoutes(routes, scope: scope)
                log.notice("stage: asking which invocation (\(routes.count, privacy: .public))")
                return Answer(
                    text: "There's more than one \(command) command for that. Which should I run?",
                    toolChips: [],
                    routeChoices: routes.map(\.asActionChoice))
            }
            // A single read-only invocation is just the answer: run it and report.
            if routes.count == 1, let route = routes.first, route.isReadOnly {
                return await execute(
                    route: route, query: query, history: history, scope: scope,
                    appName: appName, attachments: attachments,
                    extraAppNames: extraAppNames, finderSelection: finderSelection)
            }
        }

        // Which source this question should be answered from — live state, the app's own
        // documentation, what DoraX has durably learned, or the conversation itself. The
        // dock has decided this per question since it was written; the window asked every
        // question the same way and let the model pick, which is how a "what changed just
        // now" question got answered from a note written last week.
        let sourceDecision = AgentSourceAuthority.decide(query: query)
        // Assembled into named slots rather than a flat list, so reading order and the
        // budget for a small-context model are one rule shared with the dock instead of two
        // that drifted. This surface had no budget at all: on Apple's on-device model the
        // full inventory overran the window and the reply never arrived.
        var prompt = ScopedPromptAssembler()
        prompt.set(.sourceRule, [
            sourceDecision.promptRule, dateTimeBlock(), UntrustedContent.rule,
        ].joined(separator: "\n\n"))
        var context: UserContext = .none
        /// The machine as it was before this turn ran anything, kept so a tool's claim can
        /// be checked against what actually changed.
        var contextBefore: ResolvedContext?

        switch scope {
        case .app(let bundleId):
            // A Finder thread with something highlighted is a question about those files.
            // Handing the tools the selection rather than the app is what lets "rename
            // these" mean the six files on screen instead of whatever folder is frontmost.
            context =
                finderSelection.isEmpty
                ? .appFocused(name: appName, bundleID: bundleId)
                : .filesSelected(finderSelection)
            if let selectionBlock = selectionBlock(finderSelection) {
                prompt.set(.selection, selectionBlock)
            }
            prompt.set(
                .identity,
                """
                This conversation is scoped to \(appName) (\(bundleId)). Answer about that app, \
                using the verified context and capabilities below. If a detail is not in the \
                supplied context, say DoraX could not read it — never answer from generic \
                product knowledge and never claim you lack access to an app listed here.
                """)
            // Resolved once, with its gaps recorded: an answer that could not know
            // something now says which slot was empty instead of inventing a value.
            let resolved = ContextResolver.resolve(scope: scope, appName: appName)
            contextBefore = resolved
            let block = resolved.promptBlock()
            prompt.set(.resolvedContext, block)
            log.notice("context \(resolved.summary, privacy: .public)")
            // What the app is doing right now — its project, branch, changes, running
            // agents — and what its vendor documents about it. Both were the dock's alone,
            // so the window could describe an app's tool inventory and nothing about the
            // work in progress inside it.
            log.notice("stage: workspace + reference")
            let workspace = await withTimeout(seconds: 6, fallback: "", label: "workspace") {
                await ScopedGroundingBlocks.workspace(
                    bundleId: bundleId, appName: appName,
                    forceRefresh: sourceDecision.requiresFreshRead)
            }
            prompt.set(.workspace, workspace)
            let reference = await withTimeout(seconds: 8, fallback: "", label: "reference") {
                await ScopedGroundingBlocks.reference(
                    bundleId: bundleId, appName: appName, query: query)
            }
            prompt.set(.reference, reference)
            // The page a browser scope is actually on. Without it a browser thread had the
            // app's capability list and no idea what was open in it, so it offered to reload
            // a page it could not name.
            let page = ScopedGroundingBlocks.browserPage(bundleId: bundleId, query: query)
            if !page.isEmpty {
                prompt.set(.browserPage, UntrustedContent.fenced(page, from: "the current web page"))
            }
            if let history = browserHistoryFacts(bundleID: bundleId, appName: appName) {
                prompt.append(
                    .browserPage, UntrustedContent.fenced(history, from: "browser history"))
            }
            // The same block the dock builds for its scoped chat — adapter actions, menu
            // commands, MCP, API, Shortcuts, skills, CLI, and the tool-choice order.
            let capabilities = ScopedAppPromptBuilder.appIdentityBlock(
                bundleId: bundleId, appName: appName, query: query)
            prompt.append(.identity, capabilities)
            // The app's enabled skills, in full. The identity block only counts them, and
            // a Calendar chat that is told "2 skills active" without their instructions
            // behaves differently from the dock's, which reads them.
            // A chosen skill replaces the full set: the user said which workflow applies,
            // and stacking the others behind it would dilute the instruction they picked.
            let skills = skillOverride ?? SkillStore.shared.instructionsBlock(for: bundleId)
            prompt.set(.skills, skills)
            // The app's live MCP tools, in the prose protocol the loop understands, so a
            // Reminders thread can read reminders instead of describing how to.
            log.notice("stage: mcp block")
            let mcpBlock = await withTimeout(seconds: 6, fallback: "") {
                await MCPRuntime.shared.toolPromptBlock(forBundleId: bundleId)
            }
            prompt.set(.mcp, mcpBlock)

        case .folder(let path):
            let url = URL(fileURLWithPath: path)
            // The folder arrives as a selection, which is what the file capabilities
            // already resolve "here" from — so every finder.* tool defaults to this
            // directory instead of the user's Desktop, with no per-capability wiring and
            // no new argument for the model to remember to pass.
            //
            // Highlighted files inside it are narrower and win: "are these duplicates?"
            // with six files selected is a question about those six, and answering it
            // about the whole folder answers something nobody asked.
            context = .filesSelected(finderSelection.isEmpty ? [url] : finderSelection)
            prompt.set(
                .identity,
                """
                This conversation is scoped to the folder \(url.lastPathComponent) \
                (\(path)). Answer about the files in it, using the listing and the file \
                tools below. If something is not in the listing, use a tool to look rather \
                than guessing — and if a tool cannot read it, say so.
                """)
            prompt.set(.folder, FolderScopeDigest.promptBlock(for: url))
            // File work goes through the file tools, never the shell.
            //
            // Asked to tidy a folder, the model wrote `mkdir a b c` and then two `mv`s
            // chained with &&. Writes are not on the unattended allowlist and && is
            // rejected outright, so nothing was created — and the mv commands then ran
            // against destinations that did not exist, reporting "is not a directory"
            // while the answer said the folders had been made. finder.organize does that
            // whole request in one call, inside this folder, with the file list on the
            // approval card and a read-back afterwards.
            prompt.append(
                .identity,
                """
                FILE WORK IN THIS FOLDER
                Use the finder.* capabilities for anything that creates, moves, renames, \
                copies or deletes files — finder.organize for tidying by kind or month, \
                finder.newFolder, finder.moveFiles, finder.renameFiles, finder.trash. They \
                are confined to this folder, ask the user before changing anything, and are \
                checked afterwards.

                Do NOT use run_command for file changes. mkdir, mv, cp and rm are refused \
                by the command gate and chained commands (&&) are rejected, so a shell \
                attempt does nothing and reports failure you must not mistake for success. \
                If a step fails, say so and stop rather than continuing as though it worked.
                """)
            if let selectionBlock = selectionBlock(finderSelection) {
                prompt.set(.selection, selectionBlock)
            }
            // Finder's identity block, because the file tools are registered against
            // Finder's bundle id: a folder thread is the same toolset aimed at one place.
            let fileTools = ScopedAppPromptBuilder.appIdentityBlock(
                bundleId: ChatAppDirectory.finderBundleID, appName: "Finder", query: query)
            prompt.append(.identity, fileTools)

        case .cli(let command):
            let resolved = ContextResolver.resolve(scope: scope, appName: command)
            let resolvedBlock = resolved.promptBlock()
            prompt.set(.resolvedContext, resolvedBlock)
            log.notice("context \(resolved.summary, privacy: .public)")
            let tool = ScopedAppPromptBuilder.appIdentityBlock(
                bundleId: "cli://\(command)", appName: command, query: query)
            prompt.set(.cli, tool)

        case .general, .thread:
            // Unscoped chat is not ungrounded chat: it still answers about the user's
            // machine, so it gets the same capability catalogue the dock's General Chat
            // builds. Without it the model was handed a CLI protocol by the provider's
            // package matcher and nothing that could run it.
            prompt.set(
                .identity,
                """
                You are DoraX's assistant on the user's Mac. Use the capabilities listed \
                below to answer from real data rather than from memory. Never print a tool \
                call as text — call it, then answer in plain language.
                """)
        }

        // A combined chat is scoped to several apps; each one is grounded the same way.
        for name in extraAppNames {
            let bundleId =
                NSWorkspace.shared.runningApplications
                .first { $0.localizedName == name }?.bundleIdentifier
                ?? InstalledApplicationsCatalog.cachedInstalledApps()
                .first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.bundleId
            guard let bundleId else { continue }
            let block = ScopedAppPromptBuilder.appIdentityBlock(
                bundleId: bundleId, appName: name, query: query, compact: true)
            prompt.append(.identity, block)
            prompt.append(.resolvedContext, liveWindowFacts(bundleID: bundleId))
        }

        // Real Calendar / Reminders / Notes / Contacts data when the question is about
        // them — the dock's "Live app data" read. Without it the model has the app's
        // capability list and none of its contents, which is why the window could only
        // explain how to look rather than answer.
        log.notice("stage: live apple data")
        let liveAppleData = await withTimeout(seconds: 8, fallback: "") {
            await AppleLiveDataContext.appleAppsAndWeatherContext(for: query)
        }
        prompt.set(.liveAppData, liveAppleData)

        // Registered capabilities, MCP tools and skills — the same block General Chat uses.
        // A CLI thread is one executable. The cross-app catalogue is noise there — and
        // building it means walking every linked MCP server, which is where these turns
        // were dying: a scope that needs none of it was paying for all of it.
        let needsCrossAppCatalogue: Bool = {
            if case .cli = scope { return false }
            return true
        }()

        // The catalogue is built for the conversation that asked for it. Passing `.general`
        // from every thread handed a Code chat the cross-app inventory — Mail, Messages,
        // Photos — which is the whole catalogue this surface exists to narrow.
        let hubScope: AIConversationScope = {
            if case .app(let bundleId) = scope {
                return .contextDock(bundleID: bundleId, appName: appName)
            }
            if scope.folderURL != nil {
                return .contextDock(bundleID: ChatAppDirectory.finderBundleID, appName: "Finder")
            }
            return .general
        }()
        log.notice("stage: capability hub (\(needsCrossAppCatalogue ? "yes" : "skipped", privacy: .public))")
        let hubBlock = !needsCrossAppCatalogue ? "" : await withTimeout(seconds: 8, fallback: "") {
            await GeneralChatCapabilityHub.shared.capabilityPromptBlock(
                compact: provider == .onDevice,
                query: query,
                scope: hubScope,
                characterBudget: AIContextBudget.characterBudget(for: provider))
        }
        prompt.set(.capabilities, hubBlock)

        // What DoraX has durably learned — saved notes, prior findings, the user's own
        // written knowledge for this app. Withheld when the question is about live state,
        // because remembered facts are exactly what must not stand in for a fresh reading.
        // Identity goes in whether or not the question sounds personal, and whether or not
        // this turn is allowed to lean on remembered facts: knowing who is asking is not
        // evidence about the world, so the rule that withholds memory from live-state
        // questions does not apply to it.
        let profileBlock = MarkdownMemoryStore.shared.profileBlock()
        prompt.append(.memory, profileBlock)

        var memoryChips: [String] = []
        if sourceDecision.allowsMemoryEvidence {
            let memoryBundleID: String? = {
                if case .app(let bundleId) = scope { return bundleId }
                if scope.folderURL != nil { return ChatAppDirectory.finderBundleID }
                return nil
            }()
            let memory = MarkdownMemoryStore.shared.contextBlock(
                query: query, appBundleID: memoryBundleID)
            prompt.set(.memory, memory)
            memoryChips = MarkdownMemoryStore.shared.relevantSourceChips(
                query: query, appBundleID: memoryBundleID)
        }

        let systemPrompt = prompt.assemble(for: provider)
        log.notice("stage: prompt ready (\(systemPrompt.count, privacy: .public) chars)")

        // Apple Intelligence has no function-calling API, so it takes the plain path.
        guard provider.supportsNativeTools else {
            let raw = try await AIProviderService.shared.sendMessage(
                query,
                context: context,
                provider: provider,
                apiKey: apiKey,
                conversationHistory: history,
                additionalContextPrompt: systemPrompt,
                attachments: attachments.map(AIAttachment.inferred(from:)),
                // This surface supplies its own capability catalogue; letting the provider
                // also match a CLI package teaches a [TERMINAL_COMMAND: …] protocol that
                // nothing here executes, and the directive ends up printed at the user.
                surfaceScoped: true
            )
            let text = ChatAnswerSanitizer.clean(raw)
            return Answer(
                text: text,
                toolChips: liveAppleData.isEmpty ? [] : ["Live app data · just now"])
        }

        // Selected images are shown, not just named. "Explain these files" on two JPGs is a
        // question about what they depict, and neither OCR nor a file listing can answer it
        // — the provider has to actually see them. Non-image selections are left alone;
        // they are read on demand by the file tools.
        let visionAttachments = attachments + selectedImages(in: finderSelection)
        log.notice("stage: provider turn")
        // The execution stage is shared with the dock: same executor, same round budget,
        // same checks on what the answer claims. Only the prompt above is this surface's own.
        let outcome = try await ScopedTurnRunner.run(
            query: query,
            systemPrompt: systemPrompt,
            scope: .init(
                chatScope: scope,
                bundleId: routingBundleId ?? "",
                appName: appName,
                cliTool: {
                    if case .cli(let command) = scope { return command }
                    return nil
                }(),
                userContext: context),
            provider: provider,
            apiKey: apiKey,
            history: history,
            imageAttachments: visionAttachments,
            onStream: onStream,
            onStatus: onStatus)
        var text = outcome.text
        var executed = outcome.executed
        log.notice("stage: answer received (\(text.count, privacy: .public) chars, \(executed.count, privacy: .public) commands)")

        // Verification for the tool loop. Anything that was not clearly read-only gets the
        // scope read back and compared: a tool that reports success while nothing on the
        // machine moved is the failure mode worth catching, and it cannot be caught by
        // reading the model's own summary of itself.
        if let contextBefore,
            case .app = scope,
            executed.contains(where: { !MCPToolSafety.isClearlyReadOnly(name: $0.command) })
        {
            try? await Task.sleep(nanoseconds: 400_000_000)
            let after = ContextResolver.resolve(scope: scope, appName: appName)
            let changes = after.changes(since: contextBefore)
            ChatConsoleLog.shared.append(
                .note,
                title: "verified \(appName) state",
                output: changes.isEmpty
                    ? "No observable change." : changes.joined(separator: "\n"),
                success: !changes.isEmpty,
                scope: scope)
            if changes.isEmpty {
                text +=
                    "\n\n_Nothing observable changed in \(appName) — if you expected it to, "
                    + "the action may not have taken effect._"
            }
        }

        // A capability call written as prose. The built-in tools section of the prompt
        // teaches exactly this protocol, so a model following the instruction is not
        // misbehaving — and until now the surface stripped it and answered nothing, which
        // is why "sleep now" ended in a confirmation that led nowhere.
        // Either envelope: the documented `{"capability_call": …}` or the id-as-key form a
        // model writes once it has been handed an id. Both name a capability; recovering
        // only the first left the second stripped and the request dropped.
        let prose: (kind: String, id: String, arguments: [String: Any])? = {
            if let call = ChatAnswerSanitizer.knownCall(in: text) {
                let id =
                    (call.arguments["tool"] as? String)
                    ?? (call.arguments["capability"] as? String)
                    ?? (call.arguments["capability_id"] as? String)
                    ?? ""
                return (call.kind, id, (call.arguments["arguments"] as? [String: Any]) ?? [:])
            }
            if let call = ChatAnswerSanitizer.capabilityIDCall(in: text) {
                return ("capability_id_key", call.id, call.arguments)
            }
            return nil
        }()
        if let call = prose {
            log.notice("recovering prose \(call.kind, privacy: .public)")
            let capabilityID = call.id
            if !capabilityID.isEmpty,
                CapabilityRegistry.shared.capability(id: capabilityID) != nil
            {
                var input: [String: String] = [:]
                for (key, value) in call.arguments { input[key] = String(describing: value) }
                let plan = AIActionPlan(
                    capability: capabilityID, input: input,
                    explanation: "Requested in chat: \(query)")
                let result = try? await AIExecutionEngine.shared.executeWithApproval(
                    plan, context: context, chatScope: scope)
                ChatConsoleLog.shared.append(
                    .tool, title: capabilityID,
                    output: result?.output ?? "(no output)",
                    success: result?.success ?? false, scope: scope)
                if let result, result.success {
                    text = result.output.isEmpty
                        ? "Done — \(capabilityID)."
                        : result.output
                } else {
                    text = "\(capabilityID) didn't run."
                }
            } else {
                // An id that is not registered. Left alone, the JSON was stripped as
                // scaffolding and the user got an empty bubble — the worst outcome, because
                // it looks like the app simply had nothing to say.
                text = capabilityID.isEmpty
                    ? "I tried to run something but didn't name what."
                    : "I tried to run `\(capabilityID)`, which isn't a capability on this Mac."
            }
        }

        // The model sometimes writes its tool call out as text instead of calling it. The
        // dock recovers by running it; the window used to render the JSON. One recovery
        // round only — a model that keeps narrating tool calls is not going to stop.
        if let call = ChatAnswerSanitizer.terminalCall(in: text) {
            log.notice("stage: recovering prose terminal_call")
            let result = await TerminalCommandExecutor.shared.run(
                call.command, purpose: call.purpose, modelRequiresApproval: false)
            if result.success {
                let followUp = try await AIProviderService.shared.sendMessage(
                    "Command output:\n\n\(result.output.prefix(6_000))\n\nAnswer the original "
                        + "question from this output: \(query)",
                    context: context,
                    provider: provider,
                    apiKey: apiKey,
                    conversationHistory: history,
                    surfaceScoped: true
                )
                text = followUp
                executed.append(
                    AIProviderService.ExecutedCommand(
                        command: call.command, output: result.output, success: true))
            }
        }
        // The model sometimes invents a protocol for something we do support — sleep is a
        // registered global command, but it asked for it as {"system_call":…}. Look the
        // intent up in the capability registry and say what exists, rather than dropping a
        // request the user watched it make.
        if let invented = ChatAnswerSanitizer.inventedCall(in: text) {
            log.notice("invented call: \(invented.name, privacy: .public)")
            let words = invented.body.lowercased()
                .split { !$0.isLetter }.map(String.init).filter { $0.count > 2 }
            let match = CapabilityRegistry.shared.all.first { capability in
                let haystack = (capability.id + " " + capability.title).lowercased()
                return words.contains { haystack.contains($0) }
            }
            let cleaned = ChatAnswerSanitizer.clean(text)
            if let match {
                let prefix: String = cleaned.isEmpty ? "" : cleaned + "\n\n"
                let advice: String =
                    "I tried to call something that doesn't exist. The real capability is "
                    + "`\(match.id)` — say the word and I'll run it (it asks for approval "
                    + "first)."
                text = prefix + advice
            } else if cleaned.isEmpty {
                text =
                    "I tried to call `\(invented.name)`, which isn't something DoraX exposes, "
                    + "and I couldn't find a registered capability for it."
            } else {
                text = cleaned
            }
        }

        text = ChatAnswerSanitizer.clean(text)

        // The model sometimes writes its tool call out as text instead of calling it, and
        // a bare JSON object is a call that never ran. The surface refuses to show one as
        // an answer — correctly — and until now that was the end of the request here, while
        // the dock recovered the same failure by resolving the words deterministically.
        //
        // Routes are the deterministic path in this surface. If one exists for what was
        // asked, run it; the request is carried out rather than reported undeliverable.
        if ChatAnswerSanitizer.isProtocolOnly(text), case .app(let bundleId) = scope {
            log.notice("protocol-only answer; resolving via routes")
            let recovered = await ChatRouteResolver.routes(
                for: query, bundleId: bundleId, appName: appName)
            if let route = recovered.first {
                let result = await ChatRouteResolver.run(route, query: query)
                ChatConsoleLog.shared.append(
                    .route, title: route.title,
                    output: result.output.isEmpty ? "(no output)" : result.output,
                    success: result.success, scope: scope)
                text = result.success
                    ? "Done — \(route.title)."
                    : "`\(route.title)` didn't run — \(result.output)"
            }
        }

        // Everything the model ran during this turn, on the record with its real output.
        // The chips say a tool ran; the console says what it produced, which is the part
        // a user can check.
        // Tool calls the loop made without going through our executor — capabilities, MCP,
        // registry tools. Shell commands are already on the record, live, from the executor
        // above, so they are not written twice.
        let alreadyLogged = Set(
            ChatConsoleLog.shared.entries(for: scope).map(\.title))
        for command in executed where !alreadyLogged.contains(command.command) {
            ChatConsoleLog.shared.append(
                .tool,
                title: command.command,
                output: command.output,
                success: command.success,
                scope: scope)
        }

        var chips = memoryChips + outcome.mcpToolsRan + executed.map(\.command)
        if !liveAppleData.isEmpty { chips.insert("Live app data · just now", at: 0) }
        return Answer(
            text: text, toolChips: chips,
            subjectiveEvaluation: outcome.subjectiveEvaluation)
    }
}


/// Whether an executor's output is an outcome rather than a result.
///
/// "Done", "OK", an empty string: these say the thing happened. They are not material to
/// answer a question from, and treating them as such invites the model to go looking for
/// something to say — which it finds in whatever state block sits beside them.
private func actionOutputIsTrivial(_ output: String) -> Bool {
    let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    return trimmed.isEmpty
        || ["done", "ok", "okay", "success", "succeeded", "(no output)"].contains(trimmed)
}
