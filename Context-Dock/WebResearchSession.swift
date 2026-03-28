// WebResearchSession.swift
// Context-Dock
//
// Accumulates page snapshots from multiple browser tabs so the user can
// ask AI questions that span several pages ("compare these two articles").

import Foundation
import Combine

@MainActor
final class WebResearchSession: ObservableObject {
    static let shared = WebResearchSession()
    private init() {}

    @Published private(set) var pages: [PageSnapshot] = []

    var isEmpty: Bool { pages.isEmpty }
    var count: Int    { pages.count }

    func addPage(_ snap: PageSnapshot) {
        guard !pages.contains(where: { $0.url == snap.url }) else { return }
        pages.append(snap)
    }

    func remove(at index: Int) {
        guard index < pages.count else { return }
        pages.remove(at: index)
    }

    func clear() { pages.removeAll() }

    /// System prompt block injected when multiple pages are in session.
    var contextBlock: String {
        guard pages.count > 1 else { return "" }
        var block = "\n\n## MULTI-PAGE RESEARCH SESSION (\(pages.count) pages)\n"
        block += "The user has added multiple pages for comparison. Answer by referencing all of them.\n\n"
        for (i, page) in pages.enumerated() {
            let label = page.title.isEmpty ? page.url : page.title
            block += "### Page \(i + 1): \(label)\n"
            block += "URL: \(page.url)\n"
            block += page.text + "\n\n"
        }
        return block
    }

    /// Single-page context block (used when only one page is in session).
    var singlePageBlock: String {
        guard let page = pages.first else { return "" }
        var block = "\n\n## CURRENT WEB PAGE\n"
        if !page.title.isEmpty { block += "Title: \(page.title)\n" }
        block += "URL: \(page.url)\n\n"
        block += "### Page Content:\n\(page.text)\n"
        block += "\nAnswer questions about this page based ONLY on the content above.\n"
        return block
    }
}
