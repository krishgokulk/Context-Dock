import AppKit
import Foundation

struct InstalledApplicationEntry: Identifiable {
    let bundleId: String
    let name: String
    let url: URL
    let icon: NSImage?

    var id: String { bundleId }
}

private final class InstalledApplicationsCatalogCache: @unchecked Sendable {
    let lock = NSLock()
    nonisolated(unsafe) var apps: [InstalledApplicationEntry]?
}

private let installedApplicationsCatalogCache = InstalledApplicationsCatalogCache()

enum InstalledApplicationsCatalog {
    nonisolated static func warmUp() {
        Task.detached(priority: .utility) {
            _ = discoverInstalledApps()
        }
    }

    nonisolated static func cachedInstalledApps() -> [InstalledApplicationEntry] {
        installedApplicationsCatalogCache.lock.lock()
        let cached = installedApplicationsCatalogCache.apps
        installedApplicationsCatalogCache.lock.unlock()
        if let cached { return cached }
        // A cold read used to answer "no applications are installed" and leave the cache
        // cold, so the next caller got the same answer. Nothing owned warming it: whichever
        // flow happened to touch an app first did, which made General Chat work only after
        // some other app had been in front — on an empty desktop it could not resolve a
        // single app name, and said so as though the app were not installed.
        //
        // Warmed here instead, once, by whoever asks first. A scan of four directories
        // costs a fraction of the network round trip the caller is already waiting on, and
        // it happens once per launch.
        warmUp()
        return []
    }

    nonisolated static func discoverInstalledApps() -> [InstalledApplicationEntry] {
        installedApplicationsCatalogCache.lock.lock()
        if let cachedApps = installedApplicationsCatalogCache.apps {
            installedApplicationsCatalogCache.lock.unlock()
            return cachedApps
        }
        installedApplicationsCatalogCache.lock.unlock()

        let searchRoots: [URL] = [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            URL(fileURLWithPath: "/Applications/Utilities", isDirectory: true),
            URL(fileURLWithPath: "/System/Applications", isDirectory: true),
            URL(fileURLWithPath: "/System/Applications/Utilities", isDirectory: true),
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true)
        ]
        var seenBundleIds = Set<String>()
        var discovered: [InstalledApplicationEntry] = []

        for root in searchRoots {
            guard FileManager.default.fileExists(atPath: root.path) else { continue }
            guard let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey, .isApplicationKey],
                options: [.skipsHiddenFiles],
                errorHandler: { _, _ in true }
            ) else { continue }

            for case let url as URL in enumerator {
                guard url.pathExtension.caseInsensitiveCompare("app") == .orderedSame else { continue }
                enumerator.skipDescendants()

                guard
                    let bundle = Bundle(url: url),
                    let bundleId = bundle.bundleIdentifier,
                    !bundleId.isEmpty,
                    seenBundleIds.insert(bundleId).inserted
                else { continue }

                let appName = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
                    ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
                    ?? url.deletingPathExtension().lastPathComponent

                discovered.append(
                    InstalledApplicationEntry(
                        bundleId: bundleId,
                        name: appName,
                        url: url,
                        icon: NSWorkspace.shared.icon(forFile: url.path)
                    )
                )
            }
        }

        let sorted = discovered.sorted {
            let lhs = $0.name.localizedLowercase
            let rhs = $1.name.localizedLowercase
            if lhs == rhs { return $0.bundleId < $1.bundleId }
            return lhs < rhs
        }

        installedApplicationsCatalogCache.lock.lock()
        installedApplicationsCatalogCache.apps = sorted
        installedApplicationsCatalogCache.lock.unlock()
        return sorted
    }

    nonisolated static func icon(for bundleId: String) -> NSImage? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) else {
            return nil
        }
        return NSWorkspace.shared.icon(forFile: url.path)
    }
}
