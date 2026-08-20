//
//  ConversationDistiller.swift
//  Context-Dock
//
//  Turns conversations into durable facts, without a model.
//
//  Memory only ever grew when the user typed "remember that". Everything else they said
//  about themselves — which tools they use, how they want things done, what they are
//  working on — was in the transcript and nowhere else, so it left with the thread.
//
//  The obvious way to fix that is to ask a model to summarise each conversation into
//  facts. This does not, for one reason: a summary is generated text, and generated text
//  about a person is exactly where an invented detail does the most damage. A wrong fact
//  here is not a bad answer once, it is a bad premise in front of every future answer,
//  written in a file the user has no reason to re-read.
//
//  So this only ever copies the user's own sentences, verbatim, when they match a small
//  set of first-person patterns. It cannot paraphrase and it cannot infer, which means the
//  worst case is a sentence that did not need keeping rather than a claim never made. Every
//  line carries where it came from, so anything odd can be traced and deleted.
//

import Foundation

enum ConversationDistiller {
    /// Openings that make a sentence a durable statement about the user rather than a
    /// request. "open safari" is a command; "i always use safari" is a fact.
    private static let patterns: [String] = [
        "i prefer ", "i always ", "i never ", "i usually ", "i use ", "i work ",
        "i am working on ", "i'm working on ", "my name is ", "call me ",
        "i don't like ", "i do not like ", "i like ",
    ]

    /// Long enough to say something, short enough to be one fact rather than a paragraph.
    private static let minLength = 12
    private static let maxLength = 180
    /// A cap per pass, so one talkative day cannot flood the file.
    private static let maxPerRun = 8

    @MainActor
    static func distillRecentConversations() {
        let sessions = GeneralChatSessionStore.index()
        let cutoff = Calendar.current.date(byAdding: .day, value: -2, to: Date()) ?? Date()

        var candidates: [(fact: String, source: String)] = []
        for session in sessions where session.updatedAt >= cutoff && session.messageCount > 0 {
            for message in GeneralChatSessionStore.load(scope: session.scope)
            where message.role == .user && message.timestamp >= cutoff {
                for sentence in sentences(in: message.content) {
                    guard let fact = durableStatement(sentence) else { continue }
                    candidates.append((fact, session.title))
                }
            }
        }

        guard !candidates.isEmpty else { return }
        MarkdownMemoryStore.shared.appendDistilled(Array(candidates.prefix(maxPerRun)))
    }

    // MARK: - Extraction

    private static func sentences(in text: String) -> [String] {
        text.split(whereSeparator: { $0 == "." || $0 == "\n" || $0 == "!" || $0 == "?" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }

    /// The sentence itself if it is a first-person statement worth keeping, else nil.
    private static func durableStatement(_ sentence: String) -> String? {
        let lower = sentence.lowercased()
        guard lower.count >= minLength, lower.count <= maxLength else { return nil }
        guard patterns.contains(where: lower.hasPrefix) else { return nil }
        // A question is not a statement, however it starts.
        guard !lower.hasSuffix("?") else { return nil }
        // Anything with a path, a URL or code in it is a request about a thing, not a fact
        // about the person — and it dates badly.
        guard !sentence.contains("/"), !sentence.contains("`"), !sentence.contains("http")
        else { return nil }
        return sentence
    }
}
