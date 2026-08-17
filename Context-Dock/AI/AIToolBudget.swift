// AIToolBudget.swift
// Context-Dock
//
// How many tools a model is shown at once.
//
// The existing budget counts characters of prompt text — the capability block is
// trimmed to fit — but the tool schemas ride alongside it uncounted, and every one of
// them costs context whether or not the question could ever use it. Apple's on-device
// model has room for a handful; a user with three MCP servers connected can be handing
// a 4K window forty tool definitions before the question is even read.
//
// Fewer, better-chosen tools also produce better calls. A model shown forty tools picks
// the wrong one more often than a model shown six, cloud or local — the cost of a long
// list is paid twice.
//
// The indirection is what makes a short list sufficient: find_capability and
// run_capability stay in every list, so anything trimmed is still one lookup away
// instead of unreachable.

import Foundation

enum AIToolBudget {
    /// Tools that are never trimmed.
    ///
    /// The first two are the way back to everything else, so cutting them would make the
    /// trim lossy rather than lazy. The rest are the loop's own machinery: a model that
    /// cannot run a command or read back what it did is not an agent.
    static let essentials: Set<String> = [
        "find_capability",
        "run_capability",
        "run_command",
        "verify_outcome",
    ]

    /// How many tool definitions this provider should carry.
    ///
    /// On-device is not a smaller cloud model: its window is measured in a few thousand
    /// tokens, where a dozen schemas is a material fraction of the budget before the
    /// conversation starts.
    static func maxTools(for provider: AIProvider) -> Int {
        switch provider {
        case .onDevice: return 8
        default: return 40
        }
    }

    /// The tools worth showing for this question, most relevant first.
    ///
    /// Scored on the words the question actually uses. A tool whose name matches counts
    /// for more than one whose description mentions the term in passing, since a name is
    /// what the model matches on when it chooses.
    static func trim(
        _ tools: [[String: Any]],
        query: String,
        provider: AIProvider
    ) -> [[String: Any]] {
        let limit = maxTools(for: provider)
        guard tools.count > limit else { return tools }

        let terms = Set(
            query.lowercased()
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { $0.count > 2 }
        )

        var kept: [[String: Any]] = []
        var scored: [(score: Int, index: Int, tool: [String: Any])] = []

        for (index, tool) in tools.enumerated() {
            let name = toolName(tool)
            if essentials.contains(name) {
                kept.append(tool)
                continue
            }
            guard !terms.isEmpty else {
                scored.append((0, index, tool))
                continue
            }
            let haystackName = name.replacingOccurrences(of: "_", with: " ").lowercased()
            let description = toolDescription(tool).lowercased()
            var score = 0
            for term in terms {
                if haystackName.contains(term) { score += 3 }
                if description.contains(term) { score += 1 }
            }
            scored.append((score, index, tool))
        }

        // Ties keep their original order, so a list with no matching terms is the first N
        // rather than an arbitrary N.
        let remaining = limit - kept.count
        guard remaining > 0 else { return kept }
        let ranked = scored
            .sorted { $0.score != $1.score ? $0.score > $1.score : $0.index < $1.index }
            .prefix(remaining)
            .map(\.tool)

        return kept + ranked
    }

    // MARK: - Reading the three schema shapes

    /// The schemas are already rendered per provider by the time they reach here, so the
    /// name lives in a different place in each. Reading all three keeps the budget from
    /// caring which provider it is trimming for.
    static func toolName(_ tool: [String: Any]) -> String {
        if let function = tool["function"] as? [String: Any],
            let name = function["name"] as? String
        {
            return name  // OpenAI
        }
        if let name = tool["name"] as? String { return name }  // Anthropic
        if let declarations = tool["functionDeclarations"] as? [[String: Any]],
            let name = declarations.first?["name"] as? String
        {
            return name  // Gemini
        }
        return ""
    }

    static func toolDescription(_ tool: [String: Any]) -> String {
        if let function = tool["function"] as? [String: Any],
            let description = function["description"] as? String
        {
            return description
        }
        if let description = tool["description"] as? String { return description }
        if let declarations = tool["functionDeclarations"] as? [[String: Any]],
            let description = declarations.first?["description"] as? String
        {
            return description
        }
        return ""
    }
}
