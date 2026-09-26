import Foundation
import Testing
@testable import Context_Dock

/// `NSAppleScript` crashes when two scripts run at once, so every script goes through
/// `AppleScriptQueue`. These pin the two properties that keep that from deadlocking or
/// racing — no script is executed (the suite is offline).
struct AppleScriptQueueTests {
    @Test func syncFromOffTheQueueRunsOnIt() {
        #expect(!AppleScriptQueue.isCurrent)
        let inside = AppleScriptQueue.sync { AppleScriptQueue.isCurrent }
        #expect(inside)
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
