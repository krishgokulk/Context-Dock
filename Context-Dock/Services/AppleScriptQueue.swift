import Foundation

/// The one queue AppleScript runs on.
///
/// `NSAppleScript` is not thread-safe: two scripts executing at once on different threads
/// can crash inside AppleScript itself. It did — clicking a tab in the corner's Safari bar
/// switched the tab (`SafariTabManager.switchTo`) while the tab list was being re-read
/// (`fetchTabs`) and the current page asked for (`currentTab`), three scripts on three
/// global-queue threads, and the app died with EXC_BAD_ACCESS in
/// `TUASApplication::SetSupportsOperator` (2026-09-26). Serial, so scripts wait their turn
/// instead of racing; each one is short, so the wait is too.
///
/// Every `NSAppleScript` in the app executes through `executeSerialized(error:)`, which
/// takes the script lock; `shared.async` is where code that wants a script off the main
/// thread sends it.
enum AppleScriptQueue {
    nonisolated private static let marker = DispatchSpecificKey<Void>()

    nonisolated static let shared: DispatchQueue = {
        let queue = DispatchQueue(
            label: "com.krishgokul.ContextDock.applescript", qos: .userInitiated)
        queue.setSpecific(key: marker, value: ())
        return queue
    }()

    /// True while running a block on `shared`.
    nonisolated static var isCurrent: Bool { DispatchQueue.getSpecific(key: marker) != nil }

    /// One script at a time, recursively: another thread waits its turn, and the thread
    /// already holding it runs in place.
    ///
    /// A lock, not `shared.sync`. Swift's `DispatchQueue.sync` goes through `asyncAndWait`,
    /// which may run the block on a thread other than the caller's, and a script waiting for
    /// its Apple Event reply spins the run loop — the main queue's pending work, another
    /// script included, runs inside it on the thread that is holding the queue but is not on
    /// it. Both crashed (2026-09-26: `__DISPATCH_WAIT_FOR_QUEUE__`, then a trap in
    /// `_syncHelper`). A recursive lock is owned by a thread, which is exactly the question.
    nonisolated private static let lock: NSRecursiveLock = {
        let lock = NSRecursiveLock()
        lock.name = "com.krishgokul.ContextDock.applescript"
        return lock
    }()

    nonisolated private static let depthKey = "com.krishgokul.ContextDock.applescript.depth"

    /// True while this thread is inside `sync` — including from code the run loop runs
    /// during a script.
    nonisolated static var isHeldByThisThread: Bool {
        ((Thread.current.threadDictionary[depthKey] as? Int) ?? 0) > 0
    }

    /// Runs `work` serialized with every other script and returns its result, on the
    /// calling thread — a script the main thread used to run still runs on the main thread,
    /// only never beside another one.
    nonisolated static func sync<T>(_ work: () throws -> T) rethrows -> T {
        lock.lock()
        let dictionary = Thread.current.threadDictionary
        let depth = (dictionary[depthKey] as? Int) ?? 0
        dictionary[depthKey] = depth + 1
        defer {
            if depth == 0 {
                dictionary.removeObject(forKey: depthKey)
            } else {
                dictionary[depthKey] = depth
            }
            lock.unlock()
        }
        return try work()
    }
}

extension NSAppleScript {
    /// `executeAndReturnError(_:)`, waiting its turn on `AppleScriptQueue` so it can never
    /// run at the same time as another script.
    @discardableResult
    nonisolated func executeSerialized(
        error errorInfo: AutoreleasingUnsafeMutablePointer<NSDictionary?>?
    ) -> NSAppleEventDescriptor {
        AppleScriptQueue.sync { executeAndReturnError(errorInfo) }
    }
}
