import AppKit
import Foundation
import SwiftUI

extension LauncherView {
    func isCurrentFinderFolderAttachedToConversation() -> Bool {
        guard
            frontmost.bundleID == "com.apple.finder"
                || contextTargetApp()?.bundleIdentifier == "com.apple.finder"
        else { return false }
        guard canAttachCurrentFinderFolderToConversation else { return false }

        return isFinderFolderSearchAttached(currentFolderPath: currentFinderFolderPath())
    }

    func isCurrentMailContextAttached() -> Bool {
        guard
            frontmost.bundleID == "com.apple.mail"
                || contextTargetApp()?.bundleIdentifier == "com.apple.mail"
        else { return false }
        return isMailContextAttached
    }

    func toggleMailContextAttachment() {
        isMailContextAttached.toggle()
    }

    func addCurrentFinderFolderToConversation() {
        refreshCachedFinderCurrentDirectory(for: "com.apple.finder")
        let folderPath = currentFinderFolderPath()
        let normalizedPath = URL(fileURLWithPath: folderPath).standardizedFileURL.path
        guard isAttachableFinderFolder(normalizedPath) else { return }
        guard FileManager.default.fileExists(atPath: normalizedPath) else { return }

        if isFinderFolderSearchAttached(currentFolderPath: normalizedPath) {
            detachFinderFolderSearch(path: normalizedPath)
        } else {
            attachFinderFolderSearch(path: normalizedPath)
            finderFolderQueryModeActive = true
            l2.focusedPillIndex = nil
            focusedAppPillIndex = nil
            l2.pillNavViaKeyboard = false
            expandSearchBar()
            isSearchFieldFocused = true
        }
    }

    @discardableResult
    func attachCurrentFinderFolderFromEmptyFieldIfNeeded() -> Bool {
        guard showContextInDock, !isGlobalContextActive else { return false }
        // Allowed for the unscoped frontmost-Finder dock AND for a Finder app scope — both
        // mean "this Finder window's folder". A non-Finder app scope must not attach.
        guard l2.targetApp == nil || l2.targetApp?.bundleId == "com.apple.finder" else {
            return false
        }
        guard searchState.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }
        guard isSearchInputActiveAtEnd() else { return false }
        guard isFinderFrontmostWindowContext() else { return false }
        guard canAttachCurrentFinderFolderToConversation else { return false }
        guard !isCurrentFinderFolderAttachedToConversation() else { return false }

        addCurrentFinderFolderToConversation()
        scheduleDockPillRebuild(query: "", delayNanoseconds: 0, refreshContext: false)
        requestWindowSizeUpdate(reason: .panelChanged)
        return true
    }

    func isSearchInputActiveAtEnd() -> Bool {
        if searchInputHasHighlightedText() { return false }
        return searchInputCursorIsAtEnd()
    }

    func isFinderFolderSearchAttached(currentFolderPath: String? = nil) -> Bool {
        let folderPath =
            currentFolderPath.map { URL(fileURLWithPath: $0).standardizedFileURL.path }
            ?? URL(fileURLWithPath: currentFinderFolderPath()).standardizedFileURL.path
        guard !attachedFinderFolderSearchPath.isEmpty else { return false }
        return attachedFinderFolderSearchPath == folderPath
    }

    /// Any real folder the frontmost Finder window is showing can be attached as the
    /// current-folder search context — not just home subfolders. Desktop is excluded
    /// (Finder desktop-only mode owns that), as are the home root and filesystem root,
    /// which are too broad to be useful as a folder snapshot.
    func isAttachableFinderFolder(_ path: String) -> Bool {
        let normalizedPath = URL(fileURLWithPath: path).standardizedFileURL.path
        guard !normalizedPath.isEmpty, normalizedPath != "/" else { return false }
        let home = URL(fileURLWithPath: NSHomeDirectory()).standardizedFileURL.path
        guard normalizedPath != "\(home)/Desktop", normalizedPath != home else { return false }
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: normalizedPath, isDirectory: &isDir)
            && isDir.boolValue
    }

    var canAttachCurrentFinderFolderToConversation: Bool {
        guard !isFinderDesktopOnlyMode else { return false }
        return isAttachableFinderFolder(currentFinderFolderPath())
    }

    func attachFinderFolderSearch(path: String) {
        let normalizedPath = URL(fileURLWithPath: path).standardizedFileURL.path
        approvedFinderFolderSearchPaths.insert(normalizedPath)
        attachedFinderFolderSearchPath = normalizedPath
        finderFolderQueryModeActive = true
        refreshCachedFinderCurrentDirectory(for: "com.apple.finder")
        refreshAttachedFinderFolderSnapshot(path: normalizedPath, force: true)
        startAttachedFinderFolderSnapshotWatcher(path: normalizedPath)

        if showContextInDock {
            scheduleFinderSemanticSearchIfNeeded(for: searchState.query)
        }
    }

    func detachFinderFolderSearch(path: String? = nil) {
        let currentAttached = attachedFinderFolderSearchPath
        guard !currentAttached.isEmpty else { return }

        if let path {
            let normalizedPath = URL(fileURLWithPath: path).standardizedFileURL.path
            guard normalizedPath == currentAttached else { return }
        }

        attachedFinderFolderSearchPath = ""
        finderFolderQueryModeActive = false
        stopAttachedFinderFolderSnapshotWatcher()
        attachedFinderFolderSnapshotTask?.cancel()
        attachedFinderFolderSnapshotTask = nil
        attachedFinderFolderSnapshotPath = ""
        attachedFinderFolderSnapshotItems = []
        attachedFinderFolderSnapshotDate = .distantPast
        clearFinderSemanticState()
    }

    @discardableResult
    func detachFinderFolderQueryModeFromEmptyBackspace() -> Bool {
        guard finderFolderQueryModeActive else { return false }
        guard searchState.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }
        guard isFinderFolderSearchAttached() else { return false }

        detachFinderFolderSearch()
        l2.focusedPillIndex = nil
        focusedAppPillIndex = nil
        l2.pillNavViaKeyboard = false
        scheduleDockPillRebuild(query: "", delayNanoseconds: 0)
        isSearchFieldFocused = true
        return true
    }

    func presentFinderFolderSearchPermissionAlert(for path: String) {
        let normalizedPath = URL(fileURLWithPath: path).standardizedFileURL.path
        let folderName = URL(fileURLWithPath: normalizedPath).lastPathComponent
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Allow Folder Search?"
        alert.informativeText =
            "Allow Context-Dock to search names and indexed file contents inside “\(folderName.isEmpty ? normalizedPath : folderName)” for this Finder session."
        alert.addButton(withTitle: "Allow")
        alert.addButton(withTitle: "Cancel")
        alert.icon = NSWorkspace.shared.icon(forFile: normalizedPath)

        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            attachFinderFolderSearch(path: normalizedPath)
        }
    }

    func clearFinderFolderSearchAttachmentIfNeeded() {
        if attachedFinderFolderSearchPath.isEmpty { return }
        if !isFinderFolderSearchAttached() {
            clearFinderSemanticState()
        }
    }

    func startAttachedFinderFolderSnapshotWatcher(path: String) {
        let normalizedPath = URL(fileURLWithPath: path).standardizedFileURL.path
        if attachedFinderFolderSnapshotWatcher?.path == normalizedPath { return }

        stopAttachedFinderFolderSnapshotWatcher()
        attachedFinderFolderSnapshotWatcher = FinderFolderSnapshotWatcher(path: normalizedPath) {
            changedPath in
            Task { @MainActor in
                handleAttachedFinderFolderDidChange(path: changedPath)
            }
        }
    }

    func stopAttachedFinderFolderSnapshotWatcher() {
        attachedFinderFolderSnapshotWatcherTask?.cancel()
        attachedFinderFolderSnapshotWatcherTask = nil
        attachedFinderFolderSnapshotWatcher?.stop()
        attachedFinderFolderSnapshotWatcher = nil
    }

    func handleAttachedFinderFolderDidChange(path: String) {
        let normalizedPath = URL(fileURLWithPath: path).standardizedFileURL.path
        guard attachedFinderFolderSearchPath == normalizedPath else { return }

        attachedFinderFolderSnapshotWatcherTask?.cancel()
        attachedFinderFolderSnapshotWatcherTask = Task(priority: .userInitiated) {
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard attachedFinderFolderSearchPath == normalizedPath else { return }
                refreshAttachedFinderFolderSnapshot(path: normalizedPath, force: true)
                if showContextInDock {
                    scheduleFinderSemanticSearchIfNeeded(for: searchState.query)
                }
            }
        }
    }

    func refreshAttachedFinderFolderSnapshot(path: String? = nil, force: Bool = false) {
        let resolvedPath = URL(
            fileURLWithPath: path ?? attachedFinderFolderSearchPath
        ).standardizedFileURL.path
        guard !resolvedPath.isEmpty else { return }

        if !force,
            attachedFinderFolderSnapshotPath == resolvedPath,
            Date().timeIntervalSince(attachedFinderFolderSnapshotDate) < 2.0
        {
            return
        }

        attachedFinderFolderSnapshotTask?.cancel()
        attachedFinderFolderSnapshotTask = Task(priority: .userInitiated) {
            let items = await Self.readFinderFolderSnapshot(path: resolvedPath, limit: 1_200)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard attachedFinderFolderSearchPath == resolvedPath else { return }
                attachedFinderFolderSnapshotPath = resolvedPath
                attachedFinderFolderSnapshotItems = items
                attachedFinderFolderSnapshotDate = Date()
                scheduleDockPillRebuild(
                    query: searchState.query, delayNanoseconds: 0, refreshContext: false)
            }
        }
    }

    nonisolated static func readFinderFolderSnapshot(
        path: String,
        limit: Int
    ) async -> [FinderFolderSnapshotItem] {
        await Task.detached(priority: .userInitiated) {
            let folderURL = URL(fileURLWithPath: path).standardizedFileURL
            let keys: Set<URLResourceKey> = [.isDirectoryKey, .contentModificationDateKey]
            // Recurse into subfolders so current-folder search behaves like Spotlight
            // (files, folders, and nested contents). Depth is capped so a huge tree
            // can't stall the build, and the item count is limited.
            guard
                let enumerator = FileManager.default.enumerator(
                    at: folderURL,
                    includingPropertiesForKeys: Array(keys),
                    options: [.skipsHiddenFiles, .skipsPackageDescendants]
                )
            else { return [] }

            var items: [FinderFolderSnapshotItem] = []
            for case let url as URL in enumerator {
                if items.count >= limit { break }
                if enumerator.level > 6 {
                    enumerator.skipDescendants()
                    continue
                }
                let standardized = url.standardizedFileURL
                guard !standardized.lastPathComponent.hasPrefix(".") else { continue }
                let values = try? standardized.resourceValues(forKeys: keys)
                items.append(
                    FinderFolderSnapshotItem(
                        url: standardized,
                        path: standardized.path,
                        displayName: standardized.lastPathComponent,
                        isDirectory: values?.isDirectory ?? standardized.hasDirectoryPath,
                        modifiedDate: values?.contentModificationDate
                    ))
            }

            return items.sorted {
                if $0.isDirectory != $1.isDirectory { return $0.isDirectory && !$1.isDirectory }
                return $0.displayName.localizedCaseInsensitiveCompare($1.displayName)
                    == .orderedAscending
            }
        }.value
    }
}
