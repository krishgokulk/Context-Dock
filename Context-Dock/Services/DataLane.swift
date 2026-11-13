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
        "toggle",
    ]
    private static let uiPhrases = [
        "mailbox list", "show the mailbox", "hide the mailbox", "full screen", "split view",
    ]

    /// A menu press lands only on the frontmost app, so the UI lane activates it before the
    /// click; the data lane never does (plan §2a rule 1). Pass to
    /// `AXMenuReader.clickMenuItem(activatesApp:)`.
    var activatesAppForMenuClick: Bool { self == .ui }

    /// Routing instruction for the model prompt. UI-lane requests prefer run_menu_command as the
    /// first route; data-lane requests prefer direct capabilities and scripts over menus.
    /// §6–7 of docs/superpowers/specs/2026-11-09-agent-harness-model.md (H4).
    static func menuRouteInstruction(for request: String) -> String {
        switch decide(request) {
        case .ui:
            return "MENU ROUTE: This is an interface request. Prefer run_menu_command as the first route. Use find_menu_command to locate the exact item if the path is not known, then run it."
        case .data:
            return "MENU ROUTE: This is a data request. Prefer direct capabilities, connectors, MCP tools, and scripts. Do not press a menu when a direct or script route exists."
        }
    }
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
        guard
            let app = try? await NSWorkspace.shared.openApplication(
                at: url, configuration: configuration)
        else { return }
        // openApplication returns when the process exists, not when it answers Apple Events;
        // the first event sent too early fails ("Mail context could not be read").
        for _ in 0..<100 where !app.isFinishedLaunching && !app.isTerminated {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        try? await Task.sleep(nanoseconds: 800_000_000)
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
