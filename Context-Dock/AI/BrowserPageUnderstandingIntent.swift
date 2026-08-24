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

        let asksToUnderstand = [
            "understand", "summarize", "summarise", "explain", "tell me", "what is",
            "what does", "what it", "key points", "main points", "read", "analyse",
            "analyze", "compare", "extract", "find", "identify", "describe",
        ].contains(where: q.contains)
        return asksToUnderstand
    }
}
