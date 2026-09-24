// DefaultAppRouter.swift
// Context-Dock
//
// Opening something the way the user's Mac would open it.
//
// A link row in chat said "Open in Safari" and called SafariTabManager, on a Mac whose default
// browser might be Chrome. That is DoraX overriding a choice the user already made in System
// Settings, in the one place they are most likely to notice — and it is also why the rows look
// generic: a blue link glyph says nothing, while Chrome's own icon says where the click goes
// before it is clicked, which is exactly what Siri's result cards get right.
//
// LaunchServices already knows the answer for every URL and every file. This asks it, caches
// the answer per scheme or extension (the lookup is cheap but a chat can draw thirty rows), and
// hands back the name and icon so a row can show them.

import AppKit
import Foundation

@MainActor
enum DefaultAppRouter {

    struct Handler: Equatable {
        let name: String
        let bundleID: String
        let appURL: URL
    }

    private static var cache: [String: Handler] = [:]

    /// Which app this Mac opens that URL with. Nil when nothing is registered for it.
    static func handler(for url: URL) -> Handler? {
        let key = cacheKey(for: url)
        if let known = cache[key] { return known }
        guard let appURL = NSWorkspace.shared.urlForApplication(toOpen: url) else { return nil }
        let bundle = Bundle(url: appURL)
        let handler = Handler(
            name: FileManager.default.displayName(atPath: appURL.path)
                .replacingOccurrences(of: ".app", with: ""),
            bundleID: bundle?.bundleIdentifier ?? "",
            appURL: appURL)
        cache[key] = handler
        return handler
    }

    static func handler(forLink link: String) -> Handler? {
        guard let url = URL(string: link) else { return nil }
        return handler(for: url)
    }

    /// The app's own icon, for a row that should say where a click lands.
    static func icon(for url: URL) -> NSImage? {
        guard let handler = handler(for: url) else { return nil }
        return NSWorkspace.shared.icon(forFile: handler.appURL.path)
    }

    /// An installed app's own icon, for a result row that belongs to that app.
    ///
    /// Siri's cards are legible at a glance because each one carries the icon of the app the
    /// result came from; a yellow SF Symbol where the Notes icon belongs is the difference
    /// between "a note" and "your note in Notes".
    static func appIcon(bundleID: String) -> NSImage? {
        guard !bundleID.isEmpty else { return nil }
        if let known = iconCache[bundleID] { return known }
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        else { return nil }
        let icon = NSWorkspace.shared.icon(forFile: appURL.path)
        iconCache[bundleID] = icon
        return icon
    }

    private static var iconCache: [String: NSImage] = [:]

    /// Open it the way the Mac would. No app is named, so the user's default wins — which is
    /// the entire point of this type.
    @discardableResult
    static func open(_ url: URL) -> Bool {
        NSWorkspace.shared.open(url)
    }

    @discardableResult
    static func open(link: String) -> Bool {
        guard let url = URL(string: link) else { return false }
        return open(url)
    }

    /// "Open in Chrome", "Open in Safari", or plain "Open" when nothing is registered.
    static func openLabel(for link: String) -> String {
        guard let handler = handler(forLink: link), !handler.name.isEmpty else { return "Open" }
        return "Open in \(handler.name)"
    }

    /// Whether DoraX should show this file in its own preview panel rather than handing it to
    /// another app. Documents the user is likely to want a look at, not to edit — reading one
    /// should not pull a whole app in front of the chat they are reading it from.
    static func prefersInternalPreview(_ url: URL) -> Bool {
        previewableExtensions.contains(url.pathExtension.lowercased())
    }

    static let previewableExtensions: Set<String> = [
        "pdf", "txt", "md", "markdown", "rtf", "csv", "json", "xml", "yaml", "yml", "log",
        "png", "jpg", "jpeg", "gif", "heic", "heif", "webp", "tiff", "bmp", "svg",
        "swift", "js", "ts", "py", "rb", "go", "rs", "c", "h", "cpp", "java", "sh",
    ]

    private static func cacheKey(for url: URL) -> String {
        if url.isFileURL { return "ext:" + url.pathExtension.lowercased() }
        return "scheme:" + (url.scheme?.lowercased() ?? "")
    }
}
