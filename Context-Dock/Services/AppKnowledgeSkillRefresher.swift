//
//  AppKnowledgeSkillRefresher.swift
//  Context-Dock
//
//  Builds the learned skill for each adapter from what the app has already told us, and
//  keeps it current without rewriting it behind the user's back.
//
//  Everything read here is local and already cached. The Help subtree comes out of
//  AppMenuCapabilityCache — no menu is opened, because opening a menu to find something
//  out is the habit this replaces.
//

import AppKit
import Foundation

@MainActor
enum AppKnowledgeSkillRefresher {

    static func refreshAll() {
        for adapter in AppAdapterManager.shared.adapters {
            let bundleId = adapter.bundleId
            guard !bundleId.isEmpty, !bundleId.hasPrefix("scope://") else { continue }
            refresh(bundleId: bundleId, appName: adapter.appName)
        }
    }

    static func refresh(bundleId: String, appName: String) {
        let version = installedVersion(bundleId: bundleId)
        let existing = SkillStore.shared.skills(for: bundleId)
            .first { $0.id == AppKnowledgeSkill.id(for: bundleId) }

        // The app has not changed, so neither has what we know about it. Re-writing on
        // every launch would also throw away any edit the user made to the text.
        if let existing, !version.isEmpty, existing.version == version { return }

        guard var skill = AppKnowledgeSkill.make(
            bundleId: bundleId,
            appName: appName,
            version: version,
            helpTitles: helpTitles(bundleId: bundleId, appName: appName),
            capabilities: capabilities(bundleId: bundleId, appName: appName))
        else { return }

        // A skill the user switched off stays off through a refresh; the refresh is about
        // the content being current, not about overriding that decision.
        if let existing { skill.isEnabled = existing.isEnabled }
        SkillStore.shared.upsert(skill)
    }

    // MARK: - Sources

    /// The app's own Help menu, from the cache. These titles are the subjects the vendor
    /// wrote help for, which is the closest thing to a statement of what the app is.
    private static func helpTitles(bundleId: String, appName: String) -> [String] {
        AppMenuCapabilityCache.shared
            .menuItems(bundleIdentifier: bundleId, appName: appName, maxResults: 400)
            .filter { $0.path.first == "Help" && $0.path.count > 1 }
            .map(\.title)
    }

    private static func capabilities(
        bundleId: String, appName: String
    ) -> AppKnowledgeSkill.Capabilities {
        let adapter = AppAdapterManager.shared.adapter(for: bundleId)
        // The learned skill is not one of the user's own workflows, so it does not count
        // itself towards them.
        let ownID = AppKnowledgeSkill.id(for: bundleId)
        let userSkills = SkillStore.shared.skills(for: bundleId).filter { $0.id != ownID }
        return .init(
            actions: adapter?.actions.count ?? 0,
            cliTools: ScopedGroundingBlocks.runnableCommandBinaries(forBundleId: bundleId).count,
            skills: userSkills.count,
            menuCommands: AppMenuCapabilityCache.shared
                .summary(bundleIdentifier: bundleId)?.recordCount ?? 0,
            mcpServers: MCPServerManager.shared.servers(forBundleId: bundleId).count,
            apiConnections: 0)
    }

    private static func installedVersion(bundleId: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId),
            let info = Bundle(url: url)?.infoDictionary
        else { return "" }
        return (info["CFBundleShortVersionString"] as? String)
            ?? (info["CFBundleVersion"] as? String)
            ?? ""
    }
}
