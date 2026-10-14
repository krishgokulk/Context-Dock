import AppKit
import SwiftUI
import UniformTypeIdentifiers

final class GlobalApplicationMetadataCache: @unchecked Sendable {
    static let shared = GlobalApplicationMetadataCache()

    private let lock = NSLock()
    private var bundleIdentifiersByPath: [String: String?] = [:]
    private var applicationURLsByBundleIdentifier: [String: URL?] = [:]

    func bundleIdentifier(forPath path: String?) -> String? {
        guard let path, !path.isEmpty else { return nil }
        let standardizedPath = URL(fileURLWithPath: path).standardizedFileURL.path
        lock.lock()
        if let cached = bundleIdentifiersByPath[standardizedPath] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        let resolved = Bundle(path: standardizedPath)?.bundleIdentifier
        lock.lock()
        bundleIdentifiersByPath[standardizedPath] = resolved
        lock.unlock()
        return resolved
    }

    func applicationURL(bundleIdentifier: String) -> URL? {
        guard !bundleIdentifier.isEmpty else { return nil }
        lock.lock()
        if let cached = applicationURLsByBundleIdentifier[bundleIdentifier] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        let resolved = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
        lock.lock()
        applicationURLsByBundleIdentifier[bundleIdentifier] = resolved
        lock.unlock()
        return resolved
    }
}

extension LauncherView {
    func bundleIdentifierForApplicationPath(_ path: String?) -> String? {
        GlobalApplicationMetadataCache.shared.bundleIdentifier(forPath: path)
    }

    func applicationURLForBundleIdentifier(_ bundleIdentifier: String) -> URL? {
        GlobalApplicationMetadataCache.shared.applicationURL(bundleIdentifier: bundleIdentifier)
    }

    func currentRegularRunningApps() -> [NSRunningApplication] {
        GlobalSearchIndexBuilder.currentRegularRunningApps()
    }








    func resolvedPinnedIcon(for app: PinnedApp) -> NSImage? {
        if app.type == .application {
            if let bundleId = app.bundleIdentifier,
                let runningURL = runningRegularApps.first(where: {
                    $0.bundleIdentifier == bundleId
                })?.bundleURL
            {
                return preparedDockIcon(NSWorkspace.shared.icon(forFile: runningURL.path))
            }
            if let bundleId = app.bundleIdentifier,
                let appURL = applicationURLForBundleIdentifier(bundleId)
            {
                return preparedDockIcon(NSWorkspace.shared.icon(forFile: appURL.path))
            }
        }

        return preparedDockIcon(NSWorkspace.shared.icon(forFile: app.path))
    }





    func groupedGlobalApplicationList(limit: Int) -> [SearchResult] {
        var results: [SearchResult] = []
        var seen = Set<String>()

        func bundleIdentifier(for path: String?) -> String? {
            bundleIdentifierForApplicationPath(path)
        }

        func add(_ result: SearchResult) {
            guard results.count < limit else { return }
            let bundleId = bundleIdentifier(for: result.filePath ?? result.subtitle)
            guard
                !shouldIgnoreApplicationFromAppSearch(
                    appName: result.title,
                    bundleIdentifier: bundleId,
                    path: result.filePath ?? result.subtitle
                )
            else { return }

            let key = bundleId ?? result.filePath ?? result.subtitle.lowercased()
            guard seen.insert(key).inserted else { return }
            results.append(result)
        }

        let runningSource =
            runningRegularApps.isEmpty ? currentRegularRunningApps() : runningRegularApps
        for app in runningSource
        where results.count < limit && app.bundleIdentifier != "com.apple.finder" {
            guard let name = app.localizedName else { continue }
            let path = app.bundleURL?.path
            let bundleId = app.bundleIdentifier
            guard
                !shouldIgnoreApplicationFromAppSearch(
                    appName: name,
                    bundleIdentifier: bundleId,
                    path: path
                )
            else { continue }

            let key = bundleId ?? path ?? name.lowercased()
            guard seen.insert(key).inserted else { continue }
            results.append(
                SearchResult(
                    title: name,
                    subtitle: path ?? "Running",
                    icon: resolvedRunningAppIcon(for: app),
                    action: { activateRunningAppFromGlobalContext(app) },
                    type: .application,
                    filePath: path,
                    contactData: nil
                ))
        }

        for app in settings.pinnedApps where app.type == .application {
            add(
                SearchResult(
                    title: app.name,
                    subtitle: app.path,
                    icon: resolvedPinnedIcon(for: app),
                    action: { launchPinnedApp(app) },
                    type: .application,
                    filePath: app.path,
                    contactData: nil
                ))
        }

        for app in allApplications where app.type == .application {
            add(app)
        }

        return results
    }


    func resolvedApplicationIcon(bundleIdentifier: String?, appName: String? = nil)
        -> NSImage?
    {
        GlobalSearchIndexBuilder.applicationIcon(
            running: runningRegularApps, apps: allApplications,
            bundleIdentifier: bundleIdentifier, appName: appName)
    }




    func installedApplicationResult(bundleIdentifier: String) -> SearchResult? {
        allApplications.first { result in
            result.type == .application
                && bundleIdentifierForApplicationPath(result.subtitle)
                    == bundleIdentifier
        }
    }

}
