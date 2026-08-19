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

    func runIfDue() {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        if let last = UserDefaults.standard.object(forKey: lastRunKey) as? Date,
           calendar.startOfDay(for: last) >= today {
            return
        }
        UserDefaults.standard.set(Date(), forKey: lastRunKey)

        let notes = QuickNotesStore.shared.notes
        Task.detached(priority: .utility) {
            DailyBrief.rebuildToday()
            if let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: Date()) {
                DailyBrief.rebuild(for: yesterday)
            }
            // Settles anything the mirror missed while the app was closed — a note deleted
            // elsewhere, or one whose markdown never got written because the app quit
            // inside the debounce window.
            await QuickNoteMemoryMirror.sync(notes)
        }
    }
}
