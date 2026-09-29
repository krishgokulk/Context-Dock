// ScopedRoutePolicy.swift
// Context-Dock
//
// Who decides what a chat turn does: the deterministic shortcut, or the model.
//
// In a Finder chat, "find my passport pdf" became "Use Find My · Edit → Copy". The resolver
// matched words against app names and menu titles, the offer path took the best-ranked row,
// and the turn was over before any model had read the sentence. Task 16e patched the word
// lists; this file removes the cause. The shortcut may preempt the model only when the
// user's text IS a command — "copy", "new folder", "empty trash", "dark mode off" — or
// explicitly names one (`run "New Folder"`, `File > New Folder`). Every other sentence goes
// to the model, which gets the scoped app's matching commands as candidates and chooses.
//
// Pure and synchronous on purpose: the Dock and the Corner both call `decide` from
// `offerScopedNativeAppAction`, and `RoutingPhrasebookTests` calls the same function with
// owner sentences. A rule the tests can reach is a rule that cannot drift from the app.

import Foundation

enum ScopedRoutePolicy {

    /// Where a turn goes. The phrasebook's expected values are these.
    enum RouteClass: String, Sendable {
        /// The text is a command: the native action is offered without asking the model.
        case exactCommand
        /// An instruction the matcher only partly overlaps: the model reads it and picks
        /// among the scoped app's commands (handed to it as candidates), or none.
        case model
        /// An exact command in another app the sentence explicitly named: offered with the
        /// cross-app consent prompt.
        case crossAppOffer
        /// A question or a read: no action is considered; the provider answers from reads
        /// and context.
        case none
    }

    struct Decision {
        var routeClass: RouteClass
        /// The action to offer, for `.exactCommand` and `.crossAppOffer`.
        var offer: DoraXActionCandidate?
        /// For `.model`: the scoped app's candidates, best first, to put in front of the
        /// model. Never run from here.
        var modelCandidates: [DoraXActionCandidate] = []
    }

    /// What the scoped offer did with a turn.
    enum Outcome {
        /// An action was offered; the turn is over until the user answers it.
        case offered
        /// Nothing was offered; the model takes the turn. `modelCandidates` is the prompt
        /// block naming the partly-matching commands, or empty.
        case declined(modelCandidates: String)
    }

    // MARK: - Before resolution

    /// Whether an action should be looked for at all. A question is answered, never
    /// offered as an action, and a request to transform the previous answer ("save those
    /// results as Markdown") is not something any menu command does.
    static func considersActions(_ query: String) -> Bool {
        !DerivedArtifactIntent.shouldBypassNativeAppMenu(query)
            && !GeneralAIActionResolver.shared.asksOnly(query)
    }

    // MARK: - After resolution

    /// Decide an app-scoped turn from what the resolver found.
    ///
    /// - Parameters:
    ///   - scopedApp: the app the chat is scoped to.
    ///   - namedApp: another app the sentence explicitly names, if any
    ///     (`GeneralAIActionResolver.namedInstalledApp`).
    ///   - candidates: the resolver's candidates, in its order.
    ///   - aliases: extra titles a candidate answers to — an adapter action's triggers.
    static func decide(
        query: String,
        scopedApp: String,
        namedApp: String?,
        candidates: [DoraXActionCandidate],
        aliases: (DoraXActionCandidate) -> [String] = { _ in [] }
    ) -> Decision {
        guard considersActions(query) else { return Decision(routeClass: .none) }

        // The scoped app wins unless the sentence named another one (Task 16e).
        let inScope = candidates.filter {
            ActionReadiness.mayOfferCrossApp(
                candidateApp: $0.appName, scopedApp: scopedApp, namedApp: namedApp)
        }
        let runnable = inScope.filter {
            isRunnable($0, namedApp: namedApp) && ActionReadiness.isOfferable($0, query: query)
        }
        let appNames = [scopedApp, namedApp ?? ""]
        let exact = runnable.filter {
            ExactCommand.matches(
                query: query, candidate: $0,
                appNames: appNames + [$0.appName ?? ""], aliases: aliases($0))
        }
        guard let best = exact.min(by: outranks) else {
            // Partial overlap is a hint, not a route. The model sees what matched and
            // decides; it may pick one, or answer, or use a different tool entirely.
            let hints = inScope.filter { isRunnable($0, namedApp: namedApp) }
                .sorted(by: outranks)
            return Decision(routeClass: .model, modelCandidates: Array(hints.prefix(6)))
        }
        let target = best.appName ?? ""
        let crossApp = !target.isEmpty && target.caseInsensitiveCompare(scopedApp) != .orderedSame
        return Decision(routeClass: crossApp ? .crossAppOffer : .exactCommand, offer: best)
    }

    /// Routes the scoped offer can run behind its one-tap approval. A plain app launch only
    /// when the user named that app — "open Find My" is explicit; nothing else is.
    static func isRunnable(_ candidate: DoraXActionCandidate, namedApp: String?) -> Bool {
        switch candidate.route {
        case .verifiedMenu, .keyboardShortcut, .mcp, .cli:
            return true
        case .adapter:
            return candidate.capabilityID != nil
        case .appLaunch:
            guard let namedApp, let app = candidate.appName else { return false }
            return app.caseInsensitiveCompare(namedApp) == .orderedSame
        default:
            return false
        }
    }

    /// Preference by ROUTE, not by position in the resolver's list.
    ///
    /// Word overlap once put a menu item called "Add Link…" above notes.append for a sentence
    /// containing "add", so a click on someone's screen outranked the tool written to do
    /// exactly this. The order is the one ChatRouteResolver documents: the app's own tools
    /// first, structured data next, inspectable commands after that, and driving the screen
    /// last — the only one with a visible cost, and the only one that fails when the app is
    /// in the wrong state (`Edit → Add Link…` is disabled unless a note is already open).
    static func preference(_ candidate: DoraXActionCandidate) -> Int {
        switch candidate.route {
        case .adapter: return candidate.capabilityID != nil ? 0 : 1
        case .mcp: return 2
        case .api: return 3
        case .cli: return 4
        case .shortcutRunner: return 5
        case .automation: return 6
        case .verifiedMenu: return 7
        case .keyboardShortcut: return 8
        case .axFallback, .appLaunch: return 9
        }
    }

    private static func outranks(_ left: DoraXActionCandidate, _ right: DoraXActionCandidate) -> Bool {
        let leftRank = preference(left)
        let rightRank = preference(right)
        if leftRank != rightRank { return leftRank < rightRank }
        return left.confidence > right.confidence
    }

    // MARK: - Model candidates

    /// The candidates the model is given for a `.model` turn, written as the tool call that
    /// would run each one. Suggestions only; the model still decides, and anything it runs
    /// goes through the same approval as always.
    static func modelCandidatesBlock(
        _ candidates: [DoraXActionCandidate], scopedApp: String
    ) -> String {
        guard !candidates.isEmpty else { return "" }
        let lines = candidates.map { candidate -> String in
            let app = candidate.appName?.isEmpty == false ? candidate.appName! : scopedApp
            if let path = candidate.menuPath, !path.isEmpty,
                candidate.route == .verifiedMenu || candidate.route == .keyboardShortcut
            {
                let joined = path.joined(separator: " > ")
                return "- \(candidate.title) — run_menu_command(app: \"\(app)\", path: \"\(joined)\")"
            }
            if let capabilityID = candidate.capabilityID {
                return "- \(candidate.title) — run_capability(capability_id: \"\(capabilityID)\")"
            }
            if let actionID = candidate.adapterActionID {
                return "- \(candidate.title) — run_adapter_action(action_id: \"\(actionID)\")"
            }
            return "- \(candidate.title) (\(candidate.routeLabel) in \(app))"
        }
        return """
            ## \(scopedApp) commands that partly match this request
            DoraX matched these against the words of the request. None of them is the request \
            itself, so none was run. Use one only if it does what the user asked; otherwise \
            ignore the list and answer or use your other tools. Anything that acts still asks \
            the user first.

            \(lines.joined(separator: "\n"))
            """
    }

    // MARK: - General Chat

    /// General Chat is model-first already (`AppSettings.agentModelFirstRouting`); the one
    /// deterministic preempt left is an exact adapter action of the single selected app.
    static func generalChatRoute(
        query: String, modelFirst: Bool, selectedAppHasExactAction: Bool
    ) -> RouteClass {
        // Keyword-first mode (the setting off): the resolver sees every turn, as it did.
        if !modelFirst { return .exactCommand }
        // The selected app's own action, named exactly — even when it reads like a question
        // ("What's Playing"), the name is the request.
        if selectedAppHasExactAction { return .exactCommand }
        return considersActions(query) ? .model : .none
    }
}

// MARK: - Exact command

/// Whether a sentence IS a command, rather than a sentence a command's words overlap.
///
/// Equality after normalising, not similarity. Normalising drops what never changes the
/// command — case, punctuation, "…", politeness, "the", "run"/"click", "turn", the app's own
/// name — and compares word sets, so "turn dark mode off" is "Turn Off Dark Mode" and "empty
/// my trash" is "Empty Trash…". A trailing number is allowed as the command's value ("set
/// volume to 30" for "Set Volume"). Nothing else is: "find my passport pdf" shares one word
/// with "Find…" and is not that command.
enum ExactCommand {

    /// Words that never distinguish one command from another.
    static let fillerWords: Set<String> = [
        "please", "now", "thanks", "the", "a", "an", "my", "me", "for", "run", "click",
        "press", "hit", "do", "use", "choose", "trigger", "perform", "turn", "switch",
        "menu", "item", "command", "app", "can", "could", "would", "you",
    ]

    /// Words a value may bring with it: "to 30", "at 50 percent".
    static let valueWords: Set<String> = ["to", "at", "percent", "by"]

    static func matches(
        query: String, candidate: DoraXActionCandidate,
        appNames: [String] = [], aliases: [String] = []
    ) -> Bool {
        var titles = [candidate.title] + aliases
        if let path = candidate.menuPath, !path.isEmpty {
            if let leaf = path.last { titles.append(leaf) }
            titles.append(path.joined(separator: " "))
        }
        return matches(query: query, titles: titles, appNames: appNames)
    }

    static func matches(query: String, titles: [String], appNames: [String] = []) -> Bool {
        let spoken = [query] + quotedPhrases(in: query)
        for text in spoken {
            let words = commandWords(text, appNames: appNames)
            guard !words.isEmpty else { continue }
            for title in titles {
                let titleWords = commandWords(title, appNames: appNames)
                guard !titleWords.isEmpty else { continue }
                if words == titleWords { return true }
                // The command plus its value: every title word present, and what is left
                // is a number and the words that carry one.
                if titleWords.isSubset(of: words) {
                    let extra = words.subtracting(titleWords)
                    let hasNumber = extra.contains { $0.allSatisfy(\.isNumber) }
                    let onlyValue = extra.allSatisfy {
                        $0.allSatisfy(\.isNumber) || valueWords.contains($0)
                    }
                    if hasNumber, onlyValue { return true }
                }
            }
        }
        return false
    }

    /// The words that make up a command, as a set.
    static func commandWords(_ text: String, appNames: [String] = []) -> Set<String> {
        var lowered = " " + text.lowercased() + " "
        for separator in ["…", "...", ">", "→", "▸", "›", "/", "|"] {
            lowered = lowered.replacingOccurrences(of: separator, with: " ")
        }
        var words = lowered
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
        // The app's own name, and the preposition that points at it: "new folder in finder".
        for name in appNames where !name.isEmpty {
            let nameWords = name.lowercased()
                .split { !$0.isLetter && !$0.isNumber }
                .map(String.init)
            words = removing(nameWords, from: words)
        }
        return Set(words.filter { !fillerWords.contains($0) })
    }

    /// Text inside quotes — `run "New Folder"` names the command outright.
    static func quotedPhrases(in text: String) -> [String] {
        let pairs: [(Character, Character)] = [("\"", "\""), ("“", "”"), ("`", "`")]
        var found: [String] = []
        for (open, close) in pairs {
            var current: String?
            for character in text {
                if var inside = current {
                    if character == close {
                        found.append(inside)
                        current = nil
                    } else {
                        inside.append(character)
                        current = inside
                    }
                } else if character == open {
                    current = ""
                }
            }
        }
        return found
    }

    private static func removing(_ phrase: [String], from words: [String]) -> [String] {
        guard !phrase.isEmpty, words.count >= phrase.count else { return words }
        let prepositions: Set<String> = ["in", "on", "from", "inside", "using", "with"]
        var result: [String] = []
        var index = 0
        while index < words.count {
            if index + phrase.count <= words.count,
                Array(words[index..<index + phrase.count]) == phrase
            {
                if let last = result.last, prepositions.contains(last) { result.removeLast() }
                index += phrase.count
                continue
            }
            result.append(words[index])
            index += 1
        }
        return result
    }
}
