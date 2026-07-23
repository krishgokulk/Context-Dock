// RecentItemsService.swift
// Context-Dock
//
// Reads macOS Recent Items (Applications + Documents) via LSSharedFileList.
// Results are cached for 60 s so repeated calls within a typing session are free.

import AppKit
import CoreServices
import Foundation

final class RecentItemsService {
    static let shared = RecentItemsService()
    private init() {}

    struct RecentApp {
        let name: String
        let url: URL
        let bundleId: String
        let icon: NSImage?
    }

    struct RecentDocument {
        let name: String
        let url: URL
        let icon: NSImage?
    }

    // MARK: - Cache

    private var cachedApps: [RecentApp] = []
    private var cachedDocs: [RecentDocument] = []
    private var appsLoadedAt: Date = .distantPast
    private var docsLoadedAt: Date = .distantPast
    private let ttl: TimeInterval = 60

    // MARK: - Public API

    func recentApplications() -> [RecentApp] {
        if Date().timeIntervalSince(appsLoadedAt) < ttl { return cachedApps }
        cachedApps = loadItems(listType: kLSSharedFileListRecentApplicationItems.takeRetainedValue()).compactMap { url in
            guard url.pathExtension.lowercased() == "app" || url.path.hasSuffix(".app") else { return nil }
            let name = url.deletingPathExtension().lastPathComponent
            guard let bundleId = Bundle(url: url)?.bundleIdentifier else { return nil }
            let icon = NSWorkspace.shared.icon(forFile: url.path)
            return RecentApp(name: name, url: url, bundleId: bundleId, icon: icon)
        }
        appsLoadedAt = Date()
        return cachedApps
    }

    /// A bare CLI executable (no extension, sitting in a bin/sbin dir) — e.g. the
    /// `brew` binary. These show a generic white doc icon and aren't documents, so
    /// they must not appear as "Recent Document" results (the CLI tool scope owns
    /// them instead).
    private static func isCommandLineBinary(_ url: URL) -> Bool {
        guard url.pathExtension.isEmpty else { return false }
        let parent = url.deletingLastPathComponent().lastPathComponent.lowercased()
        guard parent == "bin" || parent == "sbin" else { return false }
        return FileManager.default.isExecutableFile(atPath: url.path)
    }

    func recentDocuments() -> [RecentDocument] {
        if Date().timeIntervalSince(docsLoadedAt) < ttl {
            cachedDocs.removeAll {
                !FileManager.default.fileExists(atPath: $0.url.path)
                    || Self.isCommandLineBinary($0.url)
            }
            return cachedDocs
        }
        let systemURLs = loadItems(
            listType: kLSSharedFileListRecentDocumentItems.takeRetainedValue())
        let spotlightURLs = FileIndexManager.shared.indexedFiles.lazy
            .filter { !$0.isDirectory }
            .prefix(160)
            .map { URL(fileURLWithPath: $0.path) }
        let cachedMenuURLs = AppMenuCapabilityCache.shared.resolvedRecentDocumentURLs()
        var seen = Set<String>()
        cachedDocs = (systemURLs + Array(spotlightURLs) + cachedMenuURLs).compactMap { rawURL in
            let url = rawURL.standardizedFileURL
            guard url.pathExtension.lowercased() != "app",
                FileManager.default.fileExists(atPath: url.path),
                !Self.isCommandLineBinary(url),
                seen.insert(url.path).inserted
            else { return nil }
            return RecentDocument(
                name: url.lastPathComponent,
                url: url,
                icon: NSWorkspace.shared.icon(forFile: url.path)
            )
        }
        docsLoadedAt =
            FileIndexManager.shared.isReady
            ? Date()
            : Date().addingTimeInterval(-(ttl - 2))
        return cachedDocs
    }

    func invalidate() {
        appsLoadedAt = .distantPast
        docsLoadedAt = .distantPast
    }

    // MARK: - Private

    private func loadItems(listType: CFString) -> [URL] {
        guard let rawList = LSSharedFileListCreate(nil, listType, nil) else { return [] }
        let list = rawList.takeRetainedValue()
        var seed: UInt32 = 0
        guard let rawSnapshot = LSSharedFileListCopySnapshot(list, &seed) else { return [] }
        let snapshot = rawSnapshot.takeRetainedValue() as NSArray
        var urls: [URL] = []
        for item in snapshot {
            // swiftlint:disable:next force_cast
            let listItem = item as! LSSharedFileListItem
            var cfUrl: Unmanaged<CFURL>? = nil
            let err = LSSharedFileListItemResolve(listItem, 0, &cfUrl, nil)
            guard err == noErr, let url = cfUrl?.takeRetainedValue() as URL? else { continue }
            urls.append(url)
        }
        return urls
    }
}
