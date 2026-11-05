// Context-Dock/AI/PluginAuthoring/AIPackSynthesizer.swift
// Context-Dock
//
// AI Pack Synthesis (Spec 2026-11-05 §4):
// Combines 3 discovery channels when a user creates a pack with AI:
// 1. Local App Introspection: dumps the app's AppleScript dictionary (`sdef`) and
//    inspects its live menu hierarchy (`AppMenuCapabilityCache`).
// 2. Web & Developer Knowledge / OpenAPI & UTCP Ingestion: parses OpenAPI 3.x /
//    Swagger / UTCP manuals via `UTCPManualParser` into direct HTTP endpoints.
// 3. Manifest Synthesis & Validation: feeds discovered local & API capabilities
//    into `PluginAuthoringEngine` to draft a complete pack (`target_app`,
//    `capabilities`, `utcp_endpoints`, `skills`, and `agent` instructions).

import AppKit
import Foundation

struct AppIntrospectionReport: Equatable {
    let bundleID: String
    let appName: String
    let isInstalled: Bool
    let sdefClasses: [String]
    let sdefCommands: [String]
    let menuPaths: [String]
    let openAPIBaseURL: String?
    let openAPITools: [UTCPToolDefinition]

    var hasLocalSignals: Bool {
        !sdefClasses.isEmpty || !sdefCommands.isEmpty || !menuPaths.isEmpty
    }

    var summaryBadgeText: String {
        var parts: [String] = []
        if !sdefClasses.isEmpty || !sdefCommands.isEmpty {
            parts.append("\(sdefClasses.count) sdef classes · \(sdefCommands.count) commands")
        }
        if !menuPaths.isEmpty {
            parts.append("\(menuPaths.count) menu paths")
        }
        if !openAPITools.isEmpty {
            parts.append("\(openAPITools.count) OpenAPI/UTCP tools")
        }
        if parts.isEmpty {
            return "Target: \(appName) (\(bundleID))"
        }
        return "\(appName): " + parts.joined(separator: " · ")
    }

    var promptContextBlock: String {
        var lines: [String] = [
            "## Target App Introspection",
            "- App Name: \(appName)",
            "- Bundle ID: `\(bundleID)`",
            "- Installed on this Mac: \(isInstalled ? "yes" : "no (cloud / external app)")"
        ]

        if !sdefClasses.isEmpty {
            lines.append("\n### Discovered AppleScript (`sdef`) Classes & Properties:")
            for cls in sdefClasses.prefix(15) {
                lines.append("- \(cls)")
            }
        }

        if !sdefCommands.isEmpty {
            lines.append("\n### Discovered AppleScript (`sdef`) Commands:")
            for cmd in sdefCommands.prefix(20) {
                lines.append("- \(cmd)")
            }
        }

        if !menuPaths.isEmpty {
            lines.append("\n### Discovered Live Menu Hierarchy (`NSMenu`):")
            for path in menuPaths.prefix(25) {
                lines.append("- \(path)")
            }
        }

        if !openAPITools.isEmpty {
            lines.append("\n### Parsed OpenAPI / UTCP Endpoints:")
            let base = openAPIBaseURL ?? ""
            for tool in openAPITools.prefix(20) {
                switch tool.execution {
                case .http(let http):
                    lines.append("- `\(tool.name)` (\(http.method) \(base)\(http.path)): \(tool.description)")
                case .cli(let cli):
                    lines.append("- `\(tool.name)` (CLI `\(cli.command)`): \(tool.description)")
                }
            }
        }

        return lines.joined(separator: "\n")
    }
}

@MainActor
enum AIPackIntrospector {

    private static let knownApps: [(name: String, bundleID: String)] = [
        ("Safari", "com.apple.Safari"),
        ("Mail", "com.apple.mail"),
        ("Notes", "com.apple.Notes"),
        ("Messages", "com.apple.MobileSMS"),
        ("Calendar", "com.apple.iCal"),
        ("Reminders", "com.apple.reminders"),
        ("Finder", "com.apple.finder"),
        ("TextEdit", "com.apple.TextEdit"),
        ("Preview", "com.apple.Preview"),
        ("Terminal", "com.apple.Terminal"),
        ("Music", "com.apple.Music"),
        ("Xcode", "com.apple.dt.Xcode"),
        ("Notion", "notion.id"),
        ("Linear", "com.linear"),
        ("Slack", "com.tinyspeck.slackmacgap"),
        ("Figma", "com.figma.Desktop"),
        ("VS Code", "com.microsoft.VSCode"),
        ("Visual Studio Code", "com.microsoft.VSCode"),
        ("Pixelmator Pro", "com.pixelmatorteam.pixelmator.x"),
        ("Pixelmator", "com.pixelmatorteam.pixelmator.x"),
        ("Obsidian", "md.obsidian"),
        ("Spotify", "com.spotify.client"),
        ("Arc", "company.thebrowser.Browser")
    ]

    /// Resolves which app the user wants to build a pack for, either from an explicit
    /// bundleID selection or by matching app names in the natural-language request.
    static func resolveTargetApp(
        from request: String,
        explicitBundleID: String? = nil
    ) -> (bundleID: String, appName: String)? {
        if let explicit = explicitBundleID?.trimmingCharacters(in: .whitespacesAndNewlines),
           !explicit.isEmpty,
           explicit.lowercased() != "global" {
            let name = resolveAppName(for: explicit)
            return (explicit, name)
        }

        let lowered = request.lowercased()

        // 1. Check known macOS & cloud apps
        for entry in knownApps {
            if containsWholePhrase(lowered, phrase: entry.name.lowercased()) {
                return (entry.bundleID, entry.name)
            }
        }

        // 2. Check existing adapters
        for adapter in AppAdapterManager.shared.adapters where !adapter.bundleId.isEmpty {
            let name = adapter.appName.trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty, containsWholePhrase(lowered, phrase: name.lowercased()) {
                return (adapter.bundleId, name)
            }
        }

        // 3. Check running apps
        for app in NSWorkspace.shared.runningApplications {
            guard let bundleID = app.bundleIdentifier,
                  let name = app.localizedName,
                  !name.isEmpty
            else { continue }
            if containsWholePhrase(lowered, phrase: name.lowercased()) {
                return (bundleID, name)
            }
        }

        // 4. Match "pack for <App>" or "plugin for <App>"
        if let extracted = extractAppNameAfterFor(from: request) {
            if let url = NSWorkspace.shared.urlForApplication(toOpen: URL(fileURLWithPath: "/Applications/\(extracted).app"))
                ?? (FileManager.default.fileExists(atPath: "/Applications/\(extracted).app")
                    ? URL(fileURLWithPath: "/Applications/\(extracted).app") : nil),
               let bundle = Bundle(url: url),
               let bundleID = bundle.bundleIdentifier {
                return (bundleID, extracted)
            }
            let slug = extracted.lowercased()
                .replacingOccurrences(of: " ", with: "-")
                .filter { $0.isLetter || $0.isNumber || $0 == "-" }
            if !slug.isEmpty {
                return ("app.\(slug)", extracted)
            }
        }

        return nil
    }

    /// Introspects a target app across local `sdef`, live menu cache, and optional OpenAPI/UTCP spec text.
    static func introspect(
        bundleID: String,
        appName: String,
        sdefXMLOverride: String? = nil,
        openAPISpecText: String? = nil
    ) async -> AppIntrospectionReport {
        let isInstalled = IntegrationAppPresence.isInstalled(bundleID: bundleID)

        // 1. AppleScript dictionary (`sdef`)
        let dictionary: AppScriptingDictionary?
        if let sdefXMLOverride, !sdefXMLOverride.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            dictionary = AppSdefParser.parse(
                sdefXMLOverride,
                bundleID: bundleID,
                appName: appName,
                version: "1.0")
        } else if let cached = AppDictionaryStore.shared.dictionary(forBundleID: bundleID) {
            dictionary = cached
        } else {
            dictionary = await AppDictionaryStore.shared.ensureScanned(
                bundleID: bundleID,
                appName: appName,
                grants: [bundleID])
        }

        let sdefClasses: [String] = (dictionary?.classes ?? []).compactMap { cls in
            let props = cls.properties.map { prop in
                prop.isWriteOnly ? "\(prop.name) (write)" : prop.name
            }
            guard !props.isEmpty else { return cls.name }
            return "\(cls.name) (properties: \(props.prefix(8).joined(separator: ", ")))"
        }

        let sdefCommands: [String] = (dictionary?.commands ?? []).map { cmd in
            if cmd.parameterNames.isEmpty {
                return cmd.name
            }
            return "\(cmd.name) (params: \(cmd.parameterNames.joined(separator: ", ")))"
        }

        // 2. Live Menu Hierarchy (`AppMenuCapabilityCache`)
        let menuItems = AppMenuCapabilityCache.shared.menuItems(
            bundleIdentifier: bundleID,
            appName: appName,
            query: "",
            maxResults: 60)
        var seenPaths = Set<String>()
        var menuPaths: [String] = []
        for item in menuItems where item.isLeaf && !item.path.isEmpty {
            let path = item.path.joined(separator: " ▸ ")
            if seenPaths.insert(path.lowercased()).inserted {
                menuPaths.append(path)
            }
        }

        // 3. OpenAPI 3.x / UTCP Manual Parsing
        let parsedManual: UTCPManual? = {
            guard let text = openAPISpecText?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty
            else { return nil }
            return try? UTCPManualParser.parse(text: text)
        }()

        return AppIntrospectionReport(
            bundleID: bundleID,
            appName: appName,
            isInstalled: isInstalled,
            sdefClasses: sdefClasses,
            sdefCommands: sdefCommands,
            menuPaths: menuPaths,
            openAPIBaseURL: parsedManual?.protocols.http?.baseURL,
            openAPITools: parsedManual?.tools ?? [])
    }

    /// Converts parsed OpenAPI / UTCP tools into `PluginPackUTCPEndpoint` definitions for a pack manifest.
    static func synthesizeUTCPEndpoints(
        from tools: [UTCPToolDefinition],
        baseURL: String? = nil
    ) -> [PluginPackUTCPEndpoint] {
        let resolvedBase = (baseURL?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap {
            $0.isEmpty ? nil : $0
        } ?? "https://api.example.com"
        return tools.compactMap { tool in
            guard case .http(let http) = tool.execution else { return nil }
            let path = http.path.isEmpty ? "/" : http.path
            return PluginPackUTCPEndpoint(
                id: tool.name,
                name: tool.name,
                baseURL: resolvedBase,
                method: http.method.uppercased(),
                path: path,
                description: tool.description,
                requiresAuth: true)
        }
    }

    private static func resolveAppName(for bundleID: String) -> String {
        if let known = knownApps.first(where: { $0.bundleID.caseInsensitiveCompare(bundleID) == .orderedSame }) {
            return known.name
        }
        if let adapter = AppAdapterManager.shared.adapters.first(where: { $0.bundleId == bundleID }),
           !adapter.appName.isEmpty {
            return adapter.appName
        }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return url.deletingPathExtension().lastPathComponent
        }
        return bundleID
    }

    private static func containsWholePhrase(_ haystack: String, phrase: String) -> Bool {
        guard !phrase.isEmpty else { return false }
        let pattern = "\\b" + NSRegularExpression.escapedPattern(for: phrase) + "\\b"
        return haystack.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    private static func extractAppNameAfterFor(from request: String) -> String? {
        let pattern = #"(?:pack|plugin)\s+for\s+([A-Z][A-Za-z0-9\s\-]{1,28})"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: request, range: NSRange(request.startIndex..., in: request)),
              let range = Range(match.range(at: 1), in: request)
        else { return nil }
        let candidate = String(request[range]).trimmingCharacters(in: .whitespacesAndNewlines)
        let stopWords: Set<String> = ["that", "with", "using", "to", "in", "which"]
        let words = candidate.split(separator: " ").map(String.init)
        let filtered = words.prefix { !stopWords.contains($0.lowercased()) }
        let joined = filtered.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return joined.isEmpty ? nil : joined
    }
}
