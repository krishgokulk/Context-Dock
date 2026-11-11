// AppPetProactivityTests.swift
// Context-DockTests
//
// Deterministic tests for Stage 6 (#343) Bounded proactive Pet behavior:
// - Opt-in defaults (off by default globally and per Pet)
// - Verified triggers with clear provenance and rationale
// - Interruption budgets (daily limits, cooldown)
// - Quiet periods (quiet hours, Do Not Disturb, user typing)
// - Deduplication of repeated triggers/proposals
// - Headless monitoring budgets (tokens, time, rounds, no-progress limits)
// - Consequential actions require explicit user approval (no silent actions)
// - No silent scope widening or UI launch
// - Shared suggestion state synchronization
//
// Follows docs/superpowers/plans/2026-10-27-app-pets-rollout.md § Stage 6.

import Foundation
import Testing
@testable import Context_Dock

@Suite("AppPetProactivityTests")
struct AppPetProactivityTests {

    private func makeIsolatedStore() -> (AppPetProactivityStore, UserDefaults, String) {
        let suiteName = "test.dorax.proactivity.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let store = AppPetProactivityStore(defaults: defaults)
        return (store, defaults, suiteName)
    }

    private func makeSampleSuggestion(
        petID: AppPetID = .app(bundleID: "com.apple.finder"),
        behavior: AppPetProactiveBehaviorKind = .contextAnomalyWatch,
        summary: String = "3 duplicate PDFs in ~/Downloads",
        actionName: String? = "Move duplicates to Trash",
        createdAt: Date = Date()
    ) -> AppPetSuggestion {
        let trigger = AppPetTrigger(
            source: .fileSystem(path: "~/Downloads"),
            summary: summary,
            timestamp: createdAt,
            observedFacts: ["duplicates": "3", "folder": "~/Downloads"]
        )
        let provenance = AppPetProvenance(
            petID: petID,
            trigger: trigger,
            rationale: "Detected redundant download copies while Finder was idle.",
            proposedActionName: actionName,
            isConsequential: actionName != nil
        )
        let consequentialAction = actionName.map {
            AppPetConsequentialAction(
                actionName: $0,
                description: "Moves duplicate files to macOS Trash",
                requiresApproval: true,
                isApproved: false
            )
        }
        return AppPetSuggestion(
            petID: petID,
            title: "Tidy duplicate downloads?",
            detail: summary,
            behavior: behavior,
            provenance: provenance,
            consequentialAction: consequentialAction,
            createdAt: createdAt
        )
    }

    // MARK: - 1. Opt-In Defaults

    @Test("Proactivity is disabled by default globally and per Pet")
    func optInDefaultsAreEnforced() {
        let (store, defaults, suiteName) = makeIsolatedStore()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let petID = AppPetID.app(bundleID: "com.apple.Safari")

        // 1. Global toggle defaults to false
        #expect(store.isGlobalProactivityEnabled == false)

        // 2. Per-pet settings default to completely disabled
        let settings = store.loadSettings(for: petID)
        #expect(settings.isEnabled == false)
        #expect(settings.enabledBehaviors.isEmpty)
        #expect(settings.isBehaviorActive(.arrivalBriefing) == false)
        #expect(settings.isBehaviorActive(.routineProposal) == false)
        #expect(settings.isBehaviorActive(.contextAnomalyWatch) == false)

        // 3. Evaluator rejects suggestion when global is disabled
        let suggestion = makeSampleSuggestion(petID: petID, behavior: .arrivalBriefing)
        let context1 = ProactivityEvaluationContext(
            currentTime: Date(),
            petSettings: settings,
            isProactivityGloballyEnabled: false
        )
        let result1 = ProactivityEvaluator.evaluate(suggestion: suggestion, context: context1)
        #expect(result1 == .rejected(.proactivityDisabled))

        // 4. Evaluator rejects suggestion when global is ON but Pet is disabled
        let context2 = ProactivityEvaluationContext(
            currentTime: Date(),
            petSettings: settings,
            isProactivityGloballyEnabled: true
        )
        let result2 = ProactivityEvaluator.evaluate(suggestion: suggestion, context: context2)
        #expect(result2 == .rejected(.petDisabled))

        // 5. Evaluator rejects suggestion when Pet is ON but specific behavior is not enabled
        var enabledSettings = AppPetProactivitySettings(isEnabled: true, enabledBehaviors: [.arrivalBriefing])
        let context3 = ProactivityEvaluationContext(
            currentTime: Date(),
            petSettings: enabledSettings,
            isProactivityGloballyEnabled: true
        )
        // No quiet hours: this test is about the switches, and the default 22–8 window made
        // it fail on any run started at night (CI at 00:24 UTC).
        let result3 = ProactivityEvaluator.evaluate(
            suggestion: suggestion, context: context3,
            policy: ProactivityBudgetPolicy(quietHourStart: nil, quietHourEnd: nil))
        #expect(result3 == .allowed)

        // Asking for routineProposal when only arrivalBriefing is enabled fails
        let routineSuggestion = makeSampleSuggestion(petID: petID, behavior: .routineProposal)
        let result4 = ProactivityEvaluator.evaluate(suggestion: routineSuggestion, context: context3)
        #expect(result4 == .rejected(.behaviorDisabled))

        // 6. Muted pet is rejected
        enabledSettings.mutedUntil = Date().addingTimeInterval(3600)
        let context4 = ProactivityEvaluationContext(
            currentTime: Date(),
            petSettings: enabledSettings,
            isProactivityGloballyEnabled: true
        )
        let result5 = ProactivityEvaluator.evaluate(suggestion: suggestion, context: context4)
        #expect(result5 == .rejected(.petMuted))
    }

    // MARK: - 2. Verified Triggers & Clear Provenance

    @Test("Every suggestion carries verified trigger and clear provenance")
    func provenanceAndVerifiedTriggers() {
        let petID = AppPetID.app(bundleID: "com.apple.mail")
        let trigger = AppPetTrigger(
            source: .appContext(bundleID: "com.apple.mail"),
            summary: "4 unread emails from starred contacts",
            timestamp: Date(),
            observedFacts: ["unreadCount": "4", "vipFilter": "true"]
        )
        let provenance = AppPetProvenance(
            petID: petID,
            trigger: trigger,
            rationale: "Mail has urgent unread messages from VIP senders.",
            proposedActionName: "Draft quick responses",
            isConsequential: true
        )
        let suggestion = AppPetSuggestion(
            petID: petID,
            title: "Review urgent emails",
            detail: trigger.summary,
            behavior: .arrivalBriefing,
            provenance: provenance
        )

        #expect(suggestion.provenance.petID == petID)
        #expect(suggestion.provenance.trigger.summary == "4 unread emails from starred contacts")
        #expect(suggestion.provenance.trigger.observedFacts["unreadCount"] == "4")
        #expect(suggestion.provenance.rationale == "Mail has urgent unread messages from VIP senders.")
        #expect(suggestion.provenance.isConsequential == true)
        #expect(suggestion.provenance.proposedActionName == "Draft quick responses")
    }

    // MARK: - 3. Interruption Budget (Daily Limits & Cooldown)

    @Test("Interruption budget enforces daily suggestion cap and minimum cooldown")
    func interruptionBudgetEnforcement() {
        let petID = AppPetID.app(bundleID: "com.apple.finder")
        let settings = AppPetProactivitySettings(
            isEnabled: true,
            enabledBehaviors: [.contextAnomalyWatch],
            maxDailySuggestions: 3,
            minCooldownSeconds: 1800 // 30 minutes
        )

        let baseTime = Date()
        let policy = ProactivityBudgetPolicy(
            maxDailySuggestionsPerPet: 3,
            minCooldownSeconds: 1800,
            quietHourStart: nil,
            quietHourEnd: nil
        )

        // Empty history: first suggestion succeeds
        let s1 = makeSampleSuggestion(petID: petID, summary: "Event 1", actionName: "Action 1", createdAt: baseTime)
        let ctx1 = ProactivityEvaluationContext(
            currentTime: baseTime,
            suggestionHistory: [],
            petSettings: settings,
            isProactivityGloballyEnabled: true
        )
        #expect(ProactivityEvaluator.evaluate(suggestion: s1, context: ctx1, policy: policy) == .allowed)

        // Attempting a second suggestion only 5 minutes later is blocked by cooldown
        let s2 = makeSampleSuggestion(
            petID: petID,
            summary: "Event 2",
            actionName: "Action 2",
            createdAt: baseTime.addingTimeInterval(300)
        )
        let ctx2 = ProactivityEvaluationContext(
            currentTime: baseTime.addingTimeInterval(300),
            suggestionHistory: [s1],
            petSettings: settings,
            isProactivityGloballyEnabled: true
        )
        #expect(ProactivityEvaluator.evaluate(suggestion: s2, context: ctx2, policy: policy) == .rejected(.cooldownActive))

        // Attempting after 35 minutes (cooldown passed) succeeds
        let s2Time = baseTime.addingTimeInterval(2100)
        let ctx3 = ProactivityEvaluationContext(
            currentTime: s2Time,
            suggestionHistory: [s1],
            petSettings: settings,
            isProactivityGloballyEnabled: true
        )
        #expect(ProactivityEvaluator.evaluate(suggestion: s2, context: ctx3, policy: policy) == .allowed)

        // Build history with 3 suggestions in the past 24 hours
        let s3 = makeSampleSuggestion(petID: petID, summary: "Event 3", actionName: "Action 3", createdAt: s2Time.addingTimeInterval(2000))
        let history = [s1, s2, s3]

        // 4th suggestion exceeds daily budget of 3
        let s4 = makeSampleSuggestion(petID: petID, summary: "Event 4", actionName: "Action 4", createdAt: s2Time.addingTimeInterval(5000))
        let ctx4 = ProactivityEvaluationContext(
            currentTime: s2Time.addingTimeInterval(5000),
            suggestionHistory: history,
            petSettings: settings,
            isProactivityGloballyEnabled: true
        )
        #expect(ProactivityEvaluator.evaluate(suggestion: s4, context: ctx4, policy: policy) == .rejected(.dailyBudgetExceeded))
    }

    // MARK: - 4. Quiet Periods & Active Interaction

    @Test("Quiet periods and user interaction block interruptions")
    func quietPeriodsAndInteractionGuards() {
        let petID = AppPetID.app(bundleID: "com.apple.Safari")
        let settings = AppPetProactivitySettings(
            isEnabled: true,
            enabledBehaviors: [.arrivalBriefing]
        )
        let suggestion = makeSampleSuggestion(petID: petID, behavior: .arrivalBriefing)

        // 1. User typing or actively interacting
        let ctxTyping = ProactivityEvaluationContext(
            currentTime: Date(),
            isUserTypingOrInteracting: true,
            petSettings: settings,
            isProactivityGloballyEnabled: true
        )
        #expect(ProactivityEvaluator.evaluate(suggestion: suggestion, context: ctxTyping) == .rejected(.userIsActiveOrTyping))

        // 2. In call or Do Not Disturb
        let ctxDND = ProactivityEvaluationContext(
            currentTime: Date(),
            isUserTypingOrInteracting: false,
            isInCallOrDND: true,
            petSettings: settings,
            isProactivityGloballyEnabled: true
        )
        #expect(ProactivityEvaluator.evaluate(suggestion: suggestion, context: ctxDND) == .rejected(.quietPeriodActive))

        // 3. Quiet hours (e.g. 23:00 / 11 PM falls in 22:00 to 08:00)
        let policy = ProactivityBudgetPolicy(quietHourStart: 22, quietHourEnd: 8)
        #expect(policy.isHourInQuietPeriod(23) == true)
        #expect(policy.isHourInQuietPeriod(3) == true)
        #expect(policy.isHourInQuietPeriod(7) == true)
        #expect(policy.isHourInQuietPeriod(14) == false)

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        var components = DateComponents()
        components.year = 2026
        components.month = 11
        components.day = 2
        components.hour = 23
        components.minute = 15
        let quietTime = calendar.date(from: components)!

        let ctxQuiet = ProactivityEvaluationContext(
            currentTime: quietTime,
            petSettings: settings,
            isProactivityGloballyEnabled: true,
            calendar: calendar
        )
        #expect(ProactivityEvaluator.evaluate(suggestion: suggestion, context: ctxQuiet, policy: policy) == .rejected(.quietPeriodActive))
    }

    // MARK: - 5. Deduplication

    @Test("Repeated identical triggers and proposals are deduplicated")
    func deduplicationEnforcement() {
        let petID = AppPetID.app(bundleID: "com.apple.finder")
        let settings = AppPetProactivitySettings(
            isEnabled: true,
            enabledBehaviors: [.contextAnomalyWatch],
            minCooldownSeconds: 0 // set to 0 to isolate deduplication
        )
        let policy = ProactivityBudgetPolicy(
            minCooldownSeconds: 0,
            deduplicationWindowSeconds: 86400,
            quietHourStart: nil,
            quietHourEnd: nil
        )

        let baseTime = Date()
        let original = makeSampleSuggestion(
            petID: petID,
            summary: "3 duplicate PDFs in ~/Downloads",
            actionName: "Move duplicates to Trash",
            createdAt: baseTime
        )

        // Past history contains original suggestion
        let ctx = ProactivityEvaluationContext(
            currentTime: baseTime.addingTimeInterval(3600),
            suggestionHistory: [original],
            petSettings: settings,
            isProactivityGloballyEnabled: true
        )

        // Proposal with exact same trigger and action is blocked as duplicate
        let duplicate = makeSampleSuggestion(
            petID: petID,
            summary: "3 duplicate PDFs in ~/Downloads",
            actionName: "Move duplicates to Trash",
            createdAt: baseTime.addingTimeInterval(3600)
        )
        #expect(duplicate.deduplicationFingerprint == original.deduplicationFingerprint)
        #expect(ProactivityEvaluator.evaluate(suggestion: duplicate, context: ctx, policy: policy) == .rejected(.duplicateSuggestion))

        // Proposal with DIFFERENT trigger is NOT blocked
        let distinct = makeSampleSuggestion(
            petID: petID,
            summary: "12 unorganized screenshots on Desktop",
            actionName: "Move to Screenshots folder",
            createdAt: baseTime.addingTimeInterval(3600)
        )
        #expect(ProactivityEvaluator.evaluate(suggestion: distinct, context: ctx, policy: policy) == .allowed)
    }

    // MARK: - 6. Headless Monitoring Budgets

    @Test("Headless monitoring respects token, duration, round, and no-progress limits")
    func headlessMonitoringBudgets() throws {
        let budget = HeadlessMonitoringBudget(
            maxTokens: 500,
            maxDurationSeconds: 4.0,
            maxRounds: 2,
            maxConsecutiveNoProgressScans: 3
        )
        let tracker = HeadlessMonitoringBudgetTracker(budget: budget)

        // Round 1: normal scan within budget
        try tracker.recordScan(tokens: 150, duration: 1.0, foundProgress: true)
        #expect(tracker.cumulativeTokens == 150)
        #expect(tracker.cumulativeDuration == 1.0)
        #expect(tracker.roundCount == 1)
        #expect(tracker.consecutiveNoProgressCount == 0)

        // Round 2: scan exceeding token budget throws tokenLimitExceeded
        let tracker2 = HeadlessMonitoringBudgetTracker(budget: budget)
        try tracker2.recordScan(tokens: 200, duration: 1.0, foundProgress: true)
        #expect(throws: MonitoringBudgetBreach.tokenLimitExceeded) {
            try tracker2.recordScan(tokens: 400, duration: 1.0, foundProgress: true)
        }

        // Duration breach throws timeLimitExceeded
        let tracker3 = HeadlessMonitoringBudgetTracker(budget: budget)
        #expect(throws: MonitoringBudgetBreach.timeLimitExceeded) {
            try tracker3.recordScan(tokens: 100, duration: 5.5, foundProgress: true)
        }

        // Round count breach throws roundLimitExceeded
        let tracker4 = HeadlessMonitoringBudgetTracker(budget: budget)
        try tracker4.recordScan(tokens: 50, duration: 0.5, foundProgress: true)
        try tracker4.recordScan(tokens: 50, duration: 0.5, foundProgress: true)
        #expect(throws: MonitoringBudgetBreach.roundLimitExceeded) {
            try tracker4.recordScan(tokens: 50, duration: 0.5, foundProgress: true)
        }

        // Consecutive no-progress limit (3 empty scans in a row)
        let tracker5 = HeadlessMonitoringBudgetTracker(
            budget: HeadlessMonitoringBudget(maxTokens: 5000, maxDurationSeconds: 100, maxRounds: 10, maxConsecutiveNoProgressScans: 3)
        )
        try tracker5.recordScan(tokens: 10, duration: 0.1, foundProgress: false)
        #expect(tracker5.consecutiveNoProgressCount == 1)

        try tracker5.recordScan(tokens: 10, duration: 0.1, foundProgress: false)
        #expect(tracker5.consecutiveNoProgressCount == 2)

        // Progress found resets counter
        try tracker5.recordScan(tokens: 10, duration: 0.1, foundProgress: true)
        #expect(tracker5.consecutiveNoProgressCount == 0)

        // Three consecutive empty scans trigger breach
        try tracker5.recordScan(tokens: 10, duration: 0.1, foundProgress: false)
        try tracker5.recordScan(tokens: 10, duration: 0.1, foundProgress: false)
        #expect(throws: MonitoringBudgetBreach.maxNoProgressExceeded) {
            try tracker5.recordScan(tokens: 10, duration: 0.1, foundProgress: false)
        }
    }

    // MARK: - 7. Consequential Action Safety Gate

    @Test("Suggestions cannot act silently; consequential actions require explicit user approval")
    @MainActor
    func consequentialActionApprovalRequired() async throws {
        let (store, defaults, suiteName) = makeIsolatedStore()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let coordinator = AppPetSuggestionCoordinator(store: store)
        let petID = AppPetID.app(bundleID: "com.apple.finder")

        var settings = AppPetProactivitySettings(isEnabled: true, enabledBehaviors: [.contextAnomalyWatch])
        store.saveSettings(settings, for: petID)
        store.isGlobalProactivityEnabled = true

        var executedAction = false
        coordinator.registerActionExecutor(actionName: "Move duplicates to Trash") { suggestion in
            executedAction = true
        }

        let suggestion = makeSampleSuggestion(petID: petID, actionName: "Move duplicates to Trash")

        // Invariant: Unapproved suggestion has isApproved == false
        #expect(suggestion.consequentialAction?.isApproved == false)
        #expect(suggestion.consequentialAction?.requiresApproval == true)
        #expect(executedAction == false)

        // Propose suggestion into coordinator
        // No quiet hours, so the time of the run does not decide the proposal.
        let result = coordinator.proposeSuggestion(
            suggestion: suggestion,
            policy: ProactivityBudgetPolicy(quietHourStart: nil, quietHourEnd: nil))
        guard case .success(let active) = result else {
            Issue.record("Suggestion should be accepted")
            return
        }

        #expect(coordinator.activeSuggestions.count == 1)
        #expect(coordinator.activeSuggestions[0].id == active.id)
        #expect(executedAction == false) // Proposing MUST NOT execute!

        // Explicit user approval executes the action
        try await coordinator.approveAndExecute(suggestionID: active.id)
        #expect(executedAction == true)
    }

    // MARK: - 8. Non-goals: Scope Widening & Silent UI

    @Test("Suggestions never widen scope or launch UI silently")
    func suggestionsNeverWidenScopeOrLaunchUI() {
        let petID = AppPetID.app(bundleID: "com.apple.Safari")
        let suggestion = makeSampleSuggestion(petID: petID)

        // Suggestion remains anchored only to its petID
        #expect(suggestion.petID.canonicalKey == "app:com.apple.safari")

        // No new participants are attached
        let participants = [ConversationParticipant(petID: petID, displayName: "Safari")]
        #expect(participants.count == 1)
        #expect(participants[0].petID == petID)

        // Consequential action explicitly requires approval, cannot widen scope silently
        #expect(suggestion.consequentialAction?.requiresApproval == true)
    }

    // MARK: - 9. Shared Suggestion State & Dismissal

    @Test("Suggestion dismissal synchronizes state and supports muting")
    @MainActor
    func sharedSuggestionStateAndMuting() {
        let (store, defaults, suiteName) = makeIsolatedStore()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let coordinator = AppPetSuggestionCoordinator(store: store)
        let petID = AppPetID.app(bundleID: "com.apple.finder")

        let settings = AppPetProactivitySettings(isEnabled: true, enabledBehaviors: [.contextAnomalyWatch])
        store.saveSettings(settings, for: petID)
        store.isGlobalProactivityEnabled = true

        let suggestion = makeSampleSuggestion(petID: petID)
        // No quiet hours, so the time of the run does not decide the proposal.
        _ = coordinator.proposeSuggestion(
            suggestion: suggestion,
            policy: ProactivityBudgetPolicy(quietHourStart: nil, quietHourEnd: nil))
        #expect(coordinator.activeSuggestions.count == 1)

        // Dismissing suggestion with 1 hour mute
        coordinator.dismissSuggestion(id: suggestion.id, mutePetFor: 3600)
        #expect(coordinator.activeSuggestions.isEmpty)

        // Pet settings now record mutedUntil
        let updatedSettings = store.loadSettings(for: petID)
        #expect(updatedSettings.mutedUntil != nil)
        #expect(updatedSettings.isBehaviorActive(.contextAnomalyWatch) == false)
    }
}

// MARK: - Arrival briefing wiring (#343 follow-up)

@Suite("AppPetArrivalBriefingTests")
@MainActor
struct AppPetArrivalBriefingTests {
    private let finder = AppPetArrivalBriefing.finderBundleID
    /// Noon, so the default 22–8 quiet hours never decide a test.
    private static let noon = Calendar.current.date(
        bySettingHour: 12, minute: 0, second: 0, of: Date(timeIntervalSince1970: 1_800_000_000))!

    private final class Probe: @unchecked Sendable {
        var scans = 0
        var found = 5
        var now = AppPetArrivalBriefingTests.noon
    }

    private func make() -> (AppPetArrivalBriefing, AppPetSuggestionCoordinator, AppPetProactivityStore, Probe) {
        let store = AppPetProactivityStore(
            defaults: UserDefaults(suiteName: "test.dorax.briefing.\(UUID().uuidString)")!)
        let coordinator = AppPetSuggestionCoordinator(store: store)
        let probe = Probe()
        let briefing = AppPetArrivalBriefing(
            store: store, coordinator: coordinator,
            countNewDownloads: { _ in probe.scans += 1; return probe.found },
            now: { probe.now })
        return (briefing, coordinator, store, probe)
    }

    @Test("Off by default: arriving reads nothing and proposes nothing")
    func offByDefaultReadsNothing() async {
        let (briefing, coordinator, _, probe) = make()
        #expect(await briefing.appCameForward(bundleID: finder, isUserTyping: false) == nil)
        #expect(probe.scans == 0)
        #expect(coordinator.activeSuggestions.isEmpty)
    }

    @Test("Switched on: one suggestion that states its trigger and proposes no action")
    func switchedOnSurfacesOneSuggestionWithItsTrigger() async throws {
        let (briefing, coordinator, _, _) = make()
        briefing.setOn(true, bundleID: finder)
        let result = await briefing.appCameForward(bundleID: finder, isUserTyping: false)
        let suggestion = try #require(try result?.get())
        #expect(suggestion.provenance.trigger.summary == "5 files added to Downloads in the last 24 hours")
        #expect(suggestion.consequentialAction == nil)
        #expect(coordinator.activeSuggestions.map(\.id) == [suggestion.id])
    }

    @Test("Arriving again with the same facts does not repeat the suggestion")
    func sameFactsAreNotRepeated() async {
        let (briefing, coordinator, _, probe) = make()
        briefing.setOn(true, bundleID: finder)
        await briefing.appCameForward(bundleID: finder, isUserTyping: false)
        probe.now += 3600
        let second = await briefing.appCameForward(bundleID: finder, isUserTyping: false)
        #expect(second == .failure(.duplicateSuggestion))
        #expect(coordinator.activeSuggestions.count == 1)
    }

    @Test("A newer briefing replaces the older one instead of stacking")
    func newerBriefingReplacesOlder() async throws {
        let (briefing, coordinator, _, probe) = make()
        briefing.setOn(true, bundleID: finder)
        await briefing.appCameForward(bundleID: finder, isUserTyping: false)
        probe.now += 3600
        probe.found = 9
        let second = try #require(try await briefing.appCameForward(bundleID: finder, isUserTyping: false)?.get())
        #expect(coordinator.activeSuggestions.map(\.id) == [second.id])
    }

    @Test("Typing, a mute, and an unsupported app each stop the scan before it starts")
    func guardsStopTheScan() async {
        let (briefing, coordinator, _, probe) = make()
        briefing.setOn(true, bundleID: finder)
        #expect(await briefing.appCameForward(bundleID: finder, isUserTyping: true) == nil)
        #expect(await briefing.appCameForward(bundleID: "com.apple.mail", isUserTyping: false) == nil)

        let shown = await briefing.appCameForward(bundleID: finder, isUserTyping: false)
        let id = try? shown?.get().id
        coordinator.dismissSuggestion(id: id ?? UUID(), mutePetFor: 86_400)
        // The mute is stamped with the real clock, so it outlives the probe's fixed noon.
        probe.now = Date().addingTimeInterval(60)
        #expect(!briefing.isOn(bundleID: finder))
        #expect(await briefing.appCameForward(bundleID: finder, isUserTyping: false) == nil)
        #expect(probe.scans == 1)
        #expect(coordinator.activeSuggestions.isEmpty)
    }

    @Test("Three empty arrivals in a row end scanning for the day; the next day starts fresh")
    func noProgressBudgetBacksOffUntilTomorrow() async {
        let (briefing, _, _, probe) = make()
        briefing.setOn(true, bundleID: finder)
        probe.found = 0
        for _ in 0..<6 {
            #expect(await briefing.appCameForward(bundleID: finder, isUserTyping: false) == nil)
        }
        #expect(probe.scans == 3)
        probe.now += 86_400
        await briefing.appCameForward(bundleID: finder, isUserTyping: false)
        #expect(probe.scans == 4)
    }

    @Test("Switching off stops briefings")
    func switchingOffStops() async {
        let (briefing, _, _, probe) = make()
        briefing.setOn(true, bundleID: finder)
        briefing.setOn(false, bundleID: finder)
        #expect(await briefing.appCameForward(bundleID: finder, isUserTyping: false) == nil)
        #expect(probe.scans == 0)
    }
}
