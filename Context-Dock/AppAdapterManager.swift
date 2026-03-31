//
//  AppAdapterManager.swift
//  Context-Dock
//
//  Per-app action adapters: menu-bar clicks, AppleScript, JXA, shell commands,
//  URL schemes, macOS Shortcuts, and AI prompt templates.
//
//  Built-in adapters ship with ILauncher for Safari, Finder, Mail, Xcode,
//  VS Code, Notes, Calendar, and Messages.
//
//  Users can add custom adapters by placing JSON files in:
//    ~/Library/Application Support/ILauncher/AppAdapters/
//

import Foundation
import AppKit
import Combine

// MARK: - AdapterActionType

enum AdapterActionType: String, Codable, CaseIterable {
    case menubar      = "menubar"       // Click a macOS menu item via AX API
    case applescript  = "applescript"   // Run AppleScript source
    case jxa          = "jxa"           // Run JXA (JavaScript for Automation)
    case shell        = "shell"         // Run a bash command
    case urlScheme    = "urlScheme"     // Open a URL / deep-link
    case shortcut     = "shortcut"      // Run a macOS Shortcut by name
    case aiPrompt     = "aiPrompt"      // Pre-fill the AI chat with a context-aware prompt

    var displayName: String {
        switch self {
        case .menubar:     return "Menu Bar"
        case .applescript: return "AppleScript"
        case .jxa:         return "JXA"
        case .shell:       return "Shell"
        case .urlScheme:   return "URL Scheme"
        case .shortcut:    return "Shortcut"
        case .aiPrompt:    return "AI Prompt"
        }
    }
}

// MARK: - AdapterAction

struct AdapterAction: Identifiable, Codable, Hashable {
    var id: String
    var name: String
    var icon: String                // SF Symbol name
    var description: String
    var triggers: [String]          // Keywords that surface this action when typing
    var type: AdapterActionType
    // Payload — only the relevant field is set for each type
    var menuPath: [String]?         // .menubar: ["File", "New Tab"]
    var script: String?             // .applescript / .jxa / .shell — inline source
    var scriptFile: String?         // External script file path (relative to AppAdapters dir, or absolute)
    var urlScheme: String?          // .urlScheme — supports $CURRENT_URL etc.
    var shortcutName: String?       // .shortcut
    var aiPromptTemplate: String?   // .aiPrompt — context vars resolved before sending
    // UX
    var requiresApproval: Bool      // Show confirmation dialog before executing
    var isDestructive: Bool         // Show red warning in approval UI
    var accentColor: String?        // SF Symbol accent color name (e.g. "teal", "red")

    // Hashable / Equatable by id
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
    static func == (lhs: AdapterAction, rhs: AdapterAction) -> Bool { lhs.id == rhs.id }

    init(id: String, name: String, icon: String, description: String = "",
         triggers: [String] = [], type: AdapterActionType,
         menuPath: [String]? = nil, script: String? = nil, scriptFile: String? = nil,
         urlScheme: String? = nil, shortcutName: String? = nil,
         aiPromptTemplate: String? = nil,
         requiresApproval: Bool = false, isDestructive: Bool = false,
         accentColor: String? = nil) {
        self.id = id; self.name = name; self.icon = icon
        self.description = description; self.triggers = triggers; self.type = type
        self.menuPath = menuPath; self.script = script; self.scriptFile = scriptFile
        self.urlScheme = urlScheme; self.shortcutName = shortcutName
        self.aiPromptTemplate = aiPromptTemplate
        self.requiresApproval = requiresApproval; self.isDestructive = isDestructive
        self.accentColor = accentColor
    }
}

// MARK: - AdapterContextReader

struct AdapterContextReader: Codable {
    var id: String
    var name: String
    var type: String    // "applescript" | "jxa" | "shell"
    var script: String
}

// MARK: - AppAdapter

struct AppAdapter: Identifiable, Codable {
    var id: String              // Usually the bundle ID
    var appName: String
    var bundleId: String
    var icon: String            // SF Symbol for the app
    var isEnabled: Bool
    var isBuiltIn: Bool
    var actions: [AdapterAction]
    var contextReaders: [AdapterContextReader]
    /// Non-codable: set at load time — path to the JSON file on disk (user adapters only)
    var sourceFileURL: URL?

    init(id: String, appName: String, bundleId: String, icon: String,
         isEnabled: Bool = true, isBuiltIn: Bool = true,
         actions: [AdapterAction], contextReaders: [AdapterContextReader] = []) {
        self.id = id; self.appName = appName; self.bundleId = bundleId
        self.icon = icon; self.isEnabled = isEnabled; self.isBuiltIn = isBuiltIn
        self.actions = actions; self.contextReaders = contextReaders
    }

    enum CodingKeys: String, CodingKey {
        case id, appName, bundleId, icon, isEnabled, isBuiltIn, actions, contextReaders
    }
}

// MARK: - Approval request

struct AdapterActionRequest: Identifiable {
    let id = UUID()
    let action: AdapterAction
    let adapter: AppAdapter
    var onApprove: () -> Void
    var onDeny: () -> Void
}

// MARK: - AppAdapterManager

@MainActor
final class AppAdapterManager: ObservableObject {
    static let shared = AppAdapterManager()

    @Published var adapters: [AppAdapter] = []
    @Published var pendingApproval: AdapterActionRequest? = nil
    @Published var loadErrors: [(file: String, message: String)] = []

    /// Last execution result shown as a toast / response in the dock
    @Published var lastResult: (success: Bool, output: String)? = nil

    let adaptersDirectory: URL = {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return support.appendingPathComponent("ILauncher/AppAdapters", isDirectory: true)
    }()

    private init() {
        adapters = Self.builtInAdapters
        Task { await loadUserAdapters() }
    }

    // MARK: - Query helpers

    /// Return the enabled adapter for the given bundle ID, or nil.
    func adapter(for bundleId: String) -> AppAdapter? {
        adapters.first { $0.bundleId == bundleId && $0.isEnabled }
    }

    /// Return actions for a bundle ID, optionally filtered by a search query.
    func actions(for bundleId: String, query: String = "") -> [AdapterAction] {
        guard let adapter = adapter(for: bundleId) else { return [] }
        guard !query.isEmpty else { return adapter.actions }
        let q = query.lowercased()
        return adapter.actions.filter { action in
            action.name.lowercased().contains(q) ||
            action.description.lowercased().contains(q) ||
            action.triggers.contains { $0.lowercased().contains(q) }
        }
    }

    // MARK: - Execution

    /// Execute an adapter action, showing an approval sheet if needed.
    /// For `.aiPrompt` actions this returns the resolved prompt string as output
    /// so ContentView can inject it into the search field.
    func execute(_ action: AdapterAction, context: AXContext, targetBundleId: String? = nil) async -> (Bool, String) {
        if action.requiresApproval {
            guard let adp = adapters.first(where: { $0.actions.contains(where: { $0.id == action.id }) }) else {
                return (false, "Adapter not found")
            }
            return await withCheckedContinuation { continuation in
                pendingApproval = AdapterActionRequest(
                    action: action,
                    adapter: adp,
                    onApprove: { [weak self] in
                        Task { @MainActor [weak self] in
                            self?.pendingApproval = nil
                            let result = await self?.runAction(action, context: context, targetBundleId: targetBundleId) ?? (false, "")
                            self?.lastResult = result
                            continuation.resume(returning: result)
                        }
                    },
                    onDeny: { [weak self] in
                        self?.pendingApproval = nil
                        continuation.resume(returning: (false, "Cancelled"))
                    }
                )
            }
        }
        let result = await runAction(action, context: context, targetBundleId: targetBundleId)
        lastResult = result
        return result
    }

    // MARK: - Toggle

    func setEnabled(_ enabled: Bool, for bundleId: String) {
        guard let idx = adapters.firstIndex(where: { $0.bundleId == bundleId }) else { return }
        adapters[idx].isEnabled = enabled
    }

    // MARK: - User adapters from disk

    func loadUserAdapters() async {
        try? FileManager.default.createDirectory(at: adaptersDirectory, withIntermediateDirectories: true)
        writeSampleAdaptersIfNeeded()
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: adaptersDirectory,
            includingPropertiesForKeys: nil,
            options: .skipsHiddenFiles
        ) else { return }

        // Support both camelCase and snake_case JSON keys
        let camelDecoder = JSONDecoder()
        let snakeDecoder = JSONDecoder()
        snakeDecoder.keyDecodingStrategy = .convertFromSnakeCase

        var userAdapters: [AppAdapter] = []
        var errors: [(file: String, message: String)] = []

        for url in contents where url.pathExtension == "json" && !url.lastPathComponent.hasPrefix("_") {
            guard let data = try? Data(contentsOf: url) else {
                errors.append((url.lastPathComponent, "Could not read file"))
                continue
            }
            if var a = try? camelDecoder.decode(AppAdapter.self, from: data) {
                a.isBuiltIn = false; a.sourceFileURL = url
                userAdapters.append(a)
            } else if var a = try? snakeDecoder.decode(AppAdapter.self, from: data) {
                a.isBuiltIn = false; a.sourceFileURL = url
                userAdapters.append(a)
            } else {
                // Capture the real decode error for display
                do { _ = try camelDecoder.decode(AppAdapter.self, from: data) } catch {
                    errors.append((url.lastPathComponent, error.localizedDescription))
                }
            }
        }

        // User adapters override built-in ones with the same bundleId,
        // UNLESS the user adapter has no actions — in that case the built-in wins.
        var merged = Self.builtInAdapters
        for user in userAdapters {
            if let idx = merged.firstIndex(where: { $0.bundleId == user.bundleId }) {
                if !user.actions.isEmpty { merged[idx] = user }
                // empty user adapter: keep built-in actions but honour the file's enabled state
                else { merged[idx].isEnabled = user.isEnabled }
            } else {
                merged.append(user)
            }
        }
        adapters = merged
        loadErrors = errors
    }

    /// Create a new blank adapter JSON file for the given app and reload.
    func createAdapter(appName: String, bundleId: String, icon: String) async {
        let safe = appName.replacingOccurrences(of: "/", with: "-")
        let url = adaptersDirectory.appendingPathComponent("\(safe).json")
        let template = """
{
  "id": "\(bundleId)",
  "appName": "\(appName)",
  "bundleId": "\(bundleId)",
  "icon": "\(icon)",
  "isEnabled": true,
  "isBuiltIn": false,
  "contextReaders": [],
  "actions": []
}
"""
        try? template.data(using: .utf8)?.write(to: url)
        await loadUserAdapters()
    }

    /// Append a new action to an adapter (built-in or user), saving as a user JSON override.
    /// Built-in adapters are "forked" — all existing actions are preserved plus the new one.
    func appendAction(_ action: AdapterAction, to bundleId: String) async {
        guard let base = adapters.first(where: { $0.bundleId == bundleId }) else { return }
        let safe = base.appName.replacingOccurrences(of: "/", with: "-")

        // Determine target file: existing user file OR new file
        let fileURL = base.sourceFileURL
            ?? adaptersDirectory.appendingPathComponent("\(safe).json")

        // Build merged action list (deduped by id)
        var merged = base.actions.filter { $0.id != action.id }
        merged.append(action)

        // Encode to JSON
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        var export = base
        export.isBuiltIn = false
        export.actions = merged
        if let data = try? encoder.encode(export),
           var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            json["isBuiltIn"] = false
            if let pretty = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]) {
                try? pretty.write(to: fileURL)
            }
        }
        await loadUserAdapters()
    }

    /// Delete a custom action from an adapter (no-op for pure built-in adapters with no user file).
    func deleteAction(id actionId: String, from bundleId: String) async {
        guard let base = adapters.first(where: { $0.bundleId == bundleId }) else { return }
        let safe = base.appName.replacingOccurrences(of: "/", with: "-")
        let fileURL = base.sourceFileURL
            ?? adaptersDirectory.appendingPathComponent("\(safe).json")

        var filtered = base.actions.filter { $0.id != actionId }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        var export = base
        export.isBuiltIn = false
        export.actions = filtered
        if let data = try? encoder.encode(export),
           var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            json["isBuiltIn"] = false
            if let pretty = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]) {
                try? pretty.write(to: fileURL)
            }
        }
        await loadUserAdapters()
    }

    // MARK: - Private execution

    private func runAction(_ action: AdapterAction, context: AXContext, targetBundleId: String? = nil) async -> (Bool, String) {
        switch action.type {

        case .menubar:
            guard let path = action.menuPath else { return (false, "No menu path defined") }
            let explicitTargetApp = await resolveOrLaunchTargetApp(for: targetBundleId)
            let targetApp = explicitTargetApp ?? AppDelegate.shared?.previousFrontmostApp
            guard let frontApp = targetApp else {
                return (false, "No target app")
            }
            let pid = frontApp.processIdentifier
            // Bring the target app to front so the menu press registers correctly,
            // then click via the AX API on a background thread (it uses Thread.sleep).
            frontApp.activate()
            try? await Task.sleep(nanoseconds: 80_000_000) // 0.08 s — let activation settle
            let success = await Task.detached(priority: .userInitiated) { () -> Bool in
                AXMenuReader.shared.clickMenuItem(path: path, in: pid)
            }.value
            return (success, success ? "Done" : "Menu item '\(path.last ?? "")' not found")

        case .applescript:
            guard let script = action.script else { return (false, "No script defined") }
            let appleScriptFile = action.scriptFile.flatMap { resolveScriptFile($0) }
            return await runAppleScript(inject(script, context: context), scriptFile: appleScriptFile)

        case .jxa:
            guard let script = action.script else { return (false, "No script defined") }
            let jxaFile = action.scriptFile.flatMap { resolveScriptFile($0) }
            return await runJXA(inject(script, context: context), scriptFile: jxaFile, context: context)

        case .shell:
            let shellFile = action.scriptFile.flatMap { resolveScriptFile($0) }
            let inlineScript = action.script.map { inject($0, context: context) } ?? ""
            guard shellFile != nil || !inlineScript.isEmpty else { return (false, "No script defined") }
            return await runShell(inlineScript, scriptFile: shellFile, context: context)

        case .urlScheme:
            guard let scheme = action.urlScheme else { return (false, "No URL scheme defined") }
            let resolved = inject(scheme, context: context)
            if let url = URL(string: resolved) {
                NSWorkspace.shared.open(url)
                return (true, "Opened: \(resolved)")
            }
            return (false, "Invalid URL: \(resolved)")

        case .shortcut:
            guard let name = action.shortcutName else { return (false, "No shortcut name") }
            return await runShell("shortcuts run \"\(name)\"", context: context)

        case .aiPrompt:
            // ContentView handles this type: we return the resolved prompt so it can be injected
            let tmpl = action.aiPromptTemplate ?? action.description
            return (true, inject(tmpl, context: context))
        }
    }

    private func resolvedTargetApp(for bundleId: String?) -> NSRunningApplication? {
        guard let bundleId, !bundleId.isEmpty else { return nil }

        let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId)
            .first { !$0.isTerminated }
        return running
    }

    private func resolveOrLaunchTargetApp(for bundleId: String?) async -> NSRunningApplication? {
        guard let bundleId, !bundleId.isEmpty else { return nil }

        if let running = resolvedTargetApp(for: bundleId) {
            return running
        }

        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) else {
            return nil
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true

        do {
            _ = try await NSWorkspace.shared.openApplication(at: appURL, configuration: configuration)
        } catch {
            return nil
        }

        for _ in 0..<10 {
            if let running = resolvedTargetApp(for: bundleId) {
                return running
            }
            try? await Task.sleep(nanoseconds: 120_000_000)
        }

        return nil
    }

    // MARK: - Script runners

    /// Resolve a scriptFile path: absolute paths pass through; relative paths anchor to AppAdapters dir.
    private func resolveScriptFile(_ path: String) -> URL? {
        guard !path.isEmpty else { return nil }
        if path.hasPrefix("/") { return URL(fileURLWithPath: path) }
        return adaptersDirectory.appendingPathComponent(path)
    }

    private func runAppleScript(_ source: String, scriptFile: URL? = nil) async -> (Bool, String) {
        await Task.detached(priority: .userInitiated) { () -> (Bool, String) in
            if let file = scriptFile {
                let task = Process()
                task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
                task.arguments = [file.path]
                let pipe = Pipe()
                task.standardOutput = pipe
                task.standardError  = pipe
                do {
                    try task.run()
                    task.waitUntilExit()
                    let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    return (task.terminationStatus == 0, out.isEmpty ? "Done" : out)
                } catch {
                    return (false, error.localizedDescription)
                }
            } else {
                var errDict: NSDictionary?
                let result = NSAppleScript(source: source)?.executeAndReturnError(&errDict)
                if let e = errDict {
                    let msg = e[NSAppleScript.errorMessage] as? String ?? "AppleScript error"
                    return (false, msg)
                }
                return (true, result?.stringValue ?? "Done")
            }
        }.value
    }

    private func runJXA(_ script: String, scriptFile: URL? = nil, context: AXContext) async -> (Bool, String) {
        await Task.detached(priority: .userInitiated) { () -> (Bool, String) in
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            // Inject context as env vars so scripts can use $CURRENT_URL etc.
            var env = ProcessInfo.processInfo.environment
            env["FRONTMOST_APP"]    = context.appName
            env["FRONTMOST_BUNDLE"] = context.bundleId
            if let url   = context.currentURL   { env["CURRENT_URL"]      = url }
            if let title = context.windowTitle  { env["WINDOW_TITLE"]     = title }
            if let sel   = context.selectedText { env["AX_SELECTED_TEXT"] = sel }
            task.environment = env
            if let file = scriptFile {
                task.arguments = ["-l", "JavaScript", file.path]
            } else {
                task.arguments = ["-l", "JavaScript", "-e", script]
            }
            let pipe = Pipe()
            task.standardOutput = pipe
            task.standardError  = pipe
            do {
                try task.run()
                task.waitUntilExit()
                let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return (task.terminationStatus == 0, out)
            } catch {
                return (false, error.localizedDescription)
            }
        }.value
    }

    private func runShell(_ script: String, scriptFile: URL? = nil, context: AXContext) async -> (Bool, String) {
        await Task.detached(priority: .userInitiated) { () -> (Bool, String) in
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/bin/bash")
            // Full env injection — same context vars available to shell scripts as to L2 Extensions
            var env = ProcessInfo.processInfo.environment
            env["PATH"] = "/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:" + (env["PATH"] ?? "")
            env["FRONTMOST_APP"]    = context.appName
            env["FRONTMOST_BUNDLE"] = context.bundleId
            if let url   = context.currentURL   { env["CURRENT_URL"]      = url }
            if let title = context.windowTitle  { env["WINDOW_TITLE"]     = title }
            if let sel   = context.selectedText { env["AX_SELECTED_TEXT"] = sel }
            task.environment = env
            task.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
            if let file = scriptFile {
                task.arguments = [file.path]
            } else {
                task.arguments = ["-c", script]
            }
            let pipe = Pipe()
            task.standardOutput = pipe
            task.standardError  = pipe
            do {
                try task.run()
                task.waitUntilExit()
                let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return (task.terminationStatus == 0, out.isEmpty ? "Done" : out)
            } catch {
                return (false, error.localizedDescription)
            }
        }.value
    }

    // MARK: - Context variable injection

    private func inject(_ text: String, context: AXContext) -> String {
        var s = text
        s = s.replacingOccurrences(of: "$CURRENT_URL",      with: context.currentURL   ?? "")
        s = s.replacingOccurrences(of: "$WINDOW_TITLE",     with: context.windowTitle  ?? "")
        s = s.replacingOccurrences(of: "$AX_SELECTED_TEXT", with: context.selectedText ?? "")
        s = s.replacingOccurrences(of: "$APP_NAME",         with: context.appName)
        s = s.replacingOccurrences(of: "$BUNDLE_ID",        with: context.bundleId)
        return s
    }
}

// MARK: - Sample adapter files

extension AppAdapterManager {

    /// Write editable sample JSON files on first launch so users see the format immediately.
    func writeSampleAdaptersIfNeeded() {
        let sentinel = adaptersDirectory.appendingPathComponent(".samples_written")

        // Photos.json is always kept up-to-date — it is our reference example.
        // Overwrite unconditionally so a previously empty or broken file gets fixed.
        let photosURL = adaptersDirectory.appendingPathComponent("Photos.json")
        try? Self.photosAdapterJSON.data(using: .utf8)?.write(to: photosURL)

        guard !FileManager.default.fileExists(atPath: sentinel.path) else { return }

        let samples: [(String, String)] = [
            ("Notion.json",    Self.notionAdapterJSON),
            ("Obsidian.json",  Self.obsidianAdapterJSON),
            ("_TEMPLATE.json", Self.templateAdapterJSON),
        ]
        for (filename, json) in samples {
            let url = adaptersDirectory.appendingPathComponent(filename)
            try? json.data(using: .utf8)?.write(to: url)
        }
        try? "done".data(using: .utf8)?.write(to: sentinel)
    }

    static let notionAdapterJSON = """
{
  "id": "notion.id",
  "appName": "Notion",
  "bundleId": "notion.id",
  "icon": "doc.richtext",
  "isEnabled": true,
  "isBuiltIn": false,
  "actions": [
    {
      "id": "notion.newPage",
      "name": "New Page",
      "icon": "plus.square",
      "description": "Create a new Notion page",
      "triggers": ["new page", "create page", "add page"],
      "type": "urlScheme",
      "urlScheme": "notion://",
      "requiresApproval": false,
      "isDestructive": false,
      "accentColor": "gray"
    },
    {
      "id": "notion.summarize",
      "name": "Summarize Selection",
      "icon": "sparkles",
      "description": "Ask AI to summarize selected text",
      "triggers": ["summarize", "summary", "tldr"],
      "type": "aiPrompt",
      "aiPromptTemplate": "Summarize this in clear bullet points:\\n\\n$AX_SELECTED_TEXT",
      "requiresApproval": false,
      "isDestructive": false,
      "accentColor": "indigo"
    }
  ],
  "contextReaders": []
}
"""

    static let obsidianAdapterJSON = """
{
  "id": "md.obsidian",
  "appName": "Obsidian",
  "bundleId": "md.obsidian",
  "icon": "diamond.fill",
  "isEnabled": true,
  "isBuiltIn": false,
  "actions": [
    {
      "id": "obsidian.newNote",
      "name": "New Note",
      "icon": "square.and.pencil",
      "description": "Create a new note in Obsidian",
      "triggers": ["new note", "create note", "write"],
      "type": "urlScheme",
      "urlScheme": "obsidian://new",
      "requiresApproval": false,
      "isDestructive": false,
      "accentColor": "purple"
    },
    {
      "id": "obsidian.search",
      "name": "Search Vault",
      "icon": "magnifyingglass",
      "description": "Search your Obsidian vault",
      "triggers": ["search", "find note"],
      "type": "urlScheme",
      "urlScheme": "obsidian://search",
      "requiresApproval": false,
      "isDestructive": false,
      "accentColor": "purple"
    },
    {
      "id": "obsidian.captureSelection",
      "name": "Capture to Daily Note",
      "icon": "text.badge.plus",
      "description": "Append selected text to today's Daily Note",
      "triggers": ["capture", "clip", "save selection", "daily note"],
      "type": "shell",
      "script": "TODAY=$(date +%Y-%m-%d) && open \\"obsidian://new?name=$TODAY&content=$AX_SELECTED_TEXT\\"",
      "requiresApproval": false,
      "isDestructive": false,
      "accentColor": "purple"
    }
  ],
  "contextReaders": []
}
"""

    static let templateAdapterJSON = """
{
  "_comment": "Rename this file to YourApp.json and fill in your app details. Place it next to this file.",
  "id": "com.example.MyApp",
  "appName": "My App",
  "bundleId": "com.example.MyApp",
  "icon": "app.gift",
  "isEnabled": true,
  "isBuiltIn": false,
  "actions": [
    {
      "id": "myapp.menuAction",
      "name": "Click Menu Item",
      "icon": "menubar.rectangle",
      "description": "Click File > Export via the macOS menu bar",
      "triggers": ["export", "save as"],
      "type": "menubar",
      "menuPath": ["File", "Export"],
      "requiresApproval": false,
      "isDestructive": false,
      "accentColor": "blue"
    },
    {
      "id": "myapp.applescript",
      "name": "AppleScript Action",
      "icon": "applescript",
      "description": "Run AppleScript in My App",
      "triggers": ["script"],
      "type": "applescript",
      "script": "tell application \\"My App\\" to activate",
      "requiresApproval": true,
      "isDestructive": false,
      "accentColor": "orange"
    },
    {
      "id": "myapp.shell",
      "name": "Shell Command",
      "icon": "terminal",
      "description": "Run a shell command — use $CURRENT_URL, $WINDOW_TITLE, $AX_SELECTED_TEXT",
      "triggers": ["shell", "run"],
      "type": "shell",
      "script": "echo \\"URL: $CURRENT_URL, Title: $WINDOW_TITLE\\"",
      "requiresApproval": false,
      "isDestructive": false,
      "accentColor": "green"
    },
    {
      "id": "myapp.urlScheme",
      "name": "Open URL Scheme",
      "icon": "link",
      "description": "Open a deep link — $CURRENT_URL is available",
      "triggers": ["open", "launch"],
      "type": "urlScheme",
      "urlScheme": "myapp://open?url=$CURRENT_URL",
      "requiresApproval": false,
      "isDestructive": false,
      "accentColor": "teal"
    },
    {
      "id": "myapp.aiPrompt",
      "name": "AI Prompt",
      "icon": "sparkles",
      "description": "Pre-fill AI chat with live context",
      "triggers": ["ask", "ai", "help"],
      "type": "aiPrompt",
      "aiPromptTemplate": "Help me with: $WINDOW_TITLE. Selected text: $AX_SELECTED_TEXT",
      "requiresApproval": false,
      "isDestructive": false,
      "accentColor": "indigo"
    }
  ],
  "contextReaders": []
}
"""

    // MARK: - Photos reference JSON
    // This file is written to ~/Library/Application Support/ILauncher/AppAdapters/Photos.json
    // so users can read it as the definitive real-world example of every action type.

    static let photosAdapterJSON = """
{
  "//": "Photos.json — Built-in adapter for Apple Photos.",
  "//1": "This file is a READ-ONLY reference. To customise, copy it and rename.",
  "//2": "The app is matched by bundleId when it is the frontmost app.",

  "id": "com.apple.Photos",
  "appName": "Photos",
  "bundleId": "com.apple.Photos",
  "icon": "photo.fill",
  "isEnabled": true,
  "isBuiltIn": false,

  "//actions": "Each action becomes a pill in the Context Dock when Photos is frontmost.",
  "actions": [

    {
      "//": "TYPE: menubar — clicks a macOS menu item via the Accessibility API.",
      "//path": "Exact titles from the menu bar, top-level to leaf.",
      "id": "photos.newAlbum",
      "name": "New Album",
      "icon": "rectangle.stack.badge.plus",
      "description": "Create a new album",
      "triggers": ["new album", "create album", "album"],
      "type": "menubar",
      "menuPath": ["File", "New Album"],
      "requiresApproval": false,
      "isDestructive": false,
      "accentColor": "blue"
    },

    {
      "//": "TYPE: menubar — nested submenu (3 levels deep).",
      "id": "photos.export",
      "name": "Export Photos",
      "icon": "square.and.arrow.up",
      "description": "Export selected photos",
      "triggers": ["export", "save photo", "download"],
      "type": "menubar",
      "menuPath": ["File", "Export", "Export Photos…"],
      "requiresApproval": false,
      "isDestructive": false,
      "accentColor": "teal"
    },

    {
      "//": "TYPE: menubar — destructive action. Shows a confirmation sheet before running.",
      "id": "photos.revert",
      "name": "Revert to Original",
      "icon": "arrow.uturn.backward.circle",
      "description": "Remove ALL edits — cannot be undone",
      "triggers": ["revert", "undo all edits", "original", "reset"],
      "type": "menubar",
      "menuPath": ["Image", "Revert to Original"],
      "requiresApproval": true,
      "isDestructive": true,
      "accentColor": "red"
    },

    {
      "//": "TYPE: jxa — JavaScript for Automation. Reads live data from Photos.",
      "//env": "ILauncher also injects: FRONTMOST_APP, FRONTMOST_BUNDLE, CURRENT_URL, WINDOW_TITLE, AX_SELECTED_TEXT",
      "id": "photos.selectedInfo",
      "name": "Photo Info",
      "icon": "info.circle",
      "description": "Show names and dates of currently selected photos",
      "triggers": ["info", "details", "selected", "how many", "count"],
      "type": "jxa",
      "script": "var P=Application('Photos');var s=P.selection();s.length===0?'No photos selected':['Selected: '+s.length+' photo(s)'].concat(s.slice(0,5).map(function(p){return '• '+p.name()+'  —  '+p.date()})).join('\\n')",
      "requiresApproval": false,
      "isDestructive": false,
      "accentColor": "blue"
    },

    {
      "//": "TYPE: shell — bash script. Env vars FRONTMOST_APP, CURRENT_URL etc. are auto-injected.",
      "//scriptFile": "Alternatively use scriptFile to point to a .sh file: 'scripts/my-script.sh'",
      "id": "photos.showLibrary",
      "name": "Show Library in Finder",
      "icon": "folder.badge.questionmark",
      "description": "Reveal the Photos library in Finder",
      "triggers": ["show library", "find library", "finder"],
      "type": "shell",
      "script": "open -R \\"$HOME/Pictures/Photos Library.photoslibrary\\" 2>/dev/null || open \\"$HOME/Pictures/\\"",
      "requiresApproval": false,
      "isDestructive": false,
      "accentColor": "gray"
    },

    {
      "//": "TYPE: applescript — inline AppleScript source.",
      "id": "photos.slideshow",
      "name": "Slideshow",
      "icon": "play.rectangle.fill",
      "description": "Play a full-screen slideshow via AppleScript",
      "triggers": ["slideshow", "play", "present"],
      "type": "applescript",
      "script": "tell application \\"Photos\\" to activate\\ntell application \\"System Events\\" to tell process \\"Photos\\" to keystroke \\"w\\" using {command down, shift down}",
      "requiresApproval": false,
      "isDestructive": false,
      "accentColor": "purple"
    },

    {
      "//": "TYPE: urlScheme — open a URL or deep-link. Supports $CURRENT_URL, $WINDOW_TITLE etc.",
      "id": "photos.openIcloudSettings",
      "name": "iCloud Photo Settings",
      "icon": "icloud.fill",
      "description": "Open System Settings for iCloud Photos",
      "triggers": ["icloud", "sync", "settings"],
      "type": "urlScheme",
      "urlScheme": "x-apple.systempreferences:com.apple.preference.icloud",
      "requiresApproval": false,
      "isDestructive": false,
      "accentColor": "cyan"
    },

    {
      "//": "TYPE: aiPrompt — pre-fills the AI chat with context variables resolved at runtime.",
      "//vars": "$APP_NAME, $BUNDLE_ID, $WINDOW_TITLE, $CURRENT_URL, $AX_SELECTED_TEXT",
      "id": "photos.aiAsk",
      "name": "Ask AI about Photos",
      "icon": "sparkles",
      "description": "Pre-fill the AI chat with context about your current Photos session",
      "triggers": ["ask", "ai", "help", "caption", "describe"],
      "type": "aiPrompt",
      "aiPromptTemplate": "I'm in the Photos app. Window: $WINDOW_TITLE. Help me: ",
      "requiresApproval": false,
      "isDestructive": false,
      "accentColor": "indigo"
    }

  ],
  "contextReaders": []
}
"""
}

// MARK: - Built-in Adapters

extension AppAdapterManager {

    static var builtInAdapters: [AppAdapter] {
        [safariAdapter, finderAdapter, systemSettingsAdapter, mailAdapter, xcodeAdapter,
         vsCodeAdapter, notesAdapter, calendarAdapter, messagesAdapter, photosAdapter]
    }

    // MARK: Safari

    static let safariAdapter = AppAdapter(
        id: "com.apple.Safari",
        appName: "Safari",
        bundleId: "com.apple.Safari",
        icon: "safari",
        actions: [

            // ── File ──────────────────────────────────────────────────────────
            AdapterAction(id: "safari.newTab",
                          name: "New Tab",
                          icon: "plus.square",
                          description: "Open a new tab",
                          triggers: ["new tab", "open tab", "tab"],
                          type: .menubar, menuPath: ["File", "New Tab"],
                          accentColor: "blue"),
            AdapterAction(id: "safari.newWindow",
                          name: "New Window",
                          icon: "macwindow.badge.plus",
                          description: "Open a new browser window",
                          triggers: ["new window", "window"],
                          type: .menubar, menuPath: ["File", "New Personal Window"],
                          accentColor: "blue"),
            AdapterAction(id: "safari.newPrivateWindow",
                          name: "New Private Window",
                          icon: "lock.rectangle",
                          description: "Open a new private browsing window",
                          triggers: ["private", "incognito", "private window"],
                          type: .menubar, menuPath: ["File", "New Private Window"],
                          accentColor: "gray"),
            AdapterAction(id: "safari.newWorkWindow",
                          name: "New Work Window",
                          icon: "briefcase",
                          description: "Open a new Work profile window",
                          triggers: ["work window", "work profile"],
                          type: .menubar, menuPath: ["File", "New Work Window"],
                          accentColor: "blue"),
            AdapterAction(id: "safari.newTabGroup",
                          name: "New Tab Group",
                          icon: "rectangle.stack.badge.plus",
                          description: "Create a new empty tab group",
                          triggers: ["tab group", "new group"],
                          type: .menubar, menuPath: ["File", "New Empty Tab Group"],
                          accentColor: "teal"),
            AdapterAction(id: "safari.tabGroupWithTab",
                          name: "Tab Group with This Tab",
                          icon: "rectangle.stack",
                          description: "Create a new tab group from this tab",
                          triggers: ["group this tab", "tab group this"],
                          type: .menubar, menuPath: ["File", "New Tab Group with This Tab"],
                          accentColor: "teal"),
            AdapterAction(id: "safari.openFile",
                          name: "Open File…",
                          icon: "doc",
                          description: "Open a local file in Safari",
                          triggers: ["open file", "local file"],
                          type: .menubar, menuPath: ["File", "Open File…"],
                          accentColor: "gray"),
            AdapterAction(id: "safari.openLocation",
                          name: "Open Location…",
                          icon: "globe",
                          description: "Type or paste a URL to navigate",
                          triggers: ["open location", "go to url", "address bar", "url"],
                          type: .menubar, menuPath: ["File", "Open Location…"],
                          accentColor: "blue"),
            AdapterAction(id: "safari.closeTab",
                          name: "Close Tab",
                          icon: "xmark.square",
                          description: "Close the current tab",
                          triggers: ["close tab", "close"],
                          type: .menubar, menuPath: ["File", "Close Tab"],
                          accentColor: "red"),
            AdapterAction(id: "safari.closeWindow",
                          name: "Close Window",
                          icon: "xmark.rectangle",
                          description: "Close the current window",
                          triggers: ["close window"],
                          type: .menubar, menuPath: ["File", "Close Window"],
                          accentColor: "red"),
            AdapterAction(id: "safari.closeAllWindows",
                          name: "Close All Windows",
                          icon: "xmark.rectangle.fill",
                          description: "Close all Safari windows",
                          triggers: ["close all windows", "close all"],
                          type: .menubar, menuPath: ["File", "Close All Windows"],
                          requiresApproval: true, accentColor: "red"),
            AdapterAction(id: "safari.saveAs",
                          name: "Save Page As…",
                          icon: "square.and.arrow.down",
                          description: "Save the current page to disk",
                          triggers: ["save", "save as", "download page"],
                          type: .menubar, menuPath: ["File", "Save As…"],
                          accentColor: "green"),
            AdapterAction(id: "safari.share",
                          name: "Share…",
                          icon: "square.and.arrow.up",
                          description: "Share the current page via the Share sheet",
                          triggers: ["share", "send to"],
                          type: .menubar, menuPath: ["File", "Share…"],
                          accentColor: "blue"),
            AdapterAction(id: "safari.exportPDF",
                          name: "Export as PDF…",
                          icon: "doc.richtext",
                          description: "Export the current page as a PDF",
                          triggers: ["pdf", "export pdf", "save pdf"],
                          type: .menubar, menuPath: ["File", "Export as PDF…"],
                          accentColor: "red"),
            AdapterAction(id: "safari.addToDock",
                          name: "Add to Dock…",
                          icon: "dock.arrow.down.rectangle",
                          description: "Add this web app to the Dock",
                          triggers: ["add to dock", "web app"],
                          type: .menubar, menuPath: ["File", "Add to Dock…"],
                          accentColor: "blue"),
            AdapterAction(id: "safari.print",
                          name: "Print…",
                          icon: "printer",
                          description: "Print the current page",
                          triggers: ["print"],
                          type: .menubar, menuPath: ["File", "Print…"],
                          accentColor: "gray"),
            AdapterAction(id: "safari.importBrowsingData",
                          name: "Import Browsing Data…",
                          icon: "square.and.arrow.down.on.square",
                          description: "Import bookmarks and history from another browser",
                          triggers: ["import", "import bookmarks", "import history"],
                          type: .menubar, menuPath: ["File", "Import Browsing Data from File or Folder…"],
                          accentColor: "gray"),
            AdapterAction(id: "safari.exportBrowsingData",
                          name: "Export Browsing Data…",
                          icon: "square.and.arrow.up.on.square",
                          description: "Export bookmarks and history to a file",
                          triggers: ["export bookmarks", "export history", "export data"],
                          type: .menubar, menuPath: ["File", "Export Browsing Data to File…"],
                          accentColor: "gray"),

            // ── Edit ──────────────────────────────────────────────────────────
            AdapterAction(id: "safari.undo",
                          name: "Undo",
                          icon: "arrow.uturn.backward",
                          description: "Undo the last action",
                          triggers: ["undo"],
                          type: .menubar, menuPath: ["Edit", "Undo"],
                          accentColor: "gray"),
            AdapterAction(id: "safari.redo",
                          name: "Redo",
                          icon: "arrow.uturn.forward",
                          description: "Redo the last undone action",
                          triggers: ["redo"],
                          type: .menubar, menuPath: ["Edit", "Redo"],
                          accentColor: "gray"),
            AdapterAction(id: "safari.findOnPage",
                          name: "Find on Page",
                          icon: "doc.text.magnifyingglass",
                          description: "Search for text on this page",
                          triggers: ["find", "search page", "find on page"],
                          type: .menubar, menuPath: ["Edit", "Find", "Find…"],
                          accentColor: "orange"),
            AdapterAction(id: "safari.findNext",
                          name: "Find Next",
                          icon: "chevron.down.circle",
                          description: "Jump to the next search match",
                          triggers: ["find next", "next match"],
                          type: .menubar, menuPath: ["Edit", "Find", "Find Next"],
                          accentColor: "orange"),
            AdapterAction(id: "safari.findPrevious",
                          name: "Find Previous",
                          icon: "chevron.up.circle",
                          description: "Jump to the previous search match",
                          triggers: ["find previous", "prev match"],
                          type: .menubar, menuPath: ["Edit", "Find", "Find Previous"],
                          accentColor: "orange"),
            AdapterAction(id: "safari.selectAll",
                          name: "Select All",
                          icon: "checkmark.rectangle",
                          description: "Select all content on the page",
                          triggers: ["select all"],
                          type: .menubar, menuPath: ["Edit", "Select All"],
                          accentColor: "gray"),
            AdapterAction(id: "safari.spellCheck",
                          name: "Spell Check",
                          icon: "textformat.abc.dottedunderline",
                          description: "Show Spelling and Grammar panel",
                          triggers: ["spell", "grammar", "spelling"],
                          type: .menubar, menuPath: ["Edit", "Spelling and Grammar", "Show Spelling and Grammar"],
                          accentColor: "gray"),
            AdapterAction(id: "safari.emojiSymbols",
                          name: "Emoji & Symbols",
                          icon: "face.smiling",
                          description: "Open the Emoji & Symbols picker",
                          triggers: ["emoji", "symbols", "emoji picker"],
                          type: .menubar, menuPath: ["Edit", "Emoji & Symbols"],
                          accentColor: "yellow"),

            // ── View ─────────────────────────────────────────────────────────
            AdapterAction(id: "safari.reload",
                          name: "Reload Page",
                          icon: "arrow.clockwise",
                          description: "Reload the current page",
                          triggers: ["reload", "refresh"],
                          type: .menubar, menuPath: ["View", "Reload Page"],
                          accentColor: "teal"),
            AdapterAction(id: "safari.stopLoading",
                          name: "Stop Loading",
                          icon: "xmark.circle",
                          description: "Stop loading the current page",
                          triggers: ["stop", "stop loading", "cancel load"],
                          type: .menubar, menuPath: ["View", "Stop"],
                          accentColor: "red"),
            AdapterAction(id: "safari.readerMode",
                          name: "Reader View",
                          icon: "doc.plaintext",
                          description: "Toggle Reader View for this page",
                          triggers: ["reader", "reading mode", "reader view", "distraction free"],
                          type: .menubar, menuPath: ["View", "Show Reader"],
                          accentColor: "indigo"),
            AdapterAction(id: "safari.zoomIn",
                          name: "Zoom In",
                          icon: "plus.magnifyingglass",
                          description: "Zoom in on the page",
                          triggers: ["zoom in", "bigger", "increase size"],
                          type: .menubar, menuPath: ["View", "Make Text Bigger"],
                          accentColor: "gray"),
            AdapterAction(id: "safari.zoomOut",
                          name: "Zoom Out",
                          icon: "minus.magnifyingglass",
                          description: "Zoom out on the page",
                          triggers: ["zoom out", "smaller", "decrease size"],
                          type: .menubar, menuPath: ["View", "Make Text Smaller"],
                          accentColor: "gray"),
            AdapterAction(id: "safari.actualSize",
                          name: "Actual Size",
                          icon: "1.magnifyingglass",
                          description: "Reset page zoom to 100%",
                          triggers: ["actual size", "reset zoom", "100%"],
                          type: .menubar, menuPath: ["View", "Actual Size"],
                          accentColor: "gray"),
            AdapterAction(id: "safari.pageSource",
                          name: "View Page Source",
                          icon: "chevron.left.forwardslash.chevron.right",
                          description: "View the HTML source of this page",
                          triggers: ["source", "page source", "view source", "html"],
                          type: .menubar, menuPath: ["Develop", "Show Page Source"],
                          accentColor: "purple"),
            AdapterAction(id: "safari.showStatusBar",
                          name: "Show Status Bar",
                          icon: "dock.rectangle",
                          description: "Show/hide the status bar",
                          triggers: ["status bar"],
                          type: .menubar, menuPath: ["View", "Show Status Bar"],
                          accentColor: "gray"),
            AdapterAction(id: "safari.showTabBar",
                          name: "Show Tab Bar",
                          icon: "rectangle.topthird.inset.filled",
                          description: "Show/hide the tab bar",
                          triggers: ["tab bar", "show tabs"],
                          type: .menubar, menuPath: ["View", "Show Tab Bar"],
                          accentColor: "gray"),
            AdapterAction(id: "safari.showSidebar",
                          name: "Show Sidebar",
                          icon: "sidebar.left",
                          description: "Toggle the bookmarks/reading-list sidebar",
                          triggers: ["sidebar", "show sidebar"],
                          type: .menubar, menuPath: ["View", "Show Sidebar"],
                          accentColor: "gray"),
            AdapterAction(id: "safari.enterFullscreen",
                          name: "Enter Full Screen",
                          icon: "arrow.up.left.and.arrow.down.right",
                          description: "Toggle full-screen mode",
                          triggers: ["fullscreen", "full screen"],
                          type: .menubar, menuPath: ["View", "Enter Full Screen"],
                          accentColor: "blue"),

            // ── History ───────────────────────────────────────────────────────
            AdapterAction(id: "safari.back",
                          name: "Go Back",
                          icon: "chevron.left",
                          description: "Navigate back one page",
                          triggers: ["back", "go back", "previous page"],
                          type: .menubar, menuPath: ["History", "Back"],
                          accentColor: "gray"),
            AdapterAction(id: "safari.forward",
                          name: "Go Forward",
                          icon: "chevron.right",
                          description: "Navigate forward one page",
                          triggers: ["forward", "go forward", "next page"],
                          type: .menubar, menuPath: ["History", "Forward"],
                          accentColor: "gray"),
            AdapterAction(id: "safari.home",
                          name: "Go Home",
                          icon: "house",
                          description: "Navigate to the homepage",
                          triggers: ["home", "homepage", "go home"],
                          type: .menubar, menuPath: ["History", "Home"],
                          accentColor: "blue"),
            AdapterAction(id: "safari.showHistory",
                          name: "Show History",
                          icon: "clock",
                          description: "Show your full browsing history",
                          triggers: ["history", "show history", "browsing history"],
                          type: .menubar, menuPath: ["History", "Show Personal History"],
                          accentColor: "gray"),
            AdapterAction(id: "safari.recentlyClosed",
                          name: "Recently Closed Tabs",
                          icon: "arrow.counterclockwise.circle",
                          description: "Reopen recently closed tabs",
                          triggers: ["recently closed", "reopen tab", "restore tab", "undo close"],
                          type: .menubar, menuPath: ["History", "Recently Closed"],
                          accentColor: "orange"),
            AdapterAction(id: "safari.reopenLastWindow",
                          name: "Reopen Last Closed Window",
                          icon: "arrow.counterclockwise.square",
                          description: "Reopen the last closed window",
                          triggers: ["reopen window", "restore window"],
                          type: .menubar, menuPath: ["History", "Reopen Last Closed Window"],
                          accentColor: "orange"),
            AdapterAction(id: "safari.reopenAllWindows",
                          name: "Reopen All Windows from Last Session",
                          icon: "arrow.counterclockwise.square.fill",
                          description: "Restore all windows from the previous session",
                          triggers: ["restore session", "last session", "reopen all"],
                          type: .menubar, menuPath: ["History", "Reopen All Windows from Last Session"],
                          accentColor: "orange"),

            // ── Bookmarks ─────────────────────────────────────────────────────
            AdapterAction(id: "safari.bookmark",
                          name: "Add Bookmark",
                          icon: "bookmark.fill",
                          description: "Add this page to bookmarks",
                          triggers: ["bookmark", "save page", "add bookmark"],
                          type: .menubar, menuPath: ["Bookmarks", "Add Bookmark…"],
                          accentColor: "yellow"),
            AdapterAction(id: "safari.readingList",
                          name: "Add to Reading List",
                          icon: "eyeglasses",
                          description: "Save this page to your Reading List",
                          triggers: ["reading list", "read later", "save for later"],
                          type: .menubar, menuPath: ["Bookmarks", "Add to Reading List"],
                          accentColor: "blue"),
            AdapterAction(id: "safari.showBookmarks",
                          name: "Show Bookmarks",
                          icon: "book",
                          description: "Open the Bookmarks sidebar",
                          triggers: ["show bookmarks", "bookmarks list"],
                          type: .menubar, menuPath: ["Bookmarks", "Show Bookmarks"],
                          accentColor: "yellow"),
            AdapterAction(id: "safari.editBookmarks",
                          name: "Edit Bookmarks",
                          icon: "bookmark.slash",
                          description: "Open the Bookmarks editor",
                          triggers: ["edit bookmarks", "manage bookmarks"],
                          type: .menubar, menuPath: ["Bookmarks", "Edit Bookmarks"],
                          accentColor: "yellow"),

            // ── Develop ───────────────────────────────────────────────────────
            AdapterAction(id: "safari.inspector",
                          name: "Web Inspector",
                          icon: "hammer.fill",
                          description: "Open the developer Web Inspector",
                          triggers: ["inspector", "devtools", "developer tools", "debug"],
                          type: .menubar, menuPath: ["Develop", "Show Web Inspector"],
                          accentColor: "purple"),
            AdapterAction(id: "safari.console",
                          name: "JS Console",
                          icon: "terminal",
                          description: "Open the JavaScript console",
                          triggers: ["console", "javascript console", "js"],
                          type: .menubar, menuPath: ["Develop", "Show JavaScript Console"],
                          accentColor: "purple"),
            AdapterAction(id: "safari.networkLog",
                          name: "Network Log",
                          icon: "network",
                          description: "Show the network request log",
                          triggers: ["network", "network log", "requests"],
                          type: .menubar, menuPath: ["Develop", "Show Network Tab"],
                          accentColor: "purple"),
            AdapterAction(id: "safari.disableJS",
                          name: "Disable JavaScript",
                          icon: "j.square.on.square",
                          description: "Toggle JavaScript execution on this page",
                          triggers: ["disable js", "disable javascript", "no javascript"],
                          type: .menubar, menuPath: ["Develop", "Disable JavaScript"],
                          accentColor: "orange"),
            AdapterAction(id: "safari.clearCache",
                          name: "Empty Caches",
                          icon: "trash.circle",
                          description: "Clear all Safari caches",
                          triggers: ["clear cache", "empty cache", "flush cache"],
                          type: .menubar, menuPath: ["Develop", "Empty Caches"],
                          requiresApproval: false, accentColor: "red"),
            AdapterAction(id: "safari.responsiveDesign",
                          name: "Responsive Design Mode",
                          icon: "iphone.and.ipad",
                          description: "Toggle responsive/mobile design mode",
                          triggers: ["responsive", "mobile view", "device mode"],
                          type: .menubar, menuPath: ["Develop", "Enter Responsive Design Mode"],
                          accentColor: "purple"),

            // ── Window ────────────────────────────────────────────────────────
            AdapterAction(id: "safari.minimize",
                          name: "Minimize Window",
                          icon: "minus.square",
                          description: "Minimize the Safari window to the Dock",
                          triggers: ["minimize", "minimise"],
                          type: .menubar, menuPath: ["Window", "Minimize"],
                          accentColor: "gray"),
            AdapterAction(id: "safari.nextTab",
                          name: "Next Tab",
                          icon: "chevron.right.square",
                          description: "Switch to the next tab",
                          triggers: ["next tab", "tab right"],
                          type: .menubar, menuPath: ["Window", "Select Next Tab"],
                          accentColor: "gray"),
            AdapterAction(id: "safari.prevTab",
                          name: "Previous Tab",
                          icon: "chevron.left.square",
                          description: "Switch to the previous tab",
                          triggers: ["previous tab", "prev tab", "tab left"],
                          type: .menubar, menuPath: ["Window", "Select Previous Tab"],
                          accentColor: "gray"),
            AdapterAction(id: "safari.moveTabToWindow",
                          name: "Move Tab to New Window",
                          icon: "rectangle.portrait.and.arrow.right",
                          description: "Move the current tab into its own window",
                          triggers: ["move tab", "detach tab", "pop out tab"],
                          type: .menubar, menuPath: ["Window", "Move Tab to New Window"],
                          accentColor: "gray"),
            AdapterAction(id: "safari.mergeWindows",
                          name: "Merge All Windows",
                          icon: "rectangle.3.group",
                          description: "Merge all Safari windows into one",
                          triggers: ["merge windows", "combine windows"],
                          type: .menubar, menuPath: ["Window", "Merge All Windows"],
                          accentColor: "teal"),

            // ── AppleScript / AI ──────────────────────────────────────────────
            AdapterAction(id: "safari.copyURL",
                          name: "Copy URL",
                          icon: "link",
                          description: "Copy the current page URL to clipboard",
                          triggers: ["copy url", "copy link", "get url"],
                          type: .applescript,
                          script: """
tell application "Safari"
    if (count of windows) = 0 then return ""
    set theURL to URL of current tab of front window
    set the clipboard to theURL
    return theURL
end tell
""",
                          accentColor: "teal"),
            AdapterAction(id: "safari.summarize",
                          name: "Summarize Page",
                          icon: "sparkles",
                          description: "Ask AI to summarize this page",
                          triggers: ["summarize", "tldr", "summary"],
                          type: .aiPrompt,
                          aiPromptTemplate: "Summarize this page for me: $CURRENT_URL",
                          accentColor: "indigo"),
            AdapterAction(id: "safari.askAbout",
                          name: "Ask About Page",
                          icon: "questionmark.bubble",
                          description: "Ask the AI what this page is about",
                          triggers: ["ask", "explain page", "what is this"],
                          type: .aiPrompt,
                          aiPromptTemplate: "What is this page about? URL: $CURRENT_URL\nTitle: $WINDOW_TITLE",
                          accentColor: "indigo"),
        ]
    )

    // MARK: Finder

    static let finderAdapter = AppAdapter(
        id: "com.apple.finder",
        appName: "Finder",
        bundleId: "com.apple.finder",
        icon: "square.grid.2x2",
        actions: [

            // ── File — selection-aware (shown first when files selected) ──────
            AdapterAction(id: "finder.quickLook",
                          name: "Quick Look",
                          icon: "eye",
                          description: "Quick Look preview of selected item",
                          triggers: ["quick look", "preview", "ql"],
                          type: .menubar, menuPath: ["File", "Quick Look"],
                          accentColor: "blue"),
            AdapterAction(id: "finder.getInfo",
                          name: "Get Info",
                          icon: "info.circle",
                          description: "Show info panel for selected item",
                          triggers: ["get info", "info", "details", "properties", "size"],
                          type: .menubar, menuPath: ["File", "Get Info"],
                          accentColor: "gray"),
            AdapterAction(id: "finder.openWith",
                          name: "Open With…",
                          icon: "arrow.up.right.square",
                          description: "Open selected item in a specific app",
                          triggers: ["open with", "open in"],
                          type: .menubar, menuPath: ["File", "Open With"],
                          accentColor: "blue"),
            AdapterAction(id: "finder.moveToTrash",
                          name: "Move to Trash",
                          icon: "trash",
                          description: "Move selected items to the Trash",
                          triggers: ["trash", "delete", "remove"],
                          type: .menubar, menuPath: ["File", "Move to Trash"],
                          requiresApproval: true, isDestructive: true, accentColor: "red"),
            AdapterAction(id: "finder.duplicateFile",
                          name: "Duplicate",
                          icon: "doc.on.doc",
                          description: "Duplicate selected item",
                          triggers: ["duplicate", "copy file"],
                          type: .menubar, menuPath: ["File", "Duplicate"],
                          accentColor: "blue"),
            AdapterAction(id: "finder.rename",
                          name: "Rename…",
                          icon: "pencil",
                          description: "Rename the selected file or folder",
                          triggers: ["rename", "name"],
                          type: .menubar, menuPath: ["File", "Rename"],
                          accentColor: "orange"),
            AdapterAction(id: "finder.compress",
                          name: "Compress",
                          icon: "archivebox",
                          description: "Compress selected files into a zip archive",
                          triggers: ["compress", "zip", "archive"],
                          type: .menubar, menuPath: ["File", "Compress"],
                          accentColor: "yellow"),
            AdapterAction(id: "finder.copyPath",
                          name: "Copy Path",
                          icon: "doc.on.clipboard",
                          description: "Copy the POSIX path of the selected item",
                          triggers: ["copy path", "file path", "posix path"],
                          type: .applescript,
                          script: """
tell application "Finder"
    set sel to selection
    if (count of sel) = 0 then
        set thePath to POSIX path of (target of front window as alias)
    else
        set thePath to POSIX path of (item 1 of sel as alias)
    end if
    set the clipboard to thePath
    return thePath
end tell
""",
                          accentColor: "teal"),
            AdapterAction(id: "finder.makeAlias",
                          name: "Make Alias",
                          icon: "link.badge.plus",
                          description: "Create an alias for the selected item",
                          triggers: ["alias", "make alias", "symlink"],
                          type: .menubar, menuPath: ["File", "Make Alias"],
                          accentColor: "gray"),

            // ── File — window/navigation ──────────────────────────────────────
            AdapterAction(id: "finder.newFolder",
                          name: "New Folder",
                          icon: "folder.badge.plus",
                          description: "Create a new folder in the current location",
                          triggers: ["new folder", "create folder", "mkdir"],
                          type: .menubar, menuPath: ["File", "New Folder"],
                          accentColor: "blue"),
            AdapterAction(id: "finder.newFolderWithSelection",
                          name: "New Folder with Selection",
                          icon: "folder.badge.gear",
                          description: "Create a new folder containing selected items",
                          triggers: ["new folder with selection", "folder from selection"],
                          type: .menubar, menuPath: ["File", "New Folder with Selection"],
                          accentColor: "blue"),
            AdapterAction(id: "finder.newWindow",
                          name: "New Finder Window",
                          icon: "macwindow.badge.plus",
                          description: "Open a new Finder window",
                          triggers: ["new window", "new finder window"],
                          type: .menubar, menuPath: ["File", "New Finder Window"],
                          accentColor: "blue"),
            AdapterAction(id: "finder.newTab",
                          name: "New Tab",
                          icon: "plus.square",
                          description: "Open a new Finder tab",
                          triggers: ["new tab", "tab"],
                          type: .menubar, menuPath: ["File", "New Tab"],
                          accentColor: "blue"),
            AdapterAction(id: "finder.addToSidebar",
                          name: "Add to Sidebar",
                          icon: "sidebar.leading",
                          description: "Add selected item to the Finder sidebar",
                          triggers: ["add sidebar", "sidebar", "favourite", "favorite"],
                          type: .menubar, menuPath: ["File", "Add to Sidebar"],
                          accentColor: "blue"),
            AdapterAction(id: "finder.print",
                          name: "Print…",
                          icon: "printer",
                          description: "Print the selected file",
                          triggers: ["print"],
                          type: .menubar, menuPath: ["File", "Print…"],
                          accentColor: "gray"),

            // ── Edit ──────────────────────────────────────────────────────────
            AdapterAction(id: "finder.undo",
                          name: "Undo",
                          icon: "arrow.uturn.backward",
                          description: "Undo the last file operation",
                          triggers: ["undo"],
                          type: .menubar, menuPath: ["Edit", "Undo"],
                          accentColor: "gray"),
            AdapterAction(id: "finder.selectAll",
                          name: "Select All",
                          icon: "checkmark.rectangle",
                          description: "Select all items in the current folder",
                          triggers: ["select all"],
                          type: .menubar, menuPath: ["Edit", "Select All"],
                          accentColor: "gray"),
            AdapterAction(id: "finder.invertSelection",
                          name: "Invert Selection",
                          icon: "rectangle.badge.minus",
                          description: "Invert the current selection",
                          triggers: ["invert selection", "deselect"],
                          type: .menubar, menuPath: ["Edit", "Select None"],
                          accentColor: "gray"),
            AdapterAction(id: "finder.showClipboard",
                          name: "Show Clipboard",
                          icon: "clipboard",
                          description: "Show the current clipboard contents",
                          triggers: ["clipboard", "show clipboard"],
                          type: .menubar, menuPath: ["Edit", "Show Clipboard"],
                          accentColor: "gray"),
            AdapterAction(id: "finder.emojiSymbols",
                          name: "Emoji & Symbols",
                          icon: "face.smiling",
                          description: "Open the Emoji & Symbols picker",
                          triggers: ["emoji", "symbols"],
                          type: .menubar, menuPath: ["Edit", "Emoji & Symbols"],
                          accentColor: "yellow"),

            // ── View ──────────────────────────────────────────────────────────
            AdapterAction(id: "finder.viewIcons",
                          name: "View as Icons",
                          icon: "square.grid.2x2",
                          description: "Switch to icon view",
                          triggers: ["icon view", "icons"],
                          type: .menubar, menuPath: ["View", "as Icons"],
                          accentColor: "blue"),
            AdapterAction(id: "finder.viewList",
                          name: "View as List",
                          icon: "list.bullet",
                          description: "Switch to list view",
                          triggers: ["list view", "list"],
                          type: .menubar, menuPath: ["View", "as List"],
                          accentColor: "blue"),
            AdapterAction(id: "finder.viewColumns",
                          name: "View as Columns",
                          icon: "rectangle.split.3x1",
                          description: "Switch to column view",
                          triggers: ["column view", "columns"],
                          type: .menubar, menuPath: ["View", "as Columns"],
                          accentColor: "blue"),
            AdapterAction(id: "finder.viewGallery",
                          name: "View as Gallery",
                          icon: "rectangle.grid.1x2",
                          description: "Switch to gallery view",
                          triggers: ["gallery view", "gallery"],
                          type: .menubar, menuPath: ["View", "as Gallery"],
                          accentColor: "blue"),
            AdapterAction(id: "finder.showPreview",
                          name: "Show Preview",
                          icon: "sidebar.right",
                          description: "Show/hide the Preview pane",
                          triggers: ["preview panel", "show preview", "sidebar"],
                          type: .menubar, menuPath: ["View", "Show Preview"],
                          accentColor: "gray"),
            AdapterAction(id: "finder.showPathBar",
                          name: "Show Path Bar",
                          icon: "chevron.right.2",
                          description: "Show/hide the path bar at the bottom",
                          triggers: ["path bar", "breadcrumb"],
                          type: .menubar, menuPath: ["View", "Show Path Bar"],
                          accentColor: "gray"),
            AdapterAction(id: "finder.showStatusBar",
                          name: "Show Status Bar",
                          icon: "dock.rectangle",
                          description: "Show/hide the status bar",
                          triggers: ["status bar"],
                          type: .menubar, menuPath: ["View", "Show Status Bar"],
                          accentColor: "gray"),
            AdapterAction(id: "finder.showTabBar",
                          name: "Show Tab Bar",
                          icon: "rectangle.topthird.inset.filled",
                          description: "Show/hide the tab bar",
                          triggers: ["tab bar"],
                          type: .menubar, menuPath: ["View", "Show Tab Bar"],
                          accentColor: "gray"),
            AdapterAction(id: "finder.showSidebar",
                          name: "Show Sidebar",
                          icon: "sidebar.left",
                          description: "Show/hide the sidebar",
                          triggers: ["sidebar", "hide sidebar"],
                          type: .menubar, menuPath: ["View", "Hide Sidebar"],
                          accentColor: "gray"),
            AdapterAction(id: "finder.sortBy",
                          name: "Sort by Name",
                          icon: "arrow.up.arrow.down",
                          description: "Sort items by name",
                          triggers: ["sort name", "sort by name"],
                          type: .menubar, menuPath: ["View", "Sort By", "Name"],
                          accentColor: "gray"),
            AdapterAction(id: "finder.sortByDate",
                          name: "Sort by Date Modified",
                          icon: "calendar",
                          description: "Sort items by date modified",
                          triggers: ["sort date", "sort modified", "recent files"],
                          type: .menubar, menuPath: ["View", "Sort By", "Date Modified"],
                          accentColor: "gray"),
            AdapterAction(id: "finder.cleanUp",
                          name: "Clean Up",
                          icon: "sparkles.rectangle.stack",
                          description: "Clean up icons on the desktop or in icon view",
                          triggers: ["clean up", "organize", "tidy"],
                          type: .menubar, menuPath: ["View", "Clean Up"],
                          accentColor: "teal"),

            // ── Go ────────────────────────────────────────────────────────────
            AdapterAction(id: "finder.goBack",
                          name: "Go Back",
                          icon: "chevron.left",
                          description: "Navigate back",
                          triggers: ["back", "go back"],
                          type: .menubar, menuPath: ["Go", "Back"],
                          accentColor: "gray"),
            AdapterAction(id: "finder.goForward",
                          name: "Go Forward",
                          icon: "chevron.right",
                          description: "Navigate forward",
                          triggers: ["forward", "go forward"],
                          type: .menubar, menuPath: ["Go", "Forward"],
                          accentColor: "gray"),
            AdapterAction(id: "finder.goHome",
                          name: "Go to Home Folder",
                          icon: "house",
                          description: "Navigate to your Home folder",
                          triggers: ["home", "home folder"],
                          type: .menubar, menuPath: ["Go", "Home"],
                          accentColor: "blue"),
            AdapterAction(id: "finder.goDesktop",
                          name: "Go to Desktop",
                          icon: "desktopcomputer",
                          description: "Navigate to the Desktop",
                          triggers: ["desktop"],
                          type: .menubar, menuPath: ["Go", "Desktop"],
                          accentColor: "blue"),
            AdapterAction(id: "finder.goDocuments",
                          name: "Go to Documents",
                          icon: "doc.text",
                          description: "Navigate to the Documents folder",
                          triggers: ["documents", "docs"],
                          type: .menubar, menuPath: ["Go", "Documents"],
                          accentColor: "blue"),
            AdapterAction(id: "finder.goDownloads",
                          name: "Go to Downloads",
                          icon: "arrow.down.circle",
                          description: "Navigate to the Downloads folder",
                          triggers: ["downloads", "download"],
                          type: .menubar, menuPath: ["Go", "Downloads"],
                          accentColor: "blue"),
            AdapterAction(id: "finder.goApplications",
                          name: "Go to Applications",
                          icon: "square.grid.2x2",
                          description: "Navigate to the Applications folder",
                          triggers: ["applications", "apps folder"],
                          type: .menubar, menuPath: ["Go", "Applications"],
                          accentColor: "blue"),
            AdapterAction(id: "finder.goiCloud",
                          name: "Go to iCloud Drive",
                          icon: "icloud",
                          description: "Navigate to iCloud Drive",
                          triggers: ["icloud", "icloud drive"],
                          type: .menubar, menuPath: ["Go", "iCloud Drive"],
                          accentColor: "blue"),
            AdapterAction(id: "finder.goRecent",
                          name: "Recent Folders",
                          icon: "clock",
                          description: "Show recently visited folders",
                          triggers: ["recent", "recent folders"],
                          type: .menubar, menuPath: ["Go", "Recent Folders"],
                          accentColor: "gray"),
            AdapterAction(id: "finder.goToFolder",
                          name: "Go to Folder…",
                          icon: "folder.badge.questionmark",
                          description: "Type a folder path to navigate directly",
                          triggers: ["go to folder", "navigate", "folder path"],
                          type: .menubar, menuPath: ["Go", "Go to Folder…"],
                          accentColor: "orange"),
            AdapterAction(id: "finder.connectServer",
                          name: "Connect to Server…",
                          icon: "server.rack",
                          description: "Connect to a network server",
                          triggers: ["server", "connect", "network drive", "smb", "afp"],
                          type: .menubar, menuPath: ["Go", "Connect to Server…"],
                          accentColor: "purple"),

            // ── Window ────────────────────────────────────────────────────────
            AdapterAction(id: "finder.minimize",
                          name: "Minimize",
                          icon: "minus.square",
                          description: "Minimize the Finder window",
                          triggers: ["minimize"],
                          type: .menubar, menuPath: ["Window", "Minimize"],
                          accentColor: "gray"),
            AdapterAction(id: "finder.mergeWindows",
                          name: "Merge All Windows",
                          icon: "rectangle.3.group",
                          description: "Merge all Finder windows into one with tabs",
                          triggers: ["merge windows", "combine tabs"],
                          type: .menubar, menuPath: ["Window", "Merge All Windows"],
                          accentColor: "teal"),

            // ── Finder (app) menu ─────────────────────────────────────────────
            AdapterAction(id: "finder.settings",
                          name: "Finder Settings…",
                          icon: "gear",
                          description: "Open Finder preferences/settings",
                          triggers: ["finder settings", "finder preferences", "settings"],
                          type: .menubar, menuPath: ["Finder", "Settings…"],
                          accentColor: "gray"),
            AdapterAction(id: "finder.emptyBin",
                          name: "Empty Bin…",
                          icon: "trash.slash",
                          description: "Permanently delete all items in the Trash",
                          triggers: ["empty trash", "empty bin", "purge"],
                          type: .menubar, menuPath: ["Finder", "Empty Bin…"],
                          requiresApproval: true, isDestructive: true, accentColor: "red"),

            // ── Services (common built-in macOS services) ─────────────────────
            AdapterAction(id: "finder.svc.bluetooth",
                          name: "Send to Bluetooth Device",
                          icon: "antenna.radiowaves.left.and.right",
                          description: "Share selected file via Bluetooth",
                          triggers: ["bluetooth", "send bluetooth"],
                          type: .menubar, menuPath: ["Finder", "Services", "Send File To Bluetooth Device"],
                          accentColor: "blue"),
            AdapterAction(id: "finder.svc.openTerminalHere",
                          name: "New Terminal at Folder",
                          icon: "terminal",
                          description: "Open Terminal at the selected folder",
                          triggers: ["terminal here", "terminal folder", "open terminal"],
                          type: .menubar, menuPath: ["Finder", "Services", "New Terminal at Folder"],
                          accentColor: "green"),
            AdapterAction(id: "finder.svc.openTerminalTab",
                          name: "New Terminal Tab at Folder",
                          icon: "terminal.badge.plus",
                          description: "Open a new Terminal tab at selected folder",
                          triggers: ["terminal tab", "terminal here tab"],
                          type: .menubar, menuPath: ["Finder", "Services", "New Terminal Tab at Folder"],
                          accentColor: "green"),
            AdapterAction(id: "finder.svc.encode",
                          name: "Encode Selected Video Files",
                          icon: "film",
                          description: "Encode selected video files via Compressor",
                          triggers: ["encode video", "compress video", "compressor"],
                          type: .menubar, menuPath: ["Finder", "Services", "Encode Selected Video Files"],
                          accentColor: "purple"),
            AdapterAction(id: "finder.svc.createWorkflow",
                          name: "Create Automator Workflow",
                          icon: "wand.and.rays",
                          description: "Create an Automator workflow for selected files",
                          triggers: ["automator", "workflow", "create workflow"],
                          type: .menubar, menuPath: ["Finder", "Services", "Create Workflow"],
                          accentColor: "orange"),

            // ── AppleScript helpers ───────────────────────────────────────────
            AdapterAction(id: "finder.openTerminal",
                          name: "Open in Terminal",
                          icon: "terminal.fill",
                          description: "Open Terminal at the current Finder location",
                          triggers: ["terminal", "shell", "bash"],
                          type: .applescript,
                          script: """
tell application "Finder"
    set thePath to (POSIX path of (target of front window as alias))
end tell
tell application "Terminal"
    activate
    do script "cd " & quoted form of thePath
end tell
""",
                          accentColor: "green"),
            AdapterAction(id: "finder.showHidden",
                          name: "Toggle Hidden Files",
                          icon: "eye.slash",
                          description: "Toggle visibility of hidden dot-files (restarts Finder)",
                          triggers: ["hidden", "show hidden", "dotfiles", "dot files"],
                          type: .shell,
                          script: """
CURRENT=$(defaults read com.apple.finder AppleShowAllFiles 2>/dev/null || echo "FALSE")
if [ "$CURRENT" = "TRUE" ] || [ "$CURRENT" = "1" ]; then
    defaults write com.apple.finder AppleShowAllFiles FALSE
    echo "Hidden files: OFF"
else
    defaults write com.apple.finder AppleShowAllFiles TRUE
    echo "Hidden files: ON"
fi
killall Finder
""",
                          accentColor: "gray"),
            AdapterAction(id: "finder.revealInFinder",
                          name: "Reveal Selection in Finder",
                          icon: "magnifyingglass.circle",
                          description: "Reveal selected file in a new Finder window",
                          triggers: ["reveal", "show in finder"],
                          type: .applescript,
                          script: """
tell application "Finder"
    set sel to selection
    if (count of sel) > 0 then
        reveal (item 1 of sel)
        activate
    end if
end tell
""",
                          accentColor: "blue"),
        ]
    )

    // MARK: System Settings

    static let systemSettingsAdapter = AppAdapter(
        id: "com.apple.systempreferences",
        appName: "System Settings",
        bundleId: "com.apple.systempreferences",
        icon: "gearshape.2.fill",
        actions: [

            // ── Apple Account ─────────────────────────────────────────────────
            AdapterAction(id: "sysprefs.appleaccount",
                          name: "Apple Account",
                          icon: "person.crop.circle",
                          description: "Open Apple Account (Apple ID) settings",
                          triggers: ["apple id", "apple account", "icloud account", "sign in"],
                          type: .urlScheme,
                          urlScheme: "x-apple.systempreferences:com.apple.systempreferences.AppleIDSettings",
                          accentColor: "gray"),
            AdapterAction(id: "sysprefs.appleaccount.personalinfo",
                          name: "Personal Information",
                          icon: "person.text.rectangle",
                          description: "Apple Account > Personal Information",
                          triggers: ["personal information", "name address", "birthday"],
                          type: .urlScheme,
                          urlScheme: "x-apple.systempreferences:com.apple.systempreferences.AppleIDSettings?loadPersonalInfoUI",
                          accentColor: "gray"),
            AdapterAction(id: "sysprefs.appleaccount.siginsecurity",
                          name: "Sign-In & Security",
                          icon: "lock.shield",
                          description: "Apple Account > Sign-In & Security",
                          triggers: ["sign in security", "two factor", "trusted phone", "apple id password"],
                          type: .urlScheme,
                          urlScheme: "x-apple.systempreferences:com.apple.systempreferences.AppleIDSettings?loadPasswordSecurityUI",
                          accentColor: "blue"),
            AdapterAction(id: "sysprefs.appleaccount.payment",
                          name: "Payment & Shipping",
                          icon: "creditcard",
                          description: "Apple Account > Payment & Shipping",
                          triggers: ["payment", "shipping address", "billing", "credit card apple"],
                          type: .urlScheme,
                          urlScheme: "x-apple.systempreferences:com.apple.systempreferences.AppleIDSettings?loadPaymentUI",
                          accentColor: "green"),
            AdapterAction(id: "sysprefs.icloud",
                          name: "iCloud",
                          icon: "icloud",
                          description: "Open iCloud settings",
                          triggers: ["icloud", "cloud storage", "icloud drive", "sync"],
                          type: .urlScheme,
                          urlScheme: "x-apple.systempreferences:com.apple.systempreferences.AppleIDSettings?iCloud",
                          accentColor: "blue"),
            AdapterAction(id: "sysprefs.icloud.storage",
                          name: "iCloud Storage",
                          icon: "icloud.and.arrow.up",
                          description: "iCloud > Manage Storage",
                          triggers: ["icloud storage", "manage storage", "storage plan"],
                          type: .urlScheme,
                          urlScheme: "x-apple.systempreferences:com.apple.systempreferences.AppleIDSettings?email/prefs/storage?path=STORAGE_AND_BACKUP",
                          accentColor: "blue"),
            AdapterAction(id: "sysprefs.icloud.privaterelay",
                          name: "iCloud Private Relay",
                          icon: "network.badge.shield.half.filled",
                          description: "iCloud+ > Private Relay",
                          triggers: ["private relay", "icloud plus", "ip address privacy"],
                          type: .urlScheme,
                          urlScheme: "x-apple.systempreferences:com.apple.systempreferences.AppleIDSettings?email/prefs/accountDetails?path=InternetPrivacy",
                          accentColor: "blue"),
            AdapterAction(id: "sysprefs.icloud.hidemyemail",
                          name: "Hide My Email",
                          icon: "envelope.badge.shield.half.filled",
                          description: "iCloud+ > Hide My Email",
                          triggers: ["hide my email", "icloud email", "random email"],
                          type: .urlScheme,
                          urlScheme: "x-apple.systempreferences:com.apple.systempreferences.AppleIDSettings?email/prefs/storage?root=APPLE_ACCOUNT&path=ICLOUD_SERVICE/PRIVATE_EMAIL_MANAGE",
                          accentColor: "blue"),
            AdapterAction(id: "sysprefs.icloud.adp",
                          name: "Advanced Data Protection",
                          icon: "checkmark.shield",
                          description: "iCloud > Advanced Data Protection",
                          triggers: ["advanced data protection", "end to end encryption", "adp"],
                          type: .urlScheme,
                          urlScheme: "x-apple.systempreferences:com.apple.systempreferences.AppleIDSettings?email/prefs/storage?root=APPLE_ACCOUNT&path=ICLOUD_SERVICE/ICLOUD_ADP_SPECIFIER_NAME",
                          accentColor: "blue"),
            AdapterAction(id: "sysprefs.appleaccount.mediapurchases",
                          name: "Media & Purchases",
                          icon: "bag",
                          description: "Apple Account > Media & Purchases",
                          triggers: ["media purchases", "app store account", "itunes purchases"],
                          type: .urlScheme,
                          urlScheme: "x-apple.systempreferences:com.apple.systempreferences.AppleIDSettings?com.apple.AppleMediaServicesUI.SpyglassPurchases",
                          accentColor: "gray"),
            AdapterAction(id: "sysprefs.appleaccount.signinwithapple",
                          name: "Sign in with Apple",
                          icon: "apple.logo",
                          description: "Apple Account > Sign in with Apple",
                          triggers: ["sign in with apple", "app logins", "third party login"],
                          type: .urlScheme,
                          urlScheme: "x-apple.systempreferences:com.apple.systempreferences.AppleIDSettings?signInWithApple",
                          accentColor: "gray"),

            // ── Wi-Fi ─────────────────────────────────────────────────────────
            AdapterAction(id: "sysprefs.wifi",
                          name: "Wi-Fi",
                          icon: "wifi",
                          description: "Open Wi-Fi settings",
                          triggers: ["wifi", "wireless", "network wifi"],
                          type: .urlScheme,
                          urlScheme: "x-apple.systempreferences:com.apple.wifi-settings-extension",
                          accentColor: "blue"),
            AdapterAction(id: "sysprefs.wifi.details",
                          name: "Wi-Fi Network Details",
                          icon: "wifi.circle",
                          description: "Wi-Fi > current network Details",
                          triggers: ["wifi details", "network details", "wifi ip", "wifi info"],
                          type: .urlScheme,
                          urlScheme: "x-apple.systempreferences:com.apple.wifi-settings-extension?NetworkDetails",
                          accentColor: "blue"),
            AdapterAction(id: "sysprefs.wifi.advanced",
                          name: "Wi-Fi Advanced",
                          icon: "wifi.exclamationmark",
                          description: "Wi-Fi > Advanced settings",
                          triggers: ["wifi advanced", "preferred networks", "wifi proxy"],
                          type: .urlScheme,
                          urlScheme: "x-apple.systempreferences:com.apple.wifi-settings-extension?Advanced",
                          accentColor: "blue"),
            AdapterAction(id: "sysprefs.bluetooth",
                          name: "Bluetooth",
                          icon: "antenna.radiowaves.left.and.right",
                          description: "Open Bluetooth settings",
                          triggers: ["bluetooth", "bt"],
                          type: .urlScheme,
                          urlScheme: "x-apple.systempreferences:com.apple.BluetoothSettings",
                          accentColor: "blue"),
            AdapterAction(id: "sysprefs.sound",
                          name: "Sound",
                          icon: "speaker.wave.2",
                          description: "Open Sound settings",
                          triggers: ["sound", "audio", "volume", "speakers", "microphone"],
                          type: .urlScheme,
                          urlScheme: "x-apple.systempreferences:com.apple.Sound-Settings.extension",
                          accentColor: "red"),
            AdapterAction(id: "sysprefs.sound.output",
                          name: "Sound Output",
                          icon: "speaker.wave.3",
                          description: "Sound > Output tab",
                          triggers: ["sound output", "speakers output", "audio output", "headphones output"],
                          type: .urlScheme,
                          urlScheme: "x-apple.systempreferences:com.apple.Sound-Settings.extension?output",
                          accentColor: "red"),
            AdapterAction(id: "sysprefs.sound.input",
                          name: "Sound Input",
                          icon: "mic",
                          description: "Sound > Input tab",
                          triggers: ["sound input", "microphone input", "audio input", "mic settings"],
                          type: .urlScheme,
                          urlScheme: "x-apple.systempreferences:com.apple.Sound-Settings.extension?input",
                          accentColor: "red"),
            AdapterAction(id: "sysprefs.display",
                          name: "Displays",
                          icon: "display",
                          description: "Open Displays settings",
                          triggers: ["display", "displays", "resolution", "brightness", "screen"],
                          type: .urlScheme,
                          urlScheme: "x-apple.systempreferences:com.apple.Displays-Settings.extension",
                          accentColor: "blue"),
            AdapterAction(id: "sysprefs.display.nightshift",
                          name: "Night Shift",
                          icon: "moon.stars",
                          description: "Displays > Night Shift settings",
                          triggers: ["night shift", "warm display", "blue light", "color temperature"],
                          type: .urlScheme,
                          urlScheme: "x-apple.systempreferences:com.apple.Displays-Settings.extension?nightShiftSection",
                          accentColor: "orange"),
            AdapterAction(id: "sysprefs.display.advanced",
                          name: "Display Advanced",
                          icon: "display.trianglebadge.exclamationmark",
                          description: "Displays > Advanced settings",
                          triggers: ["display advanced", "hdr", "variable refresh rate", "promoion"],
                          type: .urlScheme,
                          urlScheme: "x-apple.systempreferences:com.apple.Displays-Settings.extension?advancedSection",
                          accentColor: "blue"),
            AdapterAction(id: "sysprefs.appearance",
                          name: "Toggle Dark Mode",
                          icon: "circle.lefthalf.filled",
                          description: "Toggle between Dark and Light appearance",
                          triggers: ["appearance", "dark mode", "light mode", "accent color", "theme", "toggle"],
                          type: .applescript,
                          script: "tell application \"System Events\" to tell appearance preferences to set dark mode to not dark mode",
                          accentColor: "purple"),
            AdapterAction(id: "sysprefs.notifications",
                          name: "Notifications",
                          icon: "bell",
                          description: "Open Notifications settings",
                          triggers: ["notifications", "alerts", "banners", "do not disturb"],
                          type: .urlScheme,
                          urlScheme: "x-apple.systempreferences:com.apple.Notifications-Settings.extension",
                          accentColor: "red"),
            AdapterAction(id: "sysprefs.notifications.iphone",
                          name: "iPhone Notifications on Mac",
                          icon: "iphone.radiowaves.left.and.right",
                          description: "Notifications > Allow Notifications from iPhone",
                          triggers: ["iphone notifications", "phone notifications mac", "continuity notifications"],
                          type: .urlScheme,
                          urlScheme: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?RemoteNotifications",
                          accentColor: "red"),
            AdapterAction(id: "sysprefs.privacy",
                          name: "Privacy & Security",
                          icon: "lock.shield",
                          description: "Open Privacy & Security settings",
                          triggers: ["privacy", "security", "permissions", "camera", "microphone access", "location"],
                          type: .urlScheme,
                          urlScheme: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension",
                          accentColor: "blue"),
            AdapterAction(id: "sysprefs.privacy.location",
                          name: "Location Services",
                          icon: "location",
                          description: "Privacy > Location Services",
                          triggers: ["location", "location services", "gps", "location permission"],
                          type: .urlScheme,
                          urlScheme: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_LocationServices",
                          accentColor: "blue"),
            AdapterAction(id: "sysprefs.privacy.camera",
                          name: "Camera Permission",
                          icon: "camera",
                          description: "Privacy > Camera access permissions",
                          triggers: ["camera permission", "camera access", "allow camera"],
                          type: .urlScheme,
                          urlScheme: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Camera",
                          accentColor: "blue"),
            AdapterAction(id: "sysprefs.privacy.microphone",
                          name: "Microphone Permission",
                          icon: "mic.badge.plus",
                          description: "Privacy > Microphone access permissions",
                          triggers: ["microphone permission", "mic access", "allow microphone"],
                          type: .urlScheme,
                          urlScheme: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Microphone",
                          accentColor: "blue"),
            AdapterAction(id: "sysprefs.privacy.screenrecording",
                          name: "Screen Recording Permission",
                          icon: "rectangle.dashed.badge.record",
                          description: "Privacy > Screen & System Audio Recording",
                          triggers: ["screen recording", "screen capture permission", "allow screen recording"],
                          type: .urlScheme,
                          urlScheme: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AudioCapture",
                          accentColor: "blue"),
            AdapterAction(id: "sysprefs.privacy.fulldisk",
                          name: "Full Disk Access",
                          icon: "externaldrive.badge.checkmark",
                          description: "Privacy > Full Disk Access",
                          triggers: ["full disk access", "disk permission", "disk access"],
                          type: .urlScheme,
                          urlScheme: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AllFiles",
                          accentColor: "blue"),
            AdapterAction(id: "sysprefs.privacy.accessibility",
                          name: "Accessibility Permission",
                          icon: "figure.roll.circle",
                          description: "Privacy > Accessibility permissions",
                          triggers: ["accessibility permission", "accessibility access", "allow accessibility"],
                          type: .urlScheme,
                          urlScheme: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Accessibility",
                          accentColor: "blue"),
            AdapterAction(id: "sysprefs.privacy.automation",
                          name: "Automation Permission",
                          icon: "gearshape.arrow.triangle.2.circlepath",
                          description: "Privacy > Automation permissions",
                          triggers: ["automation permission", "applescript permission", "allow automation"],
                          type: .urlScheme,
                          urlScheme: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Automation",
                          accentColor: "blue"),
            AdapterAction(id: "sysprefs.privacy.inputmonitoring",
                          name: "Input Monitoring",
                          icon: "keyboard.badge.eye",
                          description: "Privacy > Input Monitoring",
                          triggers: ["input monitoring", "keylogger permission", "keyboard monitoring"],
                          type: .urlScheme,
                          urlScheme: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_ListenEvent",
                          accentColor: "blue"),
            AdapterAction(id: "sysprefs.privacy.filevault",
                          name: "FileVault",
                          icon: "lock.laptopcomputer",
                          description: "Privacy & Security > FileVault disk encryption",
                          triggers: ["filevault", "disk encryption", "encrypt disk"],
                          type: .urlScheme,
                          urlScheme: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?FileVault",
                          accentColor: "yellow"),
            AdapterAction(id: "sysprefs.privacy.lockdown",
                          name: "Lockdown Mode",
                          icon: "lock.trianglebadge.exclamationmark",
                          description: "Privacy & Security > Lockdown Mode",
                          triggers: ["lockdown mode", "extreme security"],
                          type: .urlScheme,
                          urlScheme: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?LockdownMode",
                          accentColor: "red"),
            AdapterAction(id: "sysprefs.privacy.analytics",
                          name: "Analytics & Improvements",
                          icon: "chart.bar.xaxis",
                          description: "Privacy > Analytics & Improvements",
                          triggers: ["analytics", "diagnostics", "share with apple", "crash reports"],
                          type: .urlScheme,
                          urlScheme: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Analytics",
                          accentColor: "gray"),
            AdapterAction(id: "sysprefs.battery",
                          name: "Battery",
                          icon: "battery.75",
                          description: "Open Battery settings",
                          triggers: ["battery", "power", "energy", "charging"],
                          type: .urlScheme,
                          urlScheme: "x-apple.systempreferences:com.apple.Battery-Settings.extension",
                          accentColor: "green"),
            AdapterAction(id: "sysprefs.battery.health",
                          name: "Battery Health",
                          icon: "battery.100.bolt",
                          description: "Battery > Battery Health",
                          triggers: ["battery health", "battery capacity", "battery condition"],
                          type: .urlScheme,
                          urlScheme: "x-apple.systempreferences:com.apple.Battery-Settings.extension?batteryhealth",
                          accentColor: "green"),
            AdapterAction(id: "sysprefs.battery.options",
                          name: "Battery Options",
                          icon: "slider.horizontal.3",
                          description: "Battery > Options (low power mode, etc.)",
                          triggers: ["battery options", "low power mode", "power nap"],
                          type: .urlScheme,
                          urlScheme: "x-apple.systempreferences:com.apple.Battery-Settings.extension?options",
                          accentColor: "green"),

            // ── System & Updates ─────────────────────────────────────────────
            AdapterAction(id: "sysprefs.about",
                          name: "About This Mac",
                          icon: "apple.logo",
                          description: "Open About This Mac",
                          triggers: ["about", "about this mac", "mac info", "serial number", "model"],
                          type: .urlScheme,
                          urlScheme: "x-apple.systempreferences:com.apple.SystemProfiler.AboutExtension",
                          accentColor: "gray"),
            AdapterAction(id: "sysprefs.softwareupdate",
                          name: "Software Update",
                          icon: "arrow.down.circle",
                          description: "Open Software Update — check for macOS updates",
                          triggers: ["software update", "update", "upgrade", "macos update", "check update"],
                          type: .urlScheme,
                          urlScheme: "x-apple.systempreferences:com.apple.Software-Update-Settings.extension",
                          accentColor: "teal"),
            AdapterAction(id: "sysprefs.softwareupdate.auto",
                          name: "Automatic Updates",
                          icon: "arrow.clockwise.circle",
                          description: "Software Update > Automatic Updates settings",
                          triggers: ["automatic update", "auto update", "background update"],
                          type: .urlScheme,
                          urlScheme: "x-apple.systempreferences:com.apple.Software-Update-Settings.extension?action=showAdvancedOptions",
                          accentColor: "teal"),
            AdapterAction(id: "sysprefs.general",
                          name: "General",
                          icon: "gearshape",
                          description: "Open General settings",
                          triggers: ["general", "sharing name", "default browser"],
                          type: .urlScheme,
                          urlScheme: "x-apple.systempreferences:com.apple.systempreferences",
                          accentColor: "gray"),
            AdapterAction(id: "sysprefs.storage",
                          name: "Storage",
                          icon: "externaldrive",
                          description: "Open Storage settings — see disk usage",
                          triggers: ["storage", "disk", "space", "disk usage"],
                          type: .urlScheme,
                          urlScheme: "x-apple.systempreferences:com.apple.settings.Storage",
                          accentColor: "orange"),
            AdapterAction(id: "sysprefs.startupdisk",
                          name: "Startup Disk",
                          icon: "internaldrive",
                          description: "Open Startup Disk settings",
                          triggers: ["startup disk", "boot disk"],
                          type: .urlScheme,
                          urlScheme: "x-apple.systempreferences:com.apple.preference.startupdisk",
                          accentColor: "gray"),
            AdapterAction(id: "sysprefs.transferreset",
                          name: "Transfer or Reset",
                          icon: "arrow.triangle.2.circlepath",
                          description: "Open Transfer or Reset settings",
                          triggers: ["reset", "erase", "factory reset", "migration", "transfer"],
                          type: .urlScheme,
                          urlScheme: "x-apple.systempreferences:com.apple.Transfer-Reset-Settings.extension",
                          accentColor: "red"),
            AdapterAction(id: "sysprefs.timemachine",
                          name: "Time Machine",
                          icon: "clock.arrow.circlepath",
                          description: "Open Time Machine settings",
                          triggers: ["time machine", "backup", "backups"],
                          type: .urlScheme,
                          urlScheme: "x-apple.systempreferences:com.apple.prefs.backup",
                          accentColor: "orange"),

            // ── Input & Peripherals ──────────────────────────────────────────
            AdapterAction(id: "sysprefs.keyboard",
                          name: "Keyboard",
                          icon: "keyboard",
                          description: "Open Keyboard settings",
                          triggers: ["keyboard", "shortcuts", "input sources", "text input"],
                          type: .urlScheme,
                          urlScheme: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension",
                          accentColor: "gray"),
            AdapterAction(id: "sysprefs.keyboard.shortcuts.spotlight",
                          name: "Spotlight Shortcut",
                          icon: "magnifyingglass.circle",
                          description: "Keyboard > Keyboard Shortcuts > Spotlight",
                          triggers: ["spotlight shortcut", "spotlight hotkey", "command space"],
                          type: .urlScheme,
                          urlScheme: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension?Spotlight",
                          accentColor: "gray"),
            AdapterAction(id: "sysprefs.keyboard.shortcuts.functionkeys",
                          name: "Function Keys",
                          icon: "fn",
                          description: "Keyboard > Keyboard Shortcuts > Function keys",
                          triggers: ["function keys", "fn keys", "f1 f2", "media keys"],
                          type: .urlScheme,
                          urlScheme: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension?FunctionKeys",
                          accentColor: "gray"),
            AdapterAction(id: "sysprefs.keyboard.shortcuts.modifiers",
                          name: "Modifier Keys",
                          icon: "keyboard.badge.ellipsis",
                          description: "Keyboard > Modifier Keys (remap Caps Lock, etc.)",
                          triggers: ["modifier keys", "caps lock", "remap keys", "control key"],
                          type: .urlScheme,
                          urlScheme: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension?ModifierKeys",
                          accentColor: "gray"),
            AdapterAction(id: "sysprefs.keyboard.inputsources",
                          name: "Input Sources",
                          icon: "globe",
                          description: "Keyboard > Text Input > Input Sources",
                          triggers: ["input sources", "keyboard language", "input language"],
                          type: .urlScheme,
                          urlScheme: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension?InputSources",
                          accentColor: "gray"),
            AdapterAction(id: "sysprefs.keyboard.textreplacements",
                          name: "Text Replacements",
                          icon: "text.badge.checkmark",
                          description: "Keyboard > Text Replacements",
                          triggers: ["text replacement", "autocorrect", "auto correct", "substitutions"],
                          type: .urlScheme,
                          urlScheme: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension?TextReplacements",
                          accentColor: "gray"),
            AdapterAction(id: "sysprefs.trackpad",
                          name: "Trackpad",
                          icon: "rectangle.and.hand.point.up.left",
                          description: "Open Trackpad settings",
                          triggers: ["trackpad", "touchpad", "gestures"],
                          type: .urlScheme,
                          urlScheme: "x-apple.systempreferences:com.apple.Trackpad-Settings.extension",
                          accentColor: "gray"),
            AdapterAction(id: "sysprefs.trackpad.pointclick",
                          name: "Trackpad Point & Click",
                          icon: "cursorarrow.click",
                          description: "Trackpad > Point & Click tab",
                          triggers: ["click speed", "tap to click", "secondary click", "tracking speed"],
                          type: .urlScheme,
                          urlScheme: "x-apple.systempreferences:com.apple.Trackpad-Settings.extension?PointAndClick",
                          accentColor: "gray"),
            AdapterAction(id: "sysprefs.trackpad.scrollzoom",
                          name: "Trackpad Scroll & Zoom",
                          icon: "arrow.up.and.down.and.arrow.left.and.right",
                          description: "Trackpad > Scroll & Zoom tab",
                          triggers: ["scroll direction", "natural scrolling", "pinch zoom", "smart zoom"],
                          type: .urlScheme,
                          urlScheme: "x-apple.systempreferences:com.apple.Trackpad-Settings.extension?ScrollAndZoom",
                          accentColor: "gray"),
            AdapterAction(id: "sysprefs.trackpad.moregestures",
                          name: "Trackpad More Gestures",
                          icon: "hand.draw",
                          description: "Trackpad > More Gestures tab",
                          triggers: ["swipe gestures", "mission control gesture", "app expose", "more gestures"],
                          type: .urlScheme,
                          urlScheme: "x-apple.systempreferences:com.apple.Trackpad-Settings.extension?MoreGestures",
                          accentColor: "gray"),
            AdapterAction(id: "sysprefs.mouse",
                          name: "Mouse",
                          icon: "computermouse",
                          description: "Open Mouse settings",
                          triggers: ["mouse", "cursor", "scroll"],
                          type: .urlScheme,
                          urlScheme: "x-apple.systempreferences:com.apple.Mouse-Settings.extension",
                          accentColor: "gray"),
            AdapterAction(id: "sysprefs.printers",
                          name: "Printers & Scanners",
                          icon: "printer",
                          description: "Open Printers & Scanners settings",
                          triggers: ["printer", "scanner", "print", "fax"],
                          type: .urlScheme,
                          urlScheme: "x-apple.systempreferences:com.apple.Print-Scan-Settings.extension",
                          accentColor: "gray"),

            // ── Network & Connectivity ────────────────────────────────────────
            AdapterAction(id: "sysprefs.network",
                          name: "Network",
                          icon: "network",
                          description: "Open Network settings (VPN, Ethernet, etc.)",
                          triggers: ["network", "ethernet", "vpn", "internet"],
                          type: .urlScheme,
                          urlScheme: "x-apple.systempreferences:com.apple.Network-Settings.extension",
                          accentColor: "blue"),
            AdapterAction(id: "sysprefs.network.dns",
                          name: "Network DNS",
                          icon: "network.badge.shield.half.filled",
                          description: "Network > current connection DNS settings",
                          triggers: ["dns", "nameserver", "custom dns"],
                          type: .urlScheme,
                          urlScheme: "x-apple.systempreferences:com.apple.Network-Settings.extension?DNS",
                          accentColor: "blue"),
            AdapterAction(id: "sysprefs.network.proxies",
                          name: "Network Proxies",
                          icon: "arrow.triangle.swap",
                          description: "Network > Proxies settings",
                          triggers: ["proxy", "proxies", "http proxy", "socks"],
                          type: .urlScheme,
                          urlScheme: "x-apple.systempreferences:com.apple.Network-Settings.extension?Proxies",
                          accentColor: "blue"),
            AdapterAction(id: "sysprefs.airdrop",
                          name: "AirDrop & Continuity",
                          icon: "point.3.connected.trianglepath.dotted",
                          description: "Open AirDrop & Continuity settings",
                          triggers: ["airdrop", "continuity", "handoff", "airplay", "universal clipboard"],
                          type: .urlScheme,
                          urlScheme: "x-apple.systempreferences:com.apple.AirDrop-Handoff-Settings.extension",
                          accentColor: "blue"),
            AdapterAction(id: "sysprefs.sharing",
                          name: "Sharing",
                          icon: "person.2",
                          description: "Open Sharing settings (screen sharing, file sharing)",
                          triggers: ["sharing", "screen sharing", "file sharing", "remote"],
                          type: .urlScheme,
                          urlScheme: "x-apple.systempreferences:com.apple.Sharing-Settings.extension",
                          accentColor: "blue"),
            AdapterAction(id: "sysprefs.sharing.screensharing",
                          name: "Screen Sharing",
                          icon: "display.and.arrow.down",
                          description: "Sharing > Screen Sharing",
                          triggers: ["screen sharing", "vnc", "remote screen", "share screen"],
                          type: .urlScheme,
                          urlScheme: "x-apple.systempreferences:com.apple.Sharing-Settings.extension?Services_ScreenSharing",
                          accentColor: "blue"),
            AdapterAction(id: "sysprefs.sharing.remotelogin",
                          name: "Remote Login (SSH)",
                          icon: "terminal.fill",
                          description: "Sharing > Remote Login (SSH access)",
                          triggers: ["remote login", "ssh", "ssh access", "remote terminal"],
                          type: .urlScheme,
                          urlScheme: "x-apple.systempreferences:com.apple.Sharing-Settings.extension?Services_RemoteLogin",
                          accentColor: "green"),
            AdapterAction(id: "sysprefs.sharing.internetsharing",
                          name: "Internet Sharing",
                          icon: "wifi.router",
                          description: "Sharing > Internet Sharing (hotspot)",
                          triggers: ["internet sharing", "hotspot", "share internet", "wifi hotspot"],
                          type: .urlScheme,
                          urlScheme: "x-apple.systempreferences:com.apple.Sharing-Settings.extension?Internet",
                          accentColor: "blue"),

            // ── Account & Security ────────────────────────────────────────────
            AdapterAction(id: "sysprefs.appleaccount",
                          name: "Apple Account",
                          icon: "person.crop.circle",
                          description: "Open Apple Account (Apple ID) settings",
                          triggers: ["apple id", "apple account", "icloud account", "sign in"],
                          type: .urlScheme,
                          urlScheme: "x-apple.systempreferences:com.apple.Apple-Account-Settings.extension",
                          accentColor: "gray"),
            AdapterAction(id: "sysprefs.icloud",
                          name: "iCloud",
                          icon: "icloud",
                          description: "Open iCloud settings",
                          triggers: ["icloud", "cloud storage", "icloud drive", "sync"],
                          type: .urlScheme,
                          urlScheme: "x-apple.systempreferences:com.apple.Apple-Account-Settings.extension",
                          accentColor: "blue"),
            AdapterAction(id: "sysprefs.touchid",
                          name: "Touch ID & Password",
                          icon: "touchid",
                          description: "Open Touch ID & Password settings",
                          triggers: ["touch id", "fingerprint", "password", "face id"],
                          type: .urlScheme,
                          urlScheme: "x-apple.systempreferences:com.apple.Touch-ID-Settings.extension",
                          accentColor: "red"),
            AdapterAction(id: "sysprefs.users",
                          name: "Users & Groups",
                          icon: "person.2.circle",
                          description: "Open Users & Groups settings",
                          triggers: ["users", "groups", "accounts", "login", "admin"],
                          type: .urlScheme,
                          urlScheme: "x-apple.systempreferences:com.apple.Users-Groups-Settings.extension",
                          accentColor: "teal"),
            AdapterAction(id: "sysprefs.passwords",
                          name: "Passwords",
                          icon: "key",
                          description: "AutoFill & Passwords settings",
                          triggers: ["passwords", "autofill passwords", "keychain", "saved passwords"],
                          type: .urlScheme,
                          urlScheme: "x-apple.systempreferences:com.apple.Passwords-Settings.extension",
                          accentColor: "yellow"),
            AdapterAction(id: "sysprefs.loginitems",
                          name: "Login Items & Extensions",
                          icon: "list.bullet.rectangle",
                          description: "Open Login Items — manage startup apps",
                          triggers: ["login items", "startup apps", "launch at login", "extensions"],
                          type: .urlScheme,
                          urlScheme: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension",
                          accentColor: "orange"),
            AdapterAction(id: "sysprefs.loginitems.openatlogin",
                          name: "Open at Login",
                          icon: "power.circle",
                          description: "Login Items > Open at Login section",
                          triggers: ["open at login", "launch at startup", "startup items"],
                          type: .urlScheme,
                          urlScheme: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension?UserItems",
                          accentColor: "orange"),
            AdapterAction(id: "sysprefs.loginitems.background",
                          name: "Background App Activity",
                          icon: "gearshape.2",
                          description: "Login Items > App Background Activity",
                          triggers: ["background activity", "background apps", "background refresh"],
                          type: .urlScheme,
                          urlScheme: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension?BackgroundItems",
                          accentColor: "orange"),

            // ── Focus & Screen Time ───────────────────────────────────────────
            AdapterAction(id: "sysprefs.focus",
                          name: "Focus",
                          icon: "moon",
                          description: "Open Focus settings (Do Not Disturb, custom Focus modes)",
                          triggers: ["focus", "do not disturb", "dnd", "focus mode"],
                          type: .urlScheme,
                          urlScheme: "x-apple.systempreferences:com.apple.Focus-Settings.extension",
                          accentColor: "indigo"),
            AdapterAction(id: "sysprefs.screentime",
                          name: "Screen Time",
                          icon: "hourglass",
                          description: "Open Screen Time settings",
                          triggers: ["screen time", "downtime", "app limits"],
                          type: .urlScheme,
                          urlScheme: "x-apple.systempreferences:com.apple.Screen-Time-Settings.extension",
                          accentColor: "purple"),
            AdapterAction(id: "sysprefs.screentime.appusage",
                          name: "App & Website Activity",
                          icon: "chart.bar",
                          description: "Screen Time > App & Website Activity",
                          triggers: ["app usage", "website activity", "screen time stats"],
                          type: .urlScheme,
                          urlScheme: "x-apple.systempreferences:com.apple.Screen-Time-Settings.extension?path=app-usage",
                          accentColor: "purple"),
            AdapterAction(id: "sysprefs.screentime.downtime",
                          name: "Downtime",
                          icon: "moon.zzz",
                          description: "Screen Time > Downtime schedule",
                          triggers: ["downtime", "screen time schedule", "bedtime screen"],
                          type: .urlScheme,
                          urlScheme: "x-apple.systempreferences:com.apple.Screen-Time-Settings.extension?path=downtime",
                          accentColor: "purple"),
            AdapterAction(id: "sysprefs.screentime.applimits",
                          name: "App Limits",
                          icon: "hourglass.badge.plus",
                          description: "Screen Time > App Limits",
                          triggers: ["app limits", "time limit", "app time limit"],
                          type: .urlScheme,
                          urlScheme: "x-apple.systempreferences:com.apple.Screen-Time-Settings.extension?path=app-limits",
                          accentColor: "purple"),
            AdapterAction(id: "sysprefs.screentime.contentprivacy",
                          name: "Content & Privacy Restrictions",
                          icon: "lock.rectangle",
                          description: "Screen Time > Content & Privacy",
                          triggers: ["content restrictions", "parental controls", "content privacy"],
                          type: .urlScheme,
                          urlScheme: "x-apple.systempreferences:com.apple.Screen-Time-Settings.extension?path=content-and-privacy",
                          accentColor: "purple"),
            AdapterAction(id: "sysprefs.lockscreen",
                          name: "Lock Screen",
                          icon: "lock.display",
                          description: "Open Lock Screen settings (screensaver, auto-lock)",
                          triggers: ["lock screen", "screensaver", "screen saver", "auto lock", "sleep"],
                          type: .urlScheme,
                          urlScheme: "x-apple.systempreferences:com.apple.Lock-Screen-Settings.extension",
                          accentColor: "gray"),

            // ── Personalisation ──────────────────────────────────────────────
            AdapterAction(id: "sysprefs.appearance",
                          name: "Appearance",
                          icon: "paintpalette",
                          description: "Open Appearance settings (Dark/Light mode, accent colour)",
                          triggers: ["appearance", "accent color", "theme", "light dark"],
                          type: .urlScheme,
                          urlScheme: "x-apple.systempreferences:com.apple.Appearance-Settings.extension",
                          accentColor: "purple"),
            AdapterAction(id: "sysprefs.wallpaper",
                          name: "Wallpaper",
                          icon: "photo",
                          description: "Open Wallpaper settings",
                          triggers: ["wallpaper", "background", "desktop background", "desktop image"],
                          type: .urlScheme,
                          urlScheme: "x-apple.systempreferences:com.apple.Wallpaper-Settings.extension",
                          accentColor: "blue"),
            AdapterAction(id: "sysprefs.wallpaper.screensaver",
                          name: "Screen Saver",
                          icon: "sparkles.rectangle.stack",
                          description: "Wallpaper > Screen Saver settings",
                          triggers: ["screen saver", "screensaver", "idle display"],
                          type: .urlScheme,
                          urlScheme: "x-apple.systempreferences:com.apple.Wallpaper-Settings.extension?ScreenSaver",
                          accentColor: "blue"),
            AdapterAction(id: "sysprefs.desktopDock",
                          name: "Desktop & Dock",
                          icon: "dock.rectangle",
                          description: "Open Desktop & Dock settings",
                          triggers: ["dock", "desktop dock", "stage manager", "menu bar", "mission control"],
                          type: .urlScheme,
                          urlScheme: "x-apple.systempreferences:com.apple.Desktop-Settings.extension",
                          accentColor: "gray"),
            AdapterAction(id: "sysprefs.desktopDock.hotcorners",
                          name: "Hot Corners",
                          icon: "arrow.up.left.and.arrow.down.right.square",
                          description: "Desktop & Dock > Hot Corners",
                          triggers: ["hot corners", "screen corners", "mission control corner"],
                          type: .urlScheme,
                          urlScheme: "x-apple.systempreferences:com.apple.Desktop-Settings.extension?HotCorners",
                          accentColor: "gray"),
            AdapterAction(id: "sysprefs.menubar",
                          name: "Menu Bar",
                          icon: "menubar.rectangle",
                          description: "Open Menu Bar (Control Centre) settings",
                          triggers: ["menu bar", "control centre", "control center", "status bar"],
                          type: .urlScheme,
                          urlScheme: "x-apple.systempreferences:com.apple.ControlCenter-Settings.extension",
                          accentColor: "gray"),
            AdapterAction(id: "sysprefs.spotlight",
                          name: "Spotlight",
                          icon: "magnifyingglass",
                          description: "Open Spotlight settings",
                          triggers: ["spotlight", "search", "siri suggestions"],
                          type: .urlScheme,
                          urlScheme: "x-apple.systempreferences:com.apple.Spotlight-Settings.extension",
                          accentColor: "gray"),

            // ── Accessibility & Language ──────────────────────────────────────
            AdapterAction(id: "sysprefs.accessibility",
                          name: "Accessibility",
                          icon: "figure.roll",
                          description: "Open Accessibility settings",
                          triggers: ["accessibility", "voiceover", "zoom", "captions", "contrast"],
                          type: .urlScheme,
                          urlScheme: "x-apple.systempreferences:com.apple.Accessibility-Settings.extension",
                          accentColor: "blue"),
            AdapterAction(id: "sysprefs.accessibility.voiceover",
                          name: "VoiceOver",
                          icon: "speaker.badge.exclamationmark",
                          description: "Accessibility > VoiceOver",
                          triggers: ["voiceover", "screen reader", "voice over"],
                          type: .urlScheme,
                          urlScheme: "x-apple.systempreferences:com.apple.Accessibility-Settings.extension?VoiceOver",
                          accentColor: "blue"),
            AdapterAction(id: "sysprefs.accessibility.zoom",
                          name: "Zoom",
                          icon: "plus.magnifyingglass",
                          description: "Accessibility > Zoom",
                          triggers: ["zoom accessibility", "magnifier", "screen zoom"],
                          type: .urlScheme,
                          urlScheme: "x-apple.systempreferences:com.apple.Accessibility-Settings.extension?Zoom",
                          accentColor: "blue"),
            AdapterAction(id: "sysprefs.accessibility.display",
                          name: "Accessibility Display",
                          icon: "eye",
                          description: "Accessibility > Display (contrast, text size)",
                          triggers: ["contrast", "reduce motion", "color filter", "text size accessibility"],
                          type: .urlScheme,
                          urlScheme: "x-apple.systempreferences:com.apple.Accessibility-Settings.extension?Display",
                          accentColor: "blue"),
            AdapterAction(id: "sysprefs.accessibility.textsize",
                          name: "Accessibility Text Size",
                          icon: "textformat.size",
                          description: "Accessibility > Display > Text Size",
                          triggers: ["text size", "font size", "larger text"],
                          type: .urlScheme,
                          urlScheme: "x-apple.systempreferences:com.apple.Accessibility-Settings.extension?AX_FONT_SIZE",
                          accentColor: "blue"),
            AdapterAction(id: "sysprefs.accessibility.voicecontrol",
                          name: "Voice Control",
                          icon: "waveform.badge.mic",
                          description: "Accessibility > Voice Control",
                          triggers: ["voice control", "dictation control", "hands free"],
                          type: .urlScheme,
                          urlScheme: "x-apple.systempreferences:com.apple.Accessibility-Settings.extension?VoiceControl",
                          accentColor: "blue"),
            AdapterAction(id: "sysprefs.accessibility.captions",
                          name: "Captions",
                          icon: "captions.bubble",
                          description: "Accessibility > Captions",
                          triggers: ["captions", "subtitles", "closed captions"],
                          type: .urlScheme,
                          urlScheme: "x-apple.systempreferences:com.apple.Accessibility-Settings.extension?Captions",
                          accentColor: "blue"),
            AdapterAction(id: "sysprefs.accessibility.livecaptions",
                          name: "Live Captions",
                          icon: "text.bubble",
                          description: "Accessibility > Live Captions",
                          triggers: ["live captions", "real time captions", "live transcription"],
                          type: .urlScheme,
                          urlScheme: "x-apple.systempreferences:com.apple.Accessibility-Settings.extension?LiveCaptions",
                          accentColor: "blue"),
            AdapterAction(id: "sysprefs.accessibility.livespeech",
                          name: "Live Speech",
                          icon: "person.wave.2",
                          description: "Accessibility > Live Speech",
                          triggers: ["live speech", "type to speak", "speak text"],
                          type: .urlScheme,
                          urlScheme: "x-apple.systempreferences:com.apple.Accessibility-Settings.extension?LiveSpeech",
                          accentColor: "blue"),
            AdapterAction(id: "sysprefs.accessibility.personalvoice",
                          name: "Personal Voice",
                          icon: "person.badge.key",
                          description: "Accessibility > Personal Voice",
                          triggers: ["personal voice", "clone voice", "my voice"],
                          type: .urlScheme,
                          urlScheme: "x-apple.systempreferences:com.apple.Accessibility-Settings.extension?PersonalVoice",
                          accentColor: "blue"),
            AdapterAction(id: "sysprefs.language",
                          name: "Language & Region",
                          icon: "globe",
                          description: "Open Language & Region settings",
                          triggers: ["language", "region", "locale", "date format", "currency"],
                          type: .urlScheme,
                          urlScheme: "x-apple.systempreferences:com.apple.Localization-Settings.extension",
                          accentColor: "blue"),
            AdapterAction(id: "sysprefs.datetime",
                          name: "Date & Time",
                          icon: "clock",
                          description: "Open Date & Time settings",
                          triggers: ["date", "time", "clock", "timezone", "time zone"],
                          type: .urlScheme,
                          urlScheme: "x-apple.systempreferences:com.apple.Date-Time-Settings.extension",
                          accentColor: "orange"),

            // ── Siri & Intelligence ───────────────────────────────────────────
            AdapterAction(id: "sysprefs.siri",
                          name: "Apple Intelligence & Siri",
                          icon: "sparkles",
                          description: "Open Apple Intelligence & Siri settings",
                          triggers: ["siri", "apple intelligence", "hey siri", "ai settings"],
                          type: .urlScheme,
                          urlScheme: "x-apple.systempreferences:com.apple.Siri-Settings.extension",
                          accentColor: "indigo"),

            // ── Family & Social ───────────────────────────────────────────────
            AdapterAction(id: "sysprefs.family",
                          name: "Family",
                          icon: "person.3",
                          description: "Open Family Sharing settings",
                          triggers: ["family", "family sharing", "parental controls"],
                          type: .urlScheme,
                          urlScheme: "x-apple.systempreferences:com.apple.Family-Settings.extension",
                          accentColor: "green"),
            AdapterAction(id: "sysprefs.gamecenter",
                          name: "Game Center",
                          icon: "gamecontroller",
                          description: "Open Game Center settings",
                          triggers: ["game center", "gaming", "achievements"],
                          type: .urlScheme,
                          urlScheme: "x-apple.systempreferences:com.apple.Game-Center-Settings.extension",
                          accentColor: "green"),
            AdapterAction(id: "sysprefs.internetaccounts",
                          name: "Internet Accounts",
                          icon: "envelope.badge.person.crop",
                          description: "Open Internet Accounts (Google, Exchange, etc.)",
                          triggers: ["internet accounts", "google account", "exchange", "mail accounts"],
                          type: .urlScheme,
                          urlScheme: "x-apple.systempreferences:com.apple.Internet-Accounts-Settings.extension",
                          accentColor: "teal"),
            AdapterAction(id: "sysprefs.wallet",
                          name: "Wallet & Apple Pay",
                          icon: "wallet.pass",
                          description: "Open Wallet & Apple Pay settings",
                          triggers: ["wallet", "apple pay", "payment", "cards"],
                          type: .urlScheme,
                          urlScheme: "x-apple.systempreferences:com.apple.Wallet-Settings.extension",
                          accentColor: "green"),

            // ── Menu bar actions ─────────────────────────────────────────────
            AdapterAction(id: "sysprefs.search",
                          name: "Search Settings",
                          icon: "magnifyingglass",
                          description: "Focus the search box inside System Settings",
                          triggers: ["search settings", "find setting"],
                          type: .menubar, menuPath: ["View", "Search"],
                          accentColor: "gray"),
            AdapterAction(id: "sysprefs.back",
                          name: "Go Back",
                          icon: "chevron.left",
                          description: "Navigate back in System Settings",
                          triggers: ["back"],
                          type: .menubar, menuPath: ["View", "Back"],
                          accentColor: "gray"),
        ]
    )

    // MARK: Mail

    static let mailAdapter = AppAdapter(
        id: "com.apple.mail",
        appName: "Mail",
        bundleId: "com.apple.mail",
        icon: "envelope.fill",
        actions: [
            // File
            AdapterAction(id: "mail.compose",           name: "New Message",
                          icon: "square.and.pencil",
                          description: "Compose a new email",
                          triggers: ["new email", "compose", "write email", "new message"],
                          type: .menubar, menuPath: ["File", "New Message"],
                          accentColor: "blue"),
            AdapterAction(id: "mail.newWindow",         name: "New Viewer Window",
                          icon: "macwindow.badge.plus",
                          description: "Open a new Mail viewer window",
                          triggers: ["new window", "viewer window"],
                          type: .menubar, menuPath: ["File", "New Viewer Window"],
                          accentColor: "blue"),
            AdapterAction(id: "mail.print",             name: "Print Message",
                          icon: "printer",
                          description: "Print the selected message",
                          triggers: ["print", "print message"],
                          type: .menubar, menuPath: ["File", "Print"],
                          accentColor: "gray"),

            // Mailbox
            AdapterAction(id: "mail.getNew",            name: "Get New Mail",
                          icon: "arrow.triangle.2.circlepath",
                          description: "Check for new messages",
                          triggers: ["get mail", "check mail", "refresh", "sync"],
                          type: .menubar, menuPath: ["Mailbox", "Get New Mail"],
                          accentColor: "teal"),
            AdapterAction(id: "mail.getAllNew",         name: "Get All New Mail",
                          icon: "arrow.triangle.2.circlepath.circle",
                          description: "Check all accounts for new mail",
                          triggers: ["get all mail", "sync all", "check all"],
                          type: .menubar, menuPath: ["Mailbox", "Get All New Mail"],
                          accentColor: "teal"),
            AdapterAction(id: "mail.goInbox",          name: "Go to Inbox",
                          icon: "tray",
                          description: "Go to your Inbox",
                          triggers: ["inbox", "go inbox"],
                          type: .menubar, menuPath: ["Mailbox", "Go To", "Inbox"],
                          accentColor: "blue"),
            AdapterAction(id: "mail.goDrafts",         name: "Go to Drafts",
                          icon: "doc.text",
                          description: "Go to your Drafts",
                          triggers: ["drafts", "draft"],
                          type: .menubar, menuPath: ["Mailbox", "Go To", "Drafts"],
                          accentColor: "gray"),
            AdapterAction(id: "mail.goSent",           name: "Go to Sent",
                          icon: "paperplane",
                          description: "Go to your Sent folder",
                          triggers: ["sent", "sent mail"],
                          type: .menubar, menuPath: ["Mailbox", "Go To", "Sent"],
                          accentColor: "blue"),
            AdapterAction(id: "mail.goTrash",          name: "Go to Trash",
                          icon: "trash",
                          description: "Go to your Trash",
                          triggers: ["trash", "deleted"],
                          type: .menubar, menuPath: ["Mailbox", "Go To", "Trash"],
                          accentColor: "red"),
            AdapterAction(id: "mail.rebuild",          name: "Rebuild Mailbox",
                          icon: "wrench.and.screwdriver",
                          description: "Rebuild the selected mailbox",
                          triggers: ["rebuild", "rebuild mailbox"],
                          type: .menubar, menuPath: ["Mailbox", "Rebuild"],
                          accentColor: "orange"),

            // Message
            AdapterAction(id: "mail.reply",            name: "Reply",
                          icon: "arrowshape.turn.up.left",
                          description: "Reply to the selected message",
                          triggers: ["reply"],
                          type: .menubar, menuPath: ["Message", "Reply"],
                          accentColor: "blue"),
            AdapterAction(id: "mail.replyAll",         name: "Reply All",
                          icon: "arrowshape.turn.up.left.2",
                          description: "Reply to all recipients",
                          triggers: ["reply all"],
                          type: .menubar, menuPath: ["Message", "Reply All"],
                          accentColor: "blue"),
            AdapterAction(id: "mail.forward",          name: "Forward",
                          icon: "arrowshape.turn.up.right",
                          description: "Forward the selected message",
                          triggers: ["forward"],
                          type: .menubar, menuPath: ["Message", "Forward"],
                          accentColor: "blue"),
            AdapterAction(id: "mail.forwardAttach",    name: "Forward as Attachment",
                          icon: "paperclip",
                          description: "Forward message as attachment",
                          triggers: ["forward attachment", "forward as attachment"],
                          type: .menubar, menuPath: ["Message", "Forward as Attachment"],
                          accentColor: "blue"),
            AdapterAction(id: "mail.redirect",         name: "Redirect",
                          icon: "arrowshape.zigzag.right",
                          description: "Redirect message to another address",
                          triggers: ["redirect", "bounce"],
                          type: .menubar, menuPath: ["Message", "Redirect"],
                          accentColor: "teal"),
            AdapterAction(id: "mail.sendAgain",        name: "Send Again",
                          icon: "paperplane.fill",
                          description: "Resend the selected message",
                          triggers: ["resend", "send again"],
                          type: .menubar, menuPath: ["Message", "Send Again"],
                          accentColor: "blue"),
            AdapterAction(id: "mail.markRead",         name: "Mark as Read",
                          icon: "envelope.open",
                          description: "Mark selected messages as read",
                          triggers: ["mark read", "read"],
                          type: .menubar, menuPath: ["Message", "Mark", "As Read"],
                          accentColor: "blue"),
            AdapterAction(id: "mail.markUnread",       name: "Mark as Unread",
                          icon: "envelope.badge",
                          description: "Mark selected messages as unread",
                          triggers: ["mark unread", "unread"],
                          type: .menubar, menuPath: ["Message", "Mark", "As Unread"],
                          accentColor: "orange"),
            AdapterAction(id: "mail.flagRed",          name: "Flag Message",
                          icon: "flag.fill",
                          description: "Flag selected message with red flag",
                          triggers: ["flag", "mark important", "red flag"],
                          type: .menubar, menuPath: ["Message", "Flag", "Red"],
                          accentColor: "red"),
            AdapterAction(id: "mail.unflag",           name: "Unflag Message",
                          icon: "flag.slash",
                          description: "Remove flag from selected message",
                          triggers: ["unflag", "remove flag"],
                          type: .menubar, menuPath: ["Message", "Flag", "Clear Flag"],
                          accentColor: "gray"),
            AdapterAction(id: "mail.moveToJunk",       name: "Move to Junk",
                          icon: "xmark.bin",
                          description: "Move selected message to Junk",
                          triggers: ["junk", "spam"],
                          type: .menubar, menuPath: ["Message", "Move to Junk"],
                          requiresApproval: true, accentColor: "orange"),
            AdapterAction(id: "mail.mute",             name: "Mute Conversation",
                          icon: "bell.slash",
                          description: "Mute notifications for this conversation",
                          triggers: ["mute", "silence", "mute conversation"],
                          type: .menubar, menuPath: ["Message", "Mute"],
                          accentColor: "gray"),
            AdapterAction(id: "mail.archive",          name: "Archive",
                          icon: "archivebox",
                          description: "Archive the selected message",
                          triggers: ["archive", "move to archive"],
                          type: .menubar, menuPath: ["Message", "Archive"],
                          accentColor: "teal"),
            AdapterAction(id: "mail.applyRules",       name: "Apply Rules",
                          icon: "slider.horizontal.3",
                          description: "Apply mail rules to selected messages",
                          triggers: ["apply rules", "rules", "filters"],
                          type: .menubar, menuPath: ["Message", "Apply Rules"],
                          accentColor: "purple"),
            AdapterAction(id: "mail.addSender",        name: "Add Sender to Contacts",
                          icon: "person.badge.plus",
                          description: "Add sender to Contacts",
                          triggers: ["add contact", "add sender", "save contact"],
                          type: .menubar, menuPath: ["Message", "Add Sender to Contacts"],
                          accentColor: "green"),
            AdapterAction(id: "mail.removeAttachments", name: "Remove Attachments",
                          icon: "paperclip.badge.ellipsis",
                          description: "Remove attachments from selected message",
                          triggers: ["remove attachments", "delete attachments"],
                          type: .menubar, menuPath: ["Message", "Remove Attachments"],
                          requiresApproval: true, isDestructive: true, accentColor: "red"),

            // View
            AdapterAction(id: "mail.sortBy",           name: "Sort Messages",
                          icon: "arrow.up.arrow.down",
                          description: "Sort messages in the selected mailbox",
                          triggers: ["sort", "sort by", "sort messages"],
                          type: .menubar, menuPath: ["View", "Sort By"],
                          accentColor: "gray"),
            AdapterAction(id: "mail.organiseConvo",    name: "Organise by Conversation",
                          icon: "bubble.left.and.bubble.right",
                          description: "Toggle conversation grouping",
                          triggers: ["conversation", "organise conversation", "thread"],
                          type: .menubar, menuPath: ["View", "Organise by Conversation"],
                          accentColor: "blue"),
            AdapterAction(id: "mail.expandConvos",     name: "Expand All Conversations",
                          icon: "arrow.up.and.down.and.arrow.left.and.right",
                          description: "Expand all conversation threads",
                          triggers: ["expand conversations", "expand all"],
                          type: .menubar, menuPath: ["View", "Expand All Conversations"],
                          accentColor: "blue"),
            AdapterAction(id: "mail.collapseConvos",   name: "Collapse All Conversations",
                          icon: "arrow.down.right.and.arrow.up.left",
                          description: "Collapse all conversation threads",
                          triggers: ["collapse conversations", "collapse all"],
                          type: .menubar, menuPath: ["View", "Collapse All Conversations"],
                          accentColor: "blue"),
            AdapterAction(id: "mail.hideSidebar",      name: "Toggle Sidebar",
                          icon: "sidebar.left",
                          description: "Show or hide the mailbox sidebar",
                          triggers: ["sidebar", "hide sidebar", "show sidebar"],
                          type: .menubar, menuPath: ["View", "Hide Sidebar"],
                          accentColor: "gray"),
            AdapterAction(id: "mail.columnLayout",     name: "Use Column Layout",
                          icon: "rectangle.split.3x1",
                          description: "Toggle column layout for Mail",
                          triggers: ["column layout", "three column", "wide view"],
                          type: .menubar, menuPath: ["View", "Use Column Layout"],
                          accentColor: "gray"),
            AdapterAction(id: "mail.bottomPreview",    name: "Show Bottom Preview",
                          icon: "rectangle.bottomhalf.inset.filled",
                          description: "Show message preview at the bottom",
                          triggers: ["bottom preview", "preview pane"],
                          type: .menubar, menuPath: ["View", "Show Bottom Preview"],
                          accentColor: "gray"),
            AdapterAction(id: "mail.fullscreen",       name: "Enter Full Screen",
                          icon: "arrow.up.left.and.arrow.down.right",
                          description: "Enter full screen mode",
                          triggers: ["full screen", "fullscreen", "expand"],
                          type: .menubar, menuPath: ["View", "Enter Full Screen"],
                          accentColor: "gray"),

            // Window
            AdapterAction(id: "mail.messageViewer",    name: "Message Viewer",
                          icon: "tray.2",
                          description: "Show the main Message Viewer window",
                          triggers: ["message viewer", "main window", "viewer"],
                          type: .menubar, menuPath: ["Window", "Message Viewer"],
                          accentColor: "blue"),
            AdapterAction(id: "mail.previousRecipients", name: "Previous Recipients",
                          icon: "person.crop.circle.badge.clock",
                          description: "Show previous email recipients",
                          triggers: ["previous recipients", "past recipients", "recent recipients"],
                          type: .menubar, menuPath: ["Window", "Previous Recipients"],
                          accentColor: "teal"),
            AdapterAction(id: "mail.activity",         name: "Activity",
                          icon: "bolt.circle",
                          description: "Show Mail activity window",
                          triggers: ["activity", "mail activity", "sending activity"],
                          type: .menubar, menuPath: ["Window", "Activity"],
                          accentColor: "orange"),
            AdapterAction(id: "mail.connectionDoctor", name: "Connection Doctor",
                          icon: "stethoscope",
                          description: "Diagnose mail server connections",
                          triggers: ["connection doctor", "connection", "diagnose mail"],
                          type: .menubar, menuPath: ["Window", "Connection Doctor"],
                          accentColor: "red"),
            AdapterAction(id: "mail.icloudCleanup",    name: "iCloud Mail Cleanup",
                          icon: "icloud.and.arrow.down",
                          description: "Manage iCloud Mail storage",
                          triggers: ["icloud cleanup", "mail cleanup", "storage"],
                          type: .menubar, menuPath: ["Window", "iCloud Mail Cleanup"],
                          accentColor: "blue"),
            AdapterAction(id: "mail.minimize",         name: "Minimize",
                          icon: "minus.circle",
                          description: "Minimize Mail window",
                          triggers: ["minimize", "minimise"],
                          type: .menubar, menuPath: ["Window", "Minimise"],
                          accentColor: "yellow"),
        ]
    )

    // MARK: Xcode

    static let xcodeAdapter = AppAdapter(
        id: "com.apple.dt.Xcode",
        appName: "Xcode",
        bundleId: "com.apple.dt.Xcode",
        icon: "hammer",
        actions: [
            AdapterAction(id: "xcode.build",        name: "Build",
                          icon: "play.fill",
                          description: "Build the current scheme",
                          triggers: ["build", "compile"],
                          type: .menubar, menuPath: ["Product", "Build"],
                          accentColor: "green"),
            AdapterAction(id: "xcode.run",          name: "Run",
                          icon: "play.circle.fill",
                          description: "Build and run the app",
                          triggers: ["run", "launch", "play"],
                          type: .menubar, menuPath: ["Product", "Run"],
                          accentColor: "green"),
            AdapterAction(id: "xcode.test",         name: "Test",
                          icon: "checkmark.circle",
                          description: "Run the test suite",
                          triggers: ["test", "unit test", "run tests"],
                          type: .menubar, menuPath: ["Product", "Test"],
                          accentColor: "blue"),
            AdapterAction(id: "xcode.clean",        name: "Clean Build Folder",
                          icon: "trash.slash",
                          description: "Clean the build folder",
                          triggers: ["clean", "clean build", "derived data"],
                          type: .menubar, menuPath: ["Product", "Clean Build Folder…"],
                          requiresApproval: true, accentColor: "orange"),
            AdapterAction(id: "xcode.stop",         name: "Stop",
                          icon: "stop.fill",
                          description: "Stop the running app",
                          triggers: ["stop", "kill"],
                          type: .menubar, menuPath: ["Product", "Stop"],
                          accentColor: "red"),
            AdapterAction(id: "xcode.showConsole",  name: "Show Console",
                          icon: "terminal",
                          description: "Show the debug console",
                          triggers: ["console", "debug area", "logs"],
                          type: .menubar, menuPath: ["View", "Debug Area", "Show Debug Area"],
                          accentColor: "purple"),
            AdapterAction(id: "xcode.navigator",    name: "Show Navigator",
                          icon: "sidebar.left",
                          description: "Show the project navigator",
                          triggers: ["navigator", "sidebar", "file tree"],
                          type: .menubar, menuPath: ["View", "Navigators", "Show Project Navigator"],
                          accentColor: "blue"),
            AdapterAction(id: "xcode.openTerminal", name: "Open Terminal Here",
                          icon: "terminal.fill",
                          description: "Open a terminal at the project root",
                          triggers: ["terminal", "shell", "open terminal"],
                          type: .applescript,
                          script: """
tell application "Xcode"
    set proj to active workspace document
    if proj is not missing value then
        set projPath to POSIX path of (file of proj)
        set projDir to do shell script "dirname " & quoted form of projPath
        tell application "Terminal"
            activate
            do script "cd " & quoted form of projDir
        end tell
    end if
end tell
""",
                          accentColor: "green"),
            AdapterAction(id: "xcode.simulators",   name: "Open Simulator",
                          icon: "iphone",
                          description: "Open the iOS Simulator",
                          triggers: ["simulator", "ios simulator"],
                          type: .shell,
                          script: "open -a Simulator",
                          accentColor: "blue"),
        ]
    )

    // MARK: VS Code

    static let vsCodeAdapter = AppAdapter(
        id: "com.microsoft.VSCode",
        appName: "VS Code",
        bundleId: "com.microsoft.VSCode",
        icon: "chevron.left.forwardslash.chevron.right",
        actions: [
            AdapterAction(id: "vscode.newFile",     name: "New File",
                          icon: "doc.badge.plus",
                          description: "Create a new file in VS Code",
                          triggers: ["new file", "create file", "new text file"],
                          type: .menubar, menuPath: ["File", "New Text File"],
                          accentColor: "blue"),
            AdapterAction(id: "vscode.terminal",    name: "New Terminal",
                          icon: "terminal.fill",
                          description: "Open a new terminal pane",
                          triggers: ["terminal", "new terminal", "shell"],
                          type: .menubar, menuPath: ["Terminal", "New Terminal"],
                          accentColor: "green"),
            AdapterAction(id: "vscode.palette",     name: "Command Palette",
                          icon: "magnifyingglass",
                          description: "Open the VS Code command palette",
                          triggers: ["command palette", "palette", "commands"],
                          type: .menubar, menuPath: ["View", "Command Palette…"],
                          accentColor: "blue"),
            AdapterAction(id: "vscode.splitEditor", name: "Split Editor",
                          icon: "rectangle.split.2x1",
                          description: "Split the editor vertically",
                          triggers: ["split", "split editor", "side by side"],
                          type: .menubar, menuPath: ["View", "Editor Layout", "Split Up"],
                          accentColor: "teal"),
            AdapterAction(id: "vscode.explorer",    name: "File Explorer",
                          icon: "sidebar.left",
                          description: "Toggle the file explorer sidebar",
                          triggers: ["explorer", "file tree", "sidebar"],
                          type: .menubar, menuPath: ["View", "Explorer"],
                          accentColor: "blue"),
            AdapterAction(id: "vscode.extensions",  name: "Extensions",
                          icon: "puzzlepiece.extension",
                          description: "Open the extensions panel",
                          triggers: ["extensions", "plugins", "marketplace"],
                          type: .menubar, menuPath: ["View", "Extensions"],
                          accentColor: "purple"),
            AdapterAction(id: "vscode.problems",    name: "Problems Panel",
                          icon: "exclamationmark.triangle",
                          description: "Show errors and warnings",
                          triggers: ["problems", "errors", "warnings", "diagnostics"],
                          type: .menubar, menuPath: ["View", "Problems"],
                          accentColor: "yellow"),
            AdapterAction(id: "vscode.settings",    name: "Settings",
                          icon: "gear",
                          description: "Open VS Code settings",
                          triggers: ["settings", "preferences", "config"],
                          type: .menubar, menuPath: ["Code", "Settings…"],
                          accentColor: "gray"),
            AdapterAction(id: "vscode.format",      name: "Format Document",
                          icon: "text.alignleft",
                          description: "Format the current file",
                          triggers: ["format", "prettier", "beautify"],
                          type: .menubar, menuPath: ["Edit", "Format Document"],
                          accentColor: "teal"),
        ]
    )

    // MARK: Notes

    static let notesAdapter = AppAdapter(
        id: "com.apple.Notes",
        appName: "Notes",
        bundleId: "com.apple.Notes",
        icon: "note.text",
        actions: [
            AdapterAction(id: "notes.newNote",      name: "New Note",
                          icon: "square.and.pencil",
                          description: "Create a new note",
                          triggers: ["new note", "create note", "write"],
                          type: .menubar, menuPath: ["File", "New Note"],
                          accentColor: "yellow"),
            AdapterAction(id: "notes.newFolder",    name: "New Folder",
                          icon: "folder.badge.plus",
                          description: "Create a new notes folder",
                          triggers: ["new folder", "folder"],
                          type: .menubar, menuPath: ["File", "New Folder"],
                          accentColor: "blue"),
            AdapterAction(id: "notes.search",       name: "Search Notes",
                          icon: "magnifyingglass",
                          description: "Search through your notes",
                          triggers: ["search", "find note"],
                          type: .menubar, menuPath: ["Edit", "Find", "Find…"],
                          accentColor: "orange"),
            AdapterAction(id: "notes.noteFromSel",  name: "Note from Selection",
                          icon: "sparkles",
                          description: "Create a new note using selected text as AI context",
                          triggers: ["note from selection", "save selection"],
                          type: .aiPrompt,
                          aiPromptTemplate: "Create a well-formatted note from this text:\n\n$AX_SELECTED_TEXT",
                          accentColor: "indigo"),
        ]
    )

    // MARK: Calendar

    static let calendarAdapter = AppAdapter(
        id: "com.apple.iCal",
        appName: "Calendar",
        bundleId: "com.apple.iCal",
        icon: "calendar",
        actions: [
            AdapterAction(id: "cal.newEvent",       name: "New Event",
                          icon: "plus.circle",
                          description: "Create a new calendar event",
                          triggers: ["new event", "add event", "schedule"],
                          type: .menubar, menuPath: ["File", "New Event"],
                          accentColor: "red"),
            AdapterAction(id: "cal.today",          name: "Go to Today",
                          icon: "calendar.badge.clock",
                          description: "Jump to today's date",
                          triggers: ["today", "go to today", "now"],
                          type: .menubar, menuPath: ["View", "Go to Today"],
                          accentColor: "blue"),
            AdapterAction(id: "cal.dayView",        name: "Day View",
                          icon: "calendar.day.timeline.left",
                          description: "Switch to Day view",
                          triggers: ["day view", "daily"],
                          type: .menubar, menuPath: ["View", "Day"],
                          accentColor: "teal"),
            AdapterAction(id: "cal.weekView",       name: "Week View",
                          icon: "calendar",
                          description: "Switch to Week view",
                          triggers: ["week view", "weekly"],
                          type: .menubar, menuPath: ["View", "Week"],
                          accentColor: "teal"),
            AdapterAction(id: "cal.monthView",      name: "Month View",
                          icon: "calendar",
                          description: "Switch to Month view",
                          triggers: ["month view", "monthly"],
                          type: .menubar, menuPath: ["View", "Month"],
                          accentColor: "teal"),
        ]
    )

    // MARK: Messages

    static let messagesAdapter = AppAdapter(
        id: "com.apple.MobileSMS",
        appName: "Messages",
        bundleId: "com.apple.MobileSMS",
        icon: "message.fill",
        actions: [
            AdapterAction(id: "msgs.newMessage",    name: "New Message",
                          icon: "square.and.pencil",
                          description: "Compose a new iMessage",
                          triggers: ["new message", "compose", "new chat"],
                          type: .menubar, menuPath: ["File", "New Message"],
                          accentColor: "green"),
            AdapterAction(id: "msgs.attachments",   name: "Attachments Folder",
                          icon: "paperclip",
                          description: "Open the Messages attachments folder in Finder",
                          triggers: ["attachments", "files", "photos", "media"],
                          type: .applescript,
                          script: """
tell application "Finder"
    open (POSIX file (POSIX path of (path to library folder from user domain) & "Messages/Attachments/"))
    activate
end tell
""",
                          accentColor: "gray"),
            AdapterAction(id: "msgs.deleteChat",    name: "Delete Conversation",
                          icon: "trash",
                          description: "Delete the selected conversation",
                          triggers: ["delete conversation", "delete chat", "remove chat"],
                          type: .menubar, menuPath: ["Conversations", "Delete Conversation…"],
                          requiresApproval: true, isDestructive: true, accentColor: "red"),
        ]
    )

    // MARK: Photos

    static let photosAdapter = AppAdapter(
        id: "com.apple.Photos",
        appName: "Photos",
        bundleId: "com.apple.Photos",
        icon: "photo.fill",
        actions: [
            // ── File menu ──────────────────────────────────────────────────────
            AdapterAction(id: "photos.newAlbum",
                          name: "New Album",
                          icon: "rectangle.stack.badge.plus",
                          description: "Create a new album",
                          triggers: ["new album", "create album", "album"],
                          type: .menubar, menuPath: ["File", "New Album"],
                          accentColor: "blue"),
            AdapterAction(id: "photos.import",
                          name: "Import",
                          icon: "square.and.arrow.down",
                          description: "Import photos from a file or device",
                          triggers: ["import", "add photos", "bring in"],
                          type: .menubar, menuPath: ["File", "Import…"],
                          accentColor: "green"),
            AdapterAction(id: "photos.export",
                          name: "Export Photos",
                          icon: "square.and.arrow.up",
                          description: "Export selected photos",
                          triggers: ["export", "save photo", "download"],
                          type: .menubar, menuPath: ["File", "Export", "Export Photos…"],
                          accentColor: "teal"),
            AdapterAction(id: "photos.exportOriginals",
                          name: "Export Originals",
                          icon: "square.and.arrow.up.on.square",
                          description: "Export unmodified originals (full resolution, no edits)",
                          triggers: ["export original", "unmodified", "raw", "full res"],
                          type: .menubar, menuPath: ["File", "Export", "Export Unmodified Original…"],
                          accentColor: "teal"),

            // ── Edit menu ──────────────────────────────────────────────────────
            AdapterAction(id: "photos.selectAll",
                          name: "Select All",
                          icon: "checkmark.circle.fill",
                          description: "Select all photos in the current view",
                          triggers: ["select all"],
                          type: .menubar, menuPath: ["Edit", "Select All"],
                          accentColor: "blue"),
            AdapterAction(id: "photos.duplicate",
                          name: "Duplicate",
                          icon: "plus.rectangle.on.rectangle",
                          description: "Duplicate the selected photo",
                          triggers: ["duplicate", "copy photo"],
                          type: .menubar, menuPath: ["Image", "Duplicate"],
                          accentColor: "gray"),

            // ── Image menu ─────────────────────────────────────────────────────
            AdapterAction(id: "photos.rotateRight",
                          name: "Rotate Right",
                          icon: "rotate.right.fill",
                          description: "Rotate selected photo 90° clockwise",
                          triggers: ["rotate", "rotate right", "clockwise", "turn right"],
                          type: .menubar, menuPath: ["Image", "Rotate Clockwise"],
                          accentColor: "orange"),
            AdapterAction(id: "photos.rotateLeft",
                          name: "Rotate Left",
                          icon: "rotate.left.fill",
                          description: "Rotate selected photo 90° counter-clockwise",
                          triggers: ["rotate left", "counter clockwise", "turn left"],
                          type: .menubar, menuPath: ["Image", "Rotate Counter Clockwise"],
                          accentColor: "orange"),
            AdapterAction(id: "photos.autoEnhance",
                          name: "Auto Enhance",
                          icon: "wand.and.stars",
                          description: "Automatically improve brightness, contrast, and colour",
                          triggers: ["enhance", "auto enhance", "auto fix", "improve", "magic"],
                          type: .menubar, menuPath: ["Image", "Auto Enhance"],
                          accentColor: "yellow"),
            AdapterAction(id: "photos.revert",
                          name: "Revert to Original",
                          icon: "arrow.uturn.backward.circle",
                          description: "Remove ALL edits — cannot be undone",
                          triggers: ["revert", "undo all edits", "original", "reset"],
                          type: .menubar, menuPath: ["Image", "Revert to Original"],
                          requiresApproval: true, isDestructive: true, accentColor: "red"),
            AdapterAction(id: "photos.hide",
                          name: "Hide Photo",
                          icon: "eye.slash",
                          description: "Hide photo from main library (still in Hidden album)",
                          triggers: ["hide", "hide photo", "private"],
                          type: .menubar, menuPath: ["Image", "Hide Photo"],
                          requiresApproval: true, accentColor: "gray"),

            // ── Window menu ────────────────────────────────────────────────────
            AdapterAction(id: "photos.slideshow",
                          name: "Slideshow",
                          icon: "play.rectangle.fill",
                          description: "Play a full-screen slideshow of selected photos",
                          triggers: ["slideshow", "play", "present"],
                          type: .menubar, menuPath: ["Window", "Slideshow"],
                          accentColor: "purple"),

            // ── JXA — reads live data from Photos ─────────────────────────────
            AdapterAction(id: "photos.selectedInfo",
                          name: "Photo Info",
                          icon: "info.circle",
                          description: "Show names and dates of currently selected photos",
                          triggers: ["info", "details", "selected", "how many", "count"],
                          type: .jxa,
                          script: """
var Photos = Application('Photos');
var sel = Photos.selection();
if (sel.length === 0) {
  'No photos selected';
} else {
  var lines = ['Selected: ' + sel.length + ' photo(s)'];
  sel.slice(0, 5).forEach(function(p) {
    try { lines.push('• ' + p.name() + '  —  ' + p.date()); }
    catch(e) { lines.push('• (unnamed)'); }
  });
  if (sel.length > 5) lines.push('…and ' + (sel.length - 5) + ' more');
  lines.join('\\n');
}
""",
                          accentColor: "blue"),

            // ── Shell — uses env vars injected by ILauncher ────────────────────
            AdapterAction(id: "photos.showLibraryInFinder",
                          name: "Show Library in Finder",
                          icon: "folder.badge.questionmark",
                          description: "Reveal the Photos library package in Finder",
                          triggers: ["show library", "find library", "open library", "finder"],
                          type: .shell,
                          script: #"open -R "$HOME/Pictures/Photos Library.photoslibrary" 2>/dev/null || open "$HOME/Pictures/""#,
                          accentColor: "gray"),

            // ── AI Prompt — pre-fills chat with photo context ──────────────────
            AdapterAction(id: "photos.aiAsk",
                          name: "Ask AI about Photos",
                          icon: "sparkles",
                          description: "Pre-fill the AI chat with context about your current Photos session",
                          triggers: ["ask", "ai", "help", "caption", "describe"],
                          type: .aiPrompt,
                          aiPromptTemplate: "I'm in the Photos app. Window title: $WINDOW_TITLE. Help me: ",
                          accentColor: "indigo"),
        ]
    )
}
