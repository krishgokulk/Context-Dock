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
/// Every `NSAppleScript` in the app executes through here — either `shared.async` from
/// code that was already off the main thread, or `executeSerialized(error:)` where the
/// caller needs the result in line.
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

    /// Runs `work` serialized with every other script and returns its result.
    ///
    /// Already on the queue (a script started from inside a queued block), it runs in place:
    /// a `sync` onto a serial queue from that same queue never returns. Otherwise it waits
    /// its turn with `sync`, which GCD runs on the calling thread — so a script the main
    /// thread used to run still runs on the main thread, only never beside another one.
    nonisolated static func sync<T>(_ work: () throws -> T) rethrows -> T {
        if isCurrent { return try work() }
        return try shared.sync(execute: work)
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
