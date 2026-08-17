// ChatHistoryBudget.swift
// Context-Dock
//
// How much of a conversation goes back to the model, and what is said about the rest.
//
// Every provider path took `history.suffix(10)`. Two problems with a fixed count of turns.
//
// It is the wrong unit. Ten turns of "yes" costs nothing; ten turns each carrying a pasted
// stack trace is tens of thousands of tokens on top of a context block that is already the
// largest thing in the request — on a small local model that is the whole window, and the
// reply comes back empty or truncated with nothing saying why.
//
// And it lies by omission. A thread quietly forgets its own beginning: the user names a file
// in message two, asks about "that file" in message fifteen, and the model — which has been
// handed no trace that anything came before — answers as though the name was never given,
// confidently and wrongly. A model told that earlier turns exist can ask; a model shown a
// conversation that appears to start in the middle cannot know to.

import Foundation

enum ChatHistoryBudget {

    /// Characters of *conversation* a provider is given, separate from the retrieved context
    /// blocks AIContextBudget governs. Roughly a quarter of that budget: the question needs
    /// the reference material more than it needs the small talk, but a conversation with no
    /// memory is not a conversation.
    static func characterBudget(for provider: AIProvider) -> Int {
        max(1_000, AIContextBudget.characterBudget(for: provider) / 4)
    }

    /// The most turns to send however small they are. A very long exchange of one-liners is
    /// still an exchange the model does not need in full to answer the next one.
    private static let maximumTurns = 20

    /// The tail of a conversation that fits the budget, plus a note when anything was left
    /// out.
    ///
    /// Returned newest-last, as the providers expect. The note is a real message rather than
    /// a prompt addition so it travels the same path as the turns it describes — every
    /// adapter builds its message array differently, and a marker that only some of them
    /// carried would be worse than none.
    static func fit(
        _ history: [ChatMessage],
        provider: AIProvider,
        limit: Int? = nil
    ) -> [ChatMessage] {
        let budget = limit ?? characterBudget(for: provider)
        let usable = history.filter { $0.role != .system }
        guard !usable.isEmpty else { return [] }

        var kept: [ChatMessage] = []
        var used = 0
        for message in usable.reversed() {
            let cost = message.content.count + 16  // role, separators, framing
            // Always keep the most recent turn, whatever it costs: a request that drops the
            // thing the user just said is answering a different question.
            if !kept.isEmpty, used + cost > budget || kept.count >= maximumTurns { break }
            kept.append(message)
            used += cost
        }
        kept.reverse()

        let dropped = usable.count - kept.count
        guard dropped > 0 else { return kept }
        // Named as a system-role message; the adapters filter those out of the wire format,
        // so it is folded into the first user turn instead.
        let note = ChatMessage(
            role: .user,
            content:
                "[\(dropped) earlier message\(dropped == 1 ? "" : "s") in this conversation "
                + "are not included here. If the answer depends on something said earlier "
                + "that you cannot see, say so and ask rather than guessing.]")
        return [note] + kept
    }
}
