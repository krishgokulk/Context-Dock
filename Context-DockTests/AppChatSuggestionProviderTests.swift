// AppChatSuggestionProviderTests.swift
// Context-DockTests

import ApplicationServices
import Testing

@testable import Context_Dock

@MainActor
private func suggestionMenuItem(_ title: String, path: [String]) -> AXMenuItem {
    AXMenuItem(
        title: title, path: path, isEnabled: true,
        element: AXUIElementCreateSystemWide(), children: [])
}

@Suite("App chat opening suggestions")
@MainActor
struct AppChatSuggestionProviderTests {

    @Test("Opening suggestions use ranked useful commands instead of cache order")
    func openingSuggestionsUseTheSharedRanker() {
        let suggestions = AppChatSuggestionProvider.suggestions(
            commands: [
                suggestionMenuItem(
                    "About Visual Studio Code",
                    path: ["Visual Studio Code", "About Visual Studio Code"]),
                suggestionMenuItem("Open…", path: ["File", "Open…"]),
                suggestionMenuItem("Copy", path: ["Edit", "Copy"]),
                suggestionMenuItem("Toggle Terminal", path: ["View", "Toggle Terminal"]),
            ],
            actions: [],
            limit: 3)

        #expect(suggestions.map(\.title) == ["Open…", "Copy", "Toggle Terminal"])
    }

    @Test("Capability summary names only positive counts that were measured")
    func capabilitySummaryUsesTruthfulCategories() {
        let populated = AppChatSuggestionProvider.summary(
            actions: 5,
            skills: 2,
            builtInTools: 1,
            cliTools: 3)
        let empty = AppChatSuggestionProvider.summary(
            actions: 0,
            skills: 0,
            builtInTools: 0,
            cliTools: 0)

        #expect(populated == "5 actions · 2 skills · 1 built-in tool · 3 CLI tools")
        #expect(empty.isEmpty)
    }
}
