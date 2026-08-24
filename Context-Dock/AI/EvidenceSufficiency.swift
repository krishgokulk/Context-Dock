// EvidenceSufficiency.swift
// Context-Dock
//
// "I can't tell from what I have" is a request for another round, not an answer.
//
// Asked who they message most, the turn ran `imsg chats --limit 12`, got back a list where
// most rows had no contact name, and stopped: "I can't tell reliably from the data available
// here." Every part of that is true and the turn had three rounds left, a larger limit it
// could have asked for, a contacts capability that resolves handles to names, and no reason
// to stop except that nothing told it to keep going.
//
// That is the shape of the whole complaint. The loop continues only while the model keeps
// choosing to call tools; the moment it writes prose, the turn is over. So a model that gives
// up early is never argued with, and DoraX reads as incurious even when the evidence it
// needed was one call away.
//
// This spots the giving-up and sends it back once, with what it has not tried yet.

import Foundation

enum EvidenceSufficiency {

    /// Phrases that mean "I did not find out", as opposed to "the answer is no".
    ///
    /// The distinction matters: "you have no meetings tomorrow" is a finding, and pushing back
    /// on it would make the assistant argue with itself. "I can't tell" is an absence of
    /// finding, and it is the only thing worth retrying.
    private static let admissions = [
        "i can't tell", "i cannot tell", "can't tell reliably", "i can't see",
        "i cannot see", "isn't available in the current context",
        "is not available in the current context", "no readable description",
        "i don't have access", "i do not have access", "not enough information",
        "insufficient information", "can't determine", "cannot determine",
        "unable to determine", "doesn't include", "does not include a verified",
        "i can't confirm", "cannot confirm", "no data available", "i don't have that",
    ]

    /// True when the answer admits it did not find out, rather than reporting what it found.
    static func admitsDefeat(_ answer: String) -> Bool {
        let text = answer.lowercased()
        guard !text.isEmpty else { return true }
        return admissions.contains { text.contains($0) }
    }

    /// Whether this turn is worth pushing once more.
    ///
    /// Only when there is somewhere left to look: rounds remaining, and at least one tool
    /// that has not been tried. Retrying a turn that has already exhausted its sources just
    /// spends the user's tokens to be told the same thing twice.
    static func shouldRetry(
        answer: String, executed: [AIProviderService.ExecutedCommand], roundsAllowed: Int
    ) -> Bool {
        guard admitsDefeat(answer) else { return false }
        // A turn that never called anything is the clearest case: it decided from the prompt
        // alone that it could not know, without looking.
        guard executed.count < roundsAllowed else { return false }
        return true
    }

    /// The nudge. Names what was already run so the model does not repeat it, and points at
    /// the kinds of source it has not touched.
    static func retryPrompt(
        query: String, answer: String, executed: [AIProviderService.ExecutedCommand]
    ) -> String {
        let tried = executed.isEmpty
            ? "You called nothing at all."
            : "Already run (do not repeat these exactly):\n"
                + executed.map { "- \($0.command)" }.joined(separator: "\n")

        return """
            You told the user: "\(answer.prefix(300))"

            That is an admission that you did not find out, not an answer. You have tools and \
            rounds left, so look before you conclude.

            \(tried)

            Try a DIFFERENT approach to: \(query)

            Widen a limit that was too small, ask a different tool for the same fact, resolve \
            identifiers to names with find_capability, read a file or page you have only seen \
            named, or use find_route to see what the app itself can do. If a source came back \
            partial, say what it did show and what is missing — a partial finding beats \
            "I can't tell".

            If you genuinely cannot reach the fact, say precisely which source failed and what \
            the user would have to enable, rather than declining in general terms.
            """
    }
}
