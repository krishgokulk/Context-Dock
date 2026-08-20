//
//  BrainMaintenance.swift
//  Context-Dock
//
//  The daily pass that keeps derived memory in step with what actually happened.
//
//  Yesterday's brief is written while yesterday is still running, so the copy on disk is
//  always missing whatever happened after it last ran. Nothing ever went back to finish
//  it. That is the whole job here — and deliberately the whole job: everything this
//  touches is derived, so an unattended pass can never lose something the user typed.
//
//  Cache staleness is not handled here on purpose. It is already computed when a cache
//  file is read into a prompt, and marking it on disk as well would be a second copy of
//  the same truth, free to disagree with the first.
//
//  Scheduling is a date check rather than a fire-at-07:00 timer. A Mac is asleep at 7am
//  more often than not, and a timer that missed its slot behind a shut lid simply never
//  runs. Asking "has today's pass happened" answers correctly whenever the machine wakes.
//

import Foundation

@MainActor
final class BrainMaintenance {
    static let shared = BrainMaintenance()

    private let lastRunKey = "dorax.brain.maintenance.lastRun.v1"
    private var timer: Timer?

    private init() {}

    /// Starts the hourly check, and runs immediately if today's pass has not happened.
    func start() {
        syncNotes()
        runIfDue()
        // Hourly, not daily: short enough that a Mac woken at noon still gets its pass,
        // long enough to cost nothing.
        let timer = Timer(timeInterval: 3_600, repeats: true) { _ in
            Task { @MainActor in self.runIfDue() }
        }
        timer.tolerance = 600
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// Mirrors notes on every launch, not once a day.
    ///
    /// The mirror was only ever driven by the Quick Note UI and by the daily pass, and
    /// `QuickNotesStore` is created on first use — so on a launch where neither happened
    /// the store was never even initialised and the markdown went stale silently. A note
    /// edited yesterday, or a change in how links are written, would not reach memory
    /// until something happened to touch Quick Note. The sync itself compares content
    /// before writing, so doing it every launch costs a directory read.
    private func syncNotes() {
        let notes = QuickNotesStore.shared.notes
        Task.detached(priority: .utility) {
            await QuickNoteMemoryMirror.sync(notes)
        }
    }

    func runIfDue() {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        if let last = UserDefaults.standard.object(forKey: lastRunKey) as? Date,
           calendar.startOfDay(for: last) >= today {
            return
        }
        UserDefaults.standard.set(Date(), forKey: lastRunKey)

        // Reads the last two days of the user's own messages. No model call, so this is
        // free and cannot invent anything.
        ConversationDistiller.distillRecentConversations()

        Task.detached(priority: .utility) {
            DailyBrief.rebuildToday()
            if let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: Date()) {
                DailyBrief.rebuild(for: yesterday)
            }

        }
    }
}
