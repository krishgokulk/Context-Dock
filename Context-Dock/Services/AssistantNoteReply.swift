//
//  AssistantNoteReply.swift
//  Context-Dock
//
//  Whether a reply from the model belongs in the user's note, or belongs to the
//  conversation about it.
//
//  `show me my saved notes` returned, among five, a refusal DoraX had produced —
//  "I can't see or access your current Safari page — I only work with your notes here" —
//  filed as something the user wrote, and retrievable later as if they had. Beside it on
//  disk: "⚠️ AI error: Configure a Shortcut in AI Settings first.", with a screenshot
//  attached to it.
//
//  The Notepad's ask-AI action appends whatever comes back into the note text and saves
//  it, and the memory mirror then treats that file as the user's own note. `QuickNote`
//  already states the invariant this broke, in the comment on `chatMessages`: the sidecar
//  conversation is separate from `text` so "an AI answer never overwrites or pollutes the
//  editable note".
//
//  Writing a note IS the point of that action, so the rule cannot be "no AI text in
//  notes". It is narrower: an error or a refusal is the assistant talking about itself,
//  and belongs in the sidecar with the rest of the conversation.
//

import Foundation

enum AssistantNoteReply {

    /// Verbs that describe what the assistant can or cannot *do*. First person alone is
    /// not the signal — "I can't stop thinking about the launch date" is a note somebody
    /// asked for, and dropping it would silently lose work.
    private static let abilityVerbs: Set<String> = [
        "see", "access", "read", "open", "run", "execute", "undo", "browse", "view",
        "reach", "retrieve", "fetch", "search", "control", "modify", "delete", "send",
        "provide", "generate", "create", "assist", "interact",
    ]

    /// Openings that mean the reply is about the assistant rather than about anything the
    /// user wanted written down.
    private static let inabilityOpenings = [
        "i can't", "i cannot", "i can not", "i'm unable", "i am unable", "i'm not able",
        "i am not able", "i don't have", "i do not have",
    ]

    /// Openings that are an apology however the sentence continues. An apology is not a
    /// note wherever it lands.
    private static let apologyOpenings = [
        "i'm sorry", "i am sorry", "sorry,", "sorry —", "sorry -", "sorry.",
        "unfortunately, i", "unfortunately i",
    ]

    /// True when this reply is content for the note. False when it is an error, a refusal,
    /// or nothing at all — those go to the note's sidecar conversation instead.
    static func isNoteContent(_ reply: String) -> Bool {
        let trimmed = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        // Errors are produced by DoraX itself, never by the model, and are never content.
        if trimmed.hasPrefix("⚠️") { return false }

        let opening = String(trimmed.prefix(240)).lowercased()
        if apologyOpenings.contains(where: { opening.hasPrefix($0) }) { return false }
        guard inabilityOpenings.contains(where: { opening.hasPrefix($0) }) else { return true }

        // Only the sentence the reply opens with: a meeting summary that mentions what an
        // API cannot do halfway down is still a meeting summary.
        let firstSentence = opening
            .split(whereSeparator: { ".!?\n".contains($0) })
            .first.map(String.init) ?? opening
        // Whole words, not substrings. "already" contains "read" and "review" contains
        // "view" — matched loosely, an ordinary note that opens "I can't review this
        // until Friday" would be thrown away as a refusal.
        let words = Set(
            firstSentence
                .split { !$0.isLetter }
                .map(String.init))
        return words.isDisjoint(with: abilityVerbs)
    }
}
