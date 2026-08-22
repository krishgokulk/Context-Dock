// MenuOutcomeVerifier.swift
// Context-Dock
//
// Reads back what clicking a menu item did to an app's windows.
//
// The menu route reported "executor confirmed success; this route has no independent
// read-back verification" — true, and useless to the person reading it. The executor
// confirms that a click was *sent*, which is exactly the gap CommandOutcomeVerifier exists
// to close for shell commands: sent is not the same as landed, and the difference is
// invisible from inside the thing that sent it.
//
// A menu bar is a poor place to look for the effect, because the effect is rarely in the
// menu. It is nearly always in the window list — About and Settings open a window, Close
// removes one, Quit removes the app. So the app's windows are counted before the click and
// counted again after.
//
// Deliberately narrow, and it says nothing rather than something plausible. "Show Sidebar"
// changes a view inside an existing window and moves none of these numbers; that gets
// silence, not a claim. The one place it will call failure is a menu item whose whole
// purpose is opening a window — About, Settings, Get Info — that opened none.

import AppKit
import ApplicationServices
import Foundation

@MainActor
enum MenuOutcomeVerifier {

    /// An app's window list at a moment in time.
    ///
    /// Titles as well as count: About windows carry an empty title on macOS 26 and Close
    /// followed by a new window leaves the count unchanged, so a count alone would both
    /// miss changes and invent them.
    struct Snapshot {
        let bundleID: String
        let isRunning: Bool
        let windowTitles: [String]
        let nowPlayingTitle: String?
        let playbackState: String
        let playbackBundleID: String?
    }

    static func snapshot(bundleID: String) -> Snapshot? {
        guard !bundleID.isEmpty else { return nil }
        guard let app = NSRunningApplication
            .runningApplications(withBundleIdentifier: bundleID)
            .first(where: { !$0.isTerminated })
        else {
            let media = MediaInfoProvider.shared.getNowPlayingSourceInfo()
            return Snapshot(
                bundleID: bundleID, isRunning: false, windowTitles: [],
                nowPlayingTitle: media.title, playbackState: media.state,
                playbackBundleID: media.bundleID)
        }
        let media = MediaInfoProvider.shared.getNowPlayingSourceInfo()
        return Snapshot(
            bundleID: bundleID, isRunning: true,
            windowTitles: windowTitles(pid: app.processIdentifier),
            nowPlayingTitle: media.title, playbackState: media.state,
            playbackBundleID: media.bundleID)
    }

    /// What changed, in the words of the thing that changed.
    ///
    /// `nil` means nothing here can tell — the caller keeps the executor's own message
    /// rather than dressing an unknown as either outcome.
    static func compare(
        before: Snapshot, appName: String, path: [String]
    ) -> (verified: Bool, message: String)? {
        guard let after = snapshot(bundleID: before.bundleID) else { return nil }
        return compare(before: before, after: after, appName: appName, path: path)
    }

    static func compare(
        before: Snapshot, after: Snapshot, appName: String, path: [String]
    ) -> (verified: Bool, message: String)? {
        let item = path.last ?? ""

        // History selections in media apps commonly keep the same window while changing
        // the system Now Playing session. That is stronger evidence than the click receipt:
        // it identifies both the source app and whether playback actually began.
        if isMediaSelection(path: path),
            after.playbackBundleID?.caseInsensitiveCompare(before.bundleID) == .orderedSame
        {
            let beganPlaying = after.playbackState.lowercased() == "playing"
                && before.playbackState.lowercased() != "playing"
            let changedTitle = after.nowPlayingTitle != nil
                && after.nowPlayingTitle != before.nowPlayingTitle
            if beganPlaying || changedTitle {
                let title = after.nowPlayingTitle ?? item
                return (true, "Verified: \(appName) is playing “\(title)”.")
            }
        }

        if before.isRunning, !after.isRunning {
            return (true, "Verified: \(appName) is no longer running.")
        }
        if !after.isRunning { return nil }

        let opened = after.windowTitles.count - before.windowTitles.count
        if opened > 0 {
            let named = after.windowTitles.first {
                !$0.isEmpty && !before.windowTitles.contains($0)
            }
            return (
                true,
                named.map { "Verified: \(appName) opened “\($0)”." }
                    ?? "Verified: \(appName) opened a new window."
            )
        }
        if opened < 0 {
            return (true, "Verified: \(appName) closed \(-opened) window(s).")
        }
        if after.windowTitles != before.windowTitles {
            return (true, "Verified: \(appName)'s windows changed.")
        }

        // Only where the item's entire job is to put a window on screen is "no new window"
        // evidence of failure. Everywhere else an unchanged window list is the normal
        // outcome of a working command, and calling that a failure would be the same false
        // report in the opposite direction.
        if opensAWindow(item) {
            return (
                false,
                "\(appName) opened no new window, so “\(item)” may not have taken effect."
            )
        }
        return nil
    }

    private static func opensAWindow(_ item: String) -> Bool {
        let lowered = item.lowercased()
        return ["about", "settings", "preferences", "get info", "inspector"]
            .contains { lowered.contains($0) }
    }

    private static func isMediaSelection(path: [String]) -> Bool {
        let words = path.joined(separator: " ").lowercased()
        return ["history", "recent", "watch", "video", "playback", "track", "song"]
            .contains { words.contains($0) }
    }

    private static func windowTitles(pid: pid_t) -> [String] {
        let app = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value)
            == .success,
            let windows = value as? [AXUIElement]
        else { return [] }
        return windows.map { window in
            var title: CFTypeRef?
            guard AXUIElementCopyAttributeValue(
                window, kAXTitleAttribute as CFString, &title) == .success,
                let text = title as? String
            else { return "" }
            return text
        }
    }
}
