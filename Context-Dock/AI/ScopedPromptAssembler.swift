// ScopedPromptAssembler.swift
// Context-Dock
//
// The order the model reads a scoped prompt in, and what goes when it will not fit.
//
// The dock and the chat window each assembled their own. Same blocks, different order, and
// only one of them had a budget: the dock trimmed for Apple's on-device model because its
// window is small enough that the full inventory produced no token at all, while the window
// joined everything and sent it. So the same question on the same model answered in the dock
// and stalled in the window, and neither surface's ordering could be reasoned about without
// reading the other's.
//
// The blocks themselves stay surface-specific — the dock knows what is frontmost right now,
// the window knows what a thread is scoped to. What lives here is what to do with them.

import Foundation

/// A slot in the prompt. Declaration order is reading order: the model sees these top to
/// bottom, identity before evidence, evidence before reference material.
enum ScopedPromptSection: Int, CaseIterable, Comparable {
    /// Which source this question must be answered from.
    case sourceRule
    /// The resolved context — window, document, selection, page — with its gaps named.
    case resolvedContext
    /// Who the user is — their own written profile, the same in every conversation.
    ///
    /// Its own slot rather than a line of memory. Memory is replaced wholesale by the
    /// query-ranked block, so a profile appended into it was overwritten on every turn
    /// that was allowed to use memory at all; and memory is droppable under budget, which
    /// identity must not be.
    case userProfile
    /// Which app this conversation is, and what may be driven in it.
    case identity
    /// What the user is pointing at right now.
    case selection
    /// The project the app has open: branch, changes, running agents.
    case workspace
    /// The page a browser scope is on.
    case browserPage
    /// The folder a folder thread is about.
    case folder
    /// Files and captures attached to this message.
    case attachments
    /// Live Calendar / Reminders / Notes / Contacts data for a question that needs it.
    case liveAppData
    /// The app's MCP tools.
    case mcp
    /// The cross-app capability catalogue.
    case capabilities
    /// The user's own written workflows for this app.
    case skills
    /// What DoraX has durably learned.
    case memory
    /// The vendor's documentation.
    case reference
    /// Linked CLI tools and their help.
    case cli

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    /// What is never dropped, however tight the budget.
    ///
    /// Without identity and the resolved context the model does not know which app it is
    /// answering about, and an answer about the wrong app is worse than a short one.
    var isEssential: Bool {
        switch self {
        case .sourceRule, .resolvedContext, .userProfile, .identity, .selection: return true
        default: return false
        }
    }

    /// Order of sacrifice, least valuable first. Reference material goes first: the model can
    /// say it does not know, which is survivable, where being wrong about live state is not.
    static let dropOrder: [ScopedPromptSection] = [
        .reference, .cli, .memory, .skills, .capabilities, .mcp, .liveAppData,
        .attachments, .folder, .browserPage, .workspace,
    ]
}

struct ScopedPromptAssembler {

    /// Characters of prompt a provider can hold before the answer suffers.
    ///
    /// Not AIContextBudget: that one sizes a single retrieved document, and this is the whole
    /// prompt. On-device is 3 200 because that is the figure the dock arrived at by watching
    /// Apple's model stall — the full inventory (every menu path, every rule paragraph, whole
    /// help pages) overran its window and it produced no token at all, so the chat sat on an
    /// empty bubble until it timed out.
    static func budget(for provider: AIProvider) -> Int? {
        switch provider {
        case .onDevice: return 3_200
        case .ollama, .openAICompatible, .shortcuts: return 24_000
        case .anthropic, .openAI, .googleGemini, .kimi, .claudeBridge, .chatGPTBridge:
            // A cloud window is large enough that trimming costs more in answer quality than
            // it saves. The per-block budgets upstream already keep any one section sane.
            return nil
        }
    }

    /// Said out loud rather than left implicit: a model that knows a list is partial asks,
    /// and a model handed a silently cut list answers as though it were complete.
    static let shortenedNote = "\n… (shortened to fit this model's context; more exists)"

    private var blocks: [ScopedPromptSection: String] = [:]

    /// Cuts on a newline so a menu path, a flag or a JSON line is never left half-written.
    static func truncatedAtLineBoundary(_ text: String, limit: Int) -> String {
        guard text.count > limit else { return text }
        let head = String(text.prefix(limit))
        guard let lastBreak = head.lastIndex(of: "\n") else { return head }
        return String(head[head.startIndex..<lastBreak])
    }

    init() {}

    mutating func set(_ section: ScopedPromptSection, _ text: String?) {
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }
        blocks[section] = text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Appends to a slot rather than replacing it — several apps' identity blocks in a
    /// combined chat are all the same kind of thing and belong together.
    mutating func append(_ section: ScopedPromptSection, _ text: String?) {
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }
        if let existing = blocks[section] {
            blocks[section] =
                existing + "\n\n" + text.trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            set(section, text)
        }
    }

    /// The prompt, in reading order, trimmed to what this provider can hold.
    ///
    /// Sections are dropped whole. Half a menu list or a truncated JSON block is worse than
    /// its absence: the model reads a cut-off flag as a real one, and a list that stops
    /// mid-way reads as a complete list of fewer things.
    func assemble(
        for provider: AIProvider,
        preserving sourceSections: Set<ScopedPromptSection> = []
    ) -> String {
        var kept = blocks
        if let budget = Self.budget(for: provider) {
            var used = kept.values.reduce(0) { $0 + $1.count + 2 }
            for section in ScopedPromptSection.dropOrder where used > budget {
                guard !section.isEssential, !sourceSections.contains(section),
                    let text = kept[section]
                else { continue }
                kept.removeValue(forKey: section)
                used -= text.count + 2
            }
            // Still over with only the essentials left. This is not hypothetical: the
            // identity block carries up to fifty menu paths, and on Apple's on-device model
            // that alone can fill the window — at which point the model returns nothing at
            // all and the chat sits on an empty bubble.
            //
            // So the largest essential is shortened, on a line boundary, and says that it
            // was. A list the model knows is partial produces "I can see these commands,
            // there may be more"; a list silently cut produces a confident claim that the
            // app has no other commands.
            while used > budget,
                let (section, text) = kept
                    .filter({ $0.value.count > 200 && !sourceSections.contains($0.key) })
                    .max(by: { $0.value.count < $1.value.count })
            {
                let room = max(200, text.count - (used - budget) - Self.shortenedNote.count)
                let shortened = Self.truncatedAtLineBoundary(text, limit: room)
                    + Self.shortenedNote
                used -= text.count - shortened.count
                kept[section] = shortened
                if shortened.count >= text.count { break }
            }
            // If the selected evidence plus the irreducible identity still exceeds the
            // model window, shorten evidence last and visibly. Dropping it would leave the
            // model with tools but no facts — exactly the inverse of a question's needs.
            while used > budget,
                let (section, text) = kept
                    .filter({ $0.value.count > 200 })
                    .max(by: { $0.value.count < $1.value.count })
            {
                let room = max(200, text.count - (used - budget) - Self.shortenedNote.count)
                let shortened = Self.truncatedAtLineBoundary(text, limit: room)
                    + Self.shortenedNote
                used -= text.count - shortened.count
                kept[section] = shortened
                if shortened.count >= text.count { break }
            }
        }
        return ScopedPromptSection.allCases
            .compactMap { kept[$0] }
            .joined(separator: "\n\n")
    }
}
