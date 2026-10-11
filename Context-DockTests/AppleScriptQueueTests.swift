import Foundation
import Testing
@testable import Context_Dock

/// `NSAppleScript` crashes when two scripts run at once, so every script goes through
/// `AppleScriptQueue`. These pin the two properties that keep that from deadlocking or
/// racing — no script is executed (the suite is offline).
struct AppleScriptQueueTests {
    /// On the caller's own thread, holding the lock — never hopped onto the queue's thread,
    /// which is what `DispatchQueue.sync`'s `asyncAndWait` does and what crashed.
    @Test func syncRunsOnTheCallingThreadHoldingTheLock() {
        #expect(!AppleScriptQueue.isHeldByThisThread)
        let caller = Thread.current
        let (sameThread, held) = AppleScriptQueue.sync {
            (Thread.current == caller, AppleScriptQueue.isHeldByThisThread)
        }
        #expect(sameThread)
        #expect(held)
        #expect(!AppleScriptQueue.isHeldByThisThread)
    }

    /// A script started from inside a queued block must not `sync` onto the same serial
    /// queue — that never returns.
    @Test func syncFromOnTheQueueRunsInPlace() async {
        let nested = await withCheckedContinuation { continuation in
            AppleScriptQueue.shared.async {
                continuation.resume(returning: AppleScriptQueue.sync { 42 })
            }
        }
        #expect(nested == 42)
    }

    @Test func blocksNeverOverlap() {
        let lock = NSLock()
        var running = 0
        var overlapped = false
        DispatchQueue.concurrentPerform(iterations: 32) { _ in
            AppleScriptQueue.sync {
                lock.lock(); running += 1; if running > 1 { overlapped = true }; lock.unlock()
                Thread.sleep(forTimeInterval: 0.001)
                lock.lock(); running -= 1; lock.unlock()
            }
        }
        #expect(!overlapped)
    }
}
