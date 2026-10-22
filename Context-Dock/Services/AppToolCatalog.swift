// AppToolCatalog.swift
// Context-Dock
//
// The curated tool catalog of plan §6.2: vetted suggestions shipped and versioned WITH
// DoraX, consulted only when an app-scoped request has no route (`find_route`'s empty
// branch). Suggestions come from here — not from a package-manager search, not from the
// model's imagination. brew / go / npm may only be used to CHECK whether an entry is
// installed; GitHub / web / MCP-registry lookups happen only when the owner asks, and
// what they return is labeled unvetted. DoraX never installs: it shows the command and
// the owner runs it (E17).
//
// A suggestion must name the tool, where it comes from, what it adds, its risk — and the
// risky part stays gated: "writes and outbound always ask" survives a suggestion, because
// a CLI learned from a suggestion still goes through §6.1's manifest review and verb gate.

import Foundation

/// One vetted entry of the catalog.
struct AppToolCatalogEntry: Codable, Equatable {
    enum Kind: String, Codable, Sendable {
        case cli, mcp, script, shortcut
    }

    enum Risk: String, Codable, Sendable {
        case low, medium, high
    }

    /// Human name of the app the tool is for — "Mail".
    var app: String
    /// The app's bundle ids, matched against the scoped app (`resolved.id`).
    var bundleIds: [String]
    /// The tool's kind — one lane rung.
    var kind: Kind
    /// The tool's command as the user invokes it — "mail-app-cli".
    var tool: String
    /// The source repository, for the "vetted, from here" claim.
    var repo: String
    /// The command the OWNER runs to install it. DoraX never runs this (E17).
    var installCommand: String
    /// What adding the tool gives the app, in words the owner reviews.
    var adds: [String]
    /// The risk, in one word, plus the rule that still applies.
    var risk: Risk
    /// One-line "why this is vetted" — the reason it is in the shipped catalog.
    var vetting: String
}

/// The no-route card (§6.2): what an app-scoped turn shows when the data lane had nothing
/// to run. The tool result (`find_route`, no routes) is its source, the answer message
/// carries it, and the shared message view draws it — never a parse of the answer's prose.
struct NoRouteOptionsCard: Equatable, Identifiable {
    struct Row: Equatable {
        let tool: String
        let repo: String
        /// The command the OWNER runs. DoraX never installs (E17): the card copies it.
        let installCommand: String
        let adds: [String]
        /// The binary resolved on the user's own PATH right now.
        let installed: Bool
        /// Commands were scanned and learned — the review lives in Settings › Integrations.
        let scanned: Bool
    }

    let appName: String
    let rows: [Row]
    /// What to do instead when the entry adds nothing — the UI-lane fallback, in words.
    let fallback: String

    var id: String { appName + rows.map(\.tool).joined() }
}

/// The bundled, versioned catalog and the sentence the no-route card reads out.
enum AppToolCatalog {
    /// Bump when the shipped entries change, so a session can tell what it consulted.
    static let version = 1

    /// The shipped catalog. mail-app-cli is the first entry (§2b worked it, §6.1 learned
    /// it, the owner hand-checked it end to end). New entries arrive HERE, reviewed —
    /// never from a live registry search.
    static let entries: [AppToolCatalogEntry] = [
        AppToolCatalogEntry(
            app: "Mail",
            bundleIds: ["com.apple.mail"],
            kind: .cli,
            tool: "mail-app-cli",
            repo: "intelligrit/mail-app-cli",
            installCommand: "go install github.com/intelligrit/mail-app-cli@latest",
            adds: ["archive", "flag", "move", "mark read/trash", "attachments"],
            risk: .medium,
            vetting: "public open-source CLI the owner hand-checked end to end; every "
                + "write command asks before it runs"),
    ]

    /// Vetted suggestions for an app, by bundle id.
    static func suggestions(forBundleId bundleId: String) -> [AppToolCatalogEntry] {
        entries.filter { $0.bundleIds.contains(bundleId.lowercased()) }
    }

    /// Is the catalog tool present on the user's own binary directories right now? Check
    /// ONLY — this is not a search and not an install (§6.2).
    @MainActor static func isInstalled(_ tool: String) -> (installed: Bool, scanned: Bool) {
        let pkg = TerminalPackageManager.shared.packages
            .first { $0.command == tool || $0.name == tool }
        if let pkg, pkg.isInstalled, let path = pkg.installedPath,
            FileManager.default.isExecutableFile(atPath: path)
        {
            return (true, !pkg.subcommands.isEmpty)
        }
        for dir in TerminalPackageManager.userBinDirectories() + ["/usr/bin", "/bin"] {
            if FileManager.default.isExecutableFile(atPath: dir + "/" + tool) {
                return (true, false)
            }
        }
        return (false, false)
    }

    /// The card for an app whose turn had no route: one row per vetted entry, checked
    /// against what is installed this minute, plus the menu fallback.
    @MainActor static func noRouteCard(
        forBundleId bundleId: String, appName: String
    ) -> NoRouteOptionsCard {
        let rows = suggestions(forBundleId: bundleId).map { entry -> NoRouteOptionsCard.Row in
            let seen = isInstalled(entry.tool)
            return NoRouteOptionsCard.Row(
                tool: entry.tool, repo: entry.repo, installCommand: entry.installCommand,
                adds: entry.adds, installed: seen.installed, scanned: seen.scanned)
        }
        let fallback: String
        if rows.isEmpty {
            fallback = "No vetted tool exists for this app in the catalog yet — nothing "
                + "to suggest, and nothing auto-installed."
        } else if rows.allSatisfy({ !$0.installed }) {
            fallback = "Nothing installed can reach that yet. You can still ask me to do it "
                + "through \(appName)'s menus (it will come forward), or install the "
                + "suggestion above yourself."
        } else {
            fallback = "In the app's menus there is a slower path; say the word and I'll "
                + "press it."
        }
        return NoRouteOptionsCard(appName: appName, rows: rows, fallback: fallback)
    }

    /// The card's lines for an app with no route: one per vetted entry, each telling the
    /// model the truthful state — not installed (the owner installs, DoraX never does),
    /// installed but not linked to this app ("add it in App Adapters", the CLI learner's
    /// own flow), or installed and linked (the route should have matched; say so).
    @MainActor static func suggestionLines(
        forBundleId bundleId: String, appName: String
    ) -> [String] {
        suggestions(forBundleId: bundleId).map { entry -> String in
            let seen = isInstalled(entry.tool)
            let head = "\(appName): optional, vetted — \(entry.tool) (\(entry.repo)) adds "
                + entry.adds.joined(separator: ", ")
            if seen.installed {
                return head + ". It is ALREADY installed on this Mac"
                    + (seen.scanned ? " and its commands are learned" : "")
                    + " — route requests through it once it is linked to this app; the "
                    + "user adds it in Settings → App Adapters («Add to this app»). "
                    + "Do not ask them to install it again."
            }
            return head + ". Install yourself: \(entry.installCommand). DoraX never "
                + "installs; its writes ask first."
        }
    }
}
