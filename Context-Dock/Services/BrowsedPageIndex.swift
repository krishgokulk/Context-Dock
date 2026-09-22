// BrowsedPageIndex.swift
// Context-Dock
//
// What DoraX has already read, so the next question about the same subject is cheaper.
//
// The owner agreed to this deliberately, so it is built deliberately: it keeps **what a page was
// about**, not what a page said. Title, address, the question that was asked and when — no page
// text, no snippets, no form values. A record of "you asked about Homebrew's docs on Monday" is
// useful to a later answer; a copy of the page is a browsing archive nobody asked for.
//
// Three properties keep it that way:
//
//   * **Bounded** — 500 entries, oldest dropped. It is an index, not a history.
//   * **Never written for a page the guard refused.** If DoraX would not read it, DoraX does not
//     record that it existed.
//   * **Clearable in one call**, and the file is plain JSON somebody can read or delete.

import Combine
import Foundation

struct BrowsedPage: Codable, Equatable, Identifiable {
    var id: String { url + "#" + String(Int(askedAt.timeIntervalSince1970)) }
    let url: String
    let title: String
    /// What the user wanted from it. The useful half: the same page read for two different
    /// reasons is two different facts about what they are working on.
    let question: String
    let askedAt: Date

    var host: String { URL(string: url)?.host ?? url }
}

@MainActor
final class BrowsedPageIndex: ObservableObject {
    static let shared = BrowsedPageIndex()

    @Published private(set) var pages: [BrowsedPage] = []

    private let maximumEntries = 500
    private let fileURL: URL

    init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let base = FileManager.default
                .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Context-Dock", isDirectory: true)
            try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
            self.fileURL = base.appendingPathComponent("browsed-pages.json")
        }
        load()
    }

    /// Record that a page was read for a question.
    ///
    /// Silently does nothing for a page the guard refuses: not reading something and then noting
    /// that it was there is not a boundary anybody would recognise as one.
    func record(url: String, title: String, question: String) {
        let address = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !address.isEmpty, SensitivePageGuard.allows(address) else { return }

        let entry = BrowsedPage(
            url: address,
            title: title.trimmingCharacters(in: .whitespacesAndNewlines),
            question: String(question.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200)),
            askedAt: Date())
        // The same page asked the same thing twice in a row is one fact, not two.
        if let last = pages.last, last.url == entry.url, last.question == entry.question {
            return
        }
        pages.append(entry)
        if pages.count > maximumEntries {
            pages.removeFirst(pages.count - maximumEntries)
        }
        save()
    }

    /// Pages already read that this question is about, newest first.
    ///
    /// Matched on the words in their titles and the questions they were read for — the index
    /// has no page text to match against, which is the point.
    func matches(_ query: String, limit: Int = 3) -> [BrowsedPage] {
        let terms = Set(
            query.lowercased()
                .split { !$0.isLetter && !$0.isNumber }
                .map(String.init)
                .filter { $0.count > 3 })
        guard !terms.isEmpty else { return [] }
        return pages.reversed().filter { page in
            let haystack = (page.title + " " + page.question + " " + page.host).lowercased()
            return terms.contains { haystack.contains($0) }
        }
        .prefix(limit)
        .map { $0 }
    }

    /// A line for the prompt, or nil when nothing matches. Says what was read and when, never
    /// what it said — the page itself is fetched again if the answer needs it.
    func groundingLine(for query: String) -> String? {
        let hits = matches(query)
        guard !hits.isEmpty else { return nil }
        let formatter = RelativeDateTimeFormatter()
        let rows = hits.map { page in
            "- \(page.title.isEmpty ? page.host : page.title) (\(page.url)) — read "
                + formatter.localizedString(for: page.askedAt, relativeTo: Date())
                + " for: \(page.question)"
        }
        return "PAGES ALREADY READ IN THIS APP ABOUT THIS:\n" + rows.joined(separator: "\n")
    }

    func clear() {
        pages = []
        try? FileManager.default.removeItem(at: fileURL)
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
            let decoded = try? JSONDecoder().decode([BrowsedPage].self, from: data)
        else { return }
        pages = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(pages) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
