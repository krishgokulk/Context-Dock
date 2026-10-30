// SolvedSkill.swift
// Context-Dock
//
// A read request DoraX has already solved once, kept so the next one like it does not pay
// for the model again.
//
// When an app-scoped chat answers a read through the tool loop and the read-back verifies,
// the typed tool calls that produced the answer are worth keeping — but not verbatim. "unread
// mail from SBI today" and "unread mail from ICICI yesterday" are the same skill with two
// fillings, so what is saved is the *shape*: the query with its entity values lifted into
// `{slot}` tokens, and each tool call's input with the same values lifted. A later sentence of
// the same shape fills the slots and replays the calls through the ordinary executor and gates
// (`SolvedSkillMatch`), with no model call.
//
// This is deliberately not a `WorkflowRecipe`: a recipe is named and run by the user, binds
// `ChatRoute`s, and carries no parameters. A solved skill is captured automatically, keyed by
// the request's shape, and is parameterized. It mirrors the recipe store's persistence pattern
// (Application Support, JSON, save/delete/markRun) rather than reusing its model.

import Combine
import Foundation
import OSLog

// MARK: - Model

/// One typed tool call from the solved turn. `argTemplate` is the tool's input with entity
/// values replaced by `{slot}` tokens, so filling the slots reconstructs a concrete input.
struct SolvedSkillToolCall: Codable, Equatable {
    let capability: String
    var argTemplate: [String: String]
    let isReadOnly: Bool
}

/// A parameter lifted out of the request. `tokenFamily` records how it is filled — a label in
/// v1, where filling is deterministic; it is where an on-device model's family would go later.
struct SolvedSkillSlot: Codable, Equatable {
    let name: String
    let tokenFamily: String
}

struct SolvedSkill: Codable, Equatable, Identifiable {
    var id = UUID()
    /// The request this was captured from, with entity values replaced by `{slot}` tokens.
    var queryTemplate: String
    /// The request's remaining words, normalized the way `ScopedRoutePolicy.commandWords` does.
    /// Matching is an exact set comparison against these, so a looser sentence falls through.
    var nonSlotWords: Set<String>
    var slots: [SolvedSkillSlot]
    var toolCalls: [SolvedSkillToolCall]
    var bundleId: String
    var createdAt: Date = Date()
    var runCount: Int = 0
    var successCount: Int = 0
}

// MARK: - Store

/// Solved skills on disk, under the same Application Support root as `WorkflowRecipeStore`.
@MainActor
final class SolvedSkillStore: ObservableObject {
    static let shared = SolvedSkillStore()

    @Published private(set) var skills: [SolvedSkill] = []

    private let fileURL: URL
    private static let log = Logger(
        subsystem: "com.krishgokul.ContextDock", category: "SolvedSkill")

    private init() {
        let dir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Context-Dock", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("solved-skills.json")
        load()
    }

    /// Saves under the request's shape, replacing any skill with the same template in the same
    /// app — a re-captured shape is the newer truth, not a second entry to match against.
    func save(_ skill: SolvedSkill) {
        skills.removeAll {
            $0.bundleId == skill.bundleId
                && $0.queryTemplate.caseInsensitiveCompare(skill.queryTemplate) == .orderedSame
        }
        skills.insert(skill, at: 0)
        persist()
    }

    func delete(_ id: UUID) {
        skills.removeAll { $0.id == id }
        persist()
    }

    func all(forBundle bundleId: String) -> [SolvedSkill] {
        skills.filter { $0.bundleId == bundleId }
    }

    func markRun(id: UUID, success: Bool) {
        guard let index = skills.firstIndex(where: { $0.id == id }) else { return }
        skills[index].runCount += 1
        if success { skills[index].successCount += 1 }
        persist()
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
            let decoded = try? JSONDecoder().decode([SolvedSkill].self, from: data)
        else { return }
        skills = decoded
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(skills) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}

// MARK: - Per-turn tool-call collector

/// The structured tool calls a turn made, kept for its scope so the capture hook can read
/// them once the answer is assembled.
///
/// The three provider loops reach every tool through `AgentToolRegistry.dispatch`, but the
/// executed-command record they hand back carries only a free-text command string — a capability
/// id and its input are gone by the time the answer is built. Rather than thread a third element
/// out through `sendWithTools` and every verifier pass, `dispatch` records the call here (the same
/// per-scope pattern `ChatResultRowCollector` uses), and `send` takes them when the turn ends.
/// Keyed by scope so two surfaces answering at once never cross their calls.
@MainActor
final class SolvedSkillToolCallCollector {
    static let shared = SolvedSkillToolCallCollector()

    private var callsByScope: [String: [SolvedSkillToolCall]] = [:]
    /// Scopes whose current turn had a call that read its result back. Turn state only, not part
    /// of the saved call. Per scope, like the calls, so two surfaces never share a verdict.
    private var verifiedScopes: Set<String> = []

    private init() {}

    func begin(scope: GeneralChatScope?) {
        callsByScope[key(scope)] = []
        verifiedScopes.remove(key(scope))
    }

    /// True when any call this turn was read back by `dispatch` (`verifiedByReadBack`), which is
    /// the verification signal on both the native and the MCP path.
    func hadVerifiedReadBack(scope: GeneralChatScope?) -> Bool {
        verifiedScopes.contains(key(scope))
    }

    /// Records one successful tool dispatch. A `run_capability` call is replayable, so it is kept
    /// as its capability id and input; any other tool (a menu click, a script, a screen read) has
    /// no typed replay, so it is kept as not-read-only and rule 4 refuses the whole turn.
    /// `find_capability`-style lookups and read-backs are plumbing and are not recorded.
    func record(
        capability: String, input: [String: String], isReadOnly: Bool, verifiedReadBack: Bool,
        scope: GeneralChatScope?
    ) {
        if verifiedReadBack { verifiedScopes.insert(key(scope)) }
        let call = SolvedSkillToolCall(
            capability: capability, argTemplate: input, isReadOnly: isReadOnly)
        // The verifier's repair pass re-runs a call the turn already made; one entry is enough.
        guard callsByScope[key(scope)]?.last != call else { return }
        callsByScope[key(scope), default: []].append(call)
    }

    func take(scope: GeneralChatScope?) -> [SolvedSkillToolCall] {
        let scopeKey = key(scope)
        let calls = callsByScope[scopeKey] ?? []
        callsByScope[scopeKey] = []
        return calls
    }

    private func key(_ scope: GeneralChatScope?) -> String {
        scope?.storageKey ?? "general"
    }
}
