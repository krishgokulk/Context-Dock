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

    func recentDocuments() -> [RecentDocument] {
        if Date().timeIntervalSince(docsLoadedAt) < ttl { return cachedDocs }
        cachedDocs = loadItems(listType: kLSSharedFileListRecentDocumentItems.takeRetainedValue()).compactMap { url in
            guard url.pathExtension.lowercased() != "app" else { return nil }
            let name = url.deletingPathExtension().lastPathComponent
            let icon = NSWorkspace.shared.icon(forFile: url.path)
            return RecentDocument(name: name, url: url, icon: icon)
        }
        docsLoadedAt = Date()
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
