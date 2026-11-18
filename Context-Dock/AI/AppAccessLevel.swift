// AppAccessLevel.swift
// Context-Dock
//
// How far General Chat may go with a given app.
//
// The gate used to be one boolean: an App Adapter exists, or the app is untouchable. That
// threw away capability the app already had. DoraX caches an app's menu bar as it browses
// it, so it can often name "Pearcleaner ▸ Settings…" exactly — and then refused to click it
// because Pearcleaner had no adapter, while cheerfully telling the user to go and add one.
//
// Two gates also disagreed with each other. The resolver already accepted a second
// authority — the in-chat "Enable X for this chat" grant — and discovery did not, so a
// chat-granted app passed one check and was silently filtered out by the next.
//
// So authority is one thing with three levels, and it is asked per *route* rather than per
// app. Knowing a menu command exists is not permission to read the app's documents, and the
// difference between those two is exactly what one boolean could not express.

import Foundation

enum AppAccessLevel: Int, Comparable {
    /// Installed, maybe running. DoraX may know it exists and start it. Nothing more.
    case awareness = 0
    /// No adapter, but DoraX has a real handle on it — a cached menu bar, or the user's
    /// grant for this conversation. Public commands only, and only after live verification.
    case menuOnly = 1
    /// The user added an App Adapter: readers, actions, MCP, CLI, skills, app data.
    case adapter = 2

    static func < (lhs: AppAccessLevel, rhs: AppAccessLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

@MainActor
enum AppAccessPolicy {

    /// What this conversation may do with this app.
    ///
    /// `chatGranted` carries the apps the user enabled for this chat at the access gate.
    /// That grant is real authority — the user was asked in plain words and said yes — and
    /// it was already honoured by the resolver, so honouring it here is consistency rather
    /// than a new permission.
    static func level(for bundleId: String, chatGranted: Set<String> = []) -> AppAccessLevel {
        guard !bundleId.isEmpty else { return .awareness }
        if AppAdapterManager.shared.adapter(for: bundleId) != nil { return .adapter }
        if !CapabilityRegistry.shared.capabilities(for: bundleId).isEmpty { return .adapter }
        if chatGranted.contains(bundleId) { return .menuOnly }
        if AppMenuCapabilityCache.shared.summary(bundleIdentifier: bundleId) != nil {
            return .menuOnly
        }
        return .awareness
    }

    /// Whether a route may run at a given level.
    ///
    /// Menu-only permits exactly what the user could do themselves by opening the app's
    /// menu bar, and nothing that reads private state. A menu command is public and
    /// observable; an MCP tool, a context reader or an adapter CLI is not, and neither is
    /// arbitrary accessibility inspection — which can read a document's contents through a
    /// window the user never opened for us.
    static func allows(_ route: DoraXActionCandidate.ExecutionRoute, at level: AppAccessLevel)
        -> Bool
    {
        switch level {
        case .adapter:
            return true
        case .menuOnly:
            switch route {
            case .verifiedMenu, .appLaunch, .keyboardShortcut:
                return true
            case .adapter, .mcp, .api, .cli, .axFallback, .automation:
                return false
            }
        case .awareness:
            return route == .appLaunch
        }
    }

    /// Whether a `.verifiedMenu` route may run a specific menu path at a given access level.
    ///
    /// A safe path at `.menuOnly` (e.g. `Window ▸ Minimize`) is allowed. An outbound or
    /// destructive path (e.g. `Message ▸ Send`, `Message ▸ Reply`) is not: observing a menu
    /// command exists is not permission to send something to another person. Those actions
    /// require `.adapter` access or an explicit user consent grant.
    ///
    /// Pass an empty `menuPath` when the path is not known (e.g. in a route-level capability
    /// filter); the check then falls back to the route-only answer.
    static func allows(
        _ route: DoraXActionCandidate.ExecutionRoute,
        at level: AppAccessLevel,
        menuPath: [String]
    ) -> Bool {
        guard allows(route, at: level) else { return false }
        // Only `.menuOnly` needs the extra path check; `.adapter` already permits everything.
        guard level == .menuOnly, route == .verifiedMenu, !menuPath.isEmpty else { return true }
        return !AppMenuConsentStore.shared.isDestructive(path: menuPath)
    }

    /// What to tell the user when a request needs more than they have granted.
    ///
    /// Four situations that used to share one sentence. "Add it to App Adapters" is the
    /// right answer to only one of them, and saying it for the others sends the user to
    /// Settings to fix something Settings cannot fix.
    static func explanation(
        for appName: String, level: AppAccessLevel, wantedRead: Bool, menuPath: [String] = []
    ) -> String {
        if level == .menuOnly, !menuPath.isEmpty,
            AppMenuConsentStore.shared.isDestructive(path: menuPath)
        {
            return "That action sends something to another person. \(appName) isn't fully "
                + "connected, so outbound menu commands need an App Adapter — add it in "
                + "Settings → App Adapters → Choose App, or use the action directly in the app."
        }
        switch level {
        case .adapter:
            return "\(appName) is connected, but that particular capability isn't available."
        case .menuOnly where wantedRead:
            return "I can run \(appName)'s known menu commands, but reading its data needs "
                + "an App Adapter — add it in Settings → App Adapters → Choose App."
        case .menuOnly:
            return "\(appName) isn't fully connected, so I'm limited to its menu commands."
        case .awareness:
            return "I know \(appName) is installed, but I haven't seen its menus and it has "
                + "no App Adapter, so I can only launch it. Open it once so I can read its "
                + "menu bar, or add it in Settings → App Adapters."
        }
    }
}
