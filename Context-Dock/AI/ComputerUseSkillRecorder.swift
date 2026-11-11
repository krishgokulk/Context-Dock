// ComputerUseSkillRecorder.swift
// Context-Dock
//
// Phase 5: a Computer Use run that worked becomes a per-app skill, automatically.
//
// Every successful `operate_app` / `ax_act` step is noted by label. When the run goes quiet
// (the operating pill hides) and its last step succeeded, the steps are saved to `SkillStore`
// as an app-scoped skill ("Learned: …"). The next turn in that app lists it by name and can
// read it with `skills.read`, so a task done once the slow way is a known route afterwards.
//
// What is deliberately NOT saved: text the user typed, pixel (OCR) targets and list rows —
// anything that is the user's content rather than the app's own controls. A Stop discards the
// run. The skill is unpinned (name and summary only in the prompt) and can be edited, disabled
// or deleted from Settings → Integrations → the app → Resources.

import Foundation

struct LearnedStep: Equatable {
    let text: String
}

@MainActor
final class ComputerUseSkillRecorder {
    static let shared = ComputerUseSkillRecorder()

    nonisolated static let namePrefix = "Learned: "
    nonisolated static let minimumSteps = 2

    private struct Run {
        var appName: String
        var goal: String = ""
        var steps: [LearnedStep] = []
        var lastSucceeded = true
        var userQuery: String = ""
        var hasUntrustedContent: Bool = false
    }

    private var runs: [String: Run] = [:]
    private var currentTurnQuery: String = ""

    private init() {}

    // MARK: Recording

    /// Call once per AI turn, before any `succeeded` or `failed` calls, to record
    /// the user's query for templated naming (Rule 3 / H1a).
    func startTurn(userQuery: String) {
        currentTurnQuery = userQuery
    }

    /// Mark the current run as having been exposed to untrusted content.
    /// Causes `finish()` to discard it rather than save (Rule 2 / H1a).
    func markUntrusted(bundleID: String) {
        runs[bundleID]?.hasUntrustedContent = true
    }

    func succeeded(bundleID: String, appName: String, goal: String, step: String) {
        var run = runs[bundleID] ?? Run(appName: appName)
        if run.goal.isEmpty { run.goal = goal.trimmingCharacters(in: .whitespacesAndNewlines) }
        if run.userQuery.isEmpty { run.userQuery = currentTurnQuery }
        if run.steps.last?.text != step { run.steps.append(LearnedStep(text: step)) }
        run.lastSucceeded = true
        runs[bundleID] = run
    }

    func failed(bundleID: String) {
        runs[bundleID]?.lastSucceeded = false
    }

    func discard(bundleID: String? = nil) {
        if let bundleID { runs[bundleID] = nil } else { runs.removeAll() }
    }

    /// The run has gone quiet. Saves it when it earned it.
    @discardableResult
    func finish(bundleID: String, store: SkillStore = .shared) -> AdapterSkill? {
        guard let run = runs.removeValue(forKey: bundleID), run.lastSucceeded,
            !run.hasUntrustedContent,  // Rule 2: untrusted-turn guard
            let skill = Self.makeSkill(
                bundleID: bundleID, appName: run.appName, goal: run.goal, steps: run.steps,
                userQuery: run.userQuery)
        else { return nil }

        // Same task done again updates its skill rather than piling up copies.
        var saved = skill
        if let existing = store.skills(for: bundleID).first(where: { $0.name == skill.name }) {
            saved = AdapterSkill(
                id: existing.id, adapterBundleId: bundleID, name: skill.name,
                summary: skill.summary, instructions: skill.instructions,
                isEnabled: existing.isEnabled, isPinned: existing.isPinned)
        }
        store.upsert(saved)
        return saved
    }

    // MARK: Step wording

    /// A step in the app's own words. Nil for anything that is the user's content.
    nonisolated static func describe(
        action: String, role: String, label: String, isPixel: Bool
    ) -> String? {
        guard !isPixel, !label.isEmpty else { return nil }
        // Rows and cells are the user's data (a mail subject, a file name), not the app's UI.
        if role == "Row" || role == "Cell" { return nil }
        switch action {
        case "type": return "type into \(role) \"\(label)\" (the text from the request)"
        default: return "\(action) \(role) \"\(label)\""
        }
    }

    nonisolated static func describeMenu(path: String) -> String { "press menu \(path)" }

    // MARK: Skill

    nonisolated static func makeSkill(
        bundleID: String, appName: String, goal: String, steps: [LearnedStep],
        userQuery: String = ""
    ) -> AdapterSkill? {
        guard steps.count >= minimumSteps else { return nil }
        // Rule 3: use slot-derived template from user query when available and clean.
        let title: String
        if !userQuery.isEmpty,
           let derived = SolvedSkillCapture.derive(query: userQuery, bundleId: bundleID),
           !derived.hasLeftoverValue,
           !derived.template.isEmpty
        {
            title = String(derived.template.prefix(48))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            let seed = goal.isEmpty ? steps[0].text : goal
            title = String(seed.prefix(48)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !title.isEmpty else { return nil }

        let numbered = steps.enumerated().map { "\($0.offset + 1). \($0.element.text)" }
            .joined(separator: "\n")
        let body = """
            Learned automatically from a Computer Use run in \(appName) that worked.

            Steps, by label (element ids change every time — take a fresh ax_snapshot and match \
            by label and role):
            \(numbered)

            Treat this as a hint, not a script: check the fresh snapshot after every step, and \
            stop and ask if the window does not look like this.
            """
        return AdapterSkill(
            adapterBundleId: bundleID,
            name: namePrefix + title,
            summary: "How DoraX did \"\(title)\" in \(appName) last time (\(steps.count) steps).",
            instructions: body)
    }
}
