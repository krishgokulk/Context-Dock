import AppKit
import Foundation

struct InstalledApplicationEntry: Identifiable {
    let bundleId: String
    let name: String
    let url: URL
    let icon: NSImage?

    var id: String { bundleId }
}

enum InstalledApplicationsCatalog {
    nonisolated static func discoverInstalledApps() -> [InstalledApplicationEntry] {
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

        return discovered.sorted {
            let lhs = $0.name.localizedLowercase
            let rhs = $1.name.localizedLowercase
            if lhs == rhs { return $0.bundleId < $1.bundleId }
            return lhs < rhs
        }
    }

    nonisolated static func icon(for bundleId: String) -> NSImage? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) else {
            return nil
        }
        return NSWorkspace.shared.icon(forFile: url.path)
    }
}
