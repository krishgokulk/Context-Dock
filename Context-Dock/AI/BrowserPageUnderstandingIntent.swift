// BrowserPageUnderstandingIntent.swift
// Context-Dock
//
// A page-reading question is an answer task, not authority to operate the browser. Once a
// fresh snapshot is in the prompt, the provider must receive no action tools at all.

import Foundation

enum BrowserPageUnderstandingIntent {
    static func matches(_ query: String) -> Bool {
        let q = query.lowercased()
        let refersToPage = [
            "this page", "current page", "the page", "this article", "current article",
            "this website", "current website", "this site", "current site",
        ].contains(where: q.contains)
        guard refersToPage else { return false }

        // Naming another of the browser's stores makes this a library request, however much
        // it also mentions the page. "find this page in my bookmarks" matched on "this page"
        // and "find", and was routed to a path with no tools at all — where browser.bookmarks
        // cannot be reached, so the only outcomes were answering about the page instead or
        // reporting that the page could not be identified.
        //
        // Erring towards exclusion is deliberate. A page question wrongly given tools still
        // has browser.currentPage and can answer; a library request wrongly denied every tool
        // cannot do anything at all.
        let namesAnotherStore = [
            "bookmark", "history", "reading list", "downloads", "tabs", "favourites",
            "favorites",
        ].contains(where: q.contains)
        guard !namesAnotherStore else { return false }

        let asksToUnderstand = [
            "understand", "summarize", "summarise", "explain", "tell me", "what is",
            "what does", "what it", "key points", "main points", "read", "analyse",
            "analyze", "compare", "extract", "find", "identify", "describe",
        ].contains(where: q.contains)
        return asksToUnderstand
    }
}
