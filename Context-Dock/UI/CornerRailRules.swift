// CornerRailRules.swift
// Context-Dock
//
// #323: the Corner's right panel and the full window's rail are one component in two
// densities, and the footer's expand glyph opens the current chat in that window. The
// decisions live here, pure, so the compact panel, the window rail and the footer cannot
// drift apart: which cards a density shows, whether the glyph shows, and which window
// thread it opens.

import Foundation

/// One card of the rail. The compact panel and the window draw the same cards; the density
/// only decides which of them there is room for.
enum CornerRailCard: String, CaseIterable, Equatable {
    /// Global / app name / General, with the running dot.
    case scope
    /// Provider and context used.
    case usage
    /// The steps the turn ran, and the reasoning behind them.
    case progress
    /// Linked to *this* app or scope.
    case connectors
    /// CLI tools and menu commands, as counts.
    case canDoHere
    /// This app's pack: actions, skills, menus, tools.
    case appPack
    /// Skills available in this scope.
    case skills
    /// DoraX interface mods that apply here.
    case mods
    /// What this chat produced (`~/Documents/DoraX Outputs`) and the uploads it was given.
    /// Replaces a code Files tree: DoraX is not an IDE.
    case outputs
}

enum CornerRailDensity: Equatable {
    /// Beside the compact Corner chat: the essential cards, today's panel.
    case compact
    /// In the full window: every card there is room for.
    case full
}

enum CornerRailRules {
    /// The cards a density shows, in the order they are drawn.
    ///
    /// Compact is exactly today's `CornerLivePanel` (header, Progress, Files/Uploads,
    /// Connectors, Can do here), so adopting the rule changes nothing there. The window adds
    /// the rest. Mods appear only when one applies to the scope: the card's content is still
    /// the owner's to define, and an empty card would promise something that is not built.
    static func cards(for density: CornerRailDensity, hasMods: Bool = false) -> [CornerRailCard] {
        switch density {
        case .compact:
            return [.scope, .progress, .outputs, .connectors, .canDoHere]
        case .full:
            let all: [CornerRailCard] = [
                .scope, .usage, .progress, .connectors, .canDoHere, .appPack, .skills, .mods,
                .outputs,
            ]
            return hasMods ? all : all.filter { $0 != .mods }
        }
    }

    /// How the footer's expand glyph presents itself.
    enum Expand: Equatable {
        /// Global Context search does not expand into a chat (layer rule): no glyph.
        case hidden
        /// A turn is still running. It stays in the compact chat until the answer lands
        /// (owner 2026-10-26), so the glyph is there but inert.
        case disabled
        case enabled
    }

    static func expand(isChatScope: Bool, isAnswering: Bool) -> Expand {
        guard isChatScope else { return .hidden }
        return isAnswering ? .disabled : .enabled
    }

    /// The window thread an expand opens. An app's chat opens that app's thread — the same
    /// conversation, through the shared `dock_app_` key — and General Chat opens General.
    static func windowScope(appBundleID: String?) -> GeneralChatScope {
        guard let id = appBundleID, !id.isEmpty else { return .general }
        return .app(bundleId: id)
    }
}
