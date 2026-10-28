// SolvedSkillCapture.swift
// Context-Dock
//
// The one place a turn is judged worth keeping as a solved skill.
//
// §6.3's rules are enforced here, each as a guard that returns rather than saving. The point
// is conservatism: a skill that is never captured costs one model call next time; a skill
// captured from an unverified or untrusted turn would replay a wrong answer with no model in
// the loop to catch it. So every doubt fails closed.
//
// The parameterization is deterministic in v1 — a token after "from" is the sender, a day
// word is the day. §6.3 rule 8 reserves on-device inference for later; this is the fallback
// that ships first, and it is pure so the capture logic is testable without a provider.

import Foundation

enum SolvedSkillCapture {

    // MARK: - Eligibility (pure)

    /// Builds the skill a turn earned, or nil if any rule rejects it. Pure, so the whole
    /// decision is drivable from a synthesized `Answer` with no provider or disk.
    nonisolated static func build(
        query: String,
        answer: AppScopedChatService.Answer,
        toolCalls: [SolvedSkillToolCall],
        bundleId: String,
        verifiedReadBack: Bool
    ) -> SolvedSkill? {
        // rule 1: a verified read-back this turn, and nothing that failed.
        guard verifiedReadBack,
            !answer.evidenceReceipts.contains(where: { !$0.success })
        else { return nil }

        // rule 3: nothing shaped by untrusted text is auto-saved. A fence in any receipt's
        // output, or in the answer itself, means the turn read email or a web page — the skill
        // could be the attacker's, not the user's.
        guard !UntrustedContent.containsFence(answer.text),
            !answer.evidenceReceipts.contains(where: { UntrustedContent.containsFence($0.output) })
        else { return nil }

        // rule 4: auto-save reads only. A write gates every run, so it is out of this slice;
        // one non-read-only call, or no call at all, and nothing is saved.
        guard !toolCalls.isEmpty, toolCalls.allSatisfy(\.isReadOnly) else { return nil }

        // rule 2: a parameterized skill, never a hard-coded one. Lift the entity values into
        // slots; a query that carries an entity but yields no slot would save a literal, so it
        // is rejected rather than kept.
        guard let derived = derive(query: query), !derived.slots.isEmpty else { return nil }

        let parameterized = toolCalls.map { call -> SolvedSkillToolCall in
            var template = call.argTemplate
            for (slot, value) in derived.values {
                template = template.mapValues {
                    $0.replacingOccurrences(of: value, with: "{\(slot)}", options: [.caseInsensitive])
                }
            }
            return SolvedSkillToolCall(
                capability: call.capability, argTemplate: template, isReadOnly: call.isReadOnly)
        }

        // rule 2, second half: EVERY slot must reach the calls. A slot whose token landed in no
        // input (the model baked "today" into a concrete date) is a frozen value, and the skill
        // would replay one answer forever.
        guard derived.slots.allSatisfy({ slot in
            parameterized.contains { $0.argTemplate.values.contains { $0.contains("{\(slot.name)}") } }
        }) else { return nil }

        return SolvedSkill(
            queryTemplate: derived.template,
            nonSlotWords: derived.nonSlotWords,
            slots: derived.slots,
            toolCalls: parameterized,
            bundleId: bundleId)
    }

    // MARK: - Capture (wired)

    @MainActor
    static func captureIfEligible(
        query: String,
        scope: GeneralChatScope,
        answer: AppScopedChatService.Answer,
        toolCalls: [SolvedSkillToolCall]
    ) {
        guard case .app(let bundleId) = scope, !bundleId.isEmpty else { return }
        guard let skill = build(
            query: query, answer: answer, toolCalls: toolCalls, bundleId: bundleId,
            verifiedReadBack: SolvedSkillToolCallCollector.shared.hadVerifiedReadBack(scope: scope))
        else { return }
        SolvedSkillStore.shared.save(skill)
    }

    // MARK: - Deterministic slot derivation (pure)

    /// The days a request can name.
    // Only today/yesterday reach a date filter in mail.search (MailAutomation.swift:534); widen when the read resolves more.
    private static let dayWords: Set<String> = ["today", "yesterday"]

    /// Words that look capitalized but open sentences, so a leading one is not an entity on
    /// its own. Kept tiny; the leading-word rule does most of the work.
    private static let sentenceStarters: Set<String> = [
        "show", "list", "find", "get", "check", "what", "which", "who", "when", "any",
    ]

    /// Lifts a request's entity values into `{slot}` tokens.
    ///
    /// Returns the templated query, the remaining words (normalized like `commandWords`, which
    /// is what matching compares), the slots in a fixed order, and the concrete values that
    /// filled them. Nil only for an empty query; an entity-bearing query with no slot returns a
    /// slot-less result, which `build` rejects under rule 2.
    nonisolated static func derive(query: String)
        -> (template: String, nonSlotWords: Set<String>, slots: [SolvedSkillSlot],
            values: [String: String])?
    {
        let tokens = query.split { $0 == " " || $0 == "\t" || $0 == "\n" }.map(String.init)
        guard !tokens.isEmpty else { return nil }
        let words = tokens.map(trimmed)

        var values: [String: String] = [:]

        // sender: the token after "from", else a capitalized proper noun that is not the
        // first word (where capitalization is only sentence case).
        if let fromIndex = words.firstIndex(where: { $0.lowercased() == "from" }),
            fromIndex + 1 < words.count, !words[fromIndex + 1].isEmpty
        {
            values["sender"] = words[fromIndex + 1]
        } else if let index = words.indices.dropFirst().first(where: { isProperNoun(words[$0]) }) {
            values["sender"] = words[index]
        }

        // day: today or yesterday.
        if let day = words.first(where: { isDayWord($0) }) {
            values["day"] = day
        }

        // Fixed slot order, so the same request always yields the same skill.
        let slots = ["sender", "day"]
            .filter { values[$0] != nil }
            .map { SolvedSkillSlot(name: $0, tokenFamily: $0) }

        let template = words.map { word -> String in
            if let (name, _) = values.first(where: { $0.value == word }) { return "{\(name)}" }
            return word
        }.joined(separator: " ")

        let slotValues = Set(values.values)
        let remaining = words.filter { !slotValues.contains($0) }.joined(separator: " ")
        let nonSlotWords = ExactCommand.commandWords(remaining)

        return (template, nonSlotWords, slots, values)
    }

    private nonisolated static func trimmed(_ token: String) -> String {
        token.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
    }

    private nonisolated static func isDayWord(_ word: String) -> Bool {
        dayWords.contains(word.lowercased())
    }

    private nonisolated static func isProperNoun(_ word: String) -> Bool {
        guard word.count >= 2, let first = word.first, first.isUppercase else { return false }
        guard word.contains(where: \.isLetter) else { return false }
        return !sentenceStarters.contains(word.lowercased())
    }
}
