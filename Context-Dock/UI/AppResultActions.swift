// AppResultActions.swift
// Context-Dock
//
// What Global Context's card offers for an app row (owner 2026-10-11): a running app shows
// its window and can be quit with ⌘⌫; a closed one says when it was last opened and can be
// launched straight into its Context Dock (→) or handed the file selected in Finder (⇧↩).

import AppKit

enum AppResultActions {
    static func runningApp(_ bundleID: String) -> NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .first { !$0.isTerminated }
    }

    /// Finder's selection as the accessibility reader last saw it — no AppleScript, which
    /// on the main thread is what crashed the corner (decision "AppleScriptQueue…").
    static var finderSelection: [String] {
        let context = AXContextReader.shared.current
        return context.bundleId == "com.apple.finder" ? context.selectedFilePaths : []
    }

    /// The first selected file the app opens. `canOpen` is injected so tests need no disk.
    static func openableFile(
        selection: [String], canOpen: (URL) -> Bool
    ) -> URL? {
        selection.lazy.map { URL(fileURLWithPath: $0) }.first(where: canOpen)
    }

    static func finderFile(openableBy appURL: URL) -> URL? {
        openableFile(selection: finderSelection) {
            NSWorkspace.shared.urlsForApplications(toOpen: $0).contains(appURL)
        }
    }

    /// Spotlight's last-used date for the app, as "2 days ago".
    static func lastOpened(_ appURL: URL) -> String? {
        guard let item = MDItemCreateWithURL(nil, appURL as CFURL),
            let date = MDItemCopyAttribute(item, kMDItemLastUsedDate) as? Date
        else { return nil }
        return RelativeDateTimeFormatter().localizedString(for: date, relativeTo: Date())
    }

    /// Launch without taking focus: the corner stays up to show the app's Context Dock.
    static func launchQuietly(_ bundleID: String) {
        guard runningApp(bundleID) == nil,
            let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        NSWorkspace.shared.openApplication(at: url, configuration: configuration)
    }
}

extension AppChatPromptModel {
    /// The app the highlighted row names — the row whose card is showing.
    var focusedAppRow: (name: String, bundleID: String)? {
        guard case .global(let doc)? = focusedRow else { return nil }
        return Self.appToStepInto(doc)
    }

    /// ⌘⌫ on a running app's row quits it. The app asks about unsaved work itself.
    func quitFocusedApp() -> Bool {
        guard let app = focusedAppRow, let running = AppResultActions.runningApp(app.bundleID)
        else { return false }
        running.terminate()
        return true
    }

    /// ⇧↩ on a closed app's row opens the file selected in Finder with it.
    func openFinderFileWithFocusedApp() -> Bool {
        guard let app = focusedAppRow, AppResultActions.runningApp(app.bundleID) == nil,
            let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: app.bundleID),
            let file = AppResultActions.finderFile(openableBy: appURL)
        else { return false }
        NSWorkspace.shared.open(
            [file], withApplicationAt: appURL, configuration: NSWorkspace.OpenConfiguration())
        return true
    }
}
