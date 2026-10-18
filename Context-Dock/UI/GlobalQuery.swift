// GlobalQuery.swift
// Context-Dock
//
// Global Context reads what is typed before it lists anything (owner 2026-10-17, S1 of the
// smarter-search plan): which words name an app, which are a time ("today"), which are glue
// ("in", "the"), and which are what is actually asked for. Two rules follow from it:
//
// - A row must answer the asked-for words, not only the app's name: "today history in
//   safari" listed "Copy GitHub Links" because it ran in a browser.
// - A command that destroys something — clear, delete, quit — is never the answer Return
//   takes unless its verb was typed: "safari history" put "Clear History…" first.

import Foundation

enum GlobalQuery {
    static let glueWords: Set<String> = ["in", "on", "the", "a", "an", "my", "for", "of", "from", "to", "at", "with", "and"]
    static let weekdayWords = ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"]
    static let timeWords: Set<String> = Set(["today", "yesterday", "tonight", "week", "month", "recent", "recently", "last"] + weekdayWords)
    static let destructiveVerbs: Set<String> = ["clear", "delete", "erase", "remove", "quit", "reset", "empty", "trash"]

    static func words(_ text: String) -> [String] {
        text.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
    }

    /// The words that say what is asked for: not glue, not a time, not an app's name.
    static func askedWords(in query: String, appNames: Set<String>) -> [String] {
        let appTokens = Set(appNames.flatMap(words))
        return words(query).filter {
            !glueWords.contains($0) && !timeWords.contains($0) && !appTokens.contains($0)
        }
    }

    /// The verb a destructive row starts with, if it does.
    static func destructiveVerb(of row: AppChatRow) -> String? {
        guard let first = words(row.title).first, destructiveVerbs.contains(first) else { return nil }
        return first
    }

    /// What a row can be found by, beyond its app's name. History and bookmark rows answer
    /// "history" and "bookmark" though their titles are page names.
    static func haystack(of row: AppChatRow) -> [String] {
        var text: [String] = [row.title]
        switch row {
        case .dock(let pill):
            text += [pill.menuContext ?? "", pill.badge ?? ""] + pill.menuPath
            // A clip, note or notification answers the name of where it was kept (S4).
            switch pill.rankingKind {
            case GlobalSources.clipKind: text.append("clipboard clip clips copied copy")
            case GlobalSources.noteKind: text.append("note notes quick")
            case GlobalSources.notificationKind: text.append("notification notifications alert alerts")
            default: break
            }
            if pill.rankingKind == "recentURL" || pill.resolvedURL.map({ !$0.isFileURL }) == true {
                let label = (pill.menuContext ?? "").lowercased()
                text.append(label.contains("bookmark") ? "bookmark bookmarks" : "history page site visited")
            }
        case .global(let doc):
            text.append(doc.subtitle)
            if case .browserURL(_, _, _, let kind, _) = doc.action {
                text.append(kind == BrowserURLLibraryEntry.Kind.tab.rawValue
                    ? "tab tabs open page site" : "history bookmark page site visited")
            }
            if case .cachedMenu(_, _, let path, _, _) = doc.action { text += path }
        case .command(let item): text += item.path
        case .file(let url): text.append(url.deletingLastPathComponent().lastPathComponent)
        case .action(let action): text.append(action.description)
        case .app, .cliSuggestion: break
        }
        return words(text.joined(separator: " "))
    }

    /// The rows, read against the query: rows that answer only the app's name are dropped
    /// (never all of them), apps are always kept, and destructive rows nobody asked for
    /// follow the safe ones.
    static func refine(_ rows: [AppChatRow], query: String) -> [AppChatRow] {
        let (safe, risky) = split(rows, query: query)
        return safe + risky
    }

    /// The refined rows as two lists: what answers the query, and the destructive rows
    /// nobody asked for — which Global lists after its fallbacks, so Return never offers to
    /// clear or delete when nothing safe matched (owner 2026-10-17).
    static func split(
        _ rows: [AppChatRow], query: String, dropsUnanswered: Bool = true
    ) -> (safe: [AppChatRow], risky: [AppChatRow]) {
        let appNames = Set(rows.map(GlobalResultSection.appName(of:)).filter { !$0.isEmpty }
            + rows.compactMap { if case .app(let entry) = $0 { return entry.name } else { return nil } }
            + rows.compactMap { row -> String? in
                guard GlobalResultSection.title(for: row) == GlobalResultSection.applications else { return nil }
                return row.title
            })
        let asked = askedWords(in: query, appNames: appNames)
        let typed = Set(words(query))

        func answers(_ row: AppChatRow) -> Bool {
            if GlobalResultSection.title(for: row) == GlobalResultSection.applications { return true }
            let hay = haystack(of: row)
            return asked.contains { word in hay.contains { $0.hasPrefix(word) || word.hasPrefix($0) && $0.count >= 4 } }
        }
        var kept = asked.isEmpty || !dropsUnanswered ? rows : rows.filter(answers)
        if !kept.contains(where: { GlobalResultSection.title(for: $0) != GlobalResultSection.applications }) {
            kept = rows
        }
        func isUnaskedDestructive(_ row: AppChatRow) -> Bool {
            guard let verb = destructiveVerb(of: row) else { return false }
            return !typed.contains(verb)
        }
        return (kept.filter { !isUnaskedDestructive($0) }, kept.filter(isUnaskedDestructive))
    }

    static let topHitSection = "Top Hit"

    /// The one row that plainly answers the query (S2): an app's own command — not a page,
    /// not a file — whose app the words name and whose title holds every asked word, never a
    /// destructive one nobody asked for. "safari history" → Show Personal History.
    static func topHit(_ rows: [AppChatRow], query: String) -> AppChatRow? {
        let typed = Set(words(query))
        let appNames = Set(rows.map(GlobalResultSection.appName(of:)).filter { !$0.isEmpty })
        let asked = askedWords(in: query, appNames: appNames)
        guard !asked.isEmpty else { return nil }
        return rows.first { row in
            let app = words(GlobalResultSection.appName(of: row))
            guard !app.isEmpty, app.allSatisfy(typed.contains) else { return false }
            guard [GlobalResultSection.menuCommands, GlobalResultSection.commands]
                .contains(GlobalResultSection.title(for: row) ?? "")
            else { return false }
            if let verb = destructiveVerb(of: row), !typed.contains(verb) { return false }
            let title = words(row.title)
            return asked.allSatisfy { word in title.contains { $0.hasPrefix(word) } }
        }
    }

    /// A named app's menu commands that hold an asked word, from the index's documents, that
    /// the rows do not already have.
    static func namedAppCommands(
        _ documents: [GlobalSearchService.SearchDocument], query: String, besides rows: [AppChatRow]
    ) -> [AppChatRow] {
        let typed = Set(words(query))
        let have = Set(rows.map { "\(GlobalResultSection.appName(of: $0).lowercased())|\($0.title.lowercased())" })
        return documents.compactMap { doc -> AppChatRow? in
            guard case .cachedMenu(_, let appName, _, _, _) = doc.action else { return nil }
            let app = words(appName)
            guard !app.isEmpty, app.allSatisfy(typed.contains) else { return nil }
            let asked = askedWords(in: query, appNames: [appName])
            let title = words(doc.title)
            guard !asked.isEmpty, asked.contains(where: { word in title.contains { $0.hasPrefix(word) } })
            else { return nil }
            guard !have.contains("\(appName.lowercased())|\(doc.title.lowercased())") else { return nil }
            return .global(doc)
        }
    }

    /// Safari's open tabs that hold every asked word, as rows, one per page (owner
    /// 2026-10-18: "if safari is running filter opened tabs"). "tabs" alone lists them all;
    /// "safari" alone lists none, so the app itself still leads.
    static func openTabRows(_ tabs: [SafariTab], query: String) -> [AppChatRow] {
        let typed = Set(words(query))
        let asked = askedWords(in: query, appNames: ["Safari"])
            .filter { !["tab", "tabs", "open"].contains($0) }
        if asked.isEmpty, typed.isDisjoint(with: ["tab", "tabs"]) { return [] }
        var seen = Set<String>()
        return tabs.compactMap { tab -> AppChatRow? in
            guard let url = URL(string: tab.url),
                seen.insert(SafariTabManager.normalizedURLKey(tab.url)).inserted
            else { return nil }
            let hay = words("\(tab.title) \(tab.url)")
            guard asked.allSatisfy({ word in hay.contains { $0.hasPrefix(word) } }) else { return nil }
            return .global(GlobalSearchService.SearchDocument(
                browserURL: BrowserURLLibraryEntry(
                    title: tab.title, url: url, visitDate: nil, kind: .tab,
                    browserName: "Safari", browserBundleId: BrowserTabList.safariBundleID),
                icon: nil))
        }
        .prefix(8).map { $0 }
    }

    /// The open tabs first, and the same pages' history and bookmark rows dropped.
    static func leadingOpenTabs(_ tabs: [AppChatRow], _ rows: [AppChatRow]) -> [AppChatRow] {
        let open = Set(tabs.compactMap(pageURL).map(SafariTabManager.normalizedURLKey))
        return tabs + rows.filter { row in
            pageURL(row).map { !open.contains(SafariTabManager.normalizedURLKey($0)) } ?? true
        }
    }

    /// The web page a row opens, if it opens one.
    static func pageURL(_ row: AppChatRow) -> String? {
        switch row {
        case .global(let doc):
            if case .browserURL(let url, _, _, _, _) = doc.action { return url.absoluteString }
        case .dock(let pill):
            if let url = pill.resolvedURL, !url.isFileURL { return url.absoluteString }
        default: break
        }
        return nil
    }

    // MARK: Time words (S3)

    /// The time the words name, ending no later than now: "today", "yesterday", "this week",
    /// "last week", "this month", "last month", "recent" (the last seven days). Nil when no
    /// time is named, and the list is not filtered by time at all.
    static func timeRange(
        in query: String, now: Date = Date(), calendar: Calendar = .current
    ) -> DateInterval? {
        let words = words(query)
        let isLast = words.contains("last")
        func period(_ unit: Calendar.Component) -> DateInterval? {
            guard let this = calendar.dateInterval(of: unit, for: now) else { return nil }
            guard isLast else { return DateInterval(start: this.start, end: max(this.start, now)) }
            guard let before = calendar.date(byAdding: unit, value: -1, to: this.start) else { return nil }
            return calendar.dateInterval(of: unit, for: before)
        }
        if words.contains("today") || words.contains("tonight") { return period(.day) }
        if words.contains("yesterday"),
            let day = calendar.date(byAdding: .day, value: -1, to: now) {
            return calendar.dateInterval(of: .day, for: day)
        }
        // "monday": the latest Monday — today when it is Monday; "last monday" a week
        // before that when today is Monday (owner 2026-10-18: "monday" listed nothing).
        if let target = weekdayWords.firstIndex(where: words.contains) {
            var back = (calendar.component(.weekday, from: now) - (target + 1) + 7) % 7
            if back == 0, isLast { back = 7 }
            guard let day = calendar.date(byAdding: .day, value: -back, to: now),
                let interval = calendar.dateInterval(of: .day, for: day)
            else { return nil }
            return DateInterval(start: interval.start, end: min(interval.end, max(interval.start, now)))
        }
        if words.contains("week") { return period(.weekOfYear) }
        if words.contains("month") { return period(.month) }
        if words.contains("recent") || words.contains("recently") {
            return DateInterval(start: now.addingTimeInterval(-7 * 86_400), end: now)
        }
        return nil
    }

    /// When a row's item happened: a visit, a copy, a note, a file's last change. Nil for
    /// what has no time of its own — an app, a menu command.
    static func date(of row: AppChatRow) -> Date? {
        func modified(_ path: String?) -> Date? {
            guard let path, !path.isEmpty, !path.hasSuffix(".app") else { return nil }
            return (try? URL(fileURLWithPath: path).resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate
        }
        switch row {
        case .dock(let pill): return pill.date ?? modified(pill.previewPath)
        case .global(let doc): return doc.date ?? modified(doc.filePath)
        case .file(let url): return modified(url.path)
        default: return nil
        }
    }

    /// The rows the time allows: a dated row only inside it; a web page with no date of its
    /// own (a live History menu's item) only when it is an open tab, which is now. Apps and
    /// commands are untouched — "today" never hides Safari or its menus.
    static func within(_ range: DateInterval, _ rows: [AppChatRow]) -> [AppChatRow] {
        rows.filter { row in
            if let date = date(of: row) { return range.contains(date) }
            if pageURL(row) != nil {
                return GlobalResultSection.title(for: row) == GlobalResultSection.openTabs
            }
            return true
        }
    }

    /// The words to look things up by when a time is named: the query without its time
    /// words ("pdf today" → "pdf"). The query itself when no time is named.
    static func searchText(_ query: String) -> String {
        guard timeRange(in: query) != nil else { return query }
        return words(query).filter { !timeWords.contains($0) && $0 != "this" }.joined(separator: " ")
    }

    static let historyWords: Set<String> = ["history", "visited", "page", "pages", "site", "sites", "browsed"]
    static let browserWords: Set<String> = [
        "safari", "chrome", "google", "arc", "firefox", "brave", "edge", "opera", "vivaldi", "browser",
    ]

    /// What to look history up by when a time is named: the asked words without the time,
    /// "history" or a browser's name — "safari history today" looks up everything, and the
    /// time does the choosing.
    static func historySearchText(_ query: String) -> String {
        words(query).filter {
            !glueWords.contains($0) && !timeWords.contains($0)
                && !historyWords.contains($0) && !browserWords.contains($0)
        }.joined(separator: " ")
    }

    /// History pages inside the time, from the named browser when one is named.
    static func datedHistory(
        _ entries: [BrowserURLLibraryEntry], query: String, range: DateInterval, limit: Int = 12
    ) -> [BrowserURLLibraryEntry] {
        let typed = Set(words(query))
        // Any word of the browser's name names it: "chrome" is Google Chrome, "edge"
        // Microsoft Edge.
        func isNamed(_ entry: BrowserURLLibraryEntry) -> Bool {
            !Set(words(entry.browserName)).subtracting(["google", "microsoft"]).isDisjoint(with: typed)
        }
        let named = entries.contains(where: isNamed)
        return Array(entries.filter { entry in
            guard let visit = entry.visitDate, range.contains(visit) else { return false }
            return !named || isNamed(entry)
        }.prefix(limit))
    }

    // MARK: History by day (owner 2026-10-18)

    static let historyDayKind = "historyDay"
    static let historyDaySection = "History by day"

    /// A browser's last seven days as rows, as its History menu lists them — "Today",
    /// "Yesterday", "Friday, 16 October" — each with how many pages it holds, read from the
    /// browser's own history rather than its menu. Shown for "history" or words that name a
    /// day ("sat", "october"); not once a time is typed, when the day's pages are the list.
    /// Return fills the field with the day ("friday"), and its pages follow.
    static func historyDayRows(
        _ entries: [BrowserURLLibraryEntry], query: String,
        now: Date = Date(), calendar: Calendar = .current
    ) -> [AppChatRow] {
        guard timeRange(in: query, now: now, calendar: calendar) == nil else { return [] }
        let typed = words(query)
        let asked = typed.filter { !glueWords.contains($0) && !browserWords.contains($0) }
        guard !asked.isEmpty else { return [] }
        let listsAll = asked.contains { ["history", "day", "days"].contains($0) }
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_GB")
        formatter.dateFormat = "EEEE, d MMMM"
        let today = calendar.startOfDay(for: now)
        return (0..<7).compactMap { back -> AppChatRow? in
            guard let start = calendar.date(byAdding: .day, value: -back, to: today),
                let end = calendar.date(byAdding: .day, value: 1, to: start)
            else { return nil }
            let pages = entries.filter { $0.kind == .history && $0.visitDate.map { $0 >= start && $0 < end } == true }
            guard !pages.isEmpty else { return nil }
            let weekday = weekdayWords[calendar.component(.weekday, from: start) - 1]
            let fill = back == 0 ? "today" : back == 1 ? "yesterday" : weekday
            let title = back == 0 ? "Today" : back == 1 ? "Yesterday" : formatter.string(from: start)
            let hay = words("\(fill) \(weekday) \(formatter.string(from: start))")
            guard listsAll || asked.allSatisfy({ word in hay.contains { $0.hasPrefix(word) } }) else { return nil }
            var pill = DockPill(
                id: "history-day-\(fill)", name: title, icon: "clock.arrow.circlepath",
                badge: nil, execute: {})
            pill.rankingKind = historyDayKind
            pill.resultSection = historyDaySection
            pill.menuItemName = fill
            pill.menuContext = pages.count == 1 ? "1 page" : "\(pages.count) pages"
            pill.sourceBundleId = pages[0].browserBundleId
            pill.sourceAppName = pages[0].browserName
            return .dock(pill)
        }
    }
}
