// AppCatalogService.swift
// Context-Dock
//
// Enumerates installed applications once and caches the result, so the launcher
// shows the full app list the instant it opens instead of walking /Applications,
// reading every bundle's Info.plist, and loading icons on the first keystroke.
//
// Prewarmed from AppDelegate at launch; the launcher's loadApplicationsInBackground
// then reads the cache (near-instant) and refreshes it on demand.

import AppKit
import Foundation

final class AppCatalogService {
    nonisolated static let shared = AppCatalogService()
    nonisolated private init() {}

    private let lock = NSLock()
    nonisolated(unsafe) private var cached: [SearchResult]?

    /// Cached apps if available, else enumerate (and cache) synchronously.
    nonisolated func appsNow() -> [SearchResult] {
        lock.lock()
        if let cached {
            lock.unlock()
            return cached
        }
        lock.unlock()
        let apps = Self.enumerateApplications()
        lock.lock()
        cached = apps
        lock.unlock()
        return apps
    }

    /// Build the catalog off the main thread at app launch.
    nonisolated func prewarm() {
        lock.lock()
        let alreadyWarm = cached != nil
        lock.unlock()
        guard !alreadyWarm else { return }
        Task.detached(priority: .userInitiated) {
            let apps = Self.enumerateApplications()
            let service = AppCatalogService.shared
            service.lock.lock()
            service.cached = apps
            service.lock.unlock()
        }
    }

    /// Force a fresh enumeration (e.g. after an app install/uninstall).
    nonisolated func invalidate() {
        lock.lock()
        cached = nil
        lock.unlock()
    }

    private nonisolated static func normalize(_ value: String) -> String {
        value.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private nonisolated static func shouldIgnore(
        appName: String, bundleIdentifier: String?, path: String
    ) -> Bool {
        if normalize(appName) == "news" { return true }
        if bundleIdentifier == "com.apple.news" { return true }
        let url = URL(fileURLWithPath: path)
        if Bundle(url: url)?.bundleIdentifier == "com.apple.news" { return true }
        if normalize(url.deletingPathExtension().lastPathComponent) == "news" { return true }
        return false
    }

    nonisolated static func enumerateApplications() -> [SearchResult] {
        let fileManager = FileManager.default
        let appDirectories = [
            "/Applications",
            "/System/Applications",
            "/System/Volumes/Preboot/Cryptexes/App/System/Applications",
            "\(NSHomeDirectory())/Applications",
        ]

        var apps: [SearchResult] = []
        var foundPaths = Set<String>()

        for directory in appDirectories {
            guard fileManager.fileExists(atPath: directory) else { continue }
            guard
                let enumerator = fileManager.enumerator(
                    at: URL(fileURLWithPath: directory),
                    includingPropertiesForKeys: [.isDirectoryKey],
                    options: [.skipsHiddenFiles]
                )
            else { continue }

            for case let fileURL as URL in enumerator {
                guard fileURL.pathExtension == "app" else { continue }
                let resolvedURL = fileURL.resolvingSymlinksInPath()
                let displayPath = fileURL.path
                let realPath = resolvedURL.path
                guard !foundPaths.contains(realPath) else { continue }
                foundPaths.insert(realPath)

                let appName = fileURL.deletingPathExtension().lastPathComponent
                let bundleId = Bundle(url: fileURL)?.bundleIdentifier
                guard !shouldIgnore(appName: appName, bundleIdentifier: bundleId, path: displayPath)
                else {
                    enumerator.skipDescendants()
                    continue
                }
                let icon = NSWorkspace.shared.icon(forFile: fileURL.path)
                let capturedPath = displayPath
                let capturedURL = fileURL
                let capturedBundleId = bundleId
                let capturedName = appName
                apps.append(
                    SearchResult(
                        title: appName,
                        subtitle: displayPath,
                        icon: icon,
                        action: {
                            NSWorkspace.shared.open(capturedURL)
                            UsageTracker.shared.recordAccess(for: "app:\(capturedPath)")
                            if let bid = capturedBundleId {
                                AppUsageLearner.shared.recordApp(
                                    bundleID: bid, appName: capturedName)
                                AppLaunchTracker.shared.record(bundleId: bid)
                            }
                        },
                        type: .application,
                        filePath: displayPath,
                        contactData: nil
                    ))
                enumerator.skipDescendants()
            }
        }

        // Fallback: ensure Safari is found via NSWorkspace.
        if !foundPaths.contains(where: { $0.contains("Safari.app") }),
            let safariURL = NSWorkspace.shared.urlForApplication(
                withBundleIdentifier: "com.apple.Safari")
        {
            let appName = safariURL.deletingPathExtension().lastPathComponent
            let icon = NSWorkspace.shared.icon(forFile: safariURL.path)
            apps.append(
                SearchResult(
                    title: appName,
                    subtitle: safariURL.path,
                    icon: icon,
                    action: {
                        NSWorkspace.shared.open(safariURL)
                        UsageTracker.shared.recordAccess(for: "app:\(safariURL.path)")
                        AppUsageLearner.shared.recordApp(
                            bundleID: "com.apple.Safari", appName: appName)
                        AppLaunchTracker.shared.record(bundleId: "com.apple.Safari")
                    },
                    type: .application,
                    filePath: safariURL.path,
                    contactData: nil
                ))
        }

        return apps.sorted { $0.title.lowercased() < $1.title.lowercased() }
    }
}
