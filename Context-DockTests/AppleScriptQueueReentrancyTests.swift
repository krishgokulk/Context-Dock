import Foundation
import Testing

@testable import Context_Dock

/// A script waiting on its Apple Event reply spins the run loop, and whatever the main queue
/// had pending runs inside it — including another script. That nested call is on the same
/// thread that holds the queue, but not *on* the queue, so the queue-specific check misses
/// it and a second `sync` traps in libdispatch (crash 2026-09-26, dragging a file while a
/// Finder-selection read was in flight).
@Suite("AppleScript queue re-entrancy")
struct AppleScriptQueueReentrancyTests {
    /// The real shape of the crash: work the run loop runs while a script is in flight
    /// starts a script of its own, on the thread that holds the lock.
    @Test func aScriptStartedFromANestedRunLoopRunsInPlace() {
        var nested: Int?
        AppleScriptQueue.sync {
            RunLoop.current.perform { nested = AppleScriptQueue.sync { 42 } }
            _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.2))
        }
        #expect(nested == 42)
    }

    @Test func directNestingStillRunsInPlace() {
        let result = AppleScriptQueue.sync { AppleScriptQueue.sync { "in" } }
        #expect(result == "in")
    }

    /// The flag is the holder's own: once the outer block returns, the next caller waits
    /// its turn on the queue again.
    @Test func theThreadLetsGoOfTheQueueWhenTheBlockEnds() {
        _ = AppleScriptQueue.sync { 1 }
        #expect(!AppleScriptQueue.isHeldByThisThread)
    }
}
