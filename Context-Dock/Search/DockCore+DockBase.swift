import AppKit
import SwiftUI
import UniformTypeIdentifiers

extension DockCore {






    struct PendingTerminalCommand {
        let command: String
        let purpose: String
    }








    // MARK: - Dock Context & Apps Helper Views



    func preparedDockIcon(_ icon: NSImage?) -> NSImage? {
        GlobalSearchIndexBuilder.preparedIcon(icon)
    }








    var isL2ContextActive: Bool {
        // L2 is active whenever the context dock is showing, we're not in pure AI mode,
        // and we're not in L3 browser layer. L3 must stay independent from L2.
        showContextInDock && !aiMode.isActive && !showMediaLayer
    }

    func dismissMediaLayer() {
        if showMediaLayer {
            showMediaLayer = false
        }
    }




    /// L2Extensions from L2ExtensionManager that match the current frontmost app.
    var frontmostAppL2Extensions: [L2Extension] {
        let appName: String
        let bundleID: String
        if !frontmost.name.isEmpty {
            appName = frontmost.name
            bundleID = frontmost.bundleID
        } else if let ws = NSWorkspace.shared.frontmostApplication,
            let name = ws.localizedName,
            !(ws.bundleIdentifier ?? "").contains("ILauncher")
        {
            appName = name
            bundleID = ws.bundleIdentifier ?? ""
        } else {
            return []
        }
        return l2Extensions(forAppName: appName, bundleID: bundleID)
    }

    func l2Extensions(forAppName appName: String, bundleID: String) -> [L2Extension] {
        let appLower = appName.lowercased()
        let bundleLower = bundleID.lowercased()
        return L2ExtensionManager.shared.extensions.filter { ext in
            guard !ext.contextApps.isEmpty else { return false }
            // Check ALL contextApps entries (app name OR bundle ID match)
            return ext.contextApps.contains { ctx in
                let ctxLower = ctx.lowercased()
                return ctxLower == appLower
                    || ctxLower.contains(appLower)
                    || appLower.contains(ctxLower)
                    || (!bundleLower.isEmpty
                        && (ctxLower == bundleLower || ctxLower.contains(bundleLower)))
            }
        }
    }

    func scopedContextExtensions(query: String, appName: String?, bundleId: String?)
        -> [ExtensionDiscoveryResult]
    {
        guard settings.enableContextAIExtensions else { return [] }

        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let includeSelectionContext =
            !isL2ContextActive

        let contextFiles: [URL] = {
            guard includeSelectionContext else { return [] }
            switch currentContext {
            case .filesSelected(let urls): return urls
            default:
                return axContext.selectedFilePaths.map { URL(fileURLWithPath: $0) }
            }
        }()
        let selectedText: String? = {
            guard includeSelectionContext else { return nil }
            switch currentContext {
            case .textSelected(let t): return t.isEmpty ? nil : t
            default: return nil
            }
        }()

        let resolvedAppName: String? = {
            if let appName, !appName.isEmpty { return appName }
            if let bundleId,
                let app = NSWorkspace.shared.runningApplications.first(where: {
                    $0.bundleIdentifier == bundleId
                })
            {
                return app.localizedName
            }
            return nil
        }()

        guard resolvedAppName != nil || !contextFiles.isEmpty || selectedText != nil else {
            return []
        }

        let results = LayeredExtensionManager.shared.discoverExtensions(
            for: trimmedQuery,
            selectedFiles: contextFiles,
            selectedText: selectedText,
            frontmostApp: resolvedAppName,
            layer: .l2_context
        )

        return Array(results.prefix(6))
    }

}
