//
//  AppKnowledgeSkill.swift
//  Context-Dock
//
//  What DoraX knows about an app, learned from the app instead of from a template.
//
//  Step 1 of docs/architecture/APP_KNOWLEDGE_SKILLS.md. An app's Help menu is a
//  vendor-authored index of what the product is — "Documentation", "Show All Commands",
//  "Keyboard Shortcuts Reference", "Ask @vscode" — and it is already sitting in
//  AppMenuCapabilityCache. Reading those titles opens nothing, which is the point: a menu
//  is a way to *do* something and was never a way to *know* something.
//
//  A Safari chat once answered "hi hello" by opening Edit ▸ Extension Actions, because a
//  page read had to drive the menu bar to reach its extension. That is fixed, but the
//  habit it came from is the one this replaces: stop interrogating the UI, and read what
//  the app has already told us.
//
//  The result is one AdapterSkill per app. That type already exists and already fits —
//  per bundle id, instructions only, never executes anything, versioned, user-editable —
//  and ChatRoute.Kind.skill already routes to it.
//

import Foundation

enum AppKnowledgeSkill {

    /// What DoraX can actually do in this app. Stated plainly so the model spends its
    /// effort on the user's sentence rather than on guessing what it has to hand.
    struct Capabilities: Equatable {
        var actions: Int
        var cliTools: Int
        var skills: Int
        var menuCommands: Int
        var mcpServers: Int
        var apiConnections: Int

        var total: Int {
            actions + cliTools + skills + menuCommands + mcpServers + apiConnections
        }
    }

    /// Stable per app, so a refresh replaces the learned skill rather than adding another
    /// one beside it every time the app updates.
    static func id(for bundleId: String) -> String { "app-knowledge.\(bundleId)" }

    static func make(
        bundleId: String,
        appName: String,
        version: String,
        helpTitles: [String],
        capabilities: Capabilities
    ) -> AdapterSkill? {
        let topics = cleanedTopics(helpTitles)
        // Nothing learned and nothing granted: a skill of empty headings is worse than no
        // skill, because it takes room in the prompt and says nothing.
        guard !topics.isEmpty || capabilities.total > 0 else { return nil }

        var body = """
            You are working inside \(appName)\(version.isEmpty ? "" : " (version \(version))").

            """

        if capabilities.total > 0 {
            body += "\nWhat you can actually do here:\n"
            // Only what exists. "0 MCP servers" reads as an offer; an absent line does not.
            let lines: [(Int, String)] = [
                (capabilities.actions, "adapter actions"),
                (capabilities.cliTools, "linked CLI tools"),
                (capabilities.skills, "saved workflows"),
                (capabilities.menuCommands, "known menu commands"),
                (capabilities.mcpServers, "MCP servers"),
                (capabilities.apiConnections, "API connections"),
            ]
            for (count, label) in lines where count > 0 {
                body += "- \(count) \(label)\n"
            }
        }

        if !topics.isEmpty {
            body += """

                What \(appName) says about itself, from its own Help menu. Treat this as the
                app's documented surface — the subjects it has help for are the subjects it
                is about:

                """
            for topic in topics { body += "- \(topic)\n" }
        }

        body += """

            Answer about \(appName) from this and from what the user asked. Do not open
            menus to find something out; menus are for carrying out an action the user
            asked for. If the answer needs something not listed above, say what is missing
            rather than guessing.
            """

        return AdapterSkill(
            id: id(for: bundleId),
            adapterBundleId: bundleId,
            name: "\(appName) — what this app is",
            summary: topics.isEmpty
                ? "Learned from \(appName)'s registered capabilities"
                : "Learned from \(appName)'s Help menu and registered capabilities",
            instructions: body,
            // The app's version, not the skill's: it refreshes when the app updates and
            // never in between, so a user's edits are not overwritten on every launch.
            version: version.isEmpty ? "1.0" : version)
    }

    /// Titles worth keeping. Separators and blanks are menu structure, not knowledge, and
    /// the same subject listed twice is still one subject.
    private static func cleanedTopics(_ titles: [String]) -> [String] {
        var seen = Set<String>()
        var kept: [String] = []
        for raw in titles {
            let title = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard title.count > 1, title != "-", title.first != "-" else { continue }
            let key = title.lowercased()
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            kept.append(title)
            if kept.count == 25 { break }
        }
        return kept
    }
}
