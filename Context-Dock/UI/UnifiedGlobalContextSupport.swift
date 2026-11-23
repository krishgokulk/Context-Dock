// UnifiedGlobalContextSupport.swift
// Context-Dock
//
// Keeps Unified Global Context alive with frontmost-app Contextual Actions,
// Finder front-folder browsing, and running-application rows without growing
// AppChatMenuBrowsing.swift.

import AppKit
import Foundation
import Quartz

extension AppChatPromptModel {
    /// Contextual actions for the underlying frontmost app in Global Context:
    /// - When Finder is frontmost: lists the active Finder folder (or Desktop / current
    ///   `finderBrowseStack` subfolder) so files/folders appear immediately.
    /// - For other apps: lists matching adapter actions (and top cached menu commands when empty).
    func frontmostContextualActionRows(for typed: String) -> [AppChatRow] {
        guard let frontApp = AppDelegate.shared?.previousFrontmostApp,
            !frontApp.isTerminated,
            let bundleID = frontApp.bundleIdentifier,
            !bundleID.isEmpty,
            bundleID != Bundle.main.bundleIdentifier
        else { return [] }

        let appName = frontApp.localizedName ?? "App"
        let section = GlobalResultSection.contextualActionsTitle(forApp: appName)
        let trimmed = typed.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        if bundleID == "com.apple.finder" {
            guard let folder = finderBrowseStack.last
                ?? (finderShowsDesktopOnly ? FinderFrontFolder.desktop : finderFrontFolder)
                ?? FinderFrontFolder.desktop
            else { return [] }
            let urls = Self.folderListing(folder, matching: typed)
            return urls.prefix(8).map { url in
                let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
                var pill = DockPill(
                    id: "global-finder-\(url.path)",
                    name: url.lastPathComponent,
                    icon: isDir ? "folder" : "doc",
                    badge: folder.lastPathComponent,
                    execute: { [weak self] in
                        if isDir {
                            self?.finderBrowseStack.append(url)
                            self?.updateMenuMatches()
                        } else {
                            NSWorkspace.shared.open(url)
                        }
                    }
                )
                pill.resolvedURL = url
                pill.previewPath = url.path
                pill.sourceBundleId = bundleID
                pill.sourceAppName = appName
                pill.resultSection = section
                return AppChatRow.dock(pill)
            }
        }

        var items: [AppChatRow] = []
        if let adapter = AppAdapterManager.shared.adapter(for: bundleID) {
            let matching = trimmed.isEmpty
                ? Array(adapter.actions.prefix(4))
                : adapter.actions.filter {
                    $0.name.lowercased().contains(trimmed)
                        || $0.description.lowercased().contains(trimmed)
                }
            for action in matching.prefix(5) {
                var pill = DockPill(
                    id: "global-ctx-action-\(bundleID)-\(action.id)",
                    name: action.name,
                    icon: "bolt.fill",
                    badge: "\(appName) Action",
                    execute: { [weak self] in self?.runAdapterAction(action) }
                )
                pill.sourceBundleId = bundleID
                pill.sourceAppName = appName
                pill.resultSection = section
                items.append(.dock(pill))
            }
        }
        return items
    }

    /// Currently running regular applications for the empty-query Global Context board.
    func globalRunningApplicationRows(limit: Int = 6) -> [AppChatRow] {
        let own = Bundle.main.bundleIdentifier
        return NSWorkspace.shared.runningApplications
            .filter {
                $0.activationPolicy == .regular && !$0.isTerminated
                    && $0.bundleIdentifier != own
            }
            .prefix(limit)
            .compactMap { app -> AppChatRow? in
                guard let bundleID = app.bundleIdentifier, !bundleID.isEmpty else { return nil }
                let name = app.localizedName ?? bundleID
                var pill = DockPill(
                    id: "global-running-\(bundleID)",
                    name: name,
                    icon: "app",
                    badge: "Running",
                    execute: { AppActivation.bringForward(bundleID: bundleID, name: name) }
                )
                pill.menuItemImage = app.icon
                pill.sourceBundleId = bundleID
                pill.sourceAppName = name
                pill.rankingKind = "application"
                pill.resultSection = GlobalResultSection.applications
                return .dock(pill)
            }
    }

    /// Populates the Global Context board when `↓` opens the list on an empty query.
    func populateEmptyGlobalContextBoard() {
        var combined: [AppChatRow] = []
        combined += elevatedFrontmostPinRows(for: "")
        combined += frontmostContextualActionRows(for: "")
        combined += globalRunningApplicationRows(limit: 6)
        rows = GlobalResultSection.capped(
            combined,
            expanded: expandedGlobalSections
        ) { section, hidden in
            var pill = DockPill(
                id: "show-more-\(section)", name: "Show \(hidden) more",
                icon: "chevron.down", badge: nil, execute: {})
            pill.rankingKind = GlobalResultSection.showMoreKind
            pill.resultSection = section
            return pill
        }
        focusedMenuIndex = rows.isEmpty ? nil : 0
    }

    /// Running app targets for Siri-style AI fallbacks: frontmost app first, then up to 3
    /// other currently running regular apps, each carrying its app icon.
    func globalFallbackAppTargets(runningLimit: Int = 3) -> [GlobalFallbackAppTarget] {
        let own = Bundle.main.bundleIdentifier
        var targets: [GlobalFallbackAppTarget] = []
        var seen = Set<String>()

        if let front = AppDelegate.shared?.previousFrontmostApp,
            !front.isTerminated,
            let bundleID = front.bundleIdentifier,
            !bundleID.isEmpty,
            bundleID != own
        {
            seen.insert(bundleID)
            targets.append(
                GlobalFallbackAppTarget(
                    bundleID: bundleID,
                    name: front.localizedName ?? "App",
                    icon: front.icon,
                    isFrontmost: true
                )
            )
        }

        for app in NSWorkspace.shared.runningApplications {
            guard targets.count < 1 + runningLimit else { break }
            guard app.activationPolicy == .regular,
                !app.isTerminated,
                let bundleID = app.bundleIdentifier,
                !bundleID.isEmpty,
                bundleID != own,
                seen.insert(bundleID).inserted
            else { continue }
            targets.append(
                GlobalFallbackAppTarget(
                    bundleID: bundleID,
                    name: app.localizedName ?? bundleID,
                    icon: app.icon,
                    isFrontmost: false
                )
            )
        }
        return targets
    }

    /// Opens a running app's App Pet chat from Global Context and submits the question.
    func askAppChatFromGlobal(bundleID: String, name: String, question: String) {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let running = NSWorkspace.shared.runningApplications.first {
            $0.bundleIdentifier == bundleID && !$0.isTerminated
        }
        let target = CornerChatTarget(
            name: name,
            bundleID: bundleID,
            suggestions: AppChatSuggestionProvider.suggestions(for: running),
            summary: AppChatSuggestionProvider.summary(for: running)
        )
        CornerDockController.shared.chatPresentation.showFrontmostApp(target: target)
        query = trimmed
        _ = submit()
    }
}
