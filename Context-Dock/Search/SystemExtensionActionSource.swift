import AppKit
import Foundation
import SwiftUI

extension LauncherView {
    func buildMacOSExtensionActionPills(
        query rawQuery: String,
        excludingTitles: Set<String> = []
    ) -> [DockPill] {
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let services = buildServicesActionSourcePills(
            query: query,
            excludingTitles: excludingTitles
        )
        let serviceTitles = excludingTitles.union(
            services.map { normalizedDockPillText($0.name) }
        )
        let finderQuickActions = buildFinderQuickActionSourcePills(
            query: query,
            excludingTitles: serviceTitles
        )
        let finderTitles = serviceTitles.union(
            finderQuickActions.map { normalizedDockPillText($0.name) }
        )
        let sharing = buildSharingActionSourcePills(
            query: query,
            excludingTitles: finderTitles
        )
        let shortcutTitles = finderTitles.union(
            sharing.map { normalizedDockPillText($0.name) }
        )
        let shortcuts = buildShortcutsActionSourcePills(
            query: query,
            excludingTitles: shortcutTitles
        )
        let appIntentTitles = shortcutTitles.union(
            shortcuts.map { normalizedDockPillText($0.name) }
        )
        let appIntents = buildAppIntentsActionSourcePills(
            query: query,
            excludingTitles: appIntentTitles
        )

        return services + finderQuickActions + sharing + shortcuts + appIntents
    }

    func buildFinderQuickActionSourcePills(
        query: String,
        excludingTitles: Set<String>
    ) -> [DockPill] {
        buildFinderFilePills(query: query).compactMap { pill in
            let title = normalizedDockPillText(pill.name)
            guard !excludingTitles.contains(title) else { return nil }
            var copy = pill
            if copy.rankingKind.isEmpty || copy.rankingKind == "finderSelection" {
                copy.rankingKind = "finderQuickAction"
            }
            copy.sourceBundleId = copy.sourceBundleId.isEmpty ? "com.apple.finder" : copy.sourceBundleId
            copy.sourceAppName = copy.sourceAppName.isEmpty ? "Finder" : copy.sourceAppName
            copy.menuContext = copy.menuContext ?? "Finder"
            copy.trackingIdentifier =
                copy.trackingIdentifier.isEmpty
                ? "finder-quick-action:\(title)"
                : copy.trackingIdentifier
            if copy.searchTerms.isEmpty {
                copy.searchTerms = [copy.name, copy.badge ?? "", "finder", "quick action", "file"]
            } else {
                copy.searchTerms.append(contentsOf: ["finder", "quick action", "file"])
            }
            copy.rankingScore = max(copy.rankingScore, 1_400)
            return copy
        }
    }

    func buildServicesActionSourcePills(
        query: String,
        excludingTitles: Set<String>
    ) -> [DockPill] {
        let contextualPills = buildFinderContextualMenuActionPills(
            query: query,
            excludingTitles: excludingTitles
        )
        if !contextualPills.isEmpty {
            return contextualPills
        }

        return buildFinderSelectionMenuPills(
            query: query,
            excludingTitles: excludingTitles,
            allowedRootNames: ["services", "quick actions"]
        ).map { pill in
            var copy = pill
            copy.rankingKind = "servicesAction"
            copy.menuContext = copy.menuContext ?? "Services"
            copy.searchTerms.append(contentsOf: ["services", "quick actions", "macos extension"])
            copy.rankingScore = max(copy.rankingScore, 1_250)
            return copy
        }
    }

    func buildFinderContextualMenuActionPills(
        query: String,
        excludingTitles: Set<String>
    ) -> [DockPill] {
        let selectedURLs = effectiveFinderSelectionURLsForPills()
        guard !selectedURLs.isEmpty else { return [] }
        let normalizedQuery = normalizedDockPillText(query)
        let actions = FinderContextualMenuActionSource.shared.cachedActions(for: selectedURLs)

        return actions.compactMap { action -> DockPill? in
            let normalizedTitle = normalizedDockPillText(action.title)
            guard !normalizedTitle.isEmpty, !excludingTitles.contains(normalizedTitle) else {
                return nil
            }
            guard macOSExtensionActionMatches(query: normalizedQuery, terms: [action.title] + action.path)
            else { return nil }

            let pathParts = action.path.map(normalizedDockPillText)
            let isQuickAction = pathParts.contains("quick actions")
            let badge = isQuickAction ? "Quick Actions" : "Services"
            let selectedCopy = selectedURLs
            var pill = DockPill(
                id: "finder-contextual-\(action.id)",
                name: action.title,
                icon: isQuickAction ? "sparkles.rectangle.stack" : "gearshape.2",
                accentColorName: isQuickAction ? "purple" : "gray",
                badge: badge,
                execute: {
                    let ok = FinderContextualMenuActionSource.shared.execute(action, selectedURLs: selectedCopy)
                    if !ok {
                        executeFinderSelectionMenuAction(titleContains: action.title)
                    }
                }
            )
            pill.sourceBundleId = "com.apple.finder"
            pill.sourceAppName = "Finder"
            pill.menuContext = badge
            pill.rankingKind = isQuickAction ? "finderQuickAction" : "servicesAction"
            pill.isEnabled = action.isEnabled
            pill.hasLiveAvailability = true
            pill.trackingIdentifier = "finder-contextual:\(action.id)"
            pill.searchTerms = action.path + ["finder", "selection", "quick actions", "services"]
            pill.rankingScore = isQuickAction ? 1_350 : 1_250
            return pill
        }
    }

    func buildSharingActionSourcePills(
        query: String,
        excludingTitles: Set<String>
    ) -> [DockPill] {
        let context = effectiveShareAXContext()
        let items = ShareIntentRouter.shared.shareableItems(for: context)
        guard !items.isEmpty else { return [] }

        let normalizedQuery = normalizedDockPillText(query)
        let services = NSSharingService.sharingServices(forItems: items)
        return services.compactMap { service -> DockPill? in
            let title = service.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { return nil }
            let normalizedTitle = normalizedDockPillText(title)
            guard !excludingTitles.contains(normalizedTitle) else { return nil }
            guard macOSExtensionActionMatches(
                query: normalizedQuery,
                terms: [title, "share", "send", "sharing", service.menuItemTitle]
            ) else { return nil }

            var pill = DockPill(
                id: "sharing-action-\(normalizedTitle)",
                name: title,
                icon: "square.and.arrow.up",
                accentColorName: "blue",
                badge: "Share",
                execute: {
                    let freshItems = ShareIntentRouter.shared.shareableItems(
                        for: effectiveShareAXContext()
                    )
                    guard !freshItems.isEmpty else {
                        AppToast.show(
                            "Nothing to share",
                            icon: "exclamationmark.triangle",
                            tint: .orange
                        )
                        return
                    }
                    guard let destination = ShareDestinationResolver.resolve(
                        query: title,
                        items: freshItems
                    ) else {
                        presentSharingPicker(items: freshItems)
                        return
                    }
                    destination.service.perform(withItems: freshItems)
                    AppToast.show(
                        "Sharing via \(destination.title)",
                        icon: "square.and.arrow.up",
                        tint: .blue
                    )
                }
            )
            pill.menuItemImage = service.image
            pill.isShareAction = true
            pill.sourceBundleId = "com.apple.sharing"
            pill.sourceAppName = "Sharing"
            pill.menuContext = "Sharing"
            pill.rankingKind = "sharingAction"
            pill.trackingIdentifier = "sharing-action:\(normalizedTitle)"
            pill.searchTerms = [title, service.menuItemTitle, "share", "send", "sharing"]
            pill.rankingScore = 1_100
            return pill
        }
        .prefix(12)
        .map { $0 }
    }

    func buildShortcutsActionSourcePills(
        query: String,
        excludingTitles: Set<String>
    ) -> [DockPill] {
        let context = effectiveShareAXContext()
        let fileURLs = context.selectedFilePaths.map(URL.init(fileURLWithPath:))
        let selectedText = context.selectedText?.trimmingCharacters(in: .whitespacesAndNewlines)
        let currentURL = context.currentURL?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !fileURLs.isEmpty || selectedText?.isEmpty == false || currentURL?.isEmpty == false
        else { return [] }

        ShortcutsCatalog.shared.loadIfNeeded()
        let normalizedQuery = normalizedDockPillText(query)
        guard !normalizedQuery.isEmpty else { return [] }

        return ShortcutsCatalog.shared.shortcuts.compactMap { shortcut -> DockPill? in
            let normalizedTitle = normalizedDockPillText(shortcut.name)
            guard !excludingTitles.contains(normalizedTitle) else { return nil }
            guard macOSExtensionActionMatches(
                query: normalizedQuery,
                terms: [shortcut.name, "shortcut", "shortcuts", "automation"]
            ) else { return nil }

            var pill = DockPill(
                id: "shortcut-action-\(normalizedTitle)",
                name: shortcut.name,
                icon: shortcut.iconName,
                accentColorName: shortcut.accentColor,
                badge: "Shortcut",
                execute: {
                    Task {
                        do {
                            let input: ShortcutRunner.DirectInput
                            if !fileURLs.isEmpty {
                                input = .files(fileURLs)
                            } else if let selectedText, !selectedText.isEmpty {
                                input = .text(selectedText)
                            } else {
                                input = .url(currentURL ?? "")
                            }
                            _ = try await ShortcutRunner.shared.runDirectly(shortcut.name, with: input)
                            await MainActor.run {
                                AppToast.show(
                                    "Ran \(shortcut.name)",
                                    icon: shortcut.iconName,
                                    tint: .purple
                                )
                            }
                        } catch {
                            await MainActor.run {
                                AppToast.show(
                                    error.localizedDescription,
                                    icon: "exclamationmark.triangle",
                                    tint: .orange
                                )
                            }
                        }
                    }
                }
            )
            pill.menuItemImage = ShortcutsCatalog.appIcon
            pill.sourceBundleId = "com.apple.shortcuts"
            pill.sourceAppName = "Shortcuts"
            pill.menuContext = "Shortcuts"
            pill.rankingKind = "shortcutsAction"
            pill.trackingIdentifier = "shortcut-action:\(normalizedTitle)"
            pill.searchTerms = [shortcut.name, "shortcut", "shortcuts", "automation"]
            pill.rankingScore = 900
            return pill
        }
        .prefix(8)
        .map { $0 }
    }

    func buildAppIntentsActionSourcePills(
        query: String,
        excludingTitles: Set<String>
    ) -> [DockPill] {
        // Keep this source explicit but quiet until an app exposes a concrete executable adapter.
        // The macOS extension list is not a command list, so generic App Intents are not surfaced here.
        []
    }

    func macOSExtensionActionMatches(query: String, terms: [String]) -> Bool {
        guard !query.isEmpty else { return true }
        let normalizedTerms = terms.map(normalizedDockPillText).filter { !$0.isEmpty }
        return normalizedTerms.contains { term in
            term == query
                || term.hasPrefix(query)
                || term.contains(query)
                || query.contains(term)
                || dockPillTokens(query).contains { queryToken in
                    dockPillTokens(term).contains { termToken in
                        termToken == queryToken || termToken.hasPrefix(queryToken)
                    }
                }
        }
    }
}
