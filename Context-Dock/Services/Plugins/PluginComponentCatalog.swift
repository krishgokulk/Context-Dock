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
        // A row of buttons holds the buttons. It was a leaf here while the renderer drew it
        // from its children, so every real button row failed validation with
        // "\"buttonRow\" does not take children" and nobody could ship one.
        "buttonRow",
    ]

    static let leaves: Set<String> = [
        // header, text
        "header", "title", "subtitle", "body", "caption", "markdown", "stat", "divider",
        // rows
        "row", "cell", "checkRow", "eventRow", "activityRow", "fileRow", "compareRow",
        // panel states
        "emptyState", "loading",
        // controls
        "button", "iconButton", "toggle", "slider", "stateButton",
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
    static let actionProps: Set<String> = ["action", "transport", "volume", "submit", "onTap", "primary", "secondary", "edit"]

    /// A prop is node-valued in one of two spellings:
    ///   "row":    { "title": … }        the prop key names the component
    ///   "detail": { "markdown": … }     the value is itself a node
    /// Anything else — a string, an array, an object matching neither — is ordinary data and
    /// stays a PluginValue. The data contract for a list item's `detail`
    /// ({ "markdown": …, "metadata": [ … ] }) matches neither and must not be promoted.
    static func nodeProp(key: String, value: PluginValue) -> PluginNode? {
        guard let object = value.objectValue else { return nil }
        // The prop key names the component. This wins over the spelling below even when the
        // value happens to be a single-key object: `"detail": { "markdown": … }` is a detail
        // holding markdown, not a markdown node. The alternative makes a prop's meaning flip
        // on how many props were written under it, which nobody could predict.
        if isKnown(key) {
            return PluginNode(component: key, props: object)
        }
        // The value is itself a node, under a prop whose name is not a component:
        // `"leading": { "thumbnail": { … } }`.
        if object.count == 1, let inner = object.first, isKnown(inner.key),
           let innerObject = inner.value.objectValue {
            return PluginNode(component: inner.key, props: innerObject)
        }
        // An empty object under a name the catalog does not know can only be a component
        // nobody knows — a real data prop carries data (`{ "kind": "chip", "label": "4k" }`).
        // Promoting it makes the schema's own unknown-component rule name it, rather than
        // needing a second list of which prop names are data.
        if object.isEmpty {
            return PluginNode(component: key, props: [:])
        }
        return nil
    }
}
