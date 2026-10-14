import AddressBook
import AppIntents
import AppKit
import Combine
import Contacts
import Darwin
import FoundationModels
import PDFKit
import Quartz
import SwiftTerm
import SwiftUI
import UniformTypeIdentifiers
import Vision

extension LauncherView {















    // MARK: - Add Page Button (browser L2 research)


    // MARK: - Safari Tabs + Button (Extension-powered)











    /// The stable folder scope represented by Finder right now. Finder returns its last
    /// browser directory even when every window is closed, so desktop-only mode must not
    /// trust that cached value: its visible place is always `~/Desktop`.
    var currentFinderAIChatFolderURL: URL {
        if isFinderDesktopOnlyMode {
            return FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Desktop", isDirectory: true)
                .standardizedFileURL
        }
        return URL(fileURLWithPath: currentFinderFolderPath()).standardizedFileURL
    }
















    // MARK: - Contextual Quick Actions (type-based)


    func appScopeShortcuts(
        for appKey: String,
        placements: Set<AppShortcut.Placement>
    ) -> [AppShortcut] {
        let builtIns = AppShortcut.builtInDefaults.filter { shortcut in
            (shortcut.appKey == appKey || shortcut.targetAppKeys.contains(appKey))
                && placements.contains(shortcut.placement)
        }
        let custom: [AppShortcut] = {
            var shortcuts: [AppShortcut] = []
            if placements.contains(.quickActions) || placements.contains(.both) {
                shortcuts += settings.shortcuts(for: appKey)
            }
            if placements.contains(.contextDock) || placements.contains(.both) {
                shortcuts += settings.contextDockShortcuts(for: appKey)
            }
            return shortcuts
        }()
        var seen = Set<String>()
        return (builtIns + custom).filter { seen.insert($0.name).inserted }
    }












}
