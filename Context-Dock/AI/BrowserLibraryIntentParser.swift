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
            let session = LanguageModelSession(instructions: Self.instructions)
            let response = try await session.respond(
                to: Self.prompt(for: query), generating: String.self)
            return Self.decode(response.content, heuristic: heuristic)
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

        var intent = BrowserLibraryIntent()
        if let source = (object["source"] as? String)?.lowercased(),
            let parsed = BrowserLibraryIntent.Source(rawValue: source)
        {
            intent.source = parsed
        } else {
            intent.source = heuristic.source
        }
        let subject = (object["subject"] as? String ?? "")
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // Guard against a model that echoes the question back as the subject.
        intent.subject = subject.count > 40 ? heuristic.subject : subject
        if let range = (object["range"] as? String)?.lowercased() {
            intent.range = BrowserLibraryIntent.Range(rawValue: range)
        }
        if intent.range == nil { intent.range = heuristic.range }
        intent.wantsLatest = (object["latest"] as? Bool) ?? heuristic.wantsLatest
        // Clipboard writes are a side effect — trust the literal wording, not the model.
        intent.copyToClipboard = heuristic.copyToClipboard
        return intent
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
        "clipboard", "please",
    ]

    private static let browserNames: Set<String> = [
        "safari", "chrome", "chromium", "brave", "edge", "arc", "firefox", "orion",
    ]

    private static func heuristicSubject(in normalized: String) -> String {
        normalized
            .split { !$0.isLetter && !$0.isNumber && $0 != "." && $0 != "-" }
            .map(String.init)
            .filter { token in
                token.count >= 3 && !functionWords.contains(token)
                    && !browserNames.contains(token)
            }
            .joined(separator: " ")
    }
}
