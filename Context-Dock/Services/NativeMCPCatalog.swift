// NativeMCPCatalog.swift
// Context-Dock
//
// MCP servers that ship with the Mac, offered per app.
//
// Apple began shipping one with Safari: `safaridriver --mcp` exposes sixteen tools for driving a
// page — navigate, evaluate JavaScript, read the console, list network requests, screenshot —
// behind two settings the user has to turn on themselves. DoraX already stores MCP servers as a
// command plus arguments linked to a bundle id, which is exactly the shape this takes, so the
// work is not plumbing: it is knowing the server exists, checking honestly whether this Mac can
// run it, and saying what to do when it cannot.
//
// **What it is not.** `safaridriver` drives an automation session. It is better than anything
// DoraX has at interacting with a page — evaluating script, reading the console, watching
// requests — and it is not the thing that answers "what do I have open", which comes from the
// Safari extension reading the windows the user is actually looking at. Two routes, different
// questions; the app profile is where that gets written down rather than guessed each turn.

import AppKit
import Foundation

struct NativeMCPServer: Identifiable, Equatable {
    let id: String
    let name: String
    let bundleID: String
    let command: String
    let args: [String]
    /// One line on what it adds, for the row that offers it.
    let summary: String
    /// What the user must do first, in their own terms. Empty when nothing is needed.
    let requirements: [String]
    /// Where those settings live, when there is somewhere to send them.
    let settingsURL: URL?

    /// Installed on this Mac at all. False is not an error — Safari's server arrives with
    /// Safari 27 / Technology Preview 247, so an older Mac simply has nothing to add.
    var isPresent: Bool {
        FileManager.default.isExecutableFile(atPath: command)
    }
}

enum NativeMCPCatalog {

    /// Apple's Safari MCP server. Facts from the WebKit announcement, verified 2026-09-21:
    /// Safari 27 beta or Safari Technology Preview 247+, "Show features for web developers" and
    /// "Allow remote automation and external agents" both on, started as `safaridriver --mcp`,
    /// no access to personal browsing data.
    static let safari = NativeMCPServer(
        id: "safari-mcp",
        name: "Safari",
        bundleID: "com.apple.Safari",
        command: "/usr/bin/safaridriver",
        args: ["--mcp"],
        summary: "Apple's own Safari server: open and switch tabs, read page content and the "
            + "console, watch network requests, run JavaScript, take screenshots.",
        requirements: [
            "Safari 27 or Safari Technology Preview 247 and later",
            "Safari → Settings → Advanced → Show features for web developers",
            "Safari → Settings → Developer → Allow remote automation and external agents",
        ],
        settingsURL: URL(string: "x-apple.systempreferences:com.apple.preference.security"))

    static let all: [NativeMCPServer] = [safari]

    /// The servers offered on an app's page. Everything, not only what is installed — an app
    /// whose server needs a newer Safari should say so, because "nothing here" reads as "DoraX
    /// cannot do this" rather than "your Mac is a version behind".
    static func servers(forBundleID bundleID: String) -> [NativeMCPServer] {
        all.filter { $0.bundleID.caseInsensitiveCompare(bundleID) == .orderedSame }
    }

    /// Whether this server is already in the user's MCP list, matched on the command rather
    /// than the name so a renamed entry is not added twice.
    @MainActor
    static func isInstalled(_ server: NativeMCPServer, in manager: MCPServerManager = .shared)
        -> Bool
    {
        manager.servers.contains { config in
            config.command == server.command && config.args == server.args
        }
    }

    /// The config DoraX would add. Kept separate from adding it so the offer can show exactly
    /// what it will write.
    static func configuration(for server: NativeMCPServer) -> MCPServerConfig {
        MCPServerConfig(
            name: server.id,
            command: server.command,
            args: server.args,
            transport: "stdio",
            bundleIds: [server.bundleID])
    }
}
