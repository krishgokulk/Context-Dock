// AsyncTimeout.swift
// Context-Dock
//
// A deadline that actually ends the wait.
//
// Both chat surfaces raced work against a sleeper inside `withTaskGroup` and returned
// whichever finished first, cancelling the rest. That reads correct and is not: a task
// group cannot return until every child has finished, so `cancelAll()` only *asks*. Work
// that never reaches a cancellation point — an MCP handshake parked on a continuation
// nobody resumes is the case that bit us — keeps the group open, and the caller waits
// forever on a timeout it believes it has.
//
// So the loser is abandoned rather than awaited. The orphan runs on to whatever end it
// finds and its result is dropped; the caller is released at the deadline with the
// fallback, which is what "give up after N seconds" has to mean to be worth writing.

import Foundation
import OSLog

enum AsyncTimeout {

    private static let log = Logger(
        subsystem: "com.krishgokul.ContextDock", category: "AsyncTimeout")

    /// Runs `operation`, returning `fallback` if it has not finished within `seconds`.
    ///
    /// `label` names the work in the log when the deadline wins — a stall that is only
    /// visible as a missing prompt section is the kind that survives for weeks.
    static func run<T: Sendable>(
        seconds: Double,
        fallback: T,
        label: String = "work",
        operation: @escaping @Sendable () async -> T
    ) async -> T {
        let box = FirstResultBox<T>()
        return await withCheckedContinuation { continuation in
            box.attach(continuation)
            Task.detached {
                let value = await operation()
                box.resume(with: value, timedOut: false)
            }
            Task.detached {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                if box.resume(with: fallback, timedOut: true) {
                    log.notice(
                        "gave up on \(label, privacy: .public) after \(seconds, privacy: .public)s")
                }
            }
        }
    }
}

/// Hands the first of two results to a continuation and drops the second. Lock-guarded
/// rather than actor-isolated: whichever task arrives first must be able to resume from
/// wherever it is running, without waiting on an executor to answer for it.
private final class FirstResultBox<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Never>?

    func attach(_ continuation: CheckedContinuation<T, Never>) {
        lock.lock()
        self.continuation = continuation
        lock.unlock()
    }

    /// True when this call is the one that resumed — so only the winner logs.
    @discardableResult
    func resume(with value: T, timedOut: Bool) -> Bool {
        lock.lock()
        guard let continuation else {
            lock.unlock()
            return false
        }
        self.continuation = nil
        lock.unlock()
        continuation.resume(returning: value)
        return true
    }
}
