// CancellableProcess.swift
// Context-Dock
//
// Stop, meaning stop.
//
// Pressing Stop ended the agent loop between rounds, and left whatever was already running to
// run. A `find` over the home directory, a `brew` install, a build — the turn was over, the
// spinner was gone, and the process was still going, still holding the continuation the loop
// had awaited. From the user's side the app had stopped; on their machine it had not.
//
// A `Process` inside `withCheckedContinuation` cannot see cancellation: the continuation is
// resumed by a termination handler, and nothing is watching the task. This holds the process
// where a cancellation handler can reach it, so cancelling the turn signals the process the
// same way ⌃C would.

import Foundation

/// A `Process` a cancellation handler can reach.
///
/// Locked rather than actor-isolated: the cancellation handler runs synchronously on whatever
/// thread cancels the task, and cannot await anything to get at the process it must stop.
final class CancellableProcessBox: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false

    /// Adopts the process. Returns false when cancellation already arrived — the caller must
    /// then not start it, because a process launched after Stop is one nothing will stop.
    func adopt(_ process: Process) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !cancelled else { return false }
        self.process = process
        return true
    }

    /// Signals the process to stop, the way ⌃C would. SIGTERM rather than SIGKILL: a tool
    /// that flushes output or removes a lock file on the way out should be allowed to.
    func cancel() {
        lock.lock()
        cancelled = true
        let running = process
        lock.unlock()
        guard let running, running.isRunning else { return }
        running.terminate()
    }

    var wasCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }
}

enum CancellableProcessRunner {

    /// Runs `body` with a box the caller registers its process into, terminating that process
    /// if the surrounding task is cancelled.
    ///
    /// The continuation still resumes normally when the process dies: a terminated process
    /// runs its termination handler like any other, so the caller reports what it produced
    /// before it was stopped rather than hanging or losing the output entirely.
    static func run<T: Sendable>(
        _ body: (CancellableProcessBox) async -> T
    ) async -> T {
        let box = CancellableProcessBox()
        return await withTaskCancellationHandler {
            await body(box)
        } onCancel: {
            box.cancel()
        }
    }

    /// What to append when a command was stopped rather than finishing.
    ///
    /// Reported, not hidden. A half-finished `mv` that was interrupted has left the machine
    /// in a state the next turn should not assume anything about, and the user is the one who
    /// interrupted it — they already know something is unfinished.
    static let stoppedNote = "\n\n[Stopped before it finished.]"
}
