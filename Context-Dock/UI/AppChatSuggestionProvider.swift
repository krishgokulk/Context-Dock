// AppChatSuggestionProvider.swift
// Context-Dock
//
// What the App Chat prompt offers before the user has typed anything.
//
// The suggestions are read from what the app has actually cached, never invented: menu
// actions come from AppMenuCapabilityCache, which is the same snapshot the dock's own
// menu routing uses. The summary line counts only what can be counted — an app with no
// cached menu yet gets a short line or none, rather than a confident number nobody
// measured.

import AppKit
import Foundation

@MainActor
enum AppChatSuggestionProvider {
    /// Top of the list: the actions this app exposes right now.
    static func suggestions(for app: NSRunningApplication?, limit: Int = 3)
        -> [AppChatSuggestion]
    {
        guard let app, let bundleID = app.bundleIdentifier else { return [] }
        let commands = AppMenuCapabilityCache.shared.menuItems(for: app, maxResults: limit * 4)
        let actions = AppAdapterManager.shared.adapter(for: bundleID)?
            .actions.filter { !$0.name.isEmpty } ?? []
        return suggestions(commands: commands, actions: actions, limit: limit)
    }

    /// The resting offer is the useful front page of an app scope, not the app's raw menu
    /// order. Generic About/Help/Quit rows remain searchable after the user types, but they
    /// should not consume one of the three opening suggestions.
    static func suggestions(
        commands: [AXMenuItem], actions: [AdapterAction], limit: Int
    ) -> [AppChatSuggestion] {
        AppChatRowRanker.rank(
            commands: commands,
            actions: actions,
            query: "",
            limit: limit,
            policy: .globalContext
        ).map { row in
            AppChatSuggestion(icon: "bolt.fill", title: row.title, kind: .action)
        }
    }

    /// "5 actions · 2 skills" — only the parts that were actually counted, and only about
    /// this app. `SystemCommandsRegistry` is macOS's own always-on commands (Wi-Fi, volume,
    /// sleep) — the same fixed count regardless of which app is scoped — and it used to be
    /// folded into this line as if it were part of what the app itself offered, so a Terminal
    /// summary and a Safari summary quoted the identical "commands" number by coincidence.
    /// A missing count is left out rather than shown as zero, because "0 skills" reads as
    /// a measured fact and this is an absent one.
    static func summary(for app: NSRunningApplication?) -> String {
        guard let app, let bundleID = app.bundleIdentifier else { return "" }
        let actions = AppAdapterManager.shared.actions(for: bundleID)
            .filter { $0.type != .aiPrompt }.count
        let skills = SkillStore.shared.skills(for: bundleID).filter(\.isEnabled).count
        let builtInTools = CapabilityRegistry.shared.all.filter {
            $0.appBundleID?.caseInsensitiveCompare(bundleID) == .orderedSame
        }.count
        let cliTools = ScopedGroundingBlocks.runnableCommandBinaries(
            forBundleId: bundleID).count

        return summary(
            actions: actions,
            skills: skills,
            builtInTools: builtInTools,
            cliTools: cliTools)
    }

    static func summary(
        actions: Int, skills: Int, builtInTools: Int, cliTools: Int
    ) -> String {
        var parts: [String] = []
        if actions > 0 { parts.append(pluralised(actions, "action")) }
        if skills > 0 { parts.append(pluralised(skills, "skill")) }
        if builtInTools > 0 { parts.append(pluralised(builtInTools, "built-in tool")) }
        if cliTools > 0 { parts.append(pluralised(cliTools, "CLI tool")) }
        return parts.joined(separator: " · ")
    }

    private static func pluralised(_ count: Int, _ noun: String) -> String {
        "\(count) \(noun)\(count == 1 ? "" : "s")"
    }
}
