//
//  AppSettings.swift
//  ILauncher
//
//  Created by Krishgokul on 20/11/2025.
//

import Carbon
import Combine
import Foundation
import SwiftUI

// MARK: - Pinned Item Model (supports apps, files, folders, shortcuts)
struct PinnedApp: Codable, Identifiable, Equatable {
    enum PinnedItemType: String, Codable {
        case application
        case file
        case folder
        case shortcut
    }

    let id: UUID
    let name: String
    let path: String
    let bundleIdentifier: String?
    let type: PinnedItemType

    init(
        name: String, path: String, bundleIdentifier: String? = nil,
        type: PinnedItemType = .application
    ) {
        self.id = UUID()
        self.name = name
        self.path = path
        self.bundleIdentifier = bundleIdentifier
        self.type = type
    }
}

// MARK: - Browser Item Model (for L3 browser layer)
struct BrowserItem: Codable, Identifiable, Equatable {
    enum BrowserItemType: String, Codable {
        case bookmark
        case folder
        case quickTab
        case pinnedSite
        case history
    }

    let id: UUID
    let title: String
    let url: String
    let favicon: String?  // URL or SF Symbol name
    let type: BrowserItemType

    init(title: String, url: String, favicon: String? = nil, type: BrowserItemType = .bookmark) {
        self.id = UUID()
        self.title = title
        self.url = url
        self.favicon = favicon
        self.type = type
    }
}

// MARK: - Custom App Entry (user-added apps in App Shortcuts sidebar)
struct CustomAppEntry: Codable, Identifiable, Equatable {
    let id: UUID
    var key: String  // lowercase trigger keyword, e.g. "slack"
    var label: String  // display name, e.g. "Slack"
    var iconName: String  // SF Symbol name
    var appPath: String  // path to .app bundle

    init(key: String, label: String, iconName: String = "app.fill", appPath: String = "") {
        self.id = UUID()
        self.key = key
        self.label = label
        self.iconName = iconName
        self.appPath = appPath
    }
}

// MARK: - Structured Tool Profile (replaces flat aiHint)
struct AppToolProfile: Codable, Equatable {
    var capabilities: [String]  // e.g. ["list reminders", "add reminder", "complete task"]
    var exampleCommands: [String]  // e.g. ["rem add \"call mom\"", "rem list"]
    var fileTypes: [String]  // file extensions this tool handles, e.g. ["pdf", "jpg"]
    var isDestructive: Bool  // true if tool can delete/overwrite — triggers extra care in AI

    init(
        capabilities: [String] = [], exampleCommands: [String] = [],
        fileTypes: [String] = [], isDestructive: Bool = false
    ) {
        self.capabilities = capabilities
        self.exampleCommands = exampleCommands
        self.fileTypes = fileTypes
        self.isDestructive = isDestructive
    }

    /// Compact string injected into AI system prompt when aiHint is empty
    var synthesizedHint: String {
        var parts: [String] = []
        if !capabilities.isEmpty {
            parts.append("Capabilities: " + capabilities.joined(separator: ", "))
        }
        if !exampleCommands.isEmpty {
            parts.append("Examples: " + exampleCommands.joined(separator: " | "))
        }
        if !fileTypes.isEmpty { parts.append("File types: " + fileTypes.joined(separator: ", ")) }
        return parts.joined(separator: ". ")
    }
}

// MARK: - Per-App CLI Tool Extension
// MARK: - Tool kind (CLI binary vs user script)

enum AppToolKind: String, Codable {
    case cli  // binary on $PATH — AI calls via run_command
    case script  // saved script file (bash / Python / JXA / AppleScript / Lua)
    case prompt  // AI prompt template — becomes the system prompt, no binary needed
}

enum AppScriptLanguage: String, Codable, CaseIterable, Identifiable {
    case bash = "bash"
    case python = "Python 3"
    case jxa = "JXA"
    case applescript = "AppleScript"
    case lua = "Lua"

    var id: String { rawValue }

    var fileExtension: String {
        switch self {
        case .bash: return "sh"
        case .python: return "py"
        case .jxa: return "js"
        case .applescript: return "applescript"
        case .lua: return "lua"
        }
    }

    var shebang: String {
        switch self {
        case .bash: return "#!/usr/bin/env bash"
        case .python: return "#!/usr/bin/env python3"
        case .jxa: return "#!/usr/bin/env osascript -l JavaScript"
        case .applescript: return "-- AppleScript"
        case .lua: return "-- Lua (runs via Hammerspoon `hs`)"
        }
    }

    var systemImage: String {
        switch self {
        case .bash: return "terminal"
        case .python: return "chevron.left.forwardslash.chevron.right"
        case .jxa: return "curlybraces"
        case .applescript: return "applescript"
        case .lua: return "hammer"
        }
    }

    /// How to execute a saved script file at the given path.
    /// Lua scripts are executed via Hammerspoon's `hs` CLI.
    func runCommand(scriptPath: String) -> String {
        switch self {
        case .bash, .python: return "\"\(scriptPath)\""
        case .jxa: return "osascript -l JavaScript \"\(scriptPath)\""
        case .applescript: return "osascript \"\(scriptPath)\""
        case .lua:
            // `hs` CLI ships with Hammerspoon at /usr/local/bin/hs
            // Falls back to running lua interpreter directly if hs not found
            let hsPaths = [
                "/usr/local/bin/hs", "/opt/homebrew/bin/hs",
                "\(NSHomeDirectory())/.local/bin/hs",
            ]
            let hs = hsPaths.first { FileManager.default.fileExists(atPath: $0) } ?? "hs"
            return "\(hs) \"\(scriptPath)\""
        }
    }

    /// Template starter code shown in the editor for each language
    func starterTemplate(appKey: String, scriptName: String) -> String {
        switch self {
        case .bash:
            return """
                #!/usr/bin/env bash
                # \(appKey) tool — \(scriptName)
                # $FILE  = selected file path (passed by ILauncher)
                # $QUERY = user's natural language query

                echo "Running \(scriptName) for: $FILE"
                """
        case .python:
            return """
                #!/usr/bin/env python3
                # \(appKey) tool — \(scriptName)
                # sys.argv[1] = selected file path
                # sys.argv[2] = user query (optional)
                import sys, os

                file  = sys.argv[1] if len(sys.argv) > 1 else ""
                query = sys.argv[2] if len(sys.argv) > 2 else ""
                #if DEBUG
                print(f"Running \(scriptName) on: {file}")
                #endif
                """
        case .jxa:
            return """
                #!/usr/bin/env osascript -l JavaScript
                // \(appKey) tool — \(scriptName)
                // argv[0] = selected file path
                // argv[1] = user query (optional)
                function run(argv) {
                    const file  = argv[0] || "";
                    const query = argv[1] || "";
                    return "Done: " + file;
                }
                """
        case .applescript:
            return """
                -- \(appKey) tool — \(scriptName)
                -- on run {filePath, query}
                on run argv
                    set filePath to item 1 of argv
                    -- set query to item 2 of argv
                    return "Done: " & filePath
                end run
                """
        case .lua:
            return """
                -- \(appKey) Hammerspoon tool — \(scriptName)
                -- Called via: hs scriptname.lua <filePath> <query>
                -- arg[1] = selected file path, arg[2] = user query
                local filePath = arg and arg[1] or ""
                local query    = arg and arg[2] or ""

                -- Example: show an alert in Hammerspoon
                hs.alert.show("\\(scriptName): " .. filePath)

                -- Example: open file with a specific app
                -- hs.execute("open -a 'Finder' '" .. filePath .. "'")
                """
        }
    }
}

// MARK: - AppToolExtension

struct AppToolExtension: Codable, Identifiable, Equatable {
    let id: UUID
    var appKey: String  // matches CustomAppEntry.key or built-in key
    var toolName: String  // CLI binary name (kind=.cli) or script display name (kind=.script)
    var toolPath: String  // full binary path (.cli) or saved script file path (.script)
    var aiHint: String  // legacy flat hint — kept for backward compat
    var profile: AppToolProfile  // structured capability profile

    // Script support
    var kind: AppToolKind = .cli
    var scriptLanguage: AppScriptLanguage? = nil
    var scriptCode: String = ""  // source shown in editor (not saved to toolPath file)

    /// Per-app entry command — e.g. "memo notes" when memo is registered for the Notes app,
    /// "memo rem" when the same binary is registered for Reminders.
    /// Empty = use `toolName` as the command root (default, backward-compatible).
    var appSubcommand: String = ""

    /// Context flag appended after each subcommand to scope the CLI to this app.
    /// Used when one binary handles multiple apps via flags instead of subcommands.
    /// e.g. "--reminders" makes AI always generate `ekctl list --reminders`, `ekctl add --reminders`
    var appContextFlag: String = ""

    /// User-facing SF Symbol. Used by global/context extension pills.
    var iconName: String = ""

    // MARK: Prompt extension fields (kind == .prompt only)
    /// The system prompt template. Supports {{query}}, {{date}}, {{time}}, {{clipboard}}, {{app}}.
    var promptTemplate: String = ""
    /// Cache identical responses for this many minutes. 0 = no cache.
    var cacheTTLMinutes: Int = 0

    /// The actual command root the AI should use in this app context.
    /// e.g. "memo notes" or "memo rem" instead of just "memo".
    var effectiveCommand: String {
        appSubcommand.trimmingCharacters(in: .whitespaces).isEmpty ? toolName : appSubcommand
    }

    init(
        appKey: String, toolName: String, toolPath: String = "",
        aiHint: String = "", profile: AppToolProfile = AppToolProfile(),
        kind: AppToolKind = .cli, scriptLanguage: AppScriptLanguage? = nil,
        scriptCode: String = "", appSubcommand: String = "", appContextFlag: String = "",
        iconName: String = "", promptTemplate: String = "", cacheTTLMinutes: Int = 0
    ) {
        self.id = UUID()
        self.appKey = appKey
        self.toolName = toolName
        self.toolPath = toolPath
        self.aiHint = aiHint
        self.profile = profile
        self.kind = kind
        self.scriptLanguage = scriptLanguage
        self.scriptCode = scriptCode
        self.appSubcommand = appSubcommand
        self.appContextFlag = appContextFlag
        self.iconName = SFSymbolResolver.validSymbol(iconName, fallback: "")
        self.promptTemplate = promptTemplate
        self.cacheTTLMinutes = cacheTTLMinutes
    }

    /// Effective hint: synthesised profile when capabilities are set, otherwise legacy aiHint.
    var effectiveHint: String {
        let synth = profile.synthesizedHint
        return synth.isEmpty ? aiHint : synth
    }

    var isScript: Bool { kind == .script }
    var isPrompt: Bool { kind == .prompt }

    // Custom decoder so old saved data (no new keys) loads without crashing
    enum CodingKeys: String, CodingKey {
        case id, appKey, toolName, toolPath, aiHint, profile, kind, scriptLanguage, scriptCode,
            appSubcommand
        case appContextFlag, iconName, promptTemplate, cacheTTLMinutes
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        appKey = try c.decode(String.self, forKey: .appKey)
        toolName = try c.decode(String.self, forKey: .toolName)
        toolPath = try c.decodeIfPresent(String.self, forKey: .toolPath) ?? ""
        aiHint = try c.decodeIfPresent(String.self, forKey: .aiHint) ?? ""
        profile = try c.decodeIfPresent(AppToolProfile.self, forKey: .profile) ?? AppToolProfile()
        kind = try c.decodeIfPresent(AppToolKind.self, forKey: .kind) ?? .cli
        scriptLanguage = try c.decodeIfPresent(AppScriptLanguage.self, forKey: .scriptLanguage)
        scriptCode = try c.decodeIfPresent(String.self, forKey: .scriptCode) ?? ""
        appSubcommand = try c.decodeIfPresent(String.self, forKey: .appSubcommand) ?? ""
        appContextFlag = try c.decodeIfPresent(String.self, forKey: .appContextFlag) ?? ""
        iconName = SFSymbolResolver.validSymbol(
            try c.decodeIfPresent(String.self, forKey: .iconName),
            fallback: ""
        )
        promptTemplate = try c.decodeIfPresent(String.self, forKey: .promptTemplate) ?? ""
        cacheTTLMinutes = try c.decodeIfPresent(Int.self, forKey: .cacheTTLMinutes) ?? 0
    }
}

// MARK: - App Profile Template (JSON export / import)
struct AppProfileTemplate: Codable {
    var version: Int = 1
    var appKey: String
    var label: String
    var iconName: String
    var appPath: String
    var quickActions: [AppShortcut]
    var tools: [AppToolExtension]
    var aiPersonality: String  // optional custom system-prompt prefix

    static func from(appKey: String, settings: AppSettings) -> AppProfileTemplate {
        let entry = settings.customAppEntries.first(where: { $0.key == appKey })
        return AppProfileTemplate(
            appKey: appKey,
            label: entry?.label ?? appKey.capitalized,
            iconName: entry?.iconName ?? "app.fill",
            appPath: entry?.appPath ?? "",
            quickActions: settings.shortcuts(for: appKey),
            tools: settings.toolExtensions(for: appKey),
            aiPersonality: ""
        )
    }
}

// MARK: - App Shortcut Model (user-defined quick actions per app/keyword)
struct AppShortcut: Codable, Identifiable, Equatable {
    enum ActionType: String, Codable {
        case openURL  // open a URL or deep-link
        case openFile  // open a file/app path
        case shellCommand  // run a shell command inline
        case appleScript  // run an AppleScript snippet
        case jxa  // JavaScript for Automation (osascript -l JavaScript)
        case scriptFile  // run an external script file (.sh/.py/.js/.rb) with context env vars
        case menuItem  // click a menu bar item by path, e.g. "File > New Tab"
        case shortcut  // run a macOS Shortcut by name with the selection as input
    }

    /// Where this shortcut appears in the launcher UI.
    enum Placement: String, Codable {
        case quickActions = "quickActions"  // Search dock bar when app name is typed
        case contextDock = "contextDock"  // L2 context dock pills when app is frontmost
        case both = "both"  // Appears in both quick actions and context dock
        case fileActions = "fileActions"  // Action button when a file is selected in search
    }

    let id: UUID
    var name: String  // display label, e.g. "New Event"
    var iconName: String  // SF Symbol name, e.g. "calendar.badge.plus"
    var actionType: ActionType
    var actionValue: String  // the URL / path / script to execute
    var appKey: String  // the trigger keyword, e.g. "calendar", "notes"
    var placement: Placement  // which section this shortcut appears in
    /// Additional app keys this shortcut also appears for (cross-app sharing).
    var targetAppKeys: [String]
    /// File extensions this action handles when placement == .fileActions (empty = all files).
    var fileTypes: [String]
    /// Keywords that trigger this action in search (placement == .fileActions / .quickActions).
    var triggerKeywords: [String]

    init(
        name: String, iconName: String = "bolt.fill",
        actionType: ActionType = .openURL, actionValue: String,
        appKey: String, placement: Placement = .quickActions,
        targetAppKeys: [String] = [],
        fileTypes: [String] = [], triggerKeywords: [String] = []
    ) {
        self.id = UUID()
        self.name = name
        self.iconName = iconName
        self.actionType = actionType
        self.actionValue = actionValue
        self.appKey = appKey
        self.placement = placement
        self.targetAppKeys = targetAppKeys
        self.fileTypes = fileTypes
        self.triggerKeywords = triggerKeywords
    }

    // Custom decoder for backward compat
    enum CodingKeys: String, CodingKey {
        case id, name, iconName, actionType, actionValue, appKey, placement, targetAppKeys
        case fileTypes, triggerKeywords
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        iconName = try c.decodeIfPresent(String.self, forKey: .iconName) ?? "bolt.fill"
        actionType = try c.decode(ActionType.self, forKey: .actionType)
        actionValue = try c.decode(String.self, forKey: .actionValue)
        appKey = try c.decode(String.self, forKey: .appKey)
        placement = try c.decodeIfPresent(Placement.self, forKey: .placement) ?? .quickActions
        targetAppKeys = try c.decodeIfPresent([String].self, forKey: .targetAppKeys) ?? []
        fileTypes = try c.decodeIfPresent([String].self, forKey: .fileTypes) ?? []
        triggerKeywords = try c.decodeIfPresent([String].self, forKey: .triggerKeywords) ?? []
    }

    /// Built-in defaults shown until user customises them
    static let builtInDefaults: [AppShortcut] = [
        // Safari
        AppShortcut(
            name: "New Tab", iconName: "plus.square", actionType: .openURL,
            actionValue: "x-safari-https://newtab", appKey: "safari"),
        AppShortcut(
            name: "New Private Tab", iconName: "eyeglasses", actionType: .openURL,
            actionValue: "x-safari-https://privatebrowsing", appKey: "safari"),
        AppShortcut(
            name: "Open Safari", iconName: "safari", actionType: .openFile,
            actionValue: "/Applications/Safari.app", appKey: "safari"),
        AppShortcut(
            name: "Reader Mode", iconName: "doc.text", actionType: .appleScript,
            actionValue:
                "tell application \"Safari\" to do JavaScript \"document.body.style.zoom='1.0'\" in front document",
            appKey: "safari"),
        AppShortcut(
            name: "Copy URL", iconName: "link", actionType: .appleScript,
            actionValue:
                "tell application \"Safari\"\nset u to URL of current tab of front window\nend tell\nset the clipboard to u",
            appKey: "safari"),
        // System Settings
        AppShortcut(
            name: "Open Settings", iconName: "gear", actionType: .openFile,
            actionValue: "/System/Applications/System Settings.app", appKey: "systemsettings"),
        AppShortcut(
            name: "Wi-Fi", iconName: "wifi", actionType: .openURL,
            actionValue: "x-apple.systempreferences:com.apple.preference.network?Wi-Fi",
            appKey: "systemsettings"),
        AppShortcut(
            name: "Bluetooth", iconName: "dot.radiowaves.right", actionType: .openURL,
            actionValue: "x-apple.systempreferences:com.apple.preference.bluetooth",
            appKey: "systemsettings"),
        AppShortcut(
            name: "Displays", iconName: "display", actionType: .openURL,
            actionValue: "x-apple.systempreferences:com.apple.Displays-Settings.extension",
            appKey: "systemsettings"),
        AppShortcut(
            name: "Notifications", iconName: "bell.badge", actionType: .openURL,
            actionValue: "x-apple.systempreferences:com.apple.preference.notifications",
            appKey: "systemsettings"),
        AppShortcut(
            name: "Privacy & Security", iconName: "lock.shield", actionType: .openURL,
            actionValue: "x-apple.systempreferences:com.apple.preference.security",
            appKey: "systemsettings"),
        // Calendar
        AppShortcut(
            name: "New Event", iconName: "calendar.badge.plus", actionType: .openURL,
            actionValue: "ical://", appKey: "calendar"),
        AppShortcut(
            name: "Open Calendar", iconName: "calendar", actionType: .openFile,
            actionValue: "/System/Applications/Calendar.app", appKey: "calendar"),
        // Reminders
        AppShortcut(
            name: "New Reminder", iconName: "plus.circle", actionType: .openURL,
            actionValue: "x-apple-reminderkit://", appKey: "reminders"),
        AppShortcut(
            name: "Open Reminders", iconName: "checkmark.circle", actionType: .openFile,
            actionValue: "/System/Applications/Reminders.app", appKey: "reminders"),
        // Notes
        AppShortcut(
            name: "New Note", iconName: "square.and.pencil", actionType: .openURL,
            actionValue: "applenotes://", appKey: "notes"),
        AppShortcut(
            name: "Open Notes", iconName: "note.text", actionType: .openFile,
            actionValue: "/System/Applications/Notes.app", appKey: "notes"),
        // Mail
        AppShortcut(
            name: "New Email", iconName: "envelope.badge", actionType: .openURL,
            actionValue: "mailto:", appKey: "mail"),
        AppShortcut(
            name: "Open Mail", iconName: "envelope", actionType: .openFile,
            actionValue: "/System/Applications/Mail.app", appKey: "mail"),
        // Photos
        AppShortcut(
            name: "Open Photos", iconName: "photo", actionType: .openFile,
            actionValue: "/System/Applications/Photos.app", appKey: "photos"),
        // Messages
        AppShortcut(
            name: "New Message", iconName: "message.badge", actionType: .openURL,
            actionValue: "sms:", appKey: "messages"),
        AppShortcut(
            name: "Open Messages", iconName: "message", actionType: .openFile,
            actionValue: "/System/Applications/Messages.app", appKey: "messages"),
        // Contacts
        AppShortcut(
            name: "New Contact", iconName: "person.badge.plus", actionType: .openURL,
            actionValue: "addressbook://", appKey: "contacts"),
        AppShortcut(
            name: "Open Contacts", iconName: "person.2", actionType: .openFile,
            actionValue: "/System/Applications/Contacts.app", appKey: "contacts"),
        // File types — shown in dock when a file of that type is selected in folder preview
        AppShortcut(
            name: "Open in Preview", iconName: "doc.richtext", actionType: .shellCommand,
            actionValue: "open -a Preview \"$1\"", appKey: "pdf"),
        AppShortcut(
            name: "Quick Look", iconName: "eye", actionType: .shellCommand,
            actionValue: "qlmanage -p \"$1\" &>/dev/null &", appKey: "pdf"),
        AppShortcut(
            name: "Open in Preview", iconName: "photo", actionType: .shellCommand,
            actionValue: "open -a Preview \"$1\"", appKey: "image"),
        AppShortcut(
            name: "Set as Wallpaper", iconName: "photo.on.rectangle", actionType: .shellCommand,
            actionValue:
                "osascript -e 'tell application \"Finder\" to set desktop picture to POSIX file \"$1\"'",
            appKey: "image"),
        AppShortcut(
            name: "Open in IINA", iconName: "play.rectangle", actionType: .shellCommand,
            actionValue: "open -a IINA \"$1\" 2>/dev/null || open \"$1\"", appKey: "video"),
        AppShortcut(
            name: "Get Info", iconName: "info.circle", actionType: .shellCommand,
            actionValue:
                "osascript -e 'tell application \"Finder\" to open information window of (POSIX file \"$1\" as alias)'",
            appKey: "video"),
        AppShortcut(
            name: "Open in Music", iconName: "music.note", actionType: .shellCommand,
            actionValue: "open -a Music \"$1\"", appKey: "audio"),
        AppShortcut(
            name: "Quick Look", iconName: "eye", actionType: .shellCommand,
            actionValue: "qlmanage -p \"$1\" &>/dev/null &", appKey: "audio"),
        AppShortcut(
            name: "Convert to MP3", iconName: "waveform", actionType: .shellCommand,
            actionValue: "~/.local/bin/audio-convert \"$1\" mp3", appKey: "audio"),
        AppShortcut(
            name: "Convert to M4A", iconName: "waveform.badge.plus", actionType: .shellCommand,
            actionValue: "~/.local/bin/audio-convert \"$1\" m4a", appKey: "audio"),
        AppShortcut(
            name: "Convert to WAV", iconName: "waveform.circle", actionType: .shellCommand,
            actionValue: "~/.local/bin/audio-convert \"$1\" wav", appKey: "audio"),
        AppShortcut(
            name: "Convert to FLAC", iconName: "waveform.badge.magnifyingglass",
            actionType: .shellCommand, actionValue: "~/.local/bin/audio-convert \"$1\" flac",
            appKey: "audio"),
        AppShortcut(
            name: "Extract Audio (MP3)", iconName: "waveform", actionType: .shellCommand,
            actionValue: "~/.local/bin/audio-convert \"$1\" mp3", appKey: "video"),
        AppShortcut(
            name: "Extract Audio (M4A)", iconName: "waveform.badge.plus", actionType: .shellCommand,
            actionValue: "~/.local/bin/audio-convert \"$1\" m4a", appKey: "video"),
        AppShortcut(
            name: "Extract Here", iconName: "archivebox", actionType: .shellCommand,
            actionValue: "cd \"$(dirname \"$1\")\" && unzip -o \"$1\" 2>/dev/null || tar xf \"$1\"",
            appKey: "archive"),
        AppShortcut(
            name: "Show in Finder", iconName: "folder", actionType: .shellCommand,
            actionValue: "open -R \"$1\"", appKey: "archive"),
        AppShortcut(
            name: "Open in Pages", iconName: "doc.text", actionType: .shellCommand,
            actionValue: "open -a Pages \"$1\" 2>/dev/null || open \"$1\"", appKey: "document"),
        AppShortcut(
            name: "Open in Numbers", iconName: "tablecells", actionType: .shellCommand,
            actionValue: "open -a Numbers \"$1\" 2>/dev/null || open \"$1\"", appKey: "spreadsheet"),
        AppShortcut(
            name: "Open in Keynote", iconName: "rectangle.on.rectangle", actionType: .shellCommand,
            actionValue: "open -a Keynote \"$1\" 2>/dev/null || open \"$1\"", appKey: "presentation"
        ),
        AppShortcut(
            name: "Open in VS Code", iconName: "chevron.left.forwardslash.chevron.right",
            actionType: .shellCommand, actionValue: "code \"$1\" 2>/dev/null || open \"$1\"",
            appKey: "code"),
        AppShortcut(
            name: "Copy Path", iconName: "doc.on.clipboard", actionType: .shellCommand,
            actionValue: "echo -n \"$1\" | pbcopy", appKey: "code"),
    ]
}

// MARK: - Spotlight Search Directory Model
struct SearchDirectory: Codable, Identifiable, Equatable {
    let id: UUID
    let path: String
    let displayName: String
    var bookmarkData: Data?  // Security-scoped bookmark for persistent access

    init(path: String, displayName: String, bookmarkData: Data? = nil) {
        self.id = UUID()
        self.path = path
        self.displayName = displayName
        self.bookmarkData = bookmarkData
    }
}

// MARK: - Extension Script Model
struct ExtensionScript: Codable, Identifiable, Equatable {
    enum ScriptType: String, Codable {
        case spoon = "spoon"
        case lua = "lua"
        case shell = "sh"
        case bash = "bash"
        case applescript = "scpt"
        case jxa = "jxa"
        case python = "py"

        var displayName: String {
            switch self {
            case .spoon: return "Hammerspoon Spoon"
            case .lua: return "Lua Script"
            case .shell: return "Shell Script"
            case .bash: return "Bash Script"
            case .applescript: return "AppleScript"
            case .jxa: return "JavaScript (JXA)"
            case .python: return "Python Script"
            }
        }

        var icon: String {
            switch self {
            case .spoon: return "cube.box.fill"
            case .lua: return "doc.text.fill"
            case .shell: return "terminal.fill"
            case .bash: return "terminal.fill"
            case .applescript: return "applescript.fill"
            case .jxa: return "applescript.fill"
            case .python: return "chevron.left.forwardslash.chevron.right"
            }
        }

        var fileExtensions: [String] {
            switch self {
            case .spoon: return ["spoon"]
            case .lua: return ["lua"]
            case .shell: return ["sh"]
            case .bash: return ["bash"]
            case .applescript: return ["scpt", "applescript"]
            case .jxa: return ["jxa"]
            case .python: return ["py"]
            }
        }
    }

    let id: UUID
    let name: String
    let path: String
    let type: ScriptType
    var isEnabled: Bool

    init(name: String, path: String, type: ScriptType, isEnabled: Bool = true) {
        self.id = UUID()
        self.name = name
        self.path = path
        self.type = type
        self.isEnabled = isEnabled
    }
}

// MARK: - AI Provider Models
enum AIProviderSupportTier: String, CaseIterable, Identifiable {
    case official = "Official APIs"
    case bridge = "Subscription Bridge"
    case local = "Local"
    case experimental = "Experimental"

    var id: String { rawValue }
}

enum AIProvider: String, Codable, CaseIterable, Identifiable {
    case onDevice = "onDevice"
    case googleGemini = "googleGemini"
    case openAI = "openAI"
    case anthropic = "anthropic"
    case claudeBridge = "claudeBridge"
    case chatGPTBridge = "chatGPTBridge"
    case ollama = "ollama"
    case openAICompatible = "openAICompatible"
    case shortcuts = "shortcuts"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .onDevice: return "On-Device Intelligence"
        case .googleGemini: return "Google Gemini"
        case .openAI: return "ChatGPT (OpenAI)"
        case .anthropic: return "Claude (Anthropic)"
        case .claudeBridge: return "Claude Pro (via Bridge)"
        case .chatGPTBridge: return "ChatGPT Plus (via Bridge)"
        case .ollama: return "Ollama (Local)"
        case .openAICompatible: return "OpenAI-Compatible"
        case .shortcuts: return "Apple Shortcuts"
        }
    }

    var shortName: String {
        switch self {
        case .onDevice: return "Apple Intelligence"
        case .googleGemini: return "Gemini"
        case .openAI: return "ChatGPT"
        case .anthropic: return "Claude"
        case .claudeBridge: return "Claude Pro"
        case .chatGPTBridge: return "ChatGPT Plus"
        case .ollama: return "Ollama"
        case .openAICompatible: return "Compatible"
        case .shortcuts: return "Shortcuts"
        }
    }

    var description: String {
        switch self {
        case .onDevice:
            return
                "Uses Apple's Foundation Models through the native Swift API for local Apple Intelligence. Requires no API key."
        case .googleGemini: return "Google's Gemini AI models. Requires API key."
        case .openAI: return "OpenAI's GPT models. Requires API key."
        case .anthropic: return "Anthropic's Claude models. Requires API key."
        case .claudeBridge:
            return
                "Use your existing Claude Pro subscription via a local bridge (e.g. VibeProxy). No extra billing."
        case .chatGPTBridge:
            return
                "Use your existing ChatGPT Plus subscription via a local bridge (e.g. VibeProxy). No extra billing."
        case .ollama: return "Run local AI models with Ollama. Free and private."
        case .openAICompatible:
            return "Use LM Studio, OpenRouter, or another OpenAI-compatible endpoint."
        case .shortcuts: return "Use any Apple Shortcut as your AI. Fully customizable."
        }
    }

    var iconName: String {
        switch self {
        case .onDevice: return "apple.intelligence"
        case .googleGemini: return "sparkles"
        case .openAI: return "bubble.left.and.bubble.right"
        case .anthropic: return "brain.head.profile"
        case .claudeBridge: return "arrow.triangle.2.circlepath.circle.fill"
        case .chatGPTBridge: return "arrow.triangle.2.circlepath.circle"
        case .ollama: return "server.rack"
        case .openAICompatible: return "network"
        case .shortcuts: return "bolt.fill"
        }
    }

    var requiresAPIKey: Bool {
        switch self {
        case .onDevice, .ollama, .openAICompatible, .shortcuts,
            .claudeBridge, .chatGPTBridge:
            return false
        case .googleGemini, .openAI, .anthropic: return true
        }
    }

    var requiresEndpoint: Bool {
        switch self {
        case .ollama, .openAICompatible, .claudeBridge, .chatGPTBridge: return true
        default: return false
        }
    }

    var requiresShortcut: Bool {
        self == .shortcuts
    }

    var supportTier: AIProviderSupportTier {
        switch self {
        case .openAI, .anthropic, .googleGemini:
            return .official
        case .claudeBridge, .chatGPTBridge:
            return .bridge
        case .onDevice, .ollama, .shortcuts:
            return .local
        case .openAICompatible:
            return .experimental
        }
    }
}

// MARK: - Ollama Model
struct OllamaModel: Codable, Identifiable, Equatable {
    let id: UUID
    let name: String
    let displayName: String

    init(name: String, displayName: String? = nil) {
        self.id = UUID()
        self.name = name
        self.displayName = displayName ?? name
    }
}

class AppSettings: ObservableObject {
    static let shared = AppSettings()

    /// User-authored steering text prepended to the system prompt of *every* AI surface
    /// — General Chat, Context Dock chat and extension AI panels. One field so the user
    /// sets tone, language and standing rules in a single place instead of per surface.
    @AppStorage("globalContextPrompt") var globalContextPrompt: String = ""

    /// Quick Note's assistant pane. Persisted so hiding it stays hidden — a note
    /// window is often wanted as just a note.
    @AppStorage("quickNoteAISidecarVisible") var quickNoteAISidecarVisible: Bool = true

    @AppStorage("showMenuBarIcon") var showMenuBarIcon: Bool = true
    @AppStorage("automaticUpdatesEnabled") var automaticUpdatesEnabled: Bool = true
    @AppStorage("openDownloadedUpdatesAutomatically") var openDownloadedUpdatesAutomatically: Bool =
        true
    /// 0…1 dark tint laid over the Liquid Glass dock shell. 0 = pure glass, 1 = much
    /// darker. User-adjustable in Appearance settings.
    @AppStorage("glassDarkness") var glassDarkness: Double = 0
    /// When on, the dock never auto-hides on focus loss or after an action runs — it
    /// stays floating until explicitly dismissed (Escape / hotkey).
    @AppStorage("alwaysFloatDock") var alwaysFloatDock: Bool = false
    /// User pinned the launcher via the pin button: it floats above every app and
    /// never auto-hides on focus loss until unpinned. Session-scoped by design —
    /// a relaunch starts unpinned.
    @Published var launcherPinned: Bool = false
    @AppStorage("enableSpotlightSearch") var enableSpotlightSearch: Bool = true
    @AppStorage("enableL1DocumentSearch") var enableL1DocumentSearch: Bool = true
    @AppStorage("enableL1FileSearch") var enableL1FileSearch: Bool = true
    @AppStorage("useCustomSearchDirectories") var useCustomSearchDirectories: Bool = false
    @AppStorage("useDoubleOptionLaunch") var useDoubleOptionLaunch: Bool = true
    @AppStorage("hotkeyKeyCode") private var _hotkeyKeyCode: Int = 49  // Space bar
    @AppStorage("hotkeyModifiers") private var _hotkeyModifiers: Int = Int(optionKey)
    @AppStorage("contextDockHotkeyKeyCode") private var _contextDockHotkeyKeyCode: Int = 0
    @AppStorage("contextDockHotkeyModifiers") private var _contextDockHotkeyModifiers: Int = 0
    @AppStorage("clipboardScopeHotkeyKeyCode") private var _clipboardScopeHotkeyKeyCode: Int = 0
    @AppStorage("clipboardScopeHotkeyModifiers") private var _clipboardScopeHotkeyModifiers: Int = 0
    @AppStorage("quickNoteHotkeyKeyCode") private var _quickNoteHotkeyKeyCode: Int = 0
    @AppStorage("quickNoteHotkeyModifiers") private var _quickNoteHotkeyModifiers: Int = 0
    @AppStorage("captureTextHotkeyKeyCode") private var _captureTextHotkeyKeyCode: Int = 0
    @AppStorage("captureTextHotkeyModifiers") private var _captureTextHotkeyModifiers: Int = 0
    @AppStorage("captureAreaHotkeyKeyCode") private var _captureAreaHotkeyKeyCode: Int = 0
    @AppStorage("captureAreaHotkeyModifiers") private var _captureAreaHotkeyModifiers: Int = 0
    @AppStorage("captureScreenshotHotkeyKeyCode") private var _captureScreenshotHotkeyKeyCode: Int = 0
    @AppStorage("captureScreenshotHotkeyModifiers") private var _captureScreenshotHotkeyModifiers: Int = 0
    @AppStorage("selectionScopeHotkeyKeyCode") private var _selectionScopeHotkeyKeyCode: Int = 0
    @AppStorage("selectionScopeHotkeyModifiers") private var _selectionScopeHotkeyModifiers: Int = 0

    /// Folder where Capture Area / Screenshot images are saved. Empty = ~/Pictures (default).
    @AppStorage("captureSaveFolderPath") private var _captureSaveFolderPath: String = ""
    var captureSaveFolderPath: String {
        get { _captureSaveFolderPath }
        set { objectWillChange.send(); _captureSaveFolderPath = newValue }
    }
    /// Resolved save directory — the chosen folder if valid, else ~/Pictures.
    var captureSaveDirectory: URL {
        if !_captureSaveFolderPath.isEmpty {
            let url = URL(fileURLWithPath: _captureSaveFolderPath, isDirectory: true)
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
                return url
            }
        }
        return FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
    }
    @AppStorage("pinnedAppsData") private var pinnedAppsData: Data = Data()
    @AppStorage("searchDirectoriesData") private var searchDirectoriesData: Data = Data()
    @AppStorage("extensionScriptsData") private var extensionScriptsData: Data = Data()
    @AppStorage("importedBookmarksData") private var importedBookmarksData: Data = Data()
    @AppStorage("recentWebSearchesData") private var recentWebSearchesData: Data = Data()
    @AppStorage("appShortcutsData") private var appShortcutsData: Data = Data()
    @AppStorage("customAppEntriesData") private var customAppEntriesData: Data = Data()
    @AppStorage("axTriggerRulesData") private var axTriggerRulesData: Data = Data()
    @AppStorage("appToolExtensionsData") private var appToolExtensionsData: Data = Data()
    @AppStorage("tuiFolderAccessData") private var tuiFolderAccessData: Data = Data()
    @AppStorage("pinnedCLIToolsData") private var pinnedCLIToolsData: Data = Data()
    @AppStorage("pinnedCLIToolsSeeded") private var pinnedCLIToolsSeeded: Bool = false
    @AppStorage("menuPillFavouritesData") private var menuPillFavouritesData: Data = Data()

    // MARK: - Favourite menu pills (per app bundle ID)

    func favouriteMenuPills(for bundleId: String) -> Set<String> {
        let dict =
            (try? JSONDecoder().decode([String: [String]].self, from: menuPillFavouritesData))
            ?? [:]
        return Set(dict[bundleId] ?? [])
    }

    /// Returns every favourited pill across all apps as a flat dictionary.
    func allFavouriteMenuPills() -> [String: [String]] {
        return (try? JSONDecoder().decode([String: [String]].self, from: menuPillFavouritesData))
            ?? [:]
    }

    func toggleFavouriteMenuPill(_ name: String, for bundleId: String) {
        var dict =
            (try? JSONDecoder().decode([String: [String]].self, from: menuPillFavouritesData))
            ?? [:]
        var set = Set(dict[bundleId] ?? [])
        if set.contains(name) { set.remove(name) } else { set.insert(name) }
        dict[bundleId] = Array(set)
        menuPillFavouritesData = (try? JSONEncoder().encode(dict)) ?? Data()
    }

    // System Data Search Toggles (surface in Settings and sync to AppPermissionCenter)
    @AppStorage("allowCalendars") var allowCalendars: Bool = true
    @AppStorage("allowReminders") var allowReminders: Bool = true
    @AppStorage("allowPhotos") var allowPhotos: Bool = true
    @AppStorage("allowContacts") var allowContacts: Bool = true
    @AppStorage("allowAutomation") var allowAutomation: Bool = true  // AppleScript (Notes/Mail/Messages)

    // First-party Apple MCP suite. Enabled by default, but macOS privacy permissions and
    // Context Dock's risk approvals still gate data access and every write operation.
    @AppStorage("noteMCPEnabled") var noteMCPEnabled: Bool = true
    @AppStorage("noteMCPAllowMetadataSearch") var noteMCPAllowMetadataSearch: Bool = true
    @AppStorage("noteMCPAllowPersistentFullRead") var noteMCPAllowPersistentFullRead: Bool = false
    @AppStorage("noteMCPAllowGlobalAccess") var noteMCPAllowGlobalAccess: Bool = false
    @AppStorage("noteMCPAllowBulkExport") var noteMCPAllowBulkExport: Bool = false
    @AppStorage("noteMCPAllowDelete") var noteMCPAllowDelete: Bool = false
    @AppStorage("noteMCPPreferLocalAI") var noteMCPPreferLocalAI: Bool = true
    @AppStorage("noteMCPRequireCloudApproval") var noteMCPRequireCloudApproval: Bool = true

    @AppStorage("calendarMCPEnabled") var calendarMCPEnabled: Bool = true
    @AppStorage("contactsMCPEnabled") var contactsMCPEnabled: Bool = true
    @AppStorage("remindersMCPEnabled") var remindersMCPEnabled: Bool = true
    @AppStorage("photosMCPEnabled") var photosMCPEnabled: Bool = true
    @AppStorage("mailMCPEnabled") var mailMCPEnabled: Bool = true
    @AppStorage("musicMCPEnabled") var musicMCPEnabled: Bool = true
    @AppStorage("messagesMCPEnabled") var messagesMCPEnabled: Bool = true
    @AppStorage("githubMCPEnabled") var githubMCPEnabled: Bool = false

    // UI Feature Toggles
    @AppStorage("enableStatusBar") var enableStatusBar: Bool = true  // Show status bar extensions
    @AppStorage("enableFrontmostDetection") var enableFrontmostDetection: Bool = true  // Show frontmost app context
    @AppStorage("enableContextAIExtensions") var enableContextAIExtensions: Bool = true  // Show built-in context-aware AI extensions
    @AppStorage("allowSelectedTextCloudSharing") var allowSelectedTextCloudSharing: Bool = true
    @AppStorage("singleCommandTogglesContextScope") var singleCommandTogglesContextScope: Bool =
        true
    @AppStorage("showFloatingAppLogo") var showFloatingAppLogo: Bool = false

    // The "Always on Bottom" / taskbar dock mode was removed — the dock always anchors at the top
    // and grows downward. Kept as a constant so existing call sites compile without a 54-site rewrite.
    var effectiveDockAtBottom: Bool { false }
    @AppStorage("enableAIMode") var enableAIMode: Bool = true  // Allow switching to AI chat mode (Tab key or horizontal swipe)

    // Layer Toggles — controls which layers are accessible via swipe and hotkeys
    // Layer 1 (search + pinned apps) is always on and cannot be disabled.
    @AppStorage("enableLayer2") var enableLayer2: Bool = true  // Context Layer (app panel / shortcuts dock)
    @AppStorage("enableLayer3") var enableLayer3: Bool = true  // Media Layer (L3)
    var l2OnlyMode: Bool { false }
    @AppStorage("l2ScrollPassthrough") var l2ScrollPassthrough: Bool = false  // Forward scroll events to frontmost app while in context dock
    // Context Dock intelligence features
    @AppStorage("crossAppPills") var crossAppPills: Bool = true  // "Send to [running app]" pills based on context
    @AppStorage("clipboardAwarePills") var clipboardAwarePills: Bool = true  // Pills based on clipboard content type
    @AppStorage("sessionDetectionPills") var sessionDetectionPills: Bool = true  // Pre-rank pills by detected work session type
    @AppStorage("enableLearnedGhostSuggestions") var enableLearnedGhostSuggestions: Bool = true  // Ghost-text suggestions drawn from all frequently-used apps' cached menu commands
    @AppStorage("clipboardHistoryLimit") var clipboardHistoryLimit: Int = 10  // Max entries kept in clipboard history (5–50)
    @AppStorage("clipboardHistoryRetentionHours") var clipboardHistoryRetentionHours: Int = 8  // Auto-remove clipboard history after N hours
    @AppStorage("dockIconSize_v2") var dockIconSize: Double = 44  // App icon and pill size in dock (28–72, default 44)

    // Notification Settings
    @AppStorage("notifyOnActionCompleted") var notifyOnActionCompleted: Bool = true
    @AppStorage("notifyOnActionFailed") var notifyOnActionFailed: Bool = true
    @AppStorage("notifyOnAIResponse") var notifyOnAIResponse: Bool = false
    @AppStorage("notifySystemBanners") var notifySystemBanners: Bool = false

    // AI Provider Settings
    @AppStorage("selectedAIProvider") private var _selectedAIProvider: String = AIProvider.onDevice
        .rawValue
    @AppStorage("shortcutsProviderShortcut") var shortcutsProviderShortcut: String = ""  // Shortcut for Shortcuts provider
    @AppStorage("onDeviceSystemPrompt") var onDeviceSystemPrompt: String =
        "You are a helpful AI assistant for quick queries and information. Provide concise, accurate answers to user questions. Keep responses brief and to the point."  // Custom system prompt for On-Device AI
    @AppStorage("openAIAPIKey") private var legacyOpenAIAPIKey: String = ""
    @AppStorage("googleGeminiAPIKey") private var legacyGoogleGeminiAPIKey: String = ""
    @AppStorage("anthropicAPIKey") private var legacyAnthropicAPIKey: String = ""
    @AppStorage("openAICompatibleAPIKey") private var legacyOpenAICompatibleAPIKey: String = ""
    // True while loading keys FROM the Keychain at launch, so the didSet writers
    // below don't persist a transiently-empty read back over a real stored key —
    // that wiped users' API keys after a crash/relaunch.
    private var isLoadingAPIKeys = false
    @Published var openAIAPIKey: String = "" {
        didSet {
            guard !isLoadingAPIKeys else { return }
            KeychainStore.shared.set(openAIAPIKey, for: AIProvider.openAI.rawValue)
        }
    }
    @Published var googleGeminiAPIKey: String = "" {
        didSet {
            guard !isLoadingAPIKeys else { return }
            KeychainStore.shared.set(googleGeminiAPIKey, for: AIProvider.googleGemini.rawValue)
        }
    }
    @Published var anthropicAPIKey: String = "" {
        didSet {
            guard !isLoadingAPIKeys else { return }
            KeychainStore.shared.set(anthropicAPIKey, for: AIProvider.anthropic.rawValue)
        }
    }
    @Published var openAICompatibleAPIKey: String = "" {
        didSet {
            guard !isLoadingAPIKeys else { return }
            KeychainStore.shared.set(
                openAICompatibleAPIKey,
                for: AIProvider.openAICompatible.rawValue
            )
        }
    }
    @AppStorage("selectedOpenAIModel") var selectedOpenAIModel: String = "gpt-4o-mini"
    @AppStorage("selectedAnthropicModel") var selectedAnthropicModel: String =
        AnthropicModelCatalog.defaultModelID
    @AppStorage("ollamaEndpoint") var ollamaEndpoint: String = "http://localhost:11434"
    @AppStorage("selectedOllamaModel") var selectedOllamaModel: String = ""
    @AppStorage("openAICompatibleEndpoint") var openAICompatibleEndpoint: String =
        "http://localhost:1234/v1"
    @AppStorage("openAICompatibleModelID") var openAICompatibleModelID: String = ""
    // Dedicated AppleScript-automation model (e.g. Osaurus AppleScript-8B/16B on
    // 127.0.0.1:1337/v1). Optional + independent of the main chat provider: used ONLY
    // to turn NL automation intents into AppleScript in the action/execution layer.
    @AppStorage("appleScriptModelEnabled") var appleScriptModelEnabled: Bool = false
    @AppStorage("appleScriptModelEndpoint") var appleScriptModelEndpoint: String =
        "http://127.0.0.1:1337/v1"
    @AppStorage("appleScriptModelID") var appleScriptModelID: String = ""
    // Subscription bridge endpoints (VibeProxy default: localhost:8317)
    @AppStorage("claudeBridgeEndpoint") var claudeBridgeEndpoint: String =
        "http://localhost:8317/v1"
    // claude-3-5-sonnet-20241022 was retired in Oct 2025 and 404s on the real API; bridges
    // that pass the model string through were failing on first use with a stale default.
    @AppStorage("claudeBridgeModelID") var claudeBridgeModelID: String =
        "claude-opus-4-8"
    @AppStorage("chatGPTBridgeEndpoint") var chatGPTBridgeEndpoint: String =
        "http://localhost:8317/v1"
    @AppStorage("chatGPTBridgeModelID") var chatGPTBridgeModelID: String = "gpt-4o"
    @AppStorage("ollamaModelsData") private var ollamaModelsData: Data = Data()
    @AppStorage("aiChatHistoryData") private var aiChatHistoryData: Data = Data()

    // Terminal/Script Settings
    @AppStorage("customScriptsDirectory") var customScriptsDirectory: String =
        "~/.ilauncher/scripts"  // Custom scripts directory for extensions
    @AppStorage("additionalPATH") var additionalPATH: String = ""  // Additional PATH entries for custom tools

    // Extension Scripts
    @Published var extensionScripts: [ExtensionScript] = [] {
        didSet {
            saveExtensionScripts()
        }
    }

    // Window Appearance Settings
    @AppStorage("appearanceMode") var appearanceMode: String = "system"  // "system", "light", "dark"
    @AppStorage("glassBlurRadius") var glassBlurRadius: Double = 1.0  // 0.0 = no blur (opaque), 1.0 = full system blur
    @AppStorage("launcherWindowOpacity") var launcherWindowOpacity: Double = 0.95  // Launcher window transparency (0.0 = fully transparent, 1.0 = opaque)
    @AppStorage("dockLogoStyle") var dockLogoStyle: String = "d_logo"  // "d_logo", "apple"
    @AppStorage("launcherWindowHasSavedPosition") var launcherWindowHasSavedPosition: Bool = false
    @AppStorage("launcherWindowAnchorX") var launcherWindowAnchorX: Double = -1  // Floating launcher center X
    @AppStorage("launcherWindowTopY") var launcherWindowTopY: Double = -1  // Floating launcher top edge
    @AppStorage("launcherWindowScreenID") var launcherWindowScreenID: String = ""  // Last display
    @AppStorage("folderPreviewOpacity") var folderPreviewOpacity: Double = 0.98  // Folder preview window transparency
    @AppStorage("webSearchWindowOpacity") var webSearchWindowOpacity: Double = 0.98  // Web search window transparency
    @AppStorage("folderPreviewWidth") var folderPreviewWidth: Double = 800  // Folder preview window width
    @AppStorage("folderPreviewHeight") var folderPreviewHeight: Double = 600  // Folder preview window height
    @AppStorage("folderPreviewX") var folderPreviewX: Double = -1  // Folder preview window X position (-1 = center)
    @AppStorage("folderPreviewY") var folderPreviewY: Double = -1  // Folder preview window Y position (-1 = center)

    // Folder Preview View Options
    @AppStorage("folderViewMode") var folderViewMode: String = "list"  // "list" or "grid"
    @AppStorage("folderSortBy") var folderSortBy: String = "name"  // "name", "date", "size", or "kind"
    @AppStorage("folderIconSize") var folderIconSize: Double = 32.0  // 24, 32, or 48

    @Published var pinnedApps: [PinnedApp] = [] {
        didSet {
            savePinnedApps()
        }
    }

    @Published var searchDirectories: [SearchDirectory] = [] {
        didSet {
            saveSearchDirectories()
        }
    }

    @Published var ollamaModels: [OllamaModel] = [] {
        didSet {
            saveOllamaModels()
        }
    }

    @Published var importedBookmarks: [BrowserItem] = [] {
        didSet {
            saveImportedBookmarks()
        }
    }

    @Published var recentWebSearches: [String] = [] {
        didSet {
            saveRecentWebSearches()
        }
    }

    @Published var appShortcuts: [AppShortcut] = [] {
        didSet { saveAppShortcuts() }
    }

    private func matchesBuiltInShortcut(_ shortcut: AppShortcut) -> Bool {
        AppShortcut.builtInDefaults.contains { builtIn in
            builtIn.appKey == shortcut.appKey
                && builtIn.name == shortcut.name
                && builtIn.iconName == shortcut.iconName
                && builtIn.actionType == shortcut.actionType
                && builtIn.actionValue == shortcut.actionValue
                && builtIn.placement == shortcut.placement
        }
    }

    private func userOwnedShortcuts(
        for appKey: String,
        placements: Set<AppShortcut.Placement>
    ) -> [AppShortcut] {
        let custom = appShortcuts.filter {
            ($0.appKey == appKey || $0.targetAppKeys.contains(appKey))
                && placements.contains($0.placement)
                && !matchesBuiltInShortcut($0)
        }
        var seen = Set<String>()
        return custom.filter { seen.insert($0.name).inserted }
    }

    /// Returns user-created Quick Actions for a given app key (placement: .quickActions or .both).
    func shortcuts(for appKey: String) -> [AppShortcut] {
        userOwnedShortcuts(for: appKey, placements: [.quickActions, .both])
    }

    /// Returns Context Dock shortcuts for a given app key (placement: .contextDock or .both).
    func contextDockShortcuts(for appKey: String) -> [AppShortcut] {
        userOwnedShortcuts(for: appKey, placements: [.contextDock, .both])
    }

    /// User-owned script/file extensions that can be surfaced as one-tap pills.
    func pillScriptExtensions(for appKey: String, query: String, maxCount: Int = 6)
        -> [AppToolExtension]
    {
        let available = toolExtensions(for: appKey).filter {
            $0.kind == .script && AppSettings.isToolInstalled($0)
        }
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return Array(available.prefix(maxCount))
        }

        let q = query.lowercased()
        let scored = available.map { ext -> (AppToolExtension, Double) in
            var score = 0.0
            if ext.toolName.lowercased().contains(q) { score += 30 }
            if ext.aiHint.lowercased().contains(q) { score += 18 }
            for capability in ext.profile.capabilities
            where q.contains(capability.lowercased()) || capability.lowercased().contains(q) {
                score += 14
            }
            for example in ext.profile.exampleCommands
            where q.contains(example.lowercased()) || example.lowercased().contains(q) {
                score += 10
            }
            return (ext, score)
        }
        let filtered =
            scored
            .filter { $0.1 > 0 }
            .sorted { lhs, rhs in
                if lhs.1 != rhs.1 { return lhs.1 > rhs.1 }
                return lhs.0.toolName.localizedCaseInsensitiveCompare(rhs.0.toolName)
                    == .orderedAscending
            }
            .map(\.0)

        return Array((filtered.isEmpty ? available : filtered).prefix(maxCount))
    }

    /// Returns File Action shortcuts that match the given file extension (placement: .fileActions).
    /// Pass an empty string to get all file-action shortcuts.
    func fileActionShortcuts(forExtension ext: String = "") -> [AppShortcut] {
        appShortcuts.filter {
            guard $0.placement == .fileActions else { return false }
            if $0.fileTypes.isEmpty { return true }  // handles all files
            let extLower = ext.lowercased()
            return $0.fileTypes.contains { $0.lowercased() == extLower }
        }
    }

    func addShortcut(_ shortcut: AppShortcut) {
        appShortcuts.append(shortcut)
    }

    func removeShortcut(_ shortcut: AppShortcut) {
        appShortcuts.removeAll { $0.id == shortcut.id }
    }

    func updateShortcut(_ shortcut: AppShortcut) {
        if let idx = appShortcuts.firstIndex(where: { $0.id == shortcut.id }) {
            appShortcuts[idx] = shortcut
        } else {
            appShortcuts.append(shortcut)
        }
    }

    // MARK: - Custom App Entries
    @Published var customAppEntries: [CustomAppEntry] = [] {
        didSet { saveCustomAppEntries() }
    }

    func addCustomApp(_ entry: CustomAppEntry) { customAppEntries.append(entry) }
    func removeCustomApp(_ entry: CustomAppEntry) {
        customAppEntries.removeAll { $0.id == entry.id }
    }
    func updateCustomApp(_ entry: CustomAppEntry) {
        if let idx = customAppEntries.firstIndex(where: { $0.id == entry.id }) {
            customAppEntries[idx] = entry
        }
    }

    private func loadCustomAppEntries() {
        guard !customAppEntriesData.isEmpty else { return }
        if let decoded = try? JSONDecoder().decode(
            [CustomAppEntry].self, from: customAppEntriesData)
        {
            customAppEntries = decoded
        }
    }
    private func saveCustomAppEntries() {
        if let encoded = try? JSONEncoder().encode(customAppEntries) {
            customAppEntriesData = encoded
        }
    }

    // MARK: - AX Trigger Rules

    @Published var axTriggerRules: [AXTriggerRule] = [] {
        didSet { saveAXTriggerRules() }
    }

    func addAXRule(_ rule: AXTriggerRule) {
        if axTriggerRules.isEmpty { axTriggerRules = AXTriggerRule.builtInExamples }
        axTriggerRules.append(rule)
    }
    func removeAXRule(_ rule: AXTriggerRule) { axTriggerRules.removeAll { $0.id == rule.id } }
    func updateAXRule(_ rule: AXTriggerRule) {
        if let idx = axTriggerRules.firstIndex(where: { $0.id == rule.id }) {
            axTriggerRules[idx] = rule
        }
    }

    func loadAXTriggerRules() {
        // Prefer file-based store — it's the canonical source post-migration
        let fileRules = ContextDockStore.shared.loadAllRules()
        if !fileRules.isEmpty {
            axTriggerRules = fileRules
            return
        }

        // Fall back to legacy @AppStorage blob
        if axTriggerRulesData.isEmpty {
            axTriggerRules = AXTriggerRule.builtInExamples
            // Seed the file store so future loads use it
            ContextDockStore.shared.saveRules(axTriggerRules, bundleId: nil)
            return
        }
        if let decoded = try? JSONDecoder().decode([AXTriggerRule].self, from: axTriggerRulesData) {
            axTriggerRules = decoded
            // Migrate legacy flat array into scoped file layout (runs once)
            ContextDockStore.shared.migrateIfNeeded(legacyRules: decoded)
        }
    }

    private func saveAXTriggerRules() {
        // Dual-write: @AppStorage for backward compat + file store as primary
        if let encoded = try? JSONEncoder().encode(axTriggerRules) { axTriggerRulesData = encoded }

        // Partition rules by scope and write each to its correct directory
        let globalRules = axTriggerRules.filter { $0.isGlobal }
        ContextDockStore.shared.saveRules(globalRules, bundleId: nil)

        let appGroups = Dictionary(grouping: axTriggerRules.filter { !$0.isGlobal }) {
            $0.bundleId!
        }
        for (bundleId, rules) in appGroups {
            ContextDockStore.shared.saveRules(rules, bundleId: bundleId)
        }
    }

    // MARK: - App Tool Extensions
    @Published var appToolExtensions: [AppToolExtension] = [] {
        didSet { saveAppToolExtensions() }
    }

    func toolExtensions(for appKey: String) -> [AppToolExtension] {
        appToolExtensions.filter { $0.appKey == appKey }
    }

    // MARK: Script file management

    /// Saves script source to ~/Library/Application Support/ILauncher/Scripts/{appKey}/
    /// Returns the saved file path, or nil on failure.
    @discardableResult
    func saveScript(appKey: String, name: String, language: AppScriptLanguage, code: String)
        -> String?
    {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("ILauncher/Scripts/\(appKey)", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let file = base.appendingPathComponent("\(name).\(language.fileExtension)")
        guard (try? code.write(to: file, atomically: true, encoding: .utf8)) != nil else {
            return nil
        }
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        return file.path
    }

    func deleteScript(at path: String) {
        try? FileManager.default.removeItem(atPath: path)
    }

    func addToolExtension(_ ext: AppToolExtension) {
        var ext = ext
        appToolExtensions.append(ext)

        // Only CLI tools need help scanning and subcommand detection.
        guard ext.kind == .cli else { return }
        // Adding a tool to an app does not silently grant its AI agent access.
        // The first message in that app's chat presents the one-time choice.
        AppCLIAgentConsentStore.shared.markPending(for: ext)
        Task {
            await TerminalPackageManager.shared.refreshHelpTextByCommand(ext.toolName)

            // After scan, subcommands are populated — try to auto-detect entry command for this app.
            let label = customAppEntries.first(where: { $0.key == ext.appKey })?.label ?? ext.appKey
            if ext.appSubcommand.isEmpty {
                let detected = TerminalPackageManager.shared
                    .autoDetectSubcommand(
                        toolName: ext.toolName, appKey: ext.appKey, appLabel: label)
                if !detected.isEmpty,
                    let idx = appToolExtensions.firstIndex(where: { $0.id == ext.id })
                {
                    appToolExtensions[idx].appSubcommand = detected
                }
            }
            // If no subcommand matches, try flag-based context detection (e.g. ekctl --reminders).
            if ext.appContextFlag.isEmpty {
                let flag = TerminalPackageManager.shared
                    .autoDetectContextFlag(
                        toolName: ext.toolName, appKey: ext.appKey, appLabel: label)
                if !flag.isEmpty, let idx = appToolExtensions.firstIndex(where: { $0.id == ext.id })
                {
                    appToolExtensions[idx].appContextFlag = flag
                }
            }
        }
    }
    func removeToolExtension(_ ext: AppToolExtension) {
        appToolExtensions.removeAll { $0.id == ext.id }
        // If no other app still uses this CLI binary, notify so UI can suggest cleanup
        if ext.kind == .cli {
            let stillUsed = appToolExtensions.contains { $0.toolName == ext.toolName }
            if !stillUsed {
                NotificationCenter.default.post(
                    name: .appPanelToolRemoved,
                    object: nil,
                    userInfo: ["toolName": ext.toolName, "appKey": ext.appKey]
                )
            }
        }
    }
    func updateToolExtension(_ ext: AppToolExtension) {
        if let idx = appToolExtensions.firstIndex(where: { $0.id == ext.id }) {
            appToolExtensions[idx] = ext
        }
    }

    private func loadAppToolExtensions() {
        guard !appToolExtensionsData.isEmpty else { return }
        if let decoded = try? JSONDecoder().decode(
            [AppToolExtension].self, from: appToolExtensionsData)
        {
            appToolExtensions = decoded
        }
    }
    private func saveAppToolExtensions() {
        if let encoded = try? JSONEncoder().encode(appToolExtensions) {
            appToolExtensionsData = encoded
        }
    }

    // MARK: - TUI Folder Access permissions (per tool command name)
    @Published var tuiFolderAccess: Set<String> = [] {
        didSet { saveTuiFolderAccess() }
    }

    func isFolderAccessEnabled(for command: String) -> Bool { tuiFolderAccess.contains(command) }
    func setFolderAccess(for command: String, enabled: Bool) {
        if enabled { tuiFolderAccess.insert(command) } else { tuiFolderAccess.remove(command) }
    }

    private func loadTuiFolderAccess() {
        guard !tuiFolderAccessData.isEmpty else { return }
        if let decoded = try? JSONDecoder().decode(Set<String>.self, from: tuiFolderAccessData) {
            tuiFolderAccess = decoded
        }
    }
    private func saveTuiFolderAccess() {
        if let encoded = try? JSONEncoder().encode(tuiFolderAccess) {
            tuiFolderAccessData = encoded
        }
    }

    // MARK: - Pinned CLI Tools (non-TUI tools user has added as AI panels)
    @Published var pinnedCLITools: Set<String> = [] {
        didSet { savePinnedCLITools() }
    }

    func isCLIToolPinned(_ command: String) -> Bool { pinnedCLITools.contains(command) }
    func pinCLITool(_ command: String) { pinnedCLITools.insert(command) }
    func unpinCLITool(_ command: String) { pinnedCLITools.remove(command) }

    private func loadPinnedCLITools() {
        if !pinnedCLIToolsData.isEmpty,
            let decoded = try? JSONDecoder().decode(Set<String>.self, from: pinnedCLIToolsData) {
            pinnedCLITools = decoded
        }
        seedDefaultCLIToolsIfNeeded()
    }

    /// Seed Homebrew as a default CLI tool scope on first run (only when it's
    /// actually installed), so users can search / install apps and work with brew
    /// via the AI-assisted CLI scope out of the box. One-shot — never re-adds after
    /// the user removes it.
    private func seedDefaultCLIToolsIfNeeded() {
        guard !pinnedCLIToolsSeeded else { return }
        pinnedCLIToolsSeeded = true
        let brewPaths = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]
        if brewPaths.contains(where: { FileManager.default.fileExists(atPath: $0) }) {
            pinnedCLITools.insert("brew")
        }
    }
    private func savePinnedCLITools() {
        if let encoded = try? JSONEncoder().encode(pinnedCLITools) { pinnedCLIToolsData = encoded }
    }

    // MARK: - Auto Context Detection

    /// Automatically resolved app key from the last NSWorkspace app-activation event.
    /// Set by ContentView.startObservingAppSwitches(); never persisted (resets on relaunch).
    @Published var autoDetectedAppKey: String? = nil

    /// Maps a running app's bundle ID + name to an appKey string used in shortcuts / tool extensions.
    func appKey(forBundleID bundleID: String, appName: String) -> String? {
        let nameLower = appName.lowercased()
        let bundleLower = bundleID.lowercased()

        // 1. Check user-added custom entries first (label match or key substring)
        if let entry = customAppEntries.first(where: {
            $0.label.lowercased() == nameLower || nameLower.contains($0.key)
                || bundleLower.contains($0.key)
        }) {
            return entry.key
        }

        // 2. Built-in system apps
        let builtIns: [(sub: String, key: String)] = [
            ("com.apple.finder", "finder"),
            ("com.apple.reminders", "reminders"),
            ("com.apple.ical", "calendar"),
            ("com.apple.notes", "notes"),
            ("com.apple.mail", "mail"),
            ("com.apple.Photos", "photos"),
            ("com.apple.MobileSMS", "messages"),
            ("com.apple.AddressBook", "contacts"),
            ("com.apple.systempreferences", "systemsettings"),
            ("com.spotify", "spotify"),
            ("com.apple.Safari", "safari"),
            ("com.microsoft.VSCode", "vscode"),
            ("com.apple.dt.Xcode", "xcode"),
            ("com.github.GitHubDesktop", "github"),
            ("com.google.Chrome", "safari"),  // Chrome → safari key (same URL tools)
            ("tv.twitch", "youtube"),  // Twitch app also uses video panel
        ]
        for entry in builtIns {
            if bundleLower.contains(entry.sub.lowercased()) || nameLower == entry.key {
                return entry.key
            }
        }

        // 3. Check if any tool extensions are registered for a matching key
        let possibleKey = nameLower.replacingOccurrences(of: " ", with: "_")
        if appToolExtensions.contains(where: { $0.appKey == possibleKey }) { return possibleKey }
        return nil
    }

    // MARK: - Tool Installation Verification

    /// Returns true if the CLI binary is reachable on disk (exact path or common bin dirs).
    static func isToolInstalled(_ ext: AppToolExtension) -> Bool {
        let fm = FileManager.default
        // Prompt extensions need no binary — always available
        if ext.kind == .prompt { return true }
        // Scripts: just check the file exists (they're not unix-executable binaries)
        if ext.kind == .script {
            return !ext.toolPath.isEmpty && fm.fileExists(atPath: ext.toolPath)
        }
        // 1. Explicit path set by user — check it directly
        if !ext.toolPath.isEmpty && fm.isExecutableFile(atPath: ext.toolPath) { return true }
        // 2. Search every directory in the user's real PATH (same source as BinaryWatcherService)
        let name = ext.toolName
        let searchPaths = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":").map(String.init)
        if searchPaths.contains(where: { fm.isExecutableFile(atPath: "\($0)/\(name)") }) {
            return true
        }
        // 3. Fallback to well-known dirs (handles tools installed before PATH was sourced)
        let home = NSHomeDirectory()
        let fallback = [
            "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin",
            "\(home)/.cargo/bin", "\(home)/.local/bin", "\(home)/.bun/bin",
            "\(home)/.deno/bin", "\(home)/go/bin", "\(home)/.volta/bin",
        ]
        return fallback.contains { fm.isExecutableFile(atPath: "\($0)/\(name)") }
    }

    /// Returns only the tool extensions for an appKey that are actually installed on disk.
    /// Used when building AI prompts — prevents hallucinations about missing tools.
    /// CLI + script extensions only (excludes .prompt — those are fetched separately).
    func installedToolExtensions(for appKey: String) -> [AppToolExtension] {
        toolExtensions(for: appKey).filter {
            $0.kind != .prompt
                && AppSettings.isToolInstalled($0)
                && AppCLIAgentConsentStore.shared.isAllowed($0)
        }
    }

    /// Returns all AI Prompt extensions for an app — they're always active (no install check needed).
    func activePromptExtensions(for appKey: String) -> [AppToolExtension] {
        toolExtensions(for: appKey).filter { $0.kind == .prompt }
    }

    // MARK: - Intent-Aware Tool Scoring

    /// Score a single extension's relevance to a query string (higher = more relevant).
    func scoreExtension(_ ext: AppToolExtension, for query: String) -> Double {
        guard !query.isEmpty else { return 1.0 }
        let q = query.lowercased()
        var score: Double = 0

        // Capabilities match
        for cap in ext.profile.capabilities {
            let tokens = cap.lowercased().split(separator: " ").map(String.init).filter {
                $0.count > 3
            }
            score += Double(tokens.filter { q.contains($0) }.count) * 10
        }
        // Example commands match
        for ex in ext.profile.exampleCommands {
            let tokens = ex.lowercased().split(separator: " ").map(String.init).filter {
                $0.count > 2
            }
            score += Double(tokens.filter { q.contains($0) }.count) * 8
        }
        // File types match
        for ft in ext.profile.fileTypes { if q.contains(ft) { score += 15 } }
        // Tool name mentioned directly
        if q.contains(ext.toolName.lowercased()) { score += 20 }
        // Legacy aiHint keyword match
        if !ext.aiHint.isEmpty {
            let tokens = ext.aiHint.lowercased().split(separator: " ").map(String.init).filter {
                $0.count > 4
            }
            score += Double(tokens.filter { q.contains($0) }.count) * 5
        }
        return score
    }

    /// Returns the top N installed extensions most relevant to the query.
    /// Falls back to all installed extensions when no query signal exists.
    func topExtensions(for appKey: String, query: String, maxCount: Int = 5) -> [AppToolExtension] {
        let all = installedToolExtensions(for: appKey)
        guard !query.isEmpty else { return Array(all.prefix(maxCount)) }
        let scored = all.map { (ext: $0, score: scoreExtension($0, for: query)) }
        let filtered = scored.filter { $0.score > 0 }.sorted { $0.score > $1.score }
        return (filtered.isEmpty ? all : filtered.map { $0.ext }).prefix(maxCount).map { $0 }
    }

    // MARK: - Template Export / Import

    func exportTemplate(for appKey: String) throws -> Data {
        let template = AppProfileTemplate.from(appKey: appKey, settings: self)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(template)
    }

    func importTemplate(_ data: Data) throws {
        let template = try JSONDecoder().decode(AppProfileTemplate.self, from: data)
        // Upsert app entry
        if !customAppEntries.contains(where: { $0.key == template.appKey }) {
            addCustomApp(
                CustomAppEntry(
                    key: template.appKey, label: template.label,
                    iconName: template.iconName, appPath: template.appPath))
        }
        // Upsert shortcuts (skip by name)
        let existingNames = Set(shortcuts(for: template.appKey).map { $0.name })
        for action in template.quickActions where !existingNames.contains(action.name) {
            addShortcut(action)
        }
        // Upsert tool extensions (skip by toolName)
        let existingTools = Set(toolExtensions(for: template.appKey).map { $0.toolName })
        for tool in template.tools where !existingTools.contains(tool.toolName) {
            addToolExtension(tool)
        }
    }

    // Bridge to SystemDataSearchManager permission center
    let permissionCenter = ILAppPermissionCenter.shared

    var selectedAIProvider: AIProvider {
        get { AIProvider(rawValue: _selectedAIProvider) ?? .onDevice }
        set {
            objectWillChange.send()
            _selectedAIProvider = newValue.rawValue
        }
    }

    var hotkeyKeyCode: UInt32 {
        get { UInt32(_hotkeyKeyCode) }
        set {
            objectWillChange.send()
            _hotkeyKeyCode = Int(newValue)
        }
    }

    var hotkeyModifiers: UInt32 {
        get { UInt32(_hotkeyModifiers) }
        set {
            objectWillChange.send()
            _hotkeyModifiers = Int(newValue)
        }
    }

    var contextDockHotkeyKeyCode: UInt32 {
        get { UInt32(_contextDockHotkeyKeyCode) }
        set {
            objectWillChange.send()
            _contextDockHotkeyKeyCode = Int(newValue)
        }
    }
    var contextDockHotkeyModifiers: UInt32 {
        get { UInt32(_contextDockHotkeyModifiers) }
        set {
            objectWillChange.send()
            _contextDockHotkeyModifiers = Int(newValue)
        }
    }
    var contextDockHotkeyEnabled: Bool { _contextDockHotkeyKeyCode != 0 }

    var clipboardScopeHotkeyKeyCode: UInt32 {
        get { UInt32(_clipboardScopeHotkeyKeyCode) }
        set {
            objectWillChange.send()
            _clipboardScopeHotkeyKeyCode = Int(newValue)
        }
    }
    var clipboardScopeHotkeyModifiers: UInt32 {
        get { UInt32(_clipboardScopeHotkeyModifiers) }
        set {
            objectWillChange.send()
            _clipboardScopeHotkeyModifiers = Int(newValue)
        }
    }
    var clipboardScopeHotkeyEnabled: Bool { _clipboardScopeHotkeyKeyCode != 0 }

    var quickNoteHotkeyKeyCode: UInt32 {
        get { UInt32(_quickNoteHotkeyKeyCode) }
        set {
            objectWillChange.send()
            _quickNoteHotkeyKeyCode = Int(newValue)
        }
    }
    var quickNoteHotkeyModifiers: UInt32 {
        get { UInt32(_quickNoteHotkeyModifiers) }
        set {
            objectWillChange.send()
            _quickNoteHotkeyModifiers = Int(newValue)
        }
    }
    var quickNoteHotkeyEnabled: Bool { _quickNoteHotkeyKeyCode != 0 }
    var quickNoteHotkeyDisplayString: String {
        hotkeyDisplayString(keyCode: quickNoteHotkeyKeyCode, modifiers: quickNoteHotkeyModifiers)
    }

    var captureTextHotkeyKeyCode: UInt32 {
        get { UInt32(_captureTextHotkeyKeyCode) }
        set { objectWillChange.send(); _captureTextHotkeyKeyCode = Int(newValue) }
    }
    var captureTextHotkeyModifiers: UInt32 {
        get { UInt32(_captureTextHotkeyModifiers) }
        set { objectWillChange.send(); _captureTextHotkeyModifiers = Int(newValue) }
    }
    var captureAreaHotkeyKeyCode: UInt32 {
        get { UInt32(_captureAreaHotkeyKeyCode) }
        set { objectWillChange.send(); _captureAreaHotkeyKeyCode = Int(newValue) }
    }
    var captureAreaHotkeyModifiers: UInt32 {
        get { UInt32(_captureAreaHotkeyModifiers) }
        set { objectWillChange.send(); _captureAreaHotkeyModifiers = Int(newValue) }
    }
    var captureScreenshotHotkeyKeyCode: UInt32 {
        get { UInt32(_captureScreenshotHotkeyKeyCode) }
        set { objectWillChange.send(); _captureScreenshotHotkeyKeyCode = Int(newValue) }
    }
    var captureScreenshotHotkeyModifiers: UInt32 {
        get { UInt32(_captureScreenshotHotkeyModifiers) }
        set { objectWillChange.send(); _captureScreenshotHotkeyModifiers = Int(newValue) }
    }
    /// Dedicated Selection Scope shortcut. When set, the normal launcher open no longer
    /// auto-enters Selection Scope (that hijacked plain app launches); the selection is
    /// only frozen into a scope when this shortcut fires.
    var selectionScopeHotkeyKeyCode: UInt32 {
        get { UInt32(_selectionScopeHotkeyKeyCode) }
        set { objectWillChange.send(); _selectionScopeHotkeyKeyCode = Int(newValue) }
    }
    var selectionScopeHotkeyModifiers: UInt32 {
        get { UInt32(_selectionScopeHotkeyModifiers) }
        set { objectWillChange.send(); _selectionScopeHotkeyModifiers = Int(newValue) }
    }
    var selectionScopeHotkeyEnabled: Bool { _selectionScopeHotkeyKeyCode != 0 }

    init() {
        migrateAIKeysToKeychain()
        loadPinnedApps()
        loadSearchDirectories()
        loadOllamaModels()
        loadExtensionScripts()
        loadImportedBookmarks()
        loadRecentWebSearches()
        loadAppShortcuts()
        loadCustomAppEntries()
        loadAppToolExtensions()
        loadTuiFolderAccess()
        loadPinnedCLITools()
        loadAXTriggerRules()

        // Auto-discover bundled extensions on first launch
        discoverBundledExtensions()

        // Sync persisted toggles into the permission center
        permissionCenter.allowCalendars = allowCalendars
        permissionCenter.allowReminders = allowReminders
        permissionCenter.allowPhotos = allowPhotos
        permissionCenter.allowContacts = allowContacts
        permissionCenter.allowAutomation = allowAutomation

        // Observe changes from UI and persist them
        _ = permissionCenter.objectWillChange.sink { [weak self] in
            guard let self = self else { return }
            self.allowCalendars = self.permissionCenter.allowCalendars
            self.allowReminders = self.permissionCenter.allowReminders
            self.allowPhotos = self.permissionCenter.allowPhotos
            self.allowContacts = self.permissionCenter.allowContacts
            self.allowAutomation = self.permissionCenter.allowAutomation
        }
    }

    // MARK: - Chat History Methods

    func hasChatHistory() -> Bool {
        return !aiChatHistoryData.isEmpty
    }

    func saveChatHistory<T: Codable>(_ messages: [T]) {
        do {
            let encoder = JSONEncoder()
            aiChatHistoryData = try encoder.encode(messages)
        } catch {
            #if DEBUG
                print("⚠️ Failed to encode chat history: \(error)")
            #endif
        }
    }

    func loadChatHistory<T: Codable>() -> [T] {
        guard !aiChatHistoryData.isEmpty else { return [] }

        do {
            let decoder = JSONDecoder()
            return try decoder.decode([T].self, from: aiChatHistoryData)
        } catch {
            #if DEBUG
                print("⚠️ Failed to decode chat history: \(error)")
            #endif
            return []
        }
    }

    func clearChatHistory() {
        aiChatHistoryData = Data()
        #if DEBUG
            print("✅ Chat history cleared")
        #endif
    }

    private func loadPinnedApps() {
        guard !pinnedAppsData.isEmpty else { return }

        do {
            let decoder = JSONDecoder()
            pinnedApps = try decoder.decode([PinnedApp].self, from: pinnedAppsData)
        } catch {
            #if DEBUG
                print("⚠️ Failed to decode pinned apps: \(error)")
            #endif
            pinnedApps = []
        }
    }

    private func savePinnedApps() {
        do {
            let encoder = JSONEncoder()
            pinnedAppsData = try encoder.encode(pinnedApps)
        } catch {
            #if DEBUG
                print("⚠️ Failed to encode pinned apps: \(error)")
            #endif
        }
    }

    private func loadSearchDirectories() {
        guard !searchDirectoriesData.isEmpty else { return }

        do {
            let decoder = JSONDecoder()
            searchDirectories = try decoder.decode(
                [SearchDirectory].self, from: searchDirectoriesData)
        } catch {
            #if DEBUG
                print("⚠️ Failed to decode search directories: \(error)")
            #endif
            searchDirectories = []
        }
    }

    private func saveSearchDirectories() {
        do {
            let encoder = JSONEncoder()
            searchDirectoriesData = try encoder.encode(searchDirectories)
        } catch {
            #if DEBUG
                print("⚠️ Failed to encode search directories: \(error)")
            #endif
        }
    }

    private func loadOllamaModels() {
        guard !ollamaModelsData.isEmpty else { return }

        do {
            let decoder = JSONDecoder()
            ollamaModels = try decoder.decode([OllamaModel].self, from: ollamaModelsData)
        } catch {
            #if DEBUG
                print("⚠️ Failed to decode Ollama models: \(error)")
            #endif
            ollamaModels = []
        }
    }

    private func saveOllamaModels() {
        do {
            let encoder = JSONEncoder()
            ollamaModelsData = try encoder.encode(ollamaModels)
        } catch {
            #if DEBUG
                print("⚠️ Failed to encode Ollama models: \(error)")
            #endif
        }
    }

    private func loadExtensionScripts() {
        guard !extensionScriptsData.isEmpty else { return }

        do {
            let decoder = JSONDecoder()
            extensionScripts = try decoder.decode(
                [ExtensionScript].self, from: extensionScriptsData)
        } catch {
            #if DEBUG
                print("⚠️ Failed to decode extension scripts: \(error)")
            #endif
        }
    }

    private func saveExtensionScripts() {
        do {
            let encoder = JSONEncoder()
            extensionScriptsData = try encoder.encode(extensionScripts)
        } catch {
            #if DEBUG
                print("⚠️ Failed to encode extension scripts: \(error)")
            #endif
        }
    }

    private func loadImportedBookmarks() {
        guard !importedBookmarksData.isEmpty else { return }

        do {
            let decoder = JSONDecoder()
            importedBookmarks = try decoder.decode([BrowserItem].self, from: importedBookmarksData)
        } catch {
            #if DEBUG
                print("⚠️ Failed to decode imported bookmarks: \(error)")
            #endif
        }
    }

    private func saveImportedBookmarks() {
        do {
            let encoder = JSONEncoder()
            importedBookmarksData = try encoder.encode(importedBookmarks)
        } catch {
            #if DEBUG
                print("⚠️ Failed to encode imported bookmarks: \(error)")
            #endif
        }
    }

    private func loadRecentWebSearches() {
        guard !recentWebSearchesData.isEmpty else { return }

        do {
            let decoder = JSONDecoder()
            recentWebSearches = try decoder.decode([String].self, from: recentWebSearchesData)
        } catch {
            #if DEBUG
                print("⚠️ Failed to decode recent web searches: \(error)")
            #endif
        }
    }

    private func saveRecentWebSearches() {
        do {
            let encoder = JSONEncoder()
            recentWebSearchesData = try encoder.encode(recentWebSearches)
        } catch {
            #if DEBUG
                print("⚠️ Failed to encode recent web searches: \(error)")
            #endif
        }
    }

    private func loadAppShortcuts() {
        guard !appShortcutsData.isEmpty else { return }
        do {
            appShortcuts = try JSONDecoder().decode([AppShortcut].self, from: appShortcutsData)
        } catch {
            #if DEBUG
                print("⚠️ Failed to decode app shortcuts: \(error)")
            #endif
        }
    }

    private func saveAppShortcuts() {
        do {
            appShortcutsData = try JSONEncoder().encode(appShortcuts)
        } catch {
            #if DEBUG
                print("⚠️ Failed to encode app shortcuts: \(error)")
            #endif
        }
    }

    /// Auto-discover bundled extensions on first launch
    private func discoverBundledExtensions() {
        let fm = FileManager.default

        // Try multiple possible locations for the project
        let possibleRoots = [
            "/Users/gokulakannan/Desktop/ILauncher",  // Explicit project path
            FileManager.default.currentDirectoryPath,
            (FileManager.default.currentDirectoryPath as NSString).deletingLastPathComponent,
        ]

        for projectRoot in possibleRoots {
            // Check StatusExtensions folder
            let statusExtensionsPath = (projectRoot as NSString).appendingPathComponent(
                "StatusExtensions")

            if fm.fileExists(atPath: statusExtensionsPath),
                let contents = try? fm.contentsOfDirectory(atPath: statusExtensionsPath)
            {
                NSLog("📦 ILauncher: Found StatusExtensions folder with \(contents.count) files")
                for fileName in contents
                where fileName.hasSuffix(".sh") || fileName.hasSuffix(".bash") {
                    let fullPath = (statusExtensionsPath as NSString).appendingPathComponent(
                        fileName)
                    // Check if already added
                    if !extensionScripts.contains(where: { $0.path == fullPath }) {
                        NSLog("✅ ILauncher: Auto-discovered status extension: \(fileName)")
                        let fileURL = URL(fileURLWithPath: fullPath)
                        addExtensionScript(url: fileURL)
                    }
                }
            }

            // Check ExtensionLibrary folder
            let extensionLibraryPath = (projectRoot as NSString).appendingPathComponent(
                "ExtensionLibrary")

            if fm.fileExists(atPath: extensionLibraryPath),
                let contents = try? fm.contentsOfDirectory(atPath: extensionLibraryPath)
            {
                NSLog("📦 ILauncher: Found ExtensionLibrary folder with \(contents.count) files")
                for fileName in contents
                where fileName.hasSuffix(".sh") || fileName.hasSuffix(".bash")
                    || fileName.hasSuffix(".lua") || fileName.hasSuffix(".py")
                {
                    let fullPath = (extensionLibraryPath as NSString).appendingPathComponent(
                        fileName)
                    // Check if already added
                    if !extensionScripts.contains(where: { $0.path == fullPath }) {
                        NSLog("✅ ILauncher: Auto-discovered library extension: \(fileName)")
                        let fileURL = URL(fileURLWithPath: fullPath)
                        addExtensionScript(url: fileURL)
                    }
                }
            }

            // If we found extensions, no need to check other paths
            if !extensionScripts.isEmpty {
                NSLog("📦 ILauncher: Total extensions after discovery: \(extensionScripts.count)")
                break
            }
        }
    }

    // MARK: - Extension Script Helpers

    func addExtensionScript(url: URL) {
        let fileExtension = url.pathExtension.lowercased()
        let fileName = url.lastPathComponent.lowercased()
        let scriptType: ExtensionScript.ScriptType?

        switch fileExtension {
        case "spoon": scriptType = .spoon
        case "lua": scriptType = .lua
        case "sh": scriptType = .shell
        case "bash": scriptType = .bash
        case "scpt", "applescript": scriptType = .applescript
        case "jxa": scriptType = .jxa
        case "py": scriptType = .python
        default:
            // Check for extensionless bash scripts
            if fileName == "bash" || url.path.contains("/bin/bash") {
                scriptType = .bash
            } else {
                scriptType = nil
            }
        }

        guard let type = scriptType else {
            #if DEBUG
                print("⚠️ Unsupported file type: \(fileExtension)")
            #endif
            return
        }

        let name = url.deletingPathExtension().lastPathComponent
        let script = ExtensionScript(name: name, path: url.path, type: type)

        if !extensionScripts.contains(where: { $0.path == script.path }) {
            extensionScripts.append(script)
            #if DEBUG
                print("✅ Added extension script: \(name) (\(type.displayName))")
            #endif
        }
    }

    func removeExtensionScript(_ script: ExtensionScript) {
        extensionScripts.removeAll { $0.id == script.id }
    }

    func toggleExtensionScript(_ script: ExtensionScript) {
        if let index = extensionScripts.firstIndex(where: { $0.id == script.id }) {
            extensionScripts[index].isEnabled.toggle()
        }
    }

    // MARK: - AI Provider Helpers

    func getAPIKey(for provider: AIProvider) -> String {
        switch provider {
        case .openAI: return openAIAPIKey
        case .googleGemini: return googleGeminiAPIKey
        case .anthropic: return anthropicAPIKey
        case .openAICompatible: return openAICompatibleAPIKey
        default: return ""
        }
    }

    func setAPIKey(_ key: String, for provider: AIProvider) {
        switch provider {
        case .openAI: openAIAPIKey = key
        case .googleGemini: googleGeminiAPIKey = key
        case .anthropic: anthropicAPIKey = key
        case .openAICompatible: openAICompatibleAPIKey = key
        default: break
        }
    }

    func isProviderConfigured(_ provider: AIProvider) -> Bool {
        switch provider {
        case .onDevice:
            return true  // Always available
        case .openAI:
            return !openAIAPIKey.isEmpty
        case .googleGemini:
            return !googleGeminiAPIKey.isEmpty
        case .anthropic:
            return !anthropicAPIKey.isEmpty
        case .ollama:
            return !ollamaEndpoint.isEmpty && !selectedOllamaModel.isEmpty
        case .openAICompatible:
            return !openAICompatibleEndpoint.isEmpty && !openAICompatibleModelID.isEmpty
        case .claudeBridge:
            return !claudeBridgeEndpoint.isEmpty && !claudeBridgeModelID.isEmpty
        case .chatGPTBridge:
            return !chatGPTBridgeEndpoint.isEmpty && !chatGPTBridgeModelID.isEmpty
        case .shortcuts:
            return !shortcutsProviderShortcut.isEmpty
        }
    }

    private func migrateAIKeysToKeychain() {
        isLoadingAPIKeys = true
        defer { isLoadingAPIKeys = false }
        openAIAPIKey = migrateAIKey(
            provider: .openAI,
            legacyValue: legacyOpenAIAPIKey
        )
        googleGeminiAPIKey = migrateAIKey(
            provider: .googleGemini,
            legacyValue: legacyGoogleGeminiAPIKey
        )
        anthropicAPIKey = migrateAIKey(
            provider: .anthropic,
            legacyValue: legacyAnthropicAPIKey
        )
        openAICompatibleAPIKey = migrateAIKey(
            provider: .openAICompatible,
            legacyValue: legacyOpenAICompatibleAPIKey
        )

        legacyOpenAIAPIKey = ""
        legacyGoogleGeminiAPIKey = ""
        legacyAnthropicAPIKey = ""
        legacyOpenAICompatibleAPIKey = ""
    }

    private func migrateAIKey(provider: AIProvider, legacyValue: String) -> String {
        let stored = KeychainStore.shared.string(for: provider.rawValue)
        if !stored.isEmpty { return stored }
        if !legacyValue.isEmpty {
            KeychainStore.shared.set(legacyValue, for: provider.rawValue)
        }
        return legacyValue
    }

    // Fetch available models from Ollama
    func fetchOllamaModels() async -> [OllamaModel] {
        guard !ollamaEndpoint.isEmpty else { return [] }

        let endpoint = ollamaEndpoint.trimmingCharacters(in: .whitespaces)
        guard let url = URL(string: "\(endpoint)/api/tags") else { return [] }

        do {
            let (data, _) = try await URLSession.shared.data(from: url)

            struct OllamaTagsResponse: Codable {
                struct Model: Codable {
                    let name: String
                }
                let models: [Model]
            }

            let response = try JSONDecoder().decode(OllamaTagsResponse.self, from: data)
            return response.models.map { OllamaModel(name: $0.name) }
        } catch {
            #if DEBUG
                print("⚠️ Failed to fetch Ollama models: \(error)")
            #endif
            return []
        }
    }

    func addSearchDirectory(path: String, displayName: String) {
        // Check if already exists
        guard !searchDirectories.contains(where: { $0.path == path }) else { return }

        let directory = SearchDirectory(path: path, displayName: displayName)
        searchDirectories.append(directory)
        triggerSearchIndexRefresh()
    }

    /// Restart the live Spotlight query so newly added/removed directories take effect
    /// immediately — the running NSMetadataQuery otherwise keeps its launch-time scope.
    private func triggerSearchIndexRefresh() {
        Task { @MainActor in
            await FileIndexManager.shared.forceReindex()
        }
    }

    /// Add a search directory with security-scoped bookmark for persistent access
    func addSearchDirectory(url: URL, displayName: String) {
        // Check if already exists
        guard !searchDirectories.contains(where: { $0.path == url.path }) else { return }

        // Create security-scoped bookmark for persistent access
        var bookmarkData: Data? = nil
        do {
            bookmarkData = try url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            #if DEBUG
                print("✅ Created security-scoped bookmark for: \(url.path)")
            #endif
        } catch {
            #if DEBUG
                print("⚠️ Failed to create bookmark for \(url.path): \(error)")
            #endif
        }

        let directory = SearchDirectory(
            path: url.path, displayName: displayName, bookmarkData: bookmarkData)
        searchDirectories.append(directory)
        triggerSearchIndexRefresh()
    }

    /// Resolve and start accessing all saved search directories
    func startAccessingSearchDirectories() {
        for directory in searchDirectories {
            startAccessingDirectory(directory)
        }
    }

    /// Stop accessing all search directories
    func stopAccessingSearchDirectories() {
        for directory in searchDirectories {
            if directory.bookmarkData != nil {
                let url = URL(fileURLWithPath: directory.path)
                url.stopAccessingSecurityScopedResource()
            }
        }
    }

    /// Start accessing a specific directory using its bookmark
    @discardableResult
    func startAccessingDirectory(_ directory: SearchDirectory) -> Bool {
        guard let bookmarkData = directory.bookmarkData else {
            // No bookmark, try direct access (will prompt user if needed)
            return FileManager.default.isReadableFile(atPath: directory.path)
        }

        var isStale = false
        do {
            let url = try URL(
                resolvingBookmarkData: bookmarkData,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )

            if isStale {
                #if DEBUG
                    print("⚠️ Bookmark is stale for: \(directory.path)")
                #endif
                // Update the bookmark
                updateBookmarkForDirectory(directory)
            }

            if url.startAccessingSecurityScopedResource() {
                #if DEBUG
                    print("✅ Started accessing: \(url.path)")
                #endif
                return true
            } else {
                #if DEBUG
                    print("⚠️ Failed to start accessing: \(url.path)")
                #endif
                return false
            }
        } catch {
            #if DEBUG
                print("⚠️ Failed to resolve bookmark for \(directory.path): \(error)")
            #endif
            return false
        }
    }

    /// Update bookmark for a directory (when stale)
    private func updateBookmarkForDirectory(_ directory: SearchDirectory) {
        let url = URL(fileURLWithPath: directory.path)

        guard FileManager.default.fileExists(atPath: directory.path) else { return }

        do {
            let newBookmarkData = try url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )

            // Find and update the directory in the array
            if let index = searchDirectories.firstIndex(where: { $0.id == directory.id }) {
                var updatedDirectory = searchDirectories[index]
                updatedDirectory = SearchDirectory(
                    path: updatedDirectory.path,
                    displayName: updatedDirectory.displayName,
                    bookmarkData: newBookmarkData
                )
                // Note: This will trigger didSet and save
                searchDirectories[index] = updatedDirectory
                #if DEBUG
                    print("✅ Updated bookmark for: \(directory.path)")
                #endif
            }
        } catch {
            #if DEBUG
                print("⚠️ Failed to update bookmark for \(directory.path): \(error)")
            #endif
        }
    }

    func removeSearchDirectory(_ directory: SearchDirectory) {
        searchDirectories.removeAll { $0.id == directory.id }
        triggerSearchIndexRefresh()
    }

    func pinApp(name: String, path: String, bundleIdentifier: String? = nil) {
        // Check if already pinned
        guard !pinnedApps.contains(where: { $0.path == path }) else { return }

        let pinnedApp = PinnedApp(
            name: name, path: path, bundleIdentifier: bundleIdentifier, type: .application)
        pinnedApps.append(pinnedApp)
    }

    func pinItem(
        name: String, path: String, bundleIdentifier: String? = nil, type: PinnedApp.PinnedItemType
    ) {
        // Check if already pinned
        guard !pinnedApps.contains(where: { $0.path == path }) else { return }

        let pinnedItem = PinnedApp(
            name: name, path: path, bundleIdentifier: bundleIdentifier, type: type)
        pinnedApps.append(pinnedItem)
    }

    func pinApp(_ app: PinnedApp) {
        // Check if already pinned
        guard !pinnedApps.contains(where: { $0.path == app.path }) else {
            #if DEBUG
                print("⚠️ App already pinned: \(app.name)")
            #endif
            return
        }

        pinnedApps.append(app)
        #if DEBUG
            print("📌 Pinned: \(app.name) (\(app.type))")
        #endif
    }

    func unpinApp(_ app: PinnedApp) {
        pinnedApps.removeAll { $0.id == app.id }
    }

    func reorderPinnedApp(from sourceIndex: Int, to destinationIndex: Int) {
        guard sourceIndex != destinationIndex,
            sourceIndex >= 0, sourceIndex < pinnedApps.count,
            destinationIndex >= 0, destinationIndex <= pinnedApps.count
        else {
            return
        }

        let app = pinnedApps.remove(at: sourceIndex)
        let adjustedDestination =
            destinationIndex > sourceIndex ? destinationIndex - 1 : destinationIndex
        pinnedApps.insert(app, at: adjustedDestination)

        #if DEBUG
            print(
                "🔄 Reordered pinned app: \(app.name) from \(sourceIndex) to \(adjustedDestination)")
        #endif
    }

    func isPinned(path: String) -> Bool {
        return pinnedApps.contains(where: { $0.path == path })
    }

    func hotkeyDisplayString(keyCode: UInt32, modifiers: UInt32) -> String {
        guard keyCode != 0 else { return "Not Set" }
        var result = ""
        if modifiers & UInt32(cmdKey) != 0 { result += "⌘" }
        if modifiers & UInt32(optionKey) != 0 { result += "⌥" }
        if modifiers & UInt32(controlKey) != 0 { result += "⌃" }
        if modifiers & UInt32(shiftKey) != 0 { result += "⇧" }
        result += keyCodeToString(keyCode)
        return result
    }
    var contextDockHotkeyDisplayString: String {
        hotkeyDisplayString(
            keyCode: contextDockHotkeyKeyCode, modifiers: contextDockHotkeyModifiers)
    }
    var clipboardScopeHotkeyDisplayString: String {
        hotkeyDisplayString(
            keyCode: clipboardScopeHotkeyKeyCode, modifiers: clipboardScopeHotkeyModifiers)
    }
    var captureTextHotkeyDisplayString: String {
        hotkeyDisplayString(keyCode: captureTextHotkeyKeyCode, modifiers: captureTextHotkeyModifiers)
    }
    var captureAreaHotkeyDisplayString: String {
        hotkeyDisplayString(keyCode: captureAreaHotkeyKeyCode, modifiers: captureAreaHotkeyModifiers)
    }
    var captureScreenshotHotkeyDisplayString: String {
        hotkeyDisplayString(
            keyCode: captureScreenshotHotkeyKeyCode,
            modifiers: captureScreenshotHotkeyModifiers)
    }
    var selectionScopeHotkeyDisplayString: String {
        hotkeyDisplayString(
            keyCode: selectionScopeHotkeyKeyCode, modifiers: selectionScopeHotkeyModifiers)
    }

    // Computed property to get hotkey display string
    var hotkeyDisplayString: String {
        var result = ""

        // Add modifiers
        if hotkeyModifiers & UInt32(cmdKey) != 0 {
            result += "⌘"
        }
        if hotkeyModifiers & UInt32(optionKey) != 0 {
            result += "⌥"
        }
        if hotkeyModifiers & UInt32(controlKey) != 0 {
            result += "⌃"
        }
        if hotkeyModifiers & UInt32(shiftKey) != 0 {
            result += "⇧"
        }

        // Add key
        result += keyCodeToString(hotkeyKeyCode)

        return result
    }

    private func keyCodeToString(_ keyCode: UInt32) -> String {
        switch keyCode {
        case 49: return "Space"
        case 0: return "A"
        case 11: return "B"
        case 8: return "C"
        case 2: return "D"
        case 14: return "E"
        case 3: return "F"
        case 5: return "G"
        case 4: return "H"
        case 34: return "I"
        case 38: return "J"
        case 40: return "K"
        case 37: return "L"
        case 46: return "M"
        case 45: return "N"
        case 31: return "O"
        case 35: return "P"
        case 12: return "Q"
        case 15: return "R"
        case 1: return "S"
        case 17: return "T"
        case 32: return "U"
        case 9: return "V"
        case 13: return "W"
        case 7: return "X"
        case 16: return "Y"
        case 6: return "Z"
        case 18: return "1"
        case 19: return "2"
        case 20: return "3"
        case 21: return "4"
        case 23: return "5"
        case 22: return "6"
        case 26: return "7"
        case 28: return "8"
        case 25: return "9"
        case 29: return "0"
        case 36: return "⏎"
        case 53: return "⎋"
        case 51: return "⌫"
        case 48: return "⇥"
        // Punctuation and the rest of the ANSI/ISO layout. Without these a bound key
        // rendered as a bare "?" in Settings and the user could not tell what they had
        // pressed (Capture Text on ⌃` showed as "^?").
        case 10: return "§"
        case 24: return "="
        case 27: return "-"
        case 30: return "]"
        case 33: return "["
        case 39: return "'"
        case 41: return ";"
        case 42: return "\\"
        case 43: return ","
        case 44: return "/"
        case 47: return "."
        case 50: return "`"
        case 65: return "."
        case 67: return "*"
        case 69: return "+"
        case 75: return "/"
        case 78: return "−"
        case 81: return "="
        case 82...92: return "Numpad"
        case 96: return "F5"
        case 97: return "F6"
        case 98: return "F7"
        case 99: return "F3"
        case 100: return "F8"
        case 101: return "F9"
        case 103: return "F11"
        case 105: return "F13"
        case 107: return "F14"
        case 109: return "F10"
        case 111: return "F12"
        case 113: return "F15"
        case 114: return "Help"
        case 115: return "Home"
        case 116: return "⇞"
        case 117: return "⌦"
        case 118: return "F4"
        case 119: return "End"
        case 120: return "F2"
        case 121: return "⇟"
        case 122: return "F1"
        case 123: return "←"
        case 124: return "→"
        case 125: return "↓"
        case 126: return "↑"
        default: return "?"
        }
    }

    // MARK: - Bookmark Import Methods

    /// Import bookmarks from Safari
    func importSafariBookmarks() -> Int {
        let bookmarksPath = NSHomeDirectory() + "/Library/Safari/Bookmarks.plist"
        guard FileManager.default.fileExists(atPath: bookmarksPath) else {
            #if DEBUG
                print("⚠️ Safari bookmarks file not found")
            #endif
            return 0
        }

        guard let plistData = FileManager.default.contents(atPath: bookmarksPath),
            let plist = try? PropertyListSerialization.propertyList(from: plistData, format: nil)
                as? [String: Any],
            let children = plist["Children"] as? [[String: Any]]
        else {
            #if DEBUG
                print("⚠️ Failed to parse Safari bookmarks")
            #endif
            return 0
        }

        var count = 0
        for child in children {
            count += parseSafariBookmarkFolder(child)
        }

        #if DEBUG
            print("✅ Imported \(count) bookmarks from Safari")
        #endif
        return count
    }

    private func parseSafariBookmarkFolder(_ folder: [String: Any]) -> Int {
        var count = 0

        if let urlString = folder["URLString"] as? String,
            let title = folder["URIDictionary"] as? [String: Any],
            let bookmarkTitle = title["title"] as? String
        {
            // This is a bookmark
            let bookmark = BrowserItem(
                title: bookmarkTitle.isEmpty ? urlString : bookmarkTitle,
                url: urlString,
                favicon: nil,
                type: .bookmark
            )
            if !importedBookmarks.contains(where: { $0.url == bookmark.url }) {
                importedBookmarks.append(bookmark)
                count += 1
            }
        }

        // Recursively parse children
        if let children = folder["Children"] as? [[String: Any]] {
            for child in children {
                count += parseSafariBookmarkFolder(child)
            }
        }

        return count
    }

    /// Import bookmarks from Chrome
    func importChromeBookmarks() -> Int {
        let bookmarksPath =
            NSHomeDirectory() + "/Library/Application Support/Google/Chrome/Default/Bookmarks"
        guard FileManager.default.fileExists(atPath: bookmarksPath) else {
            #if DEBUG
                print("⚠️ Chrome bookmarks file not found")
            #endif
            return 0
        }

        guard let bookmarksData = try? Data(contentsOf: URL(fileURLWithPath: bookmarksPath)),
            let json = try? JSONSerialization.jsonObject(with: bookmarksData) as? [String: Any],
            let roots = json["roots"] as? [String: Any]
        else {
            #if DEBUG
                print("⚠️ Failed to parse Chrome bookmarks")
            #endif
            return 0
        }

        var count = 0
        for (_, root) in roots {
            if let rootDict = root as? [String: Any] {
                count += parseChromeBookmarkFolder(rootDict)
            }
        }

        #if DEBUG
            print("✅ Imported \(count) bookmarks from Chrome")
        #endif
        return count
    }

    private func parseChromeBookmarkFolder(_ folder: [String: Any]) -> Int {
        var count = 0

        if let type = folder["type"] as? String, type == "url",
            let urlString = folder["url"] as? String,
            let name = folder["name"] as? String
        {
            // This is a bookmark
            let bookmark = BrowserItem(
                title: name,
                url: urlString,
                favicon: nil,
                type: .bookmark
            )
            if !importedBookmarks.contains(where: { $0.url == bookmark.url }) {
                importedBookmarks.append(bookmark)
                count += 1
            }
        }

        // Recursively parse children
        if let children = folder["children"] as? [[String: Any]] {
            for child in children {
                count += parseChromeBookmarkFolder(child)
            }
        }

        return count
    }

    /// Import bookmarks from Firefox
    func importFirefoxBookmarks() -> Int {
        let profilesPath = NSHomeDirectory() + "/Library/Application Support/Firefox/Profiles"
        guard FileManager.default.fileExists(atPath: profilesPath),
            let profiles = try? FileManager.default.contentsOfDirectory(atPath: profilesPath)
        else {
            #if DEBUG
                print("⚠️ Firefox profiles folder not found")
            #endif
            return 0
        }

        var totalCount = 0
        for profile in profiles {
            let placesPath = (profilesPath as NSString).appendingPathComponent(profile).appending(
                "/places.sqlite")
            if FileManager.default.fileExists(atPath: placesPath) {
                // Note: Parsing SQLite would require additional dependencies
                // For now, we'll just note that Firefox uses SQLite
                #if DEBUG
                    print("ℹ️ Firefox bookmarks found at: \(placesPath)")
                #endif
                #if DEBUG
                    print("ℹ️ Firefox bookmark import requires SQLite parsing (not yet implemented)")
                #endif
            }
        }

        return totalCount
    }

    /// Import bookmarks from Edge
    func importEdgeBookmarks() -> Int {
        let bookmarksPath =
            NSHomeDirectory() + "/Library/Application Support/Microsoft Edge/Default/Bookmarks"
        guard FileManager.default.fileExists(atPath: bookmarksPath) else {
            #if DEBUG
                print("⚠️ Edge bookmarks file not found")
            #endif
            return 0
        }

        guard let bookmarksData = try? Data(contentsOf: URL(fileURLWithPath: bookmarksPath)),
            let json = try? JSONSerialization.jsonObject(with: bookmarksData) as? [String: Any],
            let roots = json["roots"] as? [String: Any]
        else {
            #if DEBUG
                print("⚠️ Failed to parse Edge bookmarks")
            #endif
            return 0
        }

        var count = 0
        for (_, root) in roots {
            if let rootDict = root as? [String: Any] {
                count += parseChromeBookmarkFolder(rootDict)  // Edge uses same format as Chrome
            }
        }

        #if DEBUG
            print("✅ Imported \(count) bookmarks from Edge")
        #endif
        return count
    }

    /// Clear all imported bookmarks
    func clearImportedBookmarks() {
        importedBookmarks.removeAll()
        #if DEBUG
            print("✅ Cleared all imported bookmarks")
        #endif
    }

    /// Add a recent web search
    func addRecentWebSearch(_ query: String) {
        guard !query.isEmpty else { return }
        // Defer mutation to next run loop to avoid publishing during a view update
        DispatchQueue.main.async {
            self.recentWebSearches.removeAll { $0 == query }
            self.recentWebSearches.insert(query, at: 0)
            if self.recentWebSearches.count > 20 {
                self.recentWebSearches = Array(self.recentWebSearches.prefix(20))
            }
        }
    }

    /// Clear recent web searches
    func clearRecentWebSearches() {
        recentWebSearches.removeAll()
        #if DEBUG
            print("✅ Cleared recent web searches")
        #endif
    }
}
