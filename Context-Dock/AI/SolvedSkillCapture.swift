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
// Slot derivation (H0) is deterministic and context-aware:
//   1. Context slots first ({file}, {files}, {selection}, {app}) — from the turn's context.
//   2. Word slots second ({day} everywhere; {sender} only in Mail/Messages scopes).
//   3. A remaining proper noun or path that is neither a slot nor a route word blocks the save.
//
// §6.3 rule 8 reserves on-device inference for later; deterministic derivation ships first,
// and it is pure so the capture logic is testable without a provider.

import Foundation

// MARK: - Turn context for slot derivation

/// The turn's concrete context, used to identify what "this", "it", "these" refer to and
/// to populate context slots ({file}, {files}, {selection}, {app}) before the word-based
/// slots are considered. Pure value; callers populate what they know.
struct SlotDerivationContext: Equatable {
    var selectedText: String? = nil
    /// Absolute or relative paths to the selected or attached files.
    var selectedFilePaths: [String] = []
    /// Localised display name of the frontmost app (e.g. "Mail", "Finder").
    var appName: String? = nil

    static let empty = SlotDerivationContext()

    /// Basenames without extension for each selected file, lowercased.
    var fileBasenames: [String] {
        selectedFilePaths.map {
            URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent.lowercased()
        }
    }

    /// Lowercased last path components (name + extension) for each selected file.
    var fileLastComponents: [String] {
        selectedFilePaths.map { URL(fileURLWithPath: $0).lastPathComponent.lowercased() }
    }
}

// MARK: -

enum SolvedSkillCapture {

    // MARK: - Eligibility (pure)

    /// Builds the skill a turn earned, or nil if any rule rejects it. Pure, so the whole
    /// decision is drivable from a synthesized `Answer` with no provider or disk.
    nonisolated static func build(
        query: String,
        answer: AppScopedChatService.Answer,
        toolCalls: [SolvedSkillToolCall],
        bundleId: String,
        verifiedReadBack: Bool,
        context: SlotDerivationContext = .empty
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

        // Identify menu-command-only turns (rung 3): at least one run_menu_command alongside
        // at most read-only supporting calls (adapter helpers that are not replay targets).
        // The app-pet's Finder/etc. adapter may dispatch read capabilities before or after the
        // menu press; those reads belong to the adapter, not the replay, so they are stripped.
        let menuCalls = toolCalls.filter { $0.capability == "run_menu_command" }
        let isMenuCommandOnly = !menuCalls.isEmpty
            && toolCalls.allSatisfy { $0.capability == "run_menu_command" || $0.isReadOnly }
        // For menu-command-only turns, replay just the menu commands; supporting reads are
        // adapter internals and must not appear in the saved skill.
        let replayCalls = isMenuCommandOnly ? menuCalls : toolCalls

        // rule 4: auto-save reads only. A write gates every run, so it is out of this slice;
        // one non-read-only call, or no replay call at all, and nothing is saved.
        guard !replayCalls.isEmpty, replayCalls.allSatisfy(\.isReadOnly) else { return nil }

        // rule 2: a parameterized skill, never a hard-coded one. Lift the entity values into
        // slots; a query that carries an entity but yields no slot would save a literal, so it
        // is rejected rather than kept. A leftover-value (a proper noun or path remaining after
        // slot extraction that is neither a slot nor a route word) is also a rejection.
        // Exception: a menu-command-only turn (rung 3) has no entity slots by design — the path
        // is fixed and self-describing — so the slot requirement is waived for those turns.
        guard let derived = derive(query: query, bundleId: bundleId, context: context),
            (isMenuCommandOnly || !derived.slots.isEmpty),
            (isMenuCommandOnly || !derived.hasLeftoverValue)
        else { return nil }

        let parameterized = replayCalls.map { call -> SolvedSkillToolCall in
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
        toolCalls: [SolvedSkillToolCall],
        context: SlotDerivationContext = .empty
    ) {
        guard case .app(let bundleId) = scope, !bundleId.isEmpty else { return }
        guard let skill = build(
            query: query, answer: answer, toolCalls: toolCalls, bundleId: bundleId,
            verifiedReadBack: SolvedSkillToolCallCollector.shared.hadVerifiedReadBack(scope: scope),
            context: context)
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

    /// Bundle IDs where {sender} is a meaningful slot. Proper nouns in other scopes are
    /// not recipients and must not be parameterised as senders (§8 rule 3, H0).
    private static let senderScopeIds: Set<String> = [
        "com.apple.mail",
        "com.apple.MobileSMS",
    ]

    /// Reference words that stand for the single selected/attached file.
    private static let singleFileRefWords: Set<String> = ["this", "it"]

    /// Reference words that stand for multiple selected/attached files.
    private static let multiFileRefWords: Set<String> = ["these", "them"]

    /// Reference words that stand for selected text (used only when no file slot was assigned).
    private static let selectionRefWords: Set<String> = ["this", "it", "that"]

    /// Lifts a request's entity values into `{slot}` tokens.
    ///
    /// Context slots ({file}, {files}, {selection}, {app}) are filled from `context` first,
    /// then word slots ({day} everywhere; {sender} only in Mail/Messages scopes).
    ///
    /// Returns the templated query, the remaining words (normalized like `commandWords`, which
    /// is what matching compares), the slots in a fixed order, the concrete values that filled
    /// them, and a flag indicating whether a leftover-value (a proper noun or path not covered
    /// by any slot or route word) was found. Nil only for an empty query.
    nonisolated static func derive(
        query: String,
        bundleId: String = "",
        context: SlotDerivationContext = .empty
    ) -> (template: String, nonSlotWords: Set<String>, slots: [SolvedSkillSlot],
          values: [String: String], hasLeftoverValue: Bool)?
    {
        let tokens = query.split { $0 == " " || $0 == "\t" || $0 == "\n" }.map(String.init)
        guard !tokens.isEmpty else { return nil }
        let words = tokens.map(trimmed)

        var values: [String: String] = [:]

        // ── 1. Context slots (taken from the turn's context, not from words) ────────────
        //
        // {file}: single selected/attached file. Reference words ("this", "it") and the
        //         file's own basename match; the first occurrence wins.
        if context.selectedFilePaths.count == 1 {
            let basenames = context.fileBasenames          // e.g. ["report"]
            let components = context.fileLastComponents    // e.g. ["report.pdf"]
            let refWords = singleFileRefWords
            if let matchedWord = words.first(where: { word in
                let lower = word.lowercased()
                return refWords.contains(lower)
                    || basenames.contains(lower)
                    || components.contains(lower)
            }) {
                values["file"] = matchedWord
            }
        }

        // {files}: multiple selected/attached files. Reference words ("these", "them") match.
        if context.selectedFilePaths.count > 1 {
            let refWords = multiFileRefWords
            if let matchedWord = words.first(where: { refWords.contains($0.lowercased()) }) {
                values["files"] = matchedWord
            }
        }

        // {selection}: selected text (only when no {file} slot was assigned for the same ref).
        if context.selectedText != nil, values["file"] == nil {
            let refWords = selectionRefWords
            if let matchedWord = words.first(where: { refWords.contains($0.lowercased()) }) {
                values["selection"] = matchedWord
            }
        }

        // {app}: the frontmost app's name appears as a word in the query.
        if let appName = context.appName, !appName.isEmpty,
            let matchedWord = words.first(where: { $0.lowercased() == appName.lowercased() })
        {
            values["app"] = matchedWord
        }

        // ── 2. Word slots ────────────────────────────────────────────────────────────────
        //
        // {sender}: only in Mail/Messages scopes, so a product name in another app is never
        //           taken for a person (H0: "convert this to Word" ≠ {sender}).
        let claimedLower = Set(values.values.map { $0.lowercased() })
        if senderScopeIds.contains(bundleId) {
            if let fromIndex = words.firstIndex(where: { $0.lowercased() == "from" }),
                fromIndex + 1 < words.count,
                !words[fromIndex + 1].isEmpty,
                !claimedLower.contains(words[fromIndex + 1].lowercased())
            {
                values["sender"] = words[fromIndex + 1]
            } else if let index = words.indices.dropFirst().first(where: {
                isProperNoun(words[$0]) && !claimedLower.contains(words[$0].lowercased())
            }) {
                values["sender"] = words[index]
            }
        }

        // {day}: today or yesterday in any scope.
        let claimedLower2 = Set(values.values.map { $0.lowercased() })
        if let day = words.first(where: {
            isDayWord($0) && !claimedLower2.contains($0.lowercased())
        }) {
            values["day"] = day
        }

        // ── 3. Build output ──────────────────────────────────────────────────────────────

        // Fixed slot order: context slots first, then word slots.
        let slotOrder = ["file", "files", "selection", "app", "sender", "day"]
        let slots = slotOrder
            .filter { values[$0] != nil }
            .map { SolvedSkillSlot(name: $0, tokenFamily: $0) }

        // Template: replace each matched word with its {slot} token (case-insensitive).
        let lowerToSlot: [String: String] = Dictionary(
            values.map { (name, word) in (word.lowercased(), name) },
            uniquingKeysWith: { first, _ in first })
        let template = words.map { word -> String in
            if let name = lowerToSlot[word.lowercased()] { return "{\(name)}" }
            return word
        }.joined(separator: " ")

        // nonSlotWords: the remaining words, normalised for matching.
        let slotLowerValues = Set(values.values.map { $0.lowercased() })
        let remaining = words.filter { !slotLowerValues.contains($0.lowercased()) }
            .joined(separator: " ")
        let nonSlotWords = ExactCommand.commandWords(remaining)

        // ── 4. Leftover-value check ──────────────────────────────────────────────────────
        //
        // A proper noun (other than a leading sentence starter), path, or email address that
        // remains after slot extraction blocks the save (§8 rule 3). This catches entities
        // that should have been parameterised but were not (e.g. a file name when no file is
        // in context, a person's name in a non-sender scope, a path literal).
        let hasLeftoverValue = words.enumerated().contains { index, word in
            guard !slotLowerValues.contains(word.lowercased()) else { return false }
            return looksLikePath(word) || looksLikeEmailOrAddress(word)
                || (index > 0 && isProperNoun(word))
        }

        return (template, nonSlotWords, slots, values, hasLeftoverValue)
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

    private nonisolated static func looksLikePath(_ word: String) -> Bool {
        word.hasPrefix("/") || word.hasPrefix("~/") || word.hasPrefix("./")
            || (word.contains("/") && !word.hasPrefix("http"))
    }

    private nonisolated static func looksLikeEmailOrAddress(_ word: String) -> Bool {
        word.contains("@") && word.contains(".")
    }
}
