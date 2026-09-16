//
//  CapabilityGap.swift
//  Context-Dock
//
//  What to say when the app is right and nothing it has can answer the question.
//
//  "I added Tutorine as an adapter; did I view any videos in it?" is a fair question with,
//  usually, no answer available: a hand-made adapter has *actions* — things to do — and
//  rarely a *reader*, something that can see what the app holds. DoraX knew that and said
//  nothing useful about it, so the model filled the silence.
//
//  An agent that cannot answer says what it looked at and what is missing. That is the
//  difference between an assistant and a guesser, and it is also the only reply that tells
//  the user what to change: this app needs a reader, and here is where they live.
//

import Foundation

enum CapabilityGap {

    /// A reply for a read question that the app's own capabilities cannot answer, or nil
    /// when something could plausibly answer it and the normal path should continue.
    ///
    /// `records` is the app's slice of the catalogue — actions, skills, commands,
    /// capabilities — and `menuCommands` the count of cached menu items, which are counted
    /// rather than listed because a warm cache holds hundreds.
    static func explain(
        appName: String,
        records: [CapabilityRecord],
        menuCommands: Int
    ) -> String? {
        // Something here reads. Let the normal path try it.
        guard !records.contains(where: { !$0.isWrite && $0.kind != .skill }) else { return nil }

        let inventory = describe(records: records, menuCommands: menuCommands)
        guard !inventory.isEmpty else {
            return "\(appName) is linked, but nothing is connected to it yet — no actions, "
                + "tools or menu commands. Add what it can do in Settings ▸ App Adapters ▸ "
                + "\(appName), and I can work with it from there."
        }

        return """
            I can't answer that from \(appName) yet. Here is what it has: \(inventory).

            All of those *do* things. Reading what \(appName) holds — history, items, \
            what you have opened — needs something that can see inside it: a context \
            reader, a linked CLI tool, or an MCP server, in Settings ▸ App Adapters ▸ \
            \(appName) ▸ Tools.

            I would rather tell you that than guess an answer about your own app.
            """
    }

    /// The counted inventory, in the order a person would care about it.
    private static func describe(records: [CapabilityRecord], menuCommands: Int) -> String {
        var parts: [String] = []
        func add(_ count: Int, _ singular: String, _ plural: String) {
            guard count > 0 else { return }
            parts.append("\(count) \(count == 1 ? singular : plural)")
        }
        add(records.filter { $0.kind == .adapterAction }.count, "action", "actions")
        add(records.filter { $0.kind == .capability }.count, "capability", "capabilities")
        add(records.filter { $0.kind == .cliTool }.count, "CLI tool", "CLI tools")
        add(records.filter { $0.kind == .mcpTool }.count, "MCP tool", "MCP tools")
        add(records.filter { $0.kind == .skill }.count, "skill", "skills")
        add(menuCommands, "menu command", "menu commands")
        return parts.joined(separator: ", ")
    }
}
