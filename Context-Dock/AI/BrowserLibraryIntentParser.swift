import Foundation

#if canImport(FoundationModels)
import FoundationModels
#endif

/// Turns a browser-data question ("what is my last visited site?", "any github pages
/// yesterday?", "show my bookmarks about swift") into a structured query for
/// `BrowserURLLibraryService`.
///
/// Privacy: only the user's own sentence is parsed. History rows, bookmarks and tab URLs
/// never reach a model — `localBrowserHistoryAnswer` reads the library and formats the
/// answer itself after this parser returns.
///
/// Routing mirrors `MenuIntentRouter`: on-device Foundation Models first (free, instant,
/// nothing leaves the Mac), then the user's selected provider, then a deterministic
/// heuristic. The heuristic alone used to own this job as a hand-written stopword list,
/// which failed on the first phrasing nobody enumerated ("what is my last visited site?"
/// searched the library for the fragment "is last").
struct BrowserLibraryIntent: Equatable {
    enum Source: String {
        case history
        case bookmarks
        case tabs
    }

    enum Range: String {
        case today
        case yesterday
        case last7
        case last30

        var window: (start: Date, end: Date)? {
            let cal = Calendar.current
            let now = Date()
            let todayStart = cal.startOfDay(for: now)
            switch self {
            case .today:
                return (todayStart, now)
            case .yesterday:
                guard let start = cal.date(byAdding: .day, value: -1, to: todayStart) else {
                    return nil
                }
                return (start, todayStart)
            case .last7:
                guard let start = cal.date(byAdding: .day, value: -7, to: todayStart) else {
                    return nil
                }
                return (start, now)
            case .last30:
                guard let start = cal.date(byAdding: .day, value: -30, to: todayStart) else {
                    return nil
                }
                return (start, now)
            }
        }
    }

    var source: Source = .history
    /// Empty means "no subject" — list by recency instead of searching for a term.
    var subject: String = ""
    var range: Range?
    /// "last visited", "latest", "most recent" — answer with the single newest row.
    var wantsLatest: Bool = false
    var copyToClipboard: Bool = false

    var dateWindow: (start: Date, end: Date)? { range?.window }
}

#if canImport(FoundationModels)
/// What the on-device model is allowed to answer with.
///
/// Fields, not a sentence with JSON in it. The older path asked for "ONLY one JSON object,
/// no prose and no code fence" and then went looking for braces — it worked, but it spent
/// prompt budget describing a format and left the model free to get it wrong.
///
/// `copy` is deliberately absent. The clipboard is a side effect and is decided from the
/// user's literal wording, so asking a model about it would be asking a question whose
/// answer is thrown away.
@available(macOS 26.0, *)
@Generable
struct BrowserLibraryPick {
    @Guide(
        description:
            "Where to look: history, bookmarks, or tabs. Use tabs only for currently open tabs, bookmarks for saved bookmarks, otherwise history."
    )
    var source: String

    @Guide(
        description:
            "The site, topic or domain being asked about, lowercase. Empty when the question names none, as in 'what did I visit yesterday'."
    )
    var subject: String

    @Guide(description: "The time window asked for: today, yesterday, last7, last30, or none.")
    var range: String

    @Guide(
        description:
            "True only when the question asks for the single most recent item, as in 'last visited' or 'most recent'."
    )
    var latest: Bool
}
#endif

@MainActor
final class BrowserLibraryIntentParser {
    static let shared = BrowserLibraryIntentParser()

    private var cache: [String: BrowserLibraryIntent] = [:]
    private var cacheOrder: [String] = []
    private let cacheLimit = 40

    private init() {}

    /// Structured intent for a browser-data question. Never throws and never blocks
    /// indefinitely — a slow or unavailable model falls back to the heuristic.
    func intent(for rawQuery: String) async -> BrowserLibraryIntent {
        let normalized = rawQuery.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return BrowserLibraryIntent() }
        if let cached = cache[normalized] { return cached }

        let heuristic = Self.heuristicIntent(for: normalized)
        let resolved = await model(for: normalized, heuristic: heuristic) ?? heuristic
        store(resolved, for: normalized)
        return resolved
    }

    private func store(_ intent: BrowserLibraryIntent, for key: String) {
        if cache[key] == nil {
            cacheOrder.append(key)
            if cacheOrder.count > cacheLimit, let oldest = cacheOrder.first {
                cacheOrder.removeFirst()
                cache[oldest] = nil
            }
        }
        cache[key] = intent
    }

    // MARK: - Model routing

    private func model(
        for query: String,
        heuristic: BrowserLibraryIntent
    ) async -> BrowserLibraryIntent? {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *),
            case .available = SystemLanguageModel.default.availability,
            let onDevice = await askOnDevice(query: query, heuristic: heuristic)
        {
            return onDevice
        }
        #endif
        return await askSelectedProvider(query: query, heuristic: heuristic)
    }


    /// The on-device path says nothing about output format: `BrowserLibraryPick`'s fields
    /// carry their own descriptions, and the shape is not the model's problem.
    private static let onDeviceInstructions = """
        You read a question about a person's own browser data and fill in what it is asking
        for: where to look, what subject it names, which time window, and whether it wants
        only the single most recent item.
        """

    /// The provider path still has to ask for JSON — `AIProviderRouter.send(_:)` returns a
    /// String and has no typed seam.
    private static let instructions = """
        You extract a structured query from a question about a person's own browser data.
        Reply with ONLY one JSON object, no prose and no code fence:
        {"source":"history|bookmarks|tabs","subject":"","range":"today|yesterday|last7|last30|none","latest":false,"copy":false}

        source  — "tabs" only for currently open tabs; "bookmarks" for saved bookmarks;
                  otherwise "history".
        subject — the site, topic or domain being asked about, lowercase. Use "" when the
                  question names no subject (for example "what did I visit yesterday").
                  Never put question words, time words or a browser name in subject.
        range   — the time window asked for, else "none".
        latest  — true when the question asks for the single most recent item
                  ("last visited", "latest", "most recent").
        copy    — true when the question asks to copy the result to the clipboard.
        """

    private static func prompt(for query: String) -> String {
        "Question: \"\(query)\"\n\nJSON:"
    }

    #if canImport(FoundationModels)
    @available(macOS 26.0, *)
    private func askOnDevice(
        query: String,
        heuristic: BrowserLibraryIntent
    ) async -> BrowserLibraryIntent? {
        do {
            let session = LanguageModelSession(instructions: Self.onDeviceInstructions)
            let pick = try await session.respond(
                to: Self.prompt(for: query), generating: BrowserLibraryPick.self
            ).content
            return Self.reconcile(
                source: pick.source, subject: pick.subject, range: pick.range,
                latest: pick.latest, heuristic: heuristic)
        } catch {
            return nil
        }
    }
    #endif

    private func askSelectedProvider(
        query: String,
        heuristic: BrowserLibraryIntent
    ) async -> BrowserLibraryIntent? {
        let request = AIRequest(
            text: Self.instructions + "\n\n" + Self.prompt(for: query),
            context: .none,
            source: .contextDock,
            providerSelection: AIProviderSelectionResolver.current()
        )
        // A parse is a convenience, never a stall: the heuristic answers if the provider
        // is slow, rate-limited or missing a key.
        let reply: String? = await withTaskGroup(of: String?.self) { group in
            group.addTask {
                try? await AIProviderRouter.shared.send(request)
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        guard let reply else { return nil }
        return Self.decode(reply, heuristic: heuristic)
    }

    // MARK: - Decoding

    private static func decode(
        _ raw: String, heuristic: BrowserLibraryIntent
    ) -> BrowserLibraryIntent? {
        guard let start = raw.firstIndex(of: "{"), let end = raw.lastIndex(of: "}"),
            start < end
        else { return nil }
        let json = String(raw[start...end])
        guard let data = json.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        return reconcile(
            source: object["source"] as? String,
            subject: object["subject"] as? String,
            range: object["range"] as? String,
            latest: object["latest"] as? Bool,
            heuristic: heuristic)
    }

    /// One answer, checked a field at a time, against what the app already knows.
    ///
    /// Every field is admitted on its own merits: an unreadable `source` or `range` takes
    /// the heuristic's value and leaves the rest of the answer standing. That much was
    /// always true here. What was missing is a real check on `subject`, which is the field
    /// that actually goes wrong — the prompt carries three prohibitions about it, and the
    /// only guard was a 40-character limit that almost nothing trips.
    ///
    /// Shared by the typed on-device path and the JSON provider path so the two cannot
    /// drift apart, which is how the menu router ended up gating a guess on one branch and
    /// offering it on the other.
    static func reconcile(
        source: String?, subject: String?, range: String?, latest: Bool?,
        heuristic: BrowserLibraryIntent
    ) -> BrowserLibraryIntent {
        var intent = BrowserLibraryIntent()

        if let source = source?.lowercased(),
            let parsed = BrowserLibraryIntent.Source(rawValue: source)
        {
            intent.source = parsed
        } else {
            intent.source = heuristic.source
        }

        intent.subject = cleanedSubject(subject, heuristic: heuristic.subject)

        if let range = range?.lowercased() {
            intent.range = BrowserLibraryIntent.Range(rawValue: range)
        }
        if intent.range == nil { intent.range = heuristic.range }

        intent.wantsLatest = latest ?? heuristic.wantsLatest
        // Clipboard writes are a side effect — trust the literal wording, not the model.
        intent.copyToClipboard = heuristic.copyToClipboard
        return intent
    }

    /// The subject the model named, with the words that are never a subject taken out.
    ///
    /// "what did I visit yesterday on github" comes back as `visit github`: thirteen
    /// characters, so the old length guard passed it, and the library was then searched for
    /// a subject nobody asked for. The heuristic has always known `visit` is not a subject —
    /// `functionWords` and `browserNames` exist for exactly this — and the model's answer
    /// was simply never held to it.
    ///
    /// Filtering beats falling back: `visit github` becomes `github`, which is what was
    /// meant, where handing the whole field to the heuristic would only re-derive it.
    ///
    /// An empty subject is a real answer — the instructions ask for one when the question
    /// names no subject — so it is kept rather than replaced.
    static func cleanedSubject(_ raw: String?, heuristic: String) -> String {
        let subject = (raw ?? "")
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !subject.isEmpty else { return "" }
        // A model that echoed the question back rather than answering it.
        guard subject.count <= 40 else { return heuristic }

        let kept = subjectTokens(in: subject)

        // Nothing but noise. The heuristic applies the same filter, so it will usually be
        // empty too — which is the right answer, not a failure.
        guard !kept.isEmpty else { return heuristic }
        return kept.joined(separator: " ")
    }

    // MARK: - Deterministic fallback

    /// Small, obvious-cases-only parse. Used verbatim when no model answers, and as the
    /// seed the model's output is merged into.
    static func heuristicIntent(for normalized: String) -> BrowserLibraryIntent {
        var intent = BrowserLibraryIntent()

        if normalized.contains("bookmark") {
            intent.source = .bookmarks
        } else if normalized.contains("tab"), !normalized.contains("history"),
            !normalized.contains("visit")
        {
            intent.source = .tabs
        }

        if normalized.contains("yesterday") {
            intent.range = .yesterday
        } else if normalized.contains("today") {
            intent.range = .today
        } else if normalized.contains("last week") || normalized.contains("past week")
            || normalized.contains("this week") || normalized.contains("last 7 days")
        {
            intent.range = .last7
        } else if normalized.contains("last month") || normalized.contains("past month")
            || normalized.contains("last 30 days")
        {
            intent.range = .last30
        }

        intent.wantsLatest =
            normalized.contains("last visited") || normalized.contains("latest")
            || normalized.contains("most recent") || normalized.contains("newest")
            || normalized.contains("last site") || normalized.contains("last page")
            || normalized.contains("last url")

        intent.copyToClipboard = Self.asksForClipboard(normalized)
        intent.subject = Self.heuristicSubject(in: normalized)
        return intent
    }

    /// Literal clipboard wording — the side effect must not depend on a model's judgement.
    static func asksForClipboard(_ normalized: String) -> Bool {
        normalized.contains("clipboard") || normalized.contains("copy them")
            || normalized.contains("copy the links") || normalized.contains("copy all")
    }

    /// Words that are never the subject of a browser-data question. Deliberately short —
    /// the model handles real phrasing; this only has to survive its absence.
    private static let functionWords: Set<String> = [
        "the", "and", "for", "was", "were", "are", "did", "does", "have", "has", "had",
        "what", "whats", "which", "when", "where", "who", "how", "why", "show", "list",
        "find", "search", "give", "tell", "check", "see", "all", "any", "some", "most",
        "last", "latest", "recent", "recently", "newest", "past", "back", "just", "with",
        "from", "into", "that", "this", "these", "those", "them", "there", "here", "you",
        "your", "mine", "site", "sites", "page", "pages", "url", "urls", "link", "links",
        "web", "website", "websites", "webpage", "tab", "tabs", "history", "bookmark",
        "bookmarks", "browser", "browsing", "browse", "visit", "visits", "visited",
        "open", "opened", "today", "yesterday", "week", "weeks", "month", "months",
        "day", "days", "hour", "hours", "time", "times", "night", "morning", "copy",
        "clipboard", "please", "about", "regarding",
    ]

    private static let browserNames: Set<String> = [
        "safari", "chrome", "chromium", "brave", "edge", "arc", "firefox", "orion",
    ]

    private static func heuristicSubject(in normalized: String) -> String {
        subjectTokens(in: normalized).joined(separator: " ")
    }

    /// The words in a phrase that could be the subject of a browser-data question.
    ///
    /// The heuristic and the model's answer are filtered by this same function, so a word
    /// the app would never have guessed as a subject is not accepted merely because a model
    /// offered it. The short-token rule is why "what did i visit" keeps nothing: "i" is not
    /// a subject, and no list of function words is going to enumerate every stray letter.
    private static func subjectTokens(in phrase: String) -> [String] {
        phrase
            .split { !$0.isLetter && !$0.isNumber && $0 != "." && $0 != "-" }
            .map(String.init)
            .filter { token in
                token.count >= 3 && !functionWords.contains(token)
                    && !browserNames.contains(token)
            }
    }
}
