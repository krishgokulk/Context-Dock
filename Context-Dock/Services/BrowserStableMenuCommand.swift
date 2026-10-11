import Foundation

/// The commands that live in a browser's History / Bookmarks menus but are not page rows.
///
/// Those menus mix two kinds of item. Page rows (a history entry, a recently closed page) are
/// dynamic: the submenu scrolls, reorders and forgets them, so they open by URL, are never
/// AX-clicked, and are dropped from the menu cache once no live scan confirms them. Commands
/// (Back, Reopen Last Closed Window, the Recently Closed submenu itself) sit at fixed places
/// and are as durable as File ▸ New Window.
///
/// Three places used to decide this on their own: the cache and the Dock each treated every
/// item under History as volatile, so "Reopen Last Closed Window" and "Recently Closed" fell
/// out of menu results, while the URL-row check kept a private list of commands. One list now,
/// so the three cannot drift apart.
enum BrowserStableMenuCommand {

    /// Normalised titles (lowercased, punctuation dropped) of the stable commands.
    static let titles: Set<String> = [
        "back", "forward", "home",
        "show all history", "show history", "show personal history", "clear history",
        "reopen last closed window", "reopen last closed tab",
        "reopen all windows from last session", "recently closed",
        "show bookmarks", "edit bookmarks", "add bookmark", "bookmark all tabs",
        "show bookmarks editor", "add to reading list",
    ]

    /// True when this menu item title names a stable command rather than a page.
    static func isStable(title: String) -> Bool {
        titles.contains(normalize(title))
    }

    private static func normalize(_ title: String) -> String {
        title.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .joined(separator: " ")
    }
}
