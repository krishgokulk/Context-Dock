import AppKit
import Foundation

struct ContextDockMenuPillInput {
    let id: String
    let item: AXMenuItem
    let sourceBundleId: String
    let sourceAppName: String
    let accentColorName: String
    let badge: String?
    let trackingIdentifier: String
    let searchTerms: [String]
}

struct ContextDockPillBuilder {
    var menuSymbol: (AXMenuItem) -> String
    var menuIcon: (AXMenuItem) -> NSImage?
    var menuContextLabel: ([String]) -> String?
    var isEnabled: (AXMenuItem) -> Bool
    var statusBadge: (AXMenuItem, String) -> String?
    var resolvedURL: (AXMenuItem) -> URL?
    var onSubmenuParent: (AXMenuItem) -> Void

    func makeMenuDockPill(
        input: ContextDockMenuPillInput,
        executeLeaf: @escaping () -> Void
    ) -> DockPill {
        let item = input.item
        let isSubmenuParent = !item.children.isEmpty
        var pill = DockPill(
            id: input.id,
            name: item.title,
            icon: isSubmenuParent ? "chevron.right.circle" : menuSymbol(item),
            accentColorName: isSubmenuParent ? "blue" : input.accentColorName,
            badge: isSubmenuParent ? (input.badge ?? "Submenu") : input.badge,
            execute: {
                if isSubmenuParent {
                    onSubmenuParent(item)
                } else {
                    executeLeaf()
                }
            }
        )
        pill.menuItemImage = isSubmenuParent ? nil : menuIcon(item)
        pill.menuItemName = item.title
        pill.sourceBundleId = input.sourceBundleId
        pill.sourceAppName = input.sourceAppName
        pill.menuContext = menuContextLabel(item.path)
        pill.rankingKind = isSubmenuParent ? "submenuParent" : "menu"
        pill.isEnabled = isSubmenuParent ? true : isEnabled(item)
        pill.hasLiveAvailability = item.hasLiveAvailability
        pill.menuStatusBadge = statusBadge(item, input.sourceBundleId)
        pill.keyboardShortcutLabel = item.shortcutDisplay ?? input.badge

        if let url = resolvedURL(item) {
            pill.resolvedURL = url
            pill.quickLookURL = url
            if !item.hasLiveAvailability {
                pill.menuStatusBadge = "Cached File"
            }
        }

        pill.trackingIdentifier = input.trackingIdentifier
        pill.searchTerms = input.searchTerms + item.children.map(\.title)
        if let resolvedURL = pill.resolvedURL {
            pill.searchTerms.append(resolvedURL.path)
        }
        return pill
    }
}
