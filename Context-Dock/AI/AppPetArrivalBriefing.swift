// AppPetArrivalBriefing.swift
// Context-Dock
//
// The first production trigger for Stage 6 (#343): layer 3 of the App Assistant plan
// (docs/master/00-AI-ENGINE-PLAN.md § 5b) — one read-only check when a Pet's app comes forward,
// ending in at most one suggestion. Finder first: files added to Downloads in the last day.
//
// It reads nothing until the owner has switched briefings on for that Pet, never calls a model,
// and never acts: the suggestion is a line in the strip, and tidying is an ordinary chat turn
// with the ordinary approval.

import Foundation

@MainActor
final class AppPetArrivalBriefing {
    static let shared = AppPetArrivalBriefing()

    static let finderBundleID = "com.apple.finder"
    static let lookback: TimeInterval = 86_400

    /// No tokens at all, five seconds of scanning a day, and quiet until tomorrow after three
    /// arrivals in a row that found nothing.
    static let dailyBudget = HeadlessMonitoringBudget(
        maxTokens: 0, maxDurationSeconds: 5, maxRounds: 24, maxConsecutiveNoProgressScans: 3)

    private let store: AppPetProactivityStore
    private let coordinator: AppPetSuggestionCoordinator
    private let countNewDownloads: @Sendable (Date) -> Int
    private let now: @Sendable () -> Date
    private var trackers: [String: (day: Date, tracker: HeadlessMonitoringBudgetTracker)] = [:]

    init(
        store: AppPetProactivityStore = AppPetProactivityStore(),
        coordinator: AppPetSuggestionCoordinator? = nil,
        countNewDownloads: @escaping @Sendable (Date) -> Int = AppPetArrivalBriefing.newDownloads(since:),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.store = store
        self.coordinator = coordinator ?? .shared
        self.countNewDownloads = countNewDownloads
        self.now = now
    }

    /// Apps this build can brief on. The settings switch is only offered for these.
    static func supports(bundleID: String) -> Bool {
        bundleID.caseInsensitiveCompare(finderBundleID) == .orderedSame
    }

    /// Whether arrival briefings are on for this app's Pet.
    func isOn(bundleID: String) -> Bool {
        guard let petID = AppPetID(dockBundleID: bundleID) else { return false }
        return store.isGlobalProactivityEnabled
            && store.loadSettings(for: petID).isBehaviorActive(.arrivalBriefing, at: now())
    }

    /// The owner's one switch per Pet. Turning it on also clears a mute.
    func setOn(_ on: Bool, bundleID: String) {
        guard let petID = AppPetID(dockBundleID: bundleID) else { return }
        var settings = store.loadSettings(for: petID)
        settings.isEnabled = on
        if on {
            settings.enabledBehaviors.insert(.arrivalBriefing)
            settings.mutedUntil = nil
            store.isGlobalProactivityEnabled = true
        } else {
            settings.enabledBehaviors.remove(.arrivalBriefing)
        }
        store.saveSettings(settings, for: petID)
    }

    /// The Pet's app came to the front. Returns nil when nothing was even proposed: briefings
    /// off, the owner typing, today's scan budget spent, or nothing new to report.
    @discardableResult
    func appCameForward(
        bundleID: String, isUserTyping: Bool
    ) async -> Result<AppPetSuggestion, InterruptionRejectionReason>? {
        guard Self.supports(bundleID: bundleID), let petID = AppPetID(dockBundleID: bundleID),
              isOn(bundleID: bundleID), !isUserTyping
        else { return nil }

        let started = now()
        let tracker = tracker(for: petID, at: started)
        guard !tracker.isExhausted else { return nil }

        let count = countNewDownloads
        let since = started.addingTimeInterval(-Self.lookback)
        let found = await Task.detached(priority: .utility) { count(since) }.value
        let finished = now()
        do {
            try tracker.recordScan(
                tokens: 0, duration: finished.timeIntervalSince(started), foundProgress: found > 0)
        } catch {
            // Over budget: this scan's result is dropped rather than surfaced late.
            return nil
        }
        guard found > 0 else { return nil }

        let files = found == 1 ? "1 file" : "\(found) files"
        let trigger = AppPetTrigger(
            source: .fileSystem(path: "~/Downloads"),
            summary: "\(files) added to Downloads in the last 24 hours",
            timestamp: finished,
            observedFacts: ["newFiles": String(found), "folder": "~/Downloads"])
        let suggestion = AppPetSuggestion(
            petID: petID,
            title: "Tidy new downloads?",
            detail: "Finder came forward: \(trigger.summary). Ask me to sort them.",
            behavior: .arrivalBriefing,
            provenance: AppPetProvenance(
                petID: petID, trigger: trigger,
                rationale: "Finder came to the front and arrival briefings are on for this Pet."),
            createdAt: finished,
            expiresAt: finished.addingTimeInterval(Self.lookback))
        return coordinator.proposeSuggestion(
            suggestion: suggestion,
            context: ProactivityEvaluationContext(
                currentTime: finished,
                isUserTypingOrInteracting: isUserTyping,
                suggestionHistory: store.loadHistory(),
                petSettings: store.loadSettings(for: petID),
                isProactivityGloballyEnabled: store.isGlobalProactivityEnabled))
    }

    private func tracker(for petID: AppPetID, at date: Date) -> HeadlessMonitoringBudgetTracker {
        let day = Calendar.current.startOfDay(for: date)
        if let entry = trackers[petID.canonicalKey], entry.day == day { return entry.tracker }
        let fresh = HeadlessMonitoringBudgetTracker(budget: Self.dailyBudget)
        trackers[petID.canonicalKey] = (day, fresh)
        return fresh
    }

    /// Read-only: counts visible items whose "date added" is after `since`. Opens no file.
    nonisolated static func newDownloads(since: Date) -> Int {
        let manager = FileManager.default
        guard let folder = manager.urls(for: .downloadsDirectory, in: .userDomainMask).first,
              let items = try? manager.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: [.addedToDirectoryDateKey],
                options: [.skipsHiddenFiles])
        else { return 0 }
        return items.filter {
            guard let added = try? $0.resourceValues(forKeys: [.addedToDirectoryDateKey])
                .addedToDirectoryDate else { return false }
            return added > since
        }.count
    }
}
