import AppKit
import Foundation

struct DockPill: Identifiable {
    let id: String
    let name: String
    var icon: String
    var accentColorName: String?
    let badge: String?
    let execute: () -> Void
    var isSeparator: Bool = false
    var isFavourited: Bool = false
    var isEnabled: Bool = true
    var menuItemName: String = ""
    var sourceBundleId: String = ""
    var sourceAppName: String = ""
    var isShareAction: Bool = false
    var rankingKind: String = ""
    var trackingIdentifier: String = ""
    var searchTerms: [String] = []
    var rankingScore: Double = 0
    var menuItemImage: NSImage? = nil
    /// File this row stands for. Set by list extensions whose rows are paths — Space
    /// then Quick Looks it, the way it does in Finder.
    var previewPath: String? = nil
    /// Two-value comparison layout: left value, a symbol, right value. Conversions
    /// read as one thing becoming another, which a title+subtitle line cannot show.
    var compareLeft: String? = nil
    var compareRight: String? = nil
    var compareIcon: String? = nil
    /// Tapping a compare caption replaces the dock query with this string.
    var compareLeftQuery: String? = nil
    var compareRightQuery: String? = nil
    /// List extension that produced this row — the caption dropdown re-runs it.
    var compareCommandID: UUID? = nil
    /// Row id run when the centre symbol is tapped (a swap, typically).
    var compareCenterAction: String? = nil
    var menuContext: String? = nil
    var hasLiveAvailability: Bool = false
    var menuStatusBadge: String? = nil
    var keyboardShortcutLabel: String? = nil
    var quickLookURL: URL? = nil
    var resolvedURL: URL? = nil
    var dragProvider: (() -> NSItemProvider?)? = nil
}

extension DockPill {
    /// Attaches the site favicon (and resolved URL/host badge) for a Safari
    /// History/Bookmarks row. No-op when `url` is nil. Favicon arrives async via
    /// FaviconStore; the dock rebuilds on its `revision` publisher.
    @MainActor
    func applyingSafariFavicon(_ url: URL?) -> DockPill {
        guard let url else { return self }
        var copy = self
        if let favicon = FaviconStore.shared.icon(for: url) {
            copy.menuItemImage = favicon
        }
        FaviconStore.shared.fetchIfNeeded(for: url)
        copy.resolvedURL = url
        if copy.menuStatusBadge == nil { copy.menuStatusBadge = url.host }
        return copy
    }
}

struct SharedResultRowModel: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let systemIcon: String
    var image: NSImage? = nil
    var sourceImage: NSImage? = nil
    var accentColorName: String? = nil
    var trailingText: String? = nil
    var badges: [String] = []
    var isEnabled: Bool = true
    var isUnread: Bool = false
    var isFocused: Bool = false
    var quickLookURL: URL? = nil
    var dragProvider: (() -> NSItemProvider?)? = nil
    var isChild: Bool = false  // an expanded child (indented) under a multi-item clip stack
    var isExpandable: Bool = false  // a multi-item clip that can expand into a file list
    var isExpanded: Bool = false
    var toggleExpand: (() -> Void)? = nil  // chevron / right-arrow expands the stack
    var open: () -> Void = {}
    var focus: () -> Void = {}
    var markRead: (() -> Void)? = nil
    var remove: (() -> Void)? = nil
    var copy: (() -> Void)? = nil
}

struct SharedResultSectionModel: Identifiable {
    let id: String
    let title: String
    let rows: [SharedResultRowModel]
}

struct AIMenuProposal {
    var path: [String]
    var title: String
    var fullPathLabel: String
    var shortcutChar: String?
    var shortcutModifiers: Int
    var menuImage: NSImage?
    var sourcePID: pid_t
    var sourceBundleId: String
    var sourceAppName: String
}

struct MenuPillGroup: Identifiable {
    let id: String
    let primaryPill: DockPill
    let allPills: [DockPill]
    var isGrouped: Bool { allPills.count > 1 }
}

struct AppMenuGroup: Identifiable {
    let id: String
    let appName: String
    let icon: NSImage?
    let pills: [DockPill]
}

struct GlobalGroupedListNavigationState {
    var appResults: [SearchResult]
    var menuPills: [DockPill]
    var menuGroups: [MenuPillGroup]
    var appMenuGroups: [AppMenuGroup]
    var menuFirst: Bool = false

    var totalCount: Int { appResults.count + menuPills.count }

    var renderFingerprint: String {
        // Icon presence is part of render identity so async favicon arrivals repaint.
        func pillKey(_ pill: DockPill) -> String {
            "\(pill.id)~\(pill.menuItemImage != nil ? 1 : 0)"
        }
        let appIDs = appResults.map(\.trackingIdentifier).joined(separator: "|")
        let pillIDs = menuPills.map(pillKey).joined(separator: "|")
        let groupIDs = appMenuGroups.map { group in
            "\(group.id):" + group.pills.map(pillKey).joined(separator: ",")
        }.joined(separator: "|")
        return "\(menuFirst ? 1 : 0)#\(appIDs)#\(pillIDs)#\(groupIDs)"
    }

    init(
        appResults: [SearchResult],
        menuPills: [DockPill],
        menuGroups: [MenuPillGroup]? = nil,
        appMenuGroups: [AppMenuGroup] = [],
        menuFirst: Bool = false
    ) {
        self.appResults = appResults
        self.menuPills = menuPills
        self.menuGroups = menuGroups ?? menuPills.map {
            MenuPillGroup(id: $0.name.lowercased(), primaryPill: $0, allPills: [$0])
        }
        self.appMenuGroups = appMenuGroups
        self.menuFirst = menuFirst
    }

    func cappedForCommit(maxRows: Int) -> GlobalGroupedListNavigationState {
        let rowLimit = max(0, maxRows)
        guard rowLimit > 0 else {
            return GlobalGroupedListNavigationState(
                appResults: [],
                menuPills: [],
                menuGroups: [],
                appMenuGroups: [],
                menuFirst: menuFirst
            )
        }

        let appLimit = min(appResults.count, rowLimit)
        let cappedApps = Array(appResults.prefix(appLimit))
        let remaining = max(0, rowLimit - cappedApps.count)
        var remainingPills = remaining

        let cappedGroups: [AppMenuGroup] = appMenuGroups.compactMap { group in
            guard remainingPills > 0 else { return nil }
            let pills = Array(group.pills.prefix(remainingPills))
            guard !pills.isEmpty else { return nil }
            remainingPills -= pills.count
            return AppMenuGroup(id: group.id, appName: group.appName, icon: group.icon, pills: pills)
        }

        let cappedMenuPills = cappedGroups.isEmpty
            ? Array(menuPills.prefix(remaining))
            : cappedGroups.flatMap(\.pills)

        return GlobalGroupedListNavigationState(
            appResults: cappedApps,
            menuPills: cappedMenuPills,
            menuGroups: cappedGroups.isEmpty ? Array(menuGroups.prefix(remaining)) : [],
            appMenuGroups: cappedGroups,
            menuFirst: menuFirst
        )
    }
}
