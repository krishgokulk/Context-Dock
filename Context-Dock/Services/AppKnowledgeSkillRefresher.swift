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
        refresh(bundleId: bundleId, appName: appName, websiteKnowledge: nil)

        // The product page, when the user asked for it and told us where it is. Fetched
        // after the local skill is already in place, so an unreachable page delays nothing
        // and a switched-off setting costs nothing.
        guard AppSettings.shared.appWebsiteKnowledgeEnabled,
            let website = AppAdapterManager.shared.adapter(for: bundleId)?.website,
            AppWebsiteKnowledge.fetchableURL(from: website) != nil
        else { return }
        let version = installedVersion(bundleId: bundleId)
        Task {
            guard let knowledge = await AppWebsiteKnowledge.knowledge(
                bundleId: bundleId, version: version, website: website)
            else { return }
            await MainActor.run {
                refresh(bundleId: bundleId, appName: appName, websiteKnowledge: knowledge)
            }
        }
    }

    private static func refresh(
        bundleId: String, appName: String, websiteKnowledge: String?
    ) {
        let version = installedVersion(bundleId: bundleId)
        let existing = SkillStore.shared.skills(for: bundleId)
            .first { $0.id == AppKnowledgeSkill.id(for: bundleId) }

        // The app has not changed, so neither has what we know about it. Re-writing on
        // every launch would also throw away any edit the user made to the text. A page
        // that has just arrived is new knowledge, so it passes.
        if let existing, !version.isEmpty, existing.version == version,
            websiteKnowledge == nil { return }

        guard var skill = AppKnowledgeSkill.make(
            bundleId: bundleId,
            appName: appName,
            version: version,
            helpTitles: helpTitles(bundleId: bundleId, appName: appName),
            capabilities: capabilities(bundleId: bundleId, appName: appName),
            websiteKnowledge: websiteKnowledge)
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
