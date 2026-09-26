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
enum AppleScriptQueue {
    static let shared = DispatchQueue(
        label: "com.krishgokul.ContextDock.applescript", qos: .userInitiated)
}
