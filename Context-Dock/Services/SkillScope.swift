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

/// The file or content type a selection-scoped skill applies to (H3 #410).
///
/// Stored as the raw value in `AdapterSkill.selectionType` and `SolvedSkill.selectionType`.
/// Empty string / nil means "not selection-scoped". A new case here is a new raw-value string,
/// so old stores that lack the field still decode fine (they fall through to .empty / nil).
enum SkillSelectionType: String, Codable, CaseIterable, Sendable {
    /// Any plain-text selection with no attached file path.
    case text
    /// A PDF file.
    case pdf
    /// An image file (PNG, JPEG, GIF, HEIC, WebP, TIFF, BMP).
    case image
    /// Any file, regardless of type.
    case file

    /// True when the derivation context satisfies this selection type.
    func matches(context: SlotDerivationContext) -> Bool {
        switch self {
        case .text:
            return context.selectedText != nil && context.selectedFilePaths.isEmpty
        case .file:
            return !context.selectedFilePaths.isEmpty
        case .pdf:
            return context.selectedFilePaths.contains {
                $0.lowercased().hasSuffix(".pdf")
            }
        case .image:
            let imageExts: Set<String> = [
                "png", "jpg", "jpeg", "gif", "heic", "webp", "tiff", "bmp",
            ]
            return context.selectedFilePaths.contains {
                imageExts.contains(
                    URL(fileURLWithPath: $0).pathExtension.lowercased())
            }
        }
    }
}

/// A skill's audience. Derived, never stored twice: the fields on `AdapterSkill` are the
/// storage, and this reads them so a skill cannot claim two scopes at once.
enum SkillScope: Equatable, Sendable {
    case app(bundleId: String)
    case surface(DoraXSurface)
    case global
    /// The skill applies whenever the user's selection or attachment matches this type.
    case selection(SkillSelectionType)

    var label: String {
        switch self {
        case .app(let bundleId): bundleId
        case .surface(let surface): surface.displayName
        case .global: "Everywhere"
        case .selection(let t): "Selection: \(t.rawValue.capitalized)"
        }
    }
}

extension AdapterSkill {

    /// The one audience this skill has.
    ///
    /// Selection type wins first (H3 #410): a skill may carry a bundle id from the app it was
    /// exported from, but its selection scope is what the user asked for. Surface wins over
    /// bundle id for the same reason.
    var scope: SkillScope {
        if let selType = SkillSelectionType(rawValue: selectionType) { return .selection(selType) }
        if let surface = DoraXSurface(rawValue: surfaceId) { return .surface(surface) }
        let bundleId = adapterBundleId.trimmingCharacters(in: .whitespaces)
        if bundleId.isEmpty || bundleId == doraxGlobalSkillBundleID { return .global }
        return .app(bundleId: bundleId)
    }

    /// Whether this skill steers the given surface. Global skills steer every surface; an
    /// app skill or a selection-scoped skill steers none — the latter applies to any app
    /// whose selection matches, not to a surface's prompt.
    func steers(_ surface: DoraXSurface) -> Bool {
        switch scope {
        case .surface(let own): own == surface
        case .global: true
        case .app: false
        case .selection: false
        }
    }
}
