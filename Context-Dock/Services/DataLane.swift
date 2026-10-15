// DataLane.swift
// Context-Dock
//
// Plan 00-APP-AGENT-PLUGIN-PLAN.md §2a. A request is about an app's *data* (find, read, count,
// create) or its *interface* (windows, tabs, panels, views). The data lane never activates the
// app, never changes focus and never opens a window: an app that is not running is started
// hidden, one that is running is left exactly as it is.

import AppKit
import Foundation

enum RequestLane: String, Equatable {
    case data
    case ui
}

extension RequestLane {
    /// Data is the default; only a request about the interface goes to the UI lane.
    /// Decided once, at understanding. Whole words, so "tabulate" or "viewer" don't count.
    static func decide(_ request: String) -> RequestLane {
        let words = Set(
            request.lowercased()
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { !$0.isEmpty })
        let phrases = request.lowercased()
        if !words.isDisjoint(with: uiWords) { return .ui }
        return uiPhrases.contains(where: phrases.contains) ? .ui : .data
    }

    private static let uiWords: Set<String> = [
        "minimize", "minimise", "maximize", "maximise", "fullscreen", "sidebar", "zoom",
        "window", "windows", "tab", "tabs", "panel", "toolbar", "preferences", "settings",
    ]
    private static let uiPhrases = [
        "mailbox list", "show the mailbox", "hide the mailbox", "full screen", "split view",
    ]
}

/// The two things the data lane may do to an app. Nothing here can bring an app forward.
protocol DataLaneLauncher {
    func isRunning(bundleID: String) -> Bool
    /// Start the app hidden and not activated.
    func launchHidden(bundleID: String) async
}

struct WorkspaceDataLaneLauncher: DataLaneLauncher {
    func isRunning(bundleID: String) -> Bool {
        NSWorkspace.shared.runningApplications.contains {
            $0.bundleIdentifier == bundleID && !$0.isTerminated
        }
    }

    func launchHidden(bundleID: String) async {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.hides = true
        _ = try? await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
    }
}

enum DataLane {
    /// Make the app ready for Apple Events without disturbing the user.
    /// Returns true when the app had to be started (the caller may show that as a step).
    @discardableResult
    static func prepare(
        bundleID: String, launcher: DataLaneLauncher = WorkspaceDataLaneLauncher()
    ) async -> Bool {
        guard !launcher.isRunning(bundleID: bundleID) else { return false }
        await launcher.launchHidden(bundleID: bundleID)
        return true
    }
}
