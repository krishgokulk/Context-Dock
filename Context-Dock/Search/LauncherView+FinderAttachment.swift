import AppKit
import Foundation
import SwiftUI

extension LauncherView {

    func isCurrentMailContextAttached() -> Bool {
        guard
            frontmost.bundleID == "com.apple.mail"
                || contextTargetApp()?.bundleIdentifier == "com.apple.mail"
        else { return false }
        return isMailContextAttached
    }





    func isFinderFolderSearchAttached(currentFolderPath: String? = nil) -> Bool {
        let folderPath =
            currentFolderPath.map { URL(fileURLWithPath: $0).standardizedFileURL.path }
            ?? URL(fileURLWithPath: currentFinderFolderPath()).standardizedFileURL.path
        guard !attachedFinderFolderSearchPath.isEmpty else { return false }
        return attachedFinderFolderSearchPath == folderPath
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
