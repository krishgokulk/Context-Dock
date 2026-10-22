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

    /// The card's lines for an app with no route: one per entry, each naming the tool,
    /// what it adds and the install command the owner runs themselves.
    static func suggestionLines(forBundleId bundleId: String, appName: String) -> [String] {
        suggestions(forBundleId: bundleId).map { entry in
            "\(appName): optional, vetted — \(entry.tool) (\(entry.repo)) adds "
                + entry.adds.joined(separator: ", ")
                + ". Install yourself: \(entry.installCommand). DoraX never installs; "
                + "its writes ask first."
        }
    }
}
