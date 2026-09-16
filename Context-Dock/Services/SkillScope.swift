// SkillScope.swift
// Context-Dock
//
// Who a skill is for.
//
// `AdapterSkill.adapterBundleId` was required, so every skill belonged to an installed app.
// The surfaces the user spends most of their time in — Global Context, the corner chat, a CLI
// scope, the clipboard, a selection, General Chat — could not have one, which is the wrong way
// round: those are the surfaces whose rules are least discoverable from a tool list.
//
// A scope is one of three things and never two:
//
//   .app(bundleId)   the skill steers chats about that app, and nothing else
//   .surface(id)     the skill steers one product surface, whatever app is in front
//   .global          the skill applies everywhere
//
// The ids are the seed slugs, because those are already the folder names on disk and the
// user's copy of a skill is the file. A `surface:` line in the frontmatter is how a file says
// which one it steers.

import Foundation

/// Skills that belong to DoraX itself rather than to an installed app.
///
/// Lives here rather than on `SkillFolder` — which is `@MainActor` — so that a skill's scope
/// can be read from anywhere, including a model type with no isolation of its own.
/// `SkillFolder.globalBundleID` is this value.
let doraxGlobalSkillBundleID = "dorax.global"

/// The product surfaces a skill can be written for — one per layer in CLAUDE.md's rule that
/// surfaces are never merged.
enum DoraXSurface: String, CaseIterable, Codable, Sendable {
    case globalContext = "global-context"
    case contextDockChat = "context-dock-chat"
    case cliScope = "cli-scope"
    case clipboardScope = "clipboard-scope"
    case selectionScope = "selection-scope"
    case generalChat = "general-chat"
    case appAdapters = "app-adapters"

    /// What to call it in a prompt or a settings row.
    var displayName: String {
        switch self {
        case .globalContext: "Global Context"
        case .contextDockChat: "Context Dock Chat"
        case .cliScope: "CLI tool scope"
        case .clipboardScope: "Clipboard scope"
        case .selectionScope: "Selection scope"
        case .generalChat: "General Chat"
        case .appAdapters: "App adapters"
        }
    }

    /// Accepts what a person writes in frontmatter rather than only the canonical id:
    /// `surface: clipboard` and `surface: Clipboard Scope` both mean the clipboard.
    init?(loose raw: String) {
        let normalized = raw.lowercased()
            .trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: " ", with: "-")
            .replacingOccurrences(of: "_", with: "-")
        if let exact = DoraXSurface(rawValue: normalized) {
            self = exact
            return
        }
        switch normalized {
        case "global", "launcher", "search": self = .globalContext
        case "context-dock", "corner", "dock", "corner-chat": self = .contextDockChat
        case "cli", "terminal", "cli-tool", "cli-tools": self = .cliScope
        case "clipboard", "clipboard-history", "pasteboard": self = .clipboardScope
        case "selection", "selected-text", "selection-sheet": self = .selectionScope
        case "general", "chat", "general-chat-mode": self = .generalChat
        case "adapters", "app-adapter", "adapter": self = .appAdapters
        default: return nil
        }
    }
}

extension DoraXSurface {

    /// The surface a dock scope id names. A `cli://` scope is a conversation with one
    /// executable and has its own rules — reading it as an app chat is how a CLI thread ends
    /// up offered an adapter action for an app that is not there.
    init(scopeBundleId: String) {
        self = scopeBundleId.hasPrefix("cli://") ? .cliScope : .contextDockChat
    }
}

/// A skill's audience. Derived, never stored twice: the fields on `AdapterSkill` are the
/// storage, and this reads them so a skill cannot claim two scopes at once.
enum SkillScope: Equatable, Sendable {
    case app(bundleId: String)
    case surface(DoraXSurface)
    case global

    var label: String {
        switch self {
        case .app(let bundleId): bundleId
        case .surface(let surface): surface.displayName
        case .global: "Everywhere"
        }
    }
}

extension AdapterSkill {

    /// The one audience this skill has.
    ///
    /// A named surface wins over a bundle id: a skill can be written for the clipboard scope
    /// while carrying the bundle id of whatever app the user exported it from, and the
    /// surface is the thing they asked for.
    var scope: SkillScope {
        if let surface = DoraXSurface(rawValue: surfaceId) { return .surface(surface) }
        let bundleId = adapterBundleId.trimmingCharacters(in: .whitespaces)
        if bundleId.isEmpty || bundleId == doraxGlobalSkillBundleID { return .global }
        return .app(bundleId: bundleId)
    }

    /// Whether this skill steers the given surface. Global skills steer every surface; an
    /// app skill steers none of them — it belongs to a scoped chat about that app.
    func steers(_ surface: DoraXSurface) -> Bool {
        switch scope {
        case .surface(let own): own == surface
        case .global: true
        case .app: false
        }
    }
}
