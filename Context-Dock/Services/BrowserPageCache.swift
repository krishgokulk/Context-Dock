// BrowserPageCache.swift
// Context-Dock
//
// A page is read once per version, not once per question.
//
// Compaction already existed — `MarkItDownService.compact` cuts a page toward the question and
// caps it at 5 000 characters. What did not exist is memory: three questions about the same page
// extracted, compacted and sent that page three times, paying the extraction, the tokens and the
// latency each time. The page had not changed; only the question had.
//
// So: extract once, key it by what was extracted, and let later turns spend on the *question*
// instead. The key is `URL + SHA-256 of the text`, which means a page that changed is a different
// entry — a stale answer is worse than a slow one, and "same URL" is not "same page" on anything
// that updates itself.
//
// The rolling summary is the second half. After a turn has answered about a page, its own summary
// is stored; the next question sends that summary plus the passage it matches, rather than the
// page again. A follow-up then costs a fraction of the first question.
//
// Eviction is deliberately aggressive — twenty pages, thirty minutes. This is a cache for the
// conversation happening now, and must never become a quiet record of what somebody browsed.

import CryptoKit
import Foundation

struct CachedPage: Equatable {
    let url: String
    /// SHA-256 of the extracted text. Identity, not integrity: it is how "the page changed" is
    /// detected without storing two copies to compare.
    let fingerprint: String
    let title: String
    /// The extraction as it was read, before any per-question compaction.
    let text: String
    /// What a turn concluded about this page, kept so the next question can start from it.
    var summary: String?
    let readAt: Date
    var lastUsedAt: Date

    var age: TimeInterval { Date().timeIntervalSince(readAt) }
}

@MainActor
final class BrowserPageCache {
    static let shared = BrowserPageCache()

    /// Small on purpose: the working set of a conversation, not a browsing history.
    private let maximumPages = 20
    /// A page older than this is re-read rather than trusted. Thirty minutes is long enough to
    /// cover a conversation about an article, short enough that a dashboard is never stale.
    private let maximumAge: TimeInterval = 30 * 60

    private var pages: [String: CachedPage] = [:]

    init() {}

    static func fingerprint(_ text: String) -> String {
        let digest = SHA256.hash(data: Data(text.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// What is remembered for this URL, if the text still matches.
    ///
    /// - Parameter freshText: the text just read, when the caller has it. Passing it is what
    ///   turns this into a *version* check rather than a URL check: different text, different
    ///   page, no reuse.
    func cached(url: String, freshText: String? = nil) -> CachedPage? {
        guard let entry = pages[key(url)] else { return nil }
        guard entry.age < maximumAge else {
            pages[key(url)] = nil
            return nil
        }
        if let freshText, !freshText.isEmpty,
            Self.fingerprint(freshText) != entry.fingerprint
        {
            // The page moved on. Dropping it here means the next store writes the new version
            // rather than two entries disagreeing about one URL.
            pages[key(url)] = nil
            return nil
        }
        var touched = entry
        touched.lastUsedAt = Date()
        pages[key(url)] = touched
        return touched
    }

    @discardableResult
    func store(url: String, title: String, text: String) -> CachedPage {
        let entry = CachedPage(
            url: url,
            fingerprint: Self.fingerprint(text),
            title: title,
            text: text,
            summary: nil,
            readAt: Date(),
            lastUsedAt: Date())
        pages[key(url)] = entry
        evictIfNeeded()
        return entry
    }

    /// Keep what a turn concluded, for the next question about the same page.
    func rememberSummary(_ summary: String, url: String) {
        let trimmed = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, var entry = pages[key(url)] else { return }
        // Capped: a summary that grows to the size of the page defeats the point of keeping one.
        entry.summary = String(trimmed.prefix(1_200))
        entry.lastUsedAt = Date()
        pages[key(url)] = entry
    }

    /// What to send for this question about this page.
    ///
    /// First question: the compacted page. Later questions: the stored summary plus the passages
    /// this question matches — which is both cheaper and more on-point than the page's opening
    /// paragraphs, the part a naive truncation always keeps.
    func groundingText(url: String, query: String, limit: Int) -> String? {
        guard let entry = cached(url: url) else { return nil }
        guard let summary = entry.summary, !summary.isEmpty else {
            return MarkItDownService.compact(entry.text, for: query, limit: limit)
        }
        let passageBudget = max(400, limit / 2)
        let passages = MarkItDownService.compact(entry.text, for: query, limit: passageBudget)
        return """
            WHAT THIS PAGE IS (read earlier this conversation, unchanged since):
            \(summary)

            THE PART THIS QUESTION MATCHES:
            \(passages)
            """
    }

    func forget(url: String) { pages[key(url)] = nil }

    func removeAll() { pages.removeAll() }

    var count: Int { pages.count }

    private func key(_ url: String) -> String {
        url.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// Oldest use first. A conversation that keeps returning to one page keeps that page.
    private func evictIfNeeded() {
        guard pages.count > maximumPages else { return }
        let ordered = pages.sorted { $0.value.lastUsedAt < $1.value.lastUsedAt }
        for (key, _) in ordered.prefix(pages.count - maximumPages) {
            pages[key] = nil
        }
    }
}
