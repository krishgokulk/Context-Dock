// AppPetProactivity.swift
// Context-Dock
//
// Stage 6 (#343) Bounded Proactive Pet Behavior:
// - User-controlled opt-in per Pet and per proactive behavior (off by default).
// - Verified triggers based on read-only facts, clear provenance, and explicit rationale.
// - Interruption budgets, quiet periods, deduplication, and no-progress limits.
// - Suggestions never act, widen scope, or launch UI silently.
// - Consequential actions strictly require normal exact approval.
// - Unified suggestion state shared across Notification, Dock, and Detached Pet views.
//
// Follows docs/superpowers/plans/2026-10-27-app-pets-rollout.md § Stage 6 and
// docs/master/00-AI-ENGINE-PLAN.md § 5b (Watch Mode / E18 / E19).

import Foundation
import Combine

// MARK: - Proactive Behavior Kinds

/// Categorization of bounded proactive behavior an App Pet can perform.
enum AppPetProactiveBehaviorKind: String, Codable, CaseIterable, Hashable, Sendable {
    /// Briefing on arrival when the Pet's scope comes frontmost (e.g. unread count, downloaded files).
    case arrivalBriefing
    /// Suggesting recognized routines and workflows (e.g. "Export PDF then email").
    case routineProposal
    /// Watching read-only state while away (e.g. duplicate files in ~/Downloads, app version updates).
    case contextAnomalyWatch
}

// MARK: - Proactivity Settings

/// Per-Pet proactive configuration. Opt-in only: defaults to completely disabled.
struct AppPetProactivitySettings: Codable, Hashable, Sendable {
    /// Whether proactive suggestions are enabled for this Pet. OFF by default.
    var isEnabled: Bool = false
    /// Specific behaviors enabled for this Pet. Empty by default.
    var enabledBehaviors: Set<AppPetProactiveBehaviorKind> = []
    /// Optional mute timestamp: if in the future, suggestions are silenced.
    var mutedUntil: Date? = nil
    /// Maximum number of interruptions allowed per 24h window for this Pet.
    var maxDailySuggestions: Int = 3
    /// Minimum cooldown in seconds between suggestions for this Pet.
    var minCooldownSeconds: TimeInterval = 1800 // 30 minutes

    init(
        isEnabled: Bool = false,
        enabledBehaviors: Set<AppPetProactiveBehaviorKind> = [],
        mutedUntil: Date? = nil,
        maxDailySuggestions: Int = 3,
        minCooldownSeconds: TimeInterval = 1800
    ) {
        self.isEnabled = isEnabled
        self.enabledBehaviors = enabledBehaviors
        self.mutedUntil = mutedUntil
        self.maxDailySuggestions = maxDailySuggestions
        self.minCooldownSeconds = minCooldownSeconds
    }

    /// Checks if a specific proactive behavior is active at a given date.
    func isBehaviorActive(_ behavior: AppPetProactiveBehaviorKind, at date: Date = Date()) -> Bool {
        guard isEnabled else { return false }
        guard enabledBehaviors.contains(behavior) else { return false }
        if let mutedUntil, mutedUntil > date {
            return false
        }
        return true
    }
}

// MARK: - Triggers & Provenance

/// Origin source for an observed proactive trigger.
enum AppPetTriggerSource: Codable, Hashable, Sendable {
    case appContext(bundleID: String)
    case fileSystem(path: String)
    case appUpdate(bundleID: String, newVersion: String)
    case routinePattern(patternID: String)
    case custom(source: String)
}

/// A verified, read-only trigger that caused a Pet suggestion to be considered.
struct AppPetTrigger: Codable, Hashable, Sendable {
    let source: AppPetTriggerSource
    let summary: String
    let timestamp: Date
    let observedFacts: [String: String]

    init(
        source: AppPetTriggerSource,
        summary: String,
        timestamp: Date = Date(),
        observedFacts: [String: String] = [:]
    ) {
        self.source = source
        self.summary = summary
        self.timestamp = timestamp
        self.observedFacts = observedFacts
    }
}

/// Full provenance chain explaining why the Pet surfaced and what changed.
struct AppPetProvenance: Codable, Hashable, Sendable {
    let petID: AppPetID
    let trigger: AppPetTrigger
    let rationale: String
    let proposedActionName: String?
    let isConsequential: Bool

    init(
        petID: AppPetID,
        trigger: AppPetTrigger,
        rationale: String,
        proposedActionName: String? = nil,
        isConsequential: Bool = false
    ) {
        self.petID = petID.normalized
        self.trigger = trigger
        self.rationale = rationale
        self.proposedActionName = proposedActionName
        self.isConsequential = isConsequential
    }
}

// MARK: - Consequential Actions

/// A proposed action attached to a suggestion.
/// Under Stage 6 rules:
/// - Suggestions NEVER act silently.
/// - Consequential actions always require explicit, unprompted user approval.
struct AppPetConsequentialAction: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    let actionName: String
    let description: String
    let requiresApproval: Bool
    var isApproved: Bool
    var executedAt: Date?

    init(
        id: UUID = UUID(),
        actionName: String,
        description: String,
        requiresApproval: Bool = true,
        isApproved: Bool = false,
        executedAt: Date? = nil
    ) {
        self.id = id
        self.actionName = actionName
        self.description = description
        // Safety invariant: Consequential actions ALWAYS require approval
        self.requiresApproval = requiresApproval
        self.isApproved = isApproved
        self.executedAt = executedAt
    }
}

// MARK: - App Pet Suggestion Model

/// Status of an App Pet proactive suggestion.
enum AppPetSuggestionStatus: String, Codable, Hashable, Sendable {
    case active
    case dismissed
    case muted
    case approved
    case executed
    case expired
}

/// A bounded proactive suggestion surfaced by an App Pet.
struct AppPetSuggestion: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    let petID: AppPetID
    let title: String
    let detail: String
    let behavior: AppPetProactiveBehaviorKind
    let provenance: AppPetProvenance
    var consequentialAction: AppPetConsequentialAction?
    var status: AppPetSuggestionStatus
    let createdAt: Date
    var expiresAt: Date?

    init(
        id: UUID = UUID(),
        petID: AppPetID,
        title: String,
        detail: String,
        behavior: AppPetProactiveBehaviorKind,
        provenance: AppPetProvenance,
        consequentialAction: AppPetConsequentialAction? = nil,
        status: AppPetSuggestionStatus = .active,
        createdAt: Date = Date(),
        expiresAt: Date? = nil
    ) {
        self.id = id
        self.petID = petID.normalized
        self.title = title
        self.detail = detail
        self.behavior = behavior
        self.provenance = provenance
        self.consequentialAction = consequentialAction
        self.status = status
        self.createdAt = createdAt
        self.expiresAt = expiresAt
    }

    /// Fingerprint used for deduplication across scopes and time.
    var deduplicationFingerprint: String {
        let actionPart = consequentialAction?.actionName ?? "none"
        return "\(petID.canonicalKey)|\(behavior.rawValue)|\(provenance.trigger.summary)|\(actionPart)"
    }
}

// MARK: - Budget Policy & Interruption Reasons

/// Reason why a proactive suggestion was rejected or suppressed.
enum InterruptionRejectionReason: String, Codable, Hashable, Sendable, Error {
    case proactivityDisabled
    case petDisabled
    case behaviorDisabled
    case petMuted
    case dailyBudgetExceeded
    case cooldownActive
    case quietPeriodActive
    case duplicateSuggestion
    case userIsActiveOrTyping
    case actionUnapproved
}

/// Policy parameters governing interruption budgets and quiet periods.
struct ProactivityBudgetPolicy: Codable, Hashable, Sendable {
    var maxDailySuggestionsPerPet: Int = 3
    var minCooldownSeconds: TimeInterval = 1800 // 30 mins
    var deduplicationWindowSeconds: TimeInterval = 86400 // 24 hours
    /// Quiet hours range in local 24-hour clock: e.g. 22 (10pm) to 8 (8am).
    var quietHourStart: Int? = 22
    var quietHourEnd: Int? = 8

    init(
        maxDailySuggestionsPerPet: Int = 3,
        minCooldownSeconds: TimeInterval = 1800,
        deduplicationWindowSeconds: TimeInterval = 86400,
        quietHourStart: Int? = 22,
        quietHourEnd: Int? = 8
    ) {
        self.maxDailySuggestionsPerPet = maxDailySuggestionsPerPet
        self.minCooldownSeconds = minCooldownSeconds
        self.deduplicationWindowSeconds = deduplicationWindowSeconds
        self.quietHourStart = quietHourStart
        self.quietHourEnd = quietHourEnd
    }

    /// Evaluates whether the given calendar hour falls within the quiet hours window.
    func isHourInQuietPeriod(_ hour: Int) -> Bool {
        guard let start = quietHourStart, let end = quietHourEnd else { return false }
        if start < end {
            return hour >= start && hour < end
        } else {
            // Spans midnight, e.g. 22 to 8
            return hour >= start || hour < end
        }
    }
}

/// Context passed to evaluate whether a suggestion may surface.
struct ProactivityEvaluationContext: Sendable {
    var currentTime: Date = Date()
    var isUserTypingOrInteracting: Bool = false
    var isInCallOrDND: Bool = false
    var suggestionHistory: [AppPetSuggestion] = []
    var petSettings: AppPetProactivitySettings = AppPetProactivitySettings()
    var isProactivityGloballyEnabled: Bool = false
    var calendar: Calendar = .current

    init(
        currentTime: Date = Date(),
        isUserTypingOrInteracting: Bool = false,
        isInCallOrDND: Bool = false,
        suggestionHistory: [AppPetSuggestion] = [],
        petSettings: AppPetProactivitySettings = AppPetProactivitySettings(),
        isProactivityGloballyEnabled: Bool = false,
        calendar: Calendar = .current
    ) {
        self.currentTime = currentTime
        self.isUserTypingOrInteracting = isUserTypingOrInteracting
        self.isInCallOrDND = isInCallOrDND
        self.suggestionHistory = suggestionHistory
        self.petSettings = petSettings
        self.isProactivityGloballyEnabled = isProactivityGloballyEnabled
        self.calendar = calendar
    }
}

// MARK: - Proactivity Evaluator

/// Result of evaluating whether a proactive suggestion may surface.
enum ProactivityEvaluationResult: Equatable, Sendable {
    case allowed
    case rejected(InterruptionRejectionReason)

    var isAllowed: Bool {
        if case .allowed = self { return true }
        return false
    }

    var rejectionReason: InterruptionRejectionReason? {
        if case .rejected(let reason) = self { return reason }
        return nil
    }
}

/// Pure deterministic evaluator enforcing opt-in defaults, budgets, quiet periods, and deduplication.
enum ProactivityEvaluator {
    static func evaluate(
        suggestion: AppPetSuggestion,
        context: ProactivityEvaluationContext,
        policy: ProactivityBudgetPolicy = ProactivityBudgetPolicy()
    ) -> ProactivityEvaluationResult {
        // 1. Global proactivity must be explicitly enabled
        guard context.isProactivityGloballyEnabled else {
            return .rejected(.proactivityDisabled)
        }

        // 2. Per-Pet proactivity must be explicitly enabled
        guard context.petSettings.isEnabled else {
            return .rejected(.petDisabled)
        }

        // 3. The specific behavior kind must be explicitly opted into
        guard context.petSettings.enabledBehaviors.contains(suggestion.behavior) else {
            return .rejected(.behaviorDisabled)
        }

        // 4. Mute check
        if let mutedUntil = context.petSettings.mutedUntil, mutedUntil > context.currentTime {
            return .rejected(.petMuted)
        }

        // 5. Active user interaction check: never interrupt while typing
        if context.isUserTypingOrInteracting {
            return .rejected(.userIsActiveOrTyping)
        }

        // 6. Quiet period check (Do Not Disturb / in-call or quiet hours)
        if context.isInCallOrDND {
            return .rejected(.quietPeriodActive)
        }
        let currentHour = context.calendar.component(.hour, from: context.currentTime)
        if policy.isHourInQuietPeriod(currentHour) {
            return .rejected(.quietPeriodActive)
        }

        let petKey = suggestion.petID.canonicalKey
        let relevantHistory = context.suggestionHistory.filter { $0.petID.canonicalKey == petKey }

        // 7. Deduplication check
        let fingerprint = suggestion.deduplicationFingerprint
        let hasDuplicate = relevantHistory.contains { past in
            guard past.deduplicationFingerprint == fingerprint else { return false }
            let age = context.currentTime.timeIntervalSince(past.createdAt)
            return age >= 0 && age < policy.deduplicationWindowSeconds
        }
        if hasDuplicate {
            return .rejected(.duplicateSuggestion)
        }

        // 8. Cooldown check
        if let latest = relevantHistory.max(by: { $0.createdAt < $1.createdAt }) {
            let elapsed = context.currentTime.timeIntervalSince(latest.createdAt)
            let cooldown = max(policy.minCooldownSeconds, context.petSettings.minCooldownSeconds)
            if elapsed >= 0 && elapsed < cooldown {
                return .rejected(.cooldownActive)
            }
        }

        // 9. Interruption budget (daily limit)
        let dailyLimit = min(policy.maxDailySuggestionsPerPet, context.petSettings.maxDailySuggestions)
        let recentCount = relevantHistory.filter { past in
            let age = context.currentTime.timeIntervalSince(past.createdAt)
            return age >= 0 && age < 86400
        }.count
        if recentCount >= dailyLimit {
            return .rejected(.dailyBudgetExceeded)
        }

        return .allowed
    }
}

// MARK: - Headless Monitoring Budget & Execution

/// Bounded limits for headless background monitoring scans.
struct HeadlessMonitoringBudget: Codable, Hashable, Sendable {
    var maxTokens: Int = 1000
    var maxDurationSeconds: TimeInterval = 5.0
    var maxRounds: Int = 1
    var maxConsecutiveNoProgressScans: Int = 3

    init(
        maxTokens: Int = 1000,
        maxDurationSeconds: TimeInterval = 5.0,
        maxRounds: Int = 1,
        maxConsecutiveNoProgressScans: Int = 3
    ) {
        self.maxTokens = maxTokens
        self.maxDurationSeconds = maxDurationSeconds
        self.maxRounds = maxRounds
        self.maxConsecutiveNoProgressScans = maxConsecutiveNoProgressScans
    }
}

/// Breach classifications when monitoring limits are exceeded.
enum MonitoringBudgetBreach: String, Codable, Hashable, Sendable, Error {
    case tokenLimitExceeded
    case timeLimitExceeded
    case roundLimitExceeded
    case maxNoProgressExceeded
}

/// Deterministic tracker for headless monitoring execution.
final class HeadlessMonitoringBudgetTracker: @unchecked Sendable {
    let budget: HeadlessMonitoringBudget
    private(set) var cumulativeTokens: Int = 0
    private(set) var cumulativeDuration: TimeInterval = 0.0
    private(set) var roundCount: Int = 0
    private(set) var consecutiveNoProgressCount: Int = 0

    init(budget: HeadlessMonitoringBudget = HeadlessMonitoringBudget()) {
        self.budget = budget
    }

    /// True once any limit is reached: the caller must not start another scan.
    var isExhausted: Bool {
        cumulativeTokens > budget.maxTokens
            || cumulativeDuration >= budget.maxDurationSeconds
            || roundCount >= budget.maxRounds
            || consecutiveNoProgressCount >= budget.maxConsecutiveNoProgressScans
    }

    /// Records a monitoring scan iteration, validating against token, time, round, and no-progress limits.
    func recordScan(tokens: Int, duration: TimeInterval, foundProgress: Bool) throws {
        // Enforce no-progress limit first: if already at cap, prevent further scans
        if !foundProgress && consecutiveNoProgressCount >= budget.maxConsecutiveNoProgressScans {
            throw MonitoringBudgetBreach.maxNoProgressExceeded
        }

        roundCount += 1
        cumulativeTokens += tokens
        cumulativeDuration += duration

        if foundProgress {
            consecutiveNoProgressCount = 0
        } else {
            consecutiveNoProgressCount += 1
        }

        if cumulativeTokens > budget.maxTokens {
            throw MonitoringBudgetBreach.tokenLimitExceeded
        }
        if cumulativeDuration > budget.maxDurationSeconds {
            throw MonitoringBudgetBreach.timeLimitExceeded
        }
        if roundCount > budget.maxRounds {
            throw MonitoringBudgetBreach.roundLimitExceeded
        }
        if consecutiveNoProgressCount >= budget.maxConsecutiveNoProgressScans {
            throw MonitoringBudgetBreach.maxNoProgressExceeded
        }
    }
}

// MARK: - Central Suggestion State & Coordinator

/// Shared store managing proactivity settings and suggestion history in UserDefaults.
final class AppPetProactivityStore: @unchecked Sendable {
    static let settingsKey = "dorax.apppet.proactivity.settings.v1"
    static let globalEnabledKey = "dorax.apppet.proactivity.global_enabled.v1"
    static let historyKey = "dorax.apppet.proactivity.history.v1"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var isGlobalProactivityEnabled: Bool {
        get { defaults.bool(forKey: Self.globalEnabledKey) }
        set { defaults.set(newValue, forKey: Self.globalEnabledKey) }
    }

    func loadSettings(for petID: AppPetID) -> AppPetProactivitySettings {
        let key = petID.canonicalKey
        guard let data = defaults.dictionary(forKey: Self.settingsKey)?[key] as? Data,
              let settings = try? JSONDecoder().decode(AppPetProactivitySettings.self, from: data)
        else {
            return AppPetProactivitySettings() // Default: disabled
        }
        return settings
    }

    func saveSettings(_ settings: AppPetProactivitySettings, for petID: AppPetID) {
        let key = petID.canonicalKey
        var dict = defaults.dictionary(forKey: Self.settingsKey) ?? [:]
        if let data = try? JSONEncoder().encode(settings) {
            dict[key] = data
            defaults.set(dict, forKey: Self.settingsKey)
        }
    }

    func loadHistory() -> [AppPetSuggestion] {
        guard let data = defaults.data(forKey: Self.historyKey),
              let list = try? JSONDecoder().decode([AppPetSuggestion].self, from: data)
        else {
            return []
        }
        return list
    }

    func saveHistory(_ history: [AppPetSuggestion]) {
        guard let data = try? JSONEncoder().encode(history) else { return }
        defaults.set(data, forKey: Self.historyKey)
    }

    func appendSuggestion(_ suggestion: AppPetSuggestion) {
        var list = loadHistory()
        list.append(suggestion)
        // Keep max 200 items in persistent history
        if list.count > 200 {
            list.removeFirst(list.count - 200)
        }
        saveHistory(list)
    }

    func updateSuggestionStatus(id: UUID, status: AppPetSuggestionStatus) {
        var list = loadHistory()
        if let idx = list.firstIndex(where: { $0.id == id }) {
            list[idx].status = status
            saveHistory(list)
        }
    }
}

/// Central MainActor coordinator synchronizing bounded suggestions across:
/// 1. Floating Desktop Pet companion bubbles (`AppPetActionBubble`)
/// 2. Dock Strip and Corner Chat presentations
/// 3. Notification and approval flows
@MainActor
final class AppPetSuggestionCoordinator: ObservableObject {
    static let shared = AppPetSuggestionCoordinator()

    @Published private(set) var activeSuggestions: [AppPetSuggestion] = []

    private let store: AppPetProactivityStore
    private var actionExecutors: [String: @Sendable (AppPetSuggestion) async throws -> Void] = [:]

    init(store: AppPetProactivityStore = AppPetProactivityStore()) {
        self.store = store
        let now = Date()
        self.activeSuggestions = store.loadHistory().filter {
            $0.status == .active && ($0.expiresAt.map { $0 > now } ?? true)
        }
    }

    /// Register an execution handler for an approved consequential action.
    func registerActionExecutor(
        actionName: String,
        executor: @escaping @Sendable (AppPetSuggestion) async throws -> Void
    ) {
        actionExecutors[actionName] = executor
    }

    /// Evaluates and proposes a bounded proactive suggestion.
    /// If accepted by budget and policies, surfaces across Detached Pet and Dock views.
    @discardableResult
    func proposeSuggestion(
        suggestion: AppPetSuggestion,
        context: ProactivityEvaluationContext? = nil,
        policy: ProactivityBudgetPolicy = ProactivityBudgetPolicy()
    ) -> Result<AppPetSuggestion, InterruptionRejectionReason> {
        let evalContext: ProactivityEvaluationContext
        if let provided = context {
            evalContext = provided
        } else {
            let settings = store.loadSettings(for: suggestion.petID)
            let history = store.loadHistory()
            evalContext = ProactivityEvaluationContext(
                currentTime: Date(),
                isUserTypingOrInteracting: false,
                isInCallOrDND: false,
                suggestionHistory: history,
                petSettings: settings,
                isProactivityGloballyEnabled: store.isGlobalProactivityEnabled
            )
        }

        let evaluation = ProactivityEvaluator.evaluate(
            suggestion: suggestion,
            context: evalContext,
            policy: policy
        )

        switch evaluation {
        case .allowed:
            var active = suggestion
            active.status = .active
            // One line per Pet and behavior: a newer briefing replaces the older one, and
            // anything past its expiry leaves with it.
            let stale = activeSuggestions.filter {
                ($0.petID == active.petID && $0.behavior == active.behavior)
                    || ($0.expiresAt.map { $0 <= evalContext.currentTime } ?? false)
            }
            for old in stale {
                activeSuggestions.removeAll { $0.id == old.id }
                store.updateSuggestionStatus(id: old.id, status: .expired)
                syncDismissalToDetachedPet(old)
            }
            activeSuggestions.append(active)
            store.appendSuggestion(active)

            // Sync suggestion bubble onto detached Pet mascot if active
            syncSuggestionToDetachedPet(active)

            return .success(active)
        case .rejected(let reason):
            return .failure(reason)
        }
    }

    /// Dismisses a suggestion across all views simultaneously.
    func dismissSuggestion(id: UUID, mutePetFor: TimeInterval? = nil) {
        guard let idx = activeSuggestions.firstIndex(where: { $0.id == id }) else { return }
        let suggestion = activeSuggestions.remove(at: idx)
        store.updateSuggestionStatus(id: id, status: .dismissed)

        if let muteSeconds = mutePetFor {
            var settings = store.loadSettings(for: suggestion.petID)
            settings.mutedUntil = Date().addingTimeInterval(muteSeconds)
            store.saveSettings(settings, for: suggestion.petID)
        }

        // Sync dismissal to detached Pet view
        syncDismissalToDetachedPet(suggestion)
    }

    /// User approval gate: explicitly authorizes a consequential action proposed by a suggestion.
    /// Under Stage 6 rules, actions CANNOT run without this explicit invocation.
    func approveAndExecute(suggestionID: UUID) async throws {
        guard let idx = activeSuggestions.firstIndex(where: { $0.id == suggestionID }) else {
            throw InterruptionRejectionReason.actionUnapproved
        }
        var suggestion = activeSuggestions[idx]
        guard var action = suggestion.consequentialAction else {
            throw InterruptionRejectionReason.actionUnapproved
        }

        // Authorize action
        action.isApproved = true
        action.executedAt = Date()
        suggestion.consequentialAction = action
        suggestion.status = .approved
        activeSuggestions[idx] = suggestion
        store.updateSuggestionStatus(id: suggestionID, status: .approved)

        // Execute via registered executor if available
        if let executor = actionExecutors[action.actionName] {
            try await executor(suggestion)
            suggestion.status = .executed
            if let updatedIdx = activeSuggestions.firstIndex(where: { $0.id == suggestionID }) {
                activeSuggestions.remove(at: updatedIdx)
            }
            store.updateSuggestionStatus(id: suggestionID, status: .executed)
        }
    }

    // MARK: - Synchronizations with Detached Pet Presentation

    private func syncSuggestionToDetachedPet(_ suggestion: AppPetSuggestion) {
        guard let controller = DetachedPetManager.shared.activeControllers[suggestion.petID] else {
            return
        }
        let actionName = suggestion.consequentialAction?.actionName
        let bubbleKind = AppPetActionBubbleKind.suggestion(
            suggestionID: suggestion.id,
            title: suggestion.title,
            detail: suggestion.detail,
            trigger: suggestion.provenance.trigger.summary,
            actionName: actionName
        )
        let bubble = AppPetActionBubble(kind: bubbleKind, isPinned: true)
        controller.viewModel.addBubble(bubble)
    }

    private func syncDismissalToDetachedPet(_ suggestion: AppPetSuggestion) {
        guard let controller = DetachedPetManager.shared.activeControllers[suggestion.petID] else {
            return
        }
        // Dismiss corresponding suggestion bubble
        let matching = controller.viewModel.pinnedBubbles.filter { bubble in
            if case .suggestion(let sID, _, _, _, _) = bubble.kind {
                return sID == suggestion.id
            }
            return false
        }
        for bubble in matching {
            controller.viewModel.dismissBubble(id: bubble.id)
        }
    }
}
