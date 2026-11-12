// LearnedSkillJob.swift
// Context-Dock
//
// One job, one key (agent-harness spec §8 rules 4 and 6, H2 #409).
//
// Every learned skill — a solved skill (`SolvedSkill`) or a learned recipe (an `AdapterSkill`
// written by `AIScriptSkillRecorder` or `ComputerUseSkillRecorder`) — is filed under the job
// it does: *(scope, slot-lifted request shape)*, built by the H0 deriver. Two skills with one
// key are rivals, and exactly one survives:
//
//   user-installed or pack skill › solved skill › learned recipe
//
// Within one kind a lower rung replaces a higher one, and a newer success on the same rung
// replaces the older one. A recipe also goes stale: it records the app version it was learned
// on, and after a version change or two failures in a row it is disabled and waits for the
// next success to relearn it. Solved skills are not retired here — they re-bind live on every
// run and fall back to the model, which repairs them (#205 rule 7).
//
// Everything in this file is pure: the stores call it and persist what it returns.

import Foundation

nonisolated enum LearnedSkillJob {

    /// Who holds a job, strongest first.
    enum Kind: Int, Comparable {
        case userOrPack = 0
        case solved
        case recipe

        static func < (lhs: Kind, rhs: Kind) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    /// The route ladder's rung numbers (spec §6) a learned skill can come from.
    enum Rung {
        static let direct = 1
        static let script = 2
        static let menu = 3
        static let computerUse = 4
    }

    /// Failures in a row that retire a learned recipe.
    static let failureLimit = 2

    // MARK: - Key

    /// The key itself. The shape is the request's non-slot words plus its slot names, both
    /// sorted — the same two things `SolvedSkillMatch.match` compares, so two requests share a
    /// key exactly when one would replay the other's skill.
    static func key(scope: String, nonSlotWords: Set<String>, slotNames: [String]) -> String {
        let words = nonSlotWords.map { $0.lowercased() }.sorted().joined(separator: " ")
        let slots = Set(slotNames).sorted().map { "{\($0)}" }.joined(separator: " ")
        return "\(scope)|\(words)|\(slots)"
    }

    /// The key of a request, through the H0 deriver. Nil for an empty request.
    static func key(
        query: String, bundleId: String, context: SlotDerivationContext = .empty
    ) -> String? {
        guard let derived = SolvedSkillCapture.derive(
            query: query, bundleId: bundleId, context: context)
        else { return nil }
        return key(
            scope: bundleId, nonSlotWords: derived.nonSlotWords,
            slotNames: derived.slots.map(\.name))
    }

    /// The key a skill's *name* stands for: its words, with any literal `{slot}` token read as
    /// a slot. This is how a user-installed or pack skill, which carries no request, claims a
    /// job ("Zip {file}" in Finder), and how a learned recipe saved before H2 gets its key.
    static func key(forSkillName name: String, bundleId: String) -> String {
        var slots: [String] = []
        var rest: [String] = []
        for token in name.split(whereSeparator: \.isWhitespace) {
            if token.hasPrefix("{"), token.hasSuffix("}"), token.count > 2 {
                slots.append(String(token.dropFirst().dropLast()).lowercased())
            } else {
                rest.append(String(token))
            }
        }
        return key(
            scope: bundleId,
            nonSlotWords: ExactCommand.commandWords(rest.joined(separator: " ")),
            slotNames: slots)
    }

    // MARK: - Conflict order

    /// Whether a new success replaces the skill that already holds its job.
    static func incomingWins(
        kind: Kind, rung: Int, overKind existingKind: Kind, rung existingRung: Int,
        existingIsStale: Bool = false
    ) -> Bool {
        if kind != existingKind { return kind < existingKind }
        // A retired skill is relearned by the next success, whatever rung it came from.
        if existingIsStale { return true }
        // Lower rung wins; the same rung is a newer success, which also wins.
        return rung <= existingRung
    }

    // MARK: - Learned recipes

    /// Files a recipe that just succeeded. Returns the new skill list, or nil when a stronger
    /// skill already holds the job and the recipe is dropped.
    ///
    /// The winner keeps the id, the pin and the user's on/off choice of the recipe it
    /// replaces, so a relearned skill is the same row in Settings — except that a recipe
    /// disabled for staleness comes back on, which is what relearning means.
    static func merging(
        recipe incoming: AdapterSkill, into skills: [AdapterSkill], solvedKeys: Set<String>
    ) -> [AdapterSkill]? {
        let key = incoming.effectiveJobKey
        guard !solvedKeys.contains(key) else { return nil }

        let rivals = skills.filter {
            $0.adapterBundleId == incoming.adapterBundleId && $0.surfaceId == incoming.surfaceId
                && $0.id != incoming.id && $0.effectiveJobKey == key
        }
        // A skill the user installed, or one a pack shipped, is theirs to turn off: while it
        // is on, nothing learned takes its job.
        guard !rivals.contains(where: { !$0.isLearned && $0.isEnabled }) else { return nil }

        let learned = rivals.filter(\.isLearned)
        let rung = incoming.learnedRung ?? Rung.computerUse
        guard learned.allSatisfy({
            incomingWins(
                kind: .recipe, rung: rung, overKind: .recipe,
                rung: $0.learnedRung ?? Rung.computerUse, existingIsStale: $0.isStale)
        }) else { return nil }

        var saved = incoming
        if let old = learned.first {
            saved = incoming.replacingIdentity(
                id: old.id, isEnabled: old.isStale ? true : old.isEnabled, isPinned: old.isPinned)
        }
        saved.consecutiveFailures = 0
        saved.isStale = false

        let losers = Set(learned.map(\.id))
        var result = skills.filter { !losers.contains($0.id) && $0.id != saved.id }
        result.append(saved)
        return result
    }

    /// A run for this job failed. Two in a row disable its recipe. Nil when nothing changed.
    static func notingFailure(
        jobKey: String, bundleId: String, in skills: [AdapterSkill]
    ) -> [AdapterSkill]? {
        guard
            let index = skills.firstIndex(where: {
                $0.isLearned && $0.adapterBundleId == bundleId && !$0.isStale
                    && $0.effectiveJobKey == jobKey
            })
        else { return nil }
        var result = skills
        result[index].consecutiveFailures += 1
        if result[index].consecutiveFailures >= failureLimit {
            result[index].isStale = true
            result[index].isEnabled = false
        }
        return result
    }

    /// Disables the app's recipes learned on another version of it. Nil when nothing changed.
    /// A recipe with no recorded version (saved before H2), or an app whose version cannot be
    /// read, is left alone: unknown is not "changed".
    static func retiringVersionChanged(
        bundleId: String, currentVersion: String, in skills: [AdapterSkill]
    ) -> [AdapterSkill]? {
        guard !currentVersion.isEmpty else { return nil }
        var result = skills
        var changed = false
        for index in result.indices {
            let skill = result[index]
            guard skill.isLearned, skill.adapterBundleId == bundleId, !skill.isStale,
                !skill.learnedAppVersion.isEmpty, skill.learnedAppVersion != currentVersion
            else { continue }
            result[index].isStale = true
            result[index].isEnabled = false
            changed = true
        }
        return changed ? result : nil
    }

    /// Drops the recipes a solved skill now outranks. Nil when there were none.
    static func removingRecipes(
        jobKey: String, bundleId: String, from skills: [AdapterSkill]
    ) -> [AdapterSkill]? {
        let result = skills.filter {
            !($0.isLearned && $0.adapterBundleId == bundleId && $0.effectiveJobKey == jobKey)
        }
        return result.count == skills.count ? nil : result
    }

    /// The jobs an app's user-installed and pack skills hold.
    static func userHeldKeys(bundleId: String, in skills: [AdapterSkill]) -> Set<String> {
        Set(
            skills.filter {
                !$0.isLearned && $0.isEnabled && $0.adapterBundleId == bundleId
                    && $0.surfaceId.isEmpty
            }.map(\.effectiveJobKey))
    }

    // MARK: - Solved skills

    /// Files a solved skill that was just captured. Returns the new list, or nil when a
    /// user-installed or pack skill holds the job, or a lower-rung solved skill that still
    /// works does.
    static func merging(
        solved incoming: SolvedSkill, into skills: [SolvedSkill], userKeys: Set<String>
    ) -> [SolvedSkill]? {
        let key = incoming.jobKey
        guard !userKeys.contains(key) else { return nil }
        let rivals = skills.filter { $0.id != incoming.id && $0.jobKey == key }
        // A skill whose last replay failed fell through to the model, and this capture is the
        // model's repair (#205 rule 7) — it replaces the broken one from any rung.
        guard rivals.allSatisfy({
            incomingWins(
                kind: .solved, rung: incoming.rung, overKind: .solved, rung: $0.rung,
                existingIsStale: ($0.consecutiveFailures ?? 0) > 0)
        }) else { return nil }
        let losers = Set(rivals.map(\.id))
        return [incoming] + skills.filter { !losers.contains($0.id) && $0.id != incoming.id }
    }
}

// MARK: - What the two skill models say about their job

nonisolated extension SolvedSkill {
    /// The job this skill does, in its app.
    var jobKey: String {
        LearnedSkillJob.key(
            scope: bundleId, nonSlotWords: nonSlotWords, slotNames: slots.map(\.name))
    }

    /// Menu presses are rung 3; every other typed call (capability, connector, MCP) is rung 1.
    var rung: Int {
        toolCalls.allSatisfy { $0.capability == "run_menu_command" }
            ? LearnedSkillJob.Rung.menu : LearnedSkillJob.Rung.direct
    }
}

nonisolated extension AdapterSkill {
    /// The rung a learned recipe came from, or nil for a skill the user or a pack wrote.
    /// The name prefixes cover recipes saved before H2 stored the rung.
    var learnedRung: Int? {
        if rung > 0 { return rung }
        if name.hasPrefix(AIScriptSkillRecorder.namePrefix) { return LearnedSkillJob.Rung.script }
        if name.hasPrefix(ComputerUseSkillRecorder.namePrefix) {
            return LearnedSkillJob.Rung.computerUse
        }
        return nil
    }

    var isLearned: Bool { learnedRung != nil }

    /// The stored key, or the one the name stands for when none was stored.
    var effectiveJobKey: String {
        if !jobKey.isEmpty { return jobKey }
        var title = name
        for prefix in [AIScriptSkillRecorder.namePrefix, ComputerUseSkillRecorder.namePrefix]
        where title.hasPrefix(prefix) {
            title = String(title.dropFirst(prefix.count))
        }
        return LearnedSkillJob.key(forSkillName: title, bundleId: adapterBundleId)
    }

    /// This skill under another row's identity. `id` is a `let`, so this is the one way to
    /// carry a relearned recipe into the row it replaces.
    func replacingIdentity(id: String, isEnabled: Bool, isPinned: Bool) -> AdapterSkill {
        AdapterSkill(
            id: id, adapterBundleId: adapterBundleId, name: name, summary: summary,
            instructions: instructions, version: version, isEnabled: isEnabled,
            updatedAt: updatedAt, surfaceId: surfaceId, isPinned: isPinned, jobKey: jobKey,
            rung: rung, learnedAppVersion: learnedAppVersion,
            consecutiveFailures: consecutiveFailures, isStale: isStale)
    }
}
