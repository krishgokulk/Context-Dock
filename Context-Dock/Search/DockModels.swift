import AppKit
import Foundation

struct DockPill: Identifiable {
    let id: String
    let name: String
    let icon: String
    let accentColorName: String?
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
    var menuContext: String? = nil
    var hasLiveAvailability: Bool = false
    var menuStatusBadge: String? = nil
    var keyboardShortcutLabel: String? = nil
    var quickLookURL: URL? = nil
    var resolvedURL: URL? = nil
    var dragProvider: (() -> NSItemProvider?)? = nil
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
}
