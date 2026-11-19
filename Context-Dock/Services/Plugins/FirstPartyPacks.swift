// Context-Dock/Services/Plugins/FirstPartyPacks.swift
// Context-Dock
//
// Loads first-party .doraxpack v2 bundles from the app's Packs/ directory and
// seeds them into the user's plugin directory. Replaces the hardcoded inline
// StorePackCatalog manifests.

import Foundation

@MainActor
enum FirstPartyPacks {

    static let packsDirectoryName = "Packs"

    /// Discover and install all first-party .doraxpack v2 packs.
    /// Called at startup alongside PluginEssentials.seedIfNeeded().
    @discardableResult
    static func loadIfNeeded() -> [StorePackBindResult] {
        guard let packsDir = resolvePacksDirectory() else {
            NSLog("Context-Dock: Packs/ directory not found — first-party packs not loaded")
            return []
        }
        return StorePackInstaller.installAllV2(from: packsDir)
    }

    /// Looks for the Packs/ directory in multiple locations:
    /// 1. Inside the app bundle (release builds)
    /// 2. Next to the source tree (development builds)
    static func resolvePacksDirectory() -> URL? {
        // 1. App bundle Resources/Packs/
        if let bundled = Bundle.main.resourceURL?
            .appendingPathComponent(packsDirectoryName, isDirectory: true),
           FileManager.default.fileExists(atPath: bundled.path) {
            return bundled
        }

        // 2. Source tree: Context-Dock/Packs/ relative to the executable's ancestor
        //    This covers development builds where the app runs from DerivedData.
        let sourceTreeCandidates = sourceTreePacksDirectories()
        for candidate in sourceTreeCandidates {
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
        }

        return nil
    }

    /// All .doraxpack v2 packs found in the resolved Packs/ directory.
    static func allPacks() -> [DoraxPackV2] {
        guard let dir = resolvePacksDirectory() else { return [] }
        let urls = DoraxPackV2Loader.discoverPacks(in: dir)
        return urls.compactMap { url in
            try? DoraxPackV2Loader.load(from: url)
        }
    }

    /// The expected first-party pack IDs, for validation.
    static let expectedPackIDs: Set<String> = [
        "finder", "safari", "mail", "iina", "antigravity"
    ]

    // MARK: - Private

    private static func sourceTreePacksDirectories() -> [URL] {
        var candidates: [URL] = []

        // Walk up from the main bundle to find the repo root.
        // In dev builds the executable is deep inside DerivedData; the repo root
        // has a Context-Dock/ directory with Packs/ inside it.
        let fm = FileManager.default
        let searchRoots = [
            // Direct repo path (covers worktrees and main checkout)
            URL(fileURLWithPath: fm.currentDirectoryPath),
        ]

        // Known repo locations for the development Mac
        let home = fm.homeDirectoryForCurrentUser
        let repoRoot = home
            .appendingPathComponent("Developer/Context-Dock", isDirectory: true)
        let repoPacks = repoRoot
            .appendingPathComponent("Packs", isDirectory: true)
        candidates.append(repoPacks)

        // Also check for worktree paths
        let worktreeBase = repoRoot
            .appendingPathComponent(".claude/worktrees", isDirectory: true)
        if let worktrees = try? fm.contentsOfDirectory(
            at: worktreeBase, includingPropertiesForKeys: [.isDirectoryKey],
            options: .skipsHiddenFiles
        ) {
            for wt in worktrees {
                let wtPacks = wt.appendingPathComponent("Packs", isDirectory: true)
                candidates.append(wtPacks)
            }
        }

        for root in searchRoots {
            candidates.append(
                root.appendingPathComponent("Packs", isDirectory: true))
        }

        return candidates
    }
}
