// SafariDeepContextStubs.swift
// Context-Dock
//
// Minimal stubs for Safari history/bookmarks context injection and
// the context app suggestions row — both features were removed from active use.

import SwiftUI

// MARK: - SafariDeepContextReader stub

final class SafariDeepContextReader {
    static let shared = SafariDeepContextReader()
    private init() {}

    func contextBlock(
        query: String,
        maxRecentHistory: Int,
        maxMatchedHistory: Int,
        maxBookmarks: Int,
        maxCharacters: Int
    ) -> String { "" }
}

// MARK: - ContextAppSuggestionsRow stub

struct ContextAppSuggestionsRow: View {
    let context: AppUserContext
    let onOpenWith: (DefaultAppResolver.DefaultApp) -> Void
    let onRunExtension: (ScriptExtension) -> Void

    var body: some View { EmptyView() }
}
