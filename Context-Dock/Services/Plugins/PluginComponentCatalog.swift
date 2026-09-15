// Context-Dock
//
// The one list of component names a manifest may use. The renderer (UI/Plugins) implements
// exactly these; adding a component means adding it here first so the schema, the Creator's
// prompt and the renderer agree. Spec §6.

import Foundation

enum PluginComponentCatalog {
    static let containers: Set<String> = [
        "card", "vstack", "hstack", "grid", "section", "footerCard",
        "list", "listDetail", "detail", "form", "actionPanel", "capsule",
    ]

    static let leaves: Set<String> = [
        // header, text
        "header", "title", "subtitle", "body", "caption", "markdown", "stat", "divider",
        // rows
        "row", "checkRow", "eventRow", "activityRow", "fileRow", "compareRow",
        // panel states
        "emptyState", "loading",
        // controls
        "button", "iconButton", "buttonRow", "toggle", "slider", "stateButton",
        // chips
        "tag", "statusBadge", "chipRow", "segment",
        // live
        "progress", "timer", "waveform", "liveText", "pulse",
        // media
        "mediaCard", "thumbnail", "avatar",
        // input
        "textField", "searchField", "dropzone",
        // ai, and the escape hatch for Swift-implemented built-in panels (wifi, bluetooth…)
        "ai", "native",
    ]

    static var v1: Set<String> { containers.union(leaves) }

    static func isKnown(_ name: String) -> Bool { v1.contains(name) }
    static func takesChildren(_ name: String) -> Bool { containers.contains(name) }

    /// Props whose value names an action. Kept here so the schema and the renderer agree
    /// on which strings are references and which are text.
    static let actionProps: Set<String> = ["action", "transport", "volume", "submit", "onTap", "primary", "secondary"]
}
