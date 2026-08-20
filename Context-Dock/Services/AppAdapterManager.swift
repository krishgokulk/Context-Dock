//
//  AppAdapterManager.swift
//  Context-Dock
//
//  User-owned per-app action adapters: menu-bar clicks, AppleScript, JXA,
//  shell commands, URL schemes, file/app openers, script files, and AI prompts.
//
//  Adapters are stored in:
//    ~/Library/Application Support/ILauncher/AppAdapters/
//

import Foundation
import SwiftUI
import AppKit
import Combine

// MARK: - AdapterActionType

enum AdapterActionType: String, Codable, CaseIterable {
    case menubar      = "menubar"       // Click a macOS menu item via AX API
    case applescript  = "applescript"   // Run AppleScript source
    case jxa          = "jxa"           // Run JXA (JavaScript for Automation)
    case shell        = "shell"         // Run a bash command
    case cliTool      = "cliTool"       // Attach a CLI tool to the current dock workspace
    case urlScheme    = "urlScheme"     // Open a URL / deep-link
    case openItem     = "openItem"      // Open a file, folder, app, or file URL
    case scriptFile   = "scriptFile"    // Run an external script file
    case shortcut     = "shortcut"      // Run a macOS Shortcut by name
    case aiPrompt     = "aiPrompt"      // Pre-fill the AI chat with a context-aware prompt
    case pageJS       = "pageJS"        // Inject & run JavaScript in the active Safari page (userscript)

    var displayName: String {
        switch self {
        case .menubar:     return "Menu Item"
        case .applescript: return "AppleScript"
        case .jxa:         return "JavaScript for Automation"
        case .shell:       return "Terminal Command"
        case .cliTool:     return "CLI Tool"
        case .urlScheme:   return "URL / Deep Link"
        case .openItem:    return "Open Application or File"
        case .scriptFile:  return "External Script"
        case .shortcut:    return "Run Shortcut"
        case .aiPrompt:    return "AI Prompt"
        case .pageJS:      return "Browser JavaScript"
        }
    }

    /// Execution risk — drives the warning badge + approval requirement.
    var riskLevel: AdapterActionRisk {
        switch self {
        case .urlScheme, .openItem, .shortcut, .menubar: return .low
        case .aiPrompt, .pageJS: return .medium
        case .shell, .applescript, .jxa, .scriptFile, .cliTool: return .high
        }
    }
}

enum AdapterActionRisk {
    case low, medium, high
    var label: String {
        switch self {
        case .low: return "Low risk"
        case .medium: return "Medium risk"
        case .high: return "High risk"
        }
    }
    var color: String {
        switch self {
        case .low: return "green"
        case .medium: return "orange"
        case .high: return "red"
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
    var category: String?           // Optional grouping (e.g. "Network") — from adapter packs
    var type: AdapterActionType
    // Payload — only the relevant field is set for each type
    var menuPath: [String]?         // .menubar: ["File", "New Tab"]
    var script: String?             // .applescript / .jxa / .shell — inline source
    var scriptFile: String?         // External script file path (relative to AppAdapters dir, or absolute)
    var urlScheme: String?          // .urlScheme — supports $CURRENT_URL etc.
    var cliToolCommand: String?     // .cliTool — command from TerminalPackageManager
    var shortcutName: String?       // .shortcut
    var aiPromptTemplate: String?   // .aiPrompt — context vars resolved before sending
    /// Ids of actions in the *same* adapter to run, in order, before this one.
    /// e.g. a "History" navigation chains ["yt-pip"] so the playing video pops out
    /// before the page navigates away. Links are best-effort — prefix an id with `!`
    /// to make it a hard prerequisite whose failure cancels the action.
    var chain: [String]?
    // UX
    var requiresApproval: Bool      // Show confirmation dialog before executing
    var isDestructive: Bool         // Show red warning in approval UI
    var accentColor: String?        // SF Symbol accent color name (e.g. "teal", "red")

    // Hashable / Equatable by id
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
    static func == (lhs: AdapterAction, rhs: AdapterAction) -> Bool { lhs.id == rhs.id }

    init(id: String, name: String, icon: String, description: String = "",
         triggers: [String] = [], category: String? = nil, type: AdapterActionType,
         menuPath: [String]? = nil, script: String? = nil, scriptFile: String? = nil,
         urlScheme: String? = nil, cliToolCommand: String? = nil, shortcutName: String? = nil,
         aiPromptTemplate: String? = nil, chain: [String]? = nil,
         requiresApproval: Bool? = nil, isDestructive: Bool = false,
         accentColor: String? = nil) {
        self.id = id; self.name = name; self.icon = icon
        self.description = description; self.triggers = triggers; self.category = category
        self.type = type
        self.menuPath = menuPath; self.script = script; self.scriptFile = scriptFile
        self.urlScheme = urlScheme; self.cliToolCommand = cliToolCommand; self.shortcutName = shortcutName
        self.aiPromptTemplate = aiPromptTemplate; self.chain = chain
        // Unspecified means "derive from risk", not "safe". .shell / .applescript /
        // .jxa / .scriptFile / .cliTool are .high and therefore ask before running.
        self.requiresApproval = requiresApproval ?? (type.riskLevel == .high)
        self.isDestructive = isDestructive
        self.accentColor = accentColor
    }

    enum CodingKeys: String, CodingKey {
        case id, name, icon, description, triggers, category, type, menuPath, script,
             scriptFile, urlScheme, cliToolCommand, shortcutName, aiPromptTemplate,
             chain, requiresApproval, isDestructive, accentColor
    }

    // Tolerant decode: AI-generated actions may omit icon/description/triggers/flags.
    // Only id/name/type are required; everything else defaults.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        icon = try c.decodeIfPresent(String.self, forKey: .icon) ?? "bolt"
        description = try c.decodeIfPresent(String.self, forKey: .description) ?? ""
        triggers = try c.decodeIfPresent([String].self, forKey: .triggers) ?? []
        category = try c.decodeIfPresent(String.self, forKey: .category)
        type = try c.decode(AdapterActionType.self, forKey: .type)
        menuPath = try c.decodeIfPresent([String].self, forKey: .menuPath)
        script = try c.decodeIfPresent(String.self, forKey: .script)
        scriptFile = try c.decodeIfPresent(String.self, forKey: .scriptFile)
        urlScheme = try c.decodeIfPresent(String.self, forKey: .urlScheme)
        cliToolCommand = try c.decodeIfPresent(String.self, forKey: .cliToolCommand)
        shortcutName = try c.decodeIfPresent(String.self, forKey: .shortcutName)
        aiPromptTemplate = try c.decodeIfPresent(String.self, forKey: .aiPromptTemplate)
        chain = try c.decodeIfPresent([String].self, forKey: .chain)
        // An imported or AI-authored action that omits the flag does not get a free
        // pass — the default is derived from the action type's risk, so a .shell or
        // .applescript action must ask before it runs.
        requiresApproval = try c.decodeIfPresent(Bool.self, forKey: .requiresApproval)
            ?? (type.riskLevel == .high)
        isDestructive = try c.decodeIfPresent(Bool.self, forKey: .isDestructive) ?? false
        accentColor = try c.decodeIfPresent(String.self, forKey: .accentColor)
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

    // Tolerant decode: AI-generated packs (Adapter Pack Builder) legitimately omit
    // isBuiltIn / contextReaders / isEnabled / icon. Swift's synthesized Decodable would
    // throw keyNotFound on any missing non-optional key, so every generated pack would
    // fail to import. Decode identity strictly-ish (any of id/bundleId/appName), default
    // everything else.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let rid = try c.decodeIfPresent(String.self, forKey: .id)
        let rbundle = try c.decodeIfPresent(String.self, forKey: .bundleId)
        let rname = try c.decodeIfPresent(String.self, forKey: .appName)
        bundleId = rbundle ?? rid ?? ""
        id = rid ?? rbundle ?? ""
        appName = rname ?? bundleId
        icon = try c.decodeIfPresent(String.self, forKey: .icon) ?? "app.badge"
        isEnabled = try c.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        isBuiltIn = try c.decodeIfPresent(Bool.self, forKey: .isBuiltIn) ?? false
        actions = try c.decodeIfPresent([AdapterAction].self, forKey: .actions) ?? []
        contextReaders = try c.decodeIfPresent([AdapterContextReader].self, forKey: .contextReaders) ?? []
    }
}

extension AppAdapter {
    var visibleActions: [AdapterAction] {
        actions
    }
}

// MARK: - Approval request

struct AdapterActionRequest: Identifiable {
    let id = UUID()
    let action: AdapterAction
    let adapter: AppAdapter
    var onApprove: () -> Void
    var onDeny: () -> Void
    /// Approve and remember, so this action never prompts again. Nil when the
    /// action isn't eligible for a standing grant (destructive actions always ask).
    var onApproveAlways: (() -> Void)?
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
        return support.appendingPathComponent("DoraX/AppAdapters", isDirectory: true)
    }()

    /// Old location (pre-DoraX rename) — migrated into adaptersDirectory once.
    private let legacyAdaptersDirectory: URL = {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return support.appendingPathComponent("ILauncher/AppAdapters", isDirectory: true)
    }()

    /// Copy any user adapters from the old ILauncher path into the DoraX path so
    /// existing installs keep working after the rename. Runs once (skips files
    /// that already exist at the new path).
    private func migrateLegacyAdaptersIfNeeded() {
        let fm = FileManager.default
        guard fm.fileExists(atPath: legacyAdaptersDirectory.path) else { return }
        try? fm.createDirectory(at: adaptersDirectory, withIntermediateDirectories: true)
        let files = (try? fm.contentsOfDirectory(
            at: legacyAdaptersDirectory, includingPropertiesForKeys: nil)) ?? []
        for src in files where src.pathExtension.lowercased() == "json" {
            let dest = adaptersDirectory.appendingPathComponent(src.lastPathComponent)
            if !fm.fileExists(atPath: dest.path) {
                try? fm.copyItem(at: src, to: dest)
            }
        }
    }

    private let legacySampleFileNames: Set<String> = ["Photos.json", "Notion.json", "Obsidian.json", "_TEMPLATE.json"]

    private init() {
        adapters = []
        Task { await loadUserAdapters() }
    }

    // MARK: - Query helpers

    /// Return the enabled adapter for the given bundle ID, or nil.
    func adapter(for bundleId: String) -> AppAdapter? {
        adapters.first { $0.bundleId == bundleId && $0.isEnabled }
    }

    /// Return actions for a bundle ID, optionally filtered by a search query.
    func actions(for bundleId: String, query: String = "") -> [AdapterAction] {
        scoredActions(for: bundleId, query: query).map(\.action)
    }

    /// Same ranking as `actions(for:query:)`, keeping each action's match score.
    ///
    /// Callers that turn an action into a route need the score, not just the order: a score
    /// of 120 means the query *is* this action's name, while 58 can mean a single shared
    /// word ("new" in "new private window" vs. "New Tab"). Collapsing both into "best match"
    /// is how a one-word overlap got executed as if it were an exact hit.
    func scoredActions(
        for bundleId: String, query: String = ""
    ) -> [(action: AdapterAction, score: Double)] {
        guard let adapter = adapter(for: bundleId) else { return [] }
        let visibleActions = adapter.visibleActions
        guard !query.isEmpty else { return visibleActions.map { ($0, 0) } }
        let normalizedQuery = normalizedAdapterSearchText(query)
        let ranked = visibleActions.compactMap { action -> (action: AdapterAction, score: Double)? in
            let score = adapterActionMatchScore(action, query: normalizedQuery)
            guard score > 0 else { return nil }
            return (action, score)
        }

        return ranked.sorted { lhs, rhs in
            if lhs.score == rhs.score {
                return lhs.action.name.localizedCaseInsensitiveCompare(rhs.action.name) == .orderedAscending
            }
            return lhs.score > rhs.score
        }
    }

    /// Scores at or above this mean the query named the action (exact name, or one string
    /// containing the other). Below it, the match rests on partial token overlap, a category
    /// or a description — a hint worth offering, not a route worth running unprompted.
    static let adapterActionStrongMatchScore: Double = 88

    // MARK: - Execution

    /// Execute an adapter action, showing an approval sheet if needed.
    /// For `.aiPrompt` actions this returns the resolved prompt string as output
    /// so ContentView can inject it into the search field.
    func execute(_ action: AdapterAction, context: AXContext, targetBundleId: String? = nil, query: String = "") async -> (Bool, String) {
        let owningAdapter = adapters.first { $0.actions.contains { $0.id == action.id } }
        let consentBundleId = targetBundleId ?? owningAdapter?.bundleId ?? ""

        // A standing "Always Allow" grant skips the prompt. Destructive actions never
        // qualify — those re-ask every time regardless of what the user granted.
        let hasStandingGrant = !action.isDestructive
            && AdapterActionConsentStore.shared.isAllowed(bundleId: consentBundleId,
                                                          actionId: action.id)

        if action.requiresApproval && !hasStandingGrant {
            guard let adp = owningAdapter else {
                return (false, "Adapter not found")
            }
            return await withCheckedContinuation { continuation in
                let run: () -> Void = { [weak self] in
                    Task { [weak self] in
                        await MainActor.run {
                            self?.pendingApproval = nil
                        }
                        let result = await self?.runChain(action, context: context, targetBundleId: targetBundleId, query: query) ?? (false, "")
                        await MainActor.run {
                            self?.lastResult = result
                        }
                        continuation.resume(returning: result)
                    }
                }
                let request = AdapterActionRequest(
                    action: action,
                    adapter: adp,
                    onApprove: run,
                    onDeny: { [weak self] in
                        Task { @MainActor in
                            self?.pendingApproval = nil
                        }
                        continuation.resume(returning: (false, "Cancelled"))
                    },
                    onApproveAlways: action.isDestructive ? nil : {
                        AdapterActionConsentStore.shared.allowAlways(
                            bundleId: consentBundleId, actionId: action.id)
                        run()
                    }
                )
                Task { @MainActor in
                    self.pendingApproval = request
                }
            }
        }
        let result = await runChain(action, context: context, targetBundleId: targetBundleId, query: query)
        await MainActor.run {
            self.lastResult = result
        }
        return result
    }

    /// Run an action's `chain` prerequisites (in declared order) and then the action
    /// itself. Chained ids resolve within the same adapter only — a chain must never
    /// reach across apps.
    ///
    /// Links are **best-effort**: a link that fails is noted and the primary action still
    /// runs. Most chains are enhancements rather than prerequisites — YouTube's navigation
    /// actions chain "pip" so a playing video pops out before the page changes — and an
    /// aborting chain meant every one of them silently did nothing the moment Picture-in-
    /// Picture was unavailable (a Safari Web App without the extension enabled, or simply
    /// no video playing). Prefix a link id with `!` when it genuinely is a prerequisite and
    /// its failure must cancel the action.
    private func runChain(_ action: AdapterAction, context: AXContext,
                          targetBundleId: String?, query: String) async -> (Bool, String) {
        let links = action.chain ?? []
        guard !links.isEmpty else {
            return await runAction(action, context: context, targetBundleId: targetBundleId, query: query)
        }

        guard let adapter = adapters.first(where: { $0.actions.contains { $0.id == action.id } }) else {
            return await runAction(action, context: context, targetBundleId: targetBundleId, query: query)
        }

        var seen: Set<String> = [action.id]
        var skipped: [String] = []
        for rawId in links {
            let isRequired = rawId.hasPrefix("!")
            let linkId = isRequired ? String(rawId.dropFirst()) : rawId
            guard !seen.contains(linkId) else { continue }   // cycle guard
            seen.insert(linkId)
            guard let link = adapter.actions.first(where: { $0.id == linkId }) else {
                if isRequired { return (false, "Chained action not found: \(linkId)") }
                skipped.append(linkId)
                continue
            }
            let (ok, output) = await runAction(link, context: context,
                                               targetBundleId: targetBundleId, query: query)
            if !ok {
                if isRequired { return (false, "\(link.name) failed: \(output)") }
                skipped.append(link.name)
            }
        }

        let (ok, output) = await runAction(action, context: context,
                                           targetBundleId: targetBundleId, query: query)
        guard ok, !skipped.isEmpty else { return (ok, output) }
        let note = "Skipped \(skipped.joined(separator: ", "))"
        return (true, output.isEmpty ? note : "\(output) · \(note)")
    }

    // MARK: - Menu command (universal control surface)

    /// Click a verified app menu item by its menu path — the route the scoped/general AI
    /// chat uses to actually DO things (Minimize, New Tab, Export…) instead of narrating.
    /// Safe items run immediately; destructive-sounding paths (Close, Quit, Delete…) prompt
    /// once, and approving one remembers it ("allow always") so it runs unattended next time.
    /// Ask before a destructive menu command, once, and remember the answer.
    ///
    /// This lived inside `runMenuPath`, which meant it was consent belonging to one way of
    /// clicking a menu rather than to menu clicks. Anything that reached a menu item by
    /// another route — the shared executor's `.verifiedMenu`, for one — skipped it
    /// entirely. On a surface that draws no approval card of its own it is the only thing
    /// asking, so it has to be reachable from every path that clicks.
    ///
    /// Returns true when the command may proceed: not destructive, already granted, or
    /// just approved.
    func ensureMenuConsent(
        path: [String], targetBundleId: String, appName: String
    ) async -> Bool {
        let consent = AppMenuConsentStore.shared
        guard consent.isDestructive(path: path),
            !consent.isAllowed(bundleId: targetBundleId, path: path)
        else { return true }

        let label = path.joined(separator: " ▸ ")
        let action = AdapterAction(
            id: "menu:\(targetBundleId):\(path.joined(separator: ">"))",
            name: label,
            icon: "filemenu.and.selection",
            description: "Menu command in \(appName.isEmpty ? "the app" : appName)",
            type: .menubar,
            menuPath: path,
            requiresApproval: true,
            isDestructive: true)
        let adp = AppAdapter(
            id: targetBundleId, appName: appName.isEmpty ? targetBundleId : appName,
            bundleId: targetBundleId, icon: "app.badge",
            isBuiltIn: false, actions: [action])

        return await withCheckedContinuation { continuation in
            let request = AdapterActionRequest(
                action: action,
                adapter: adp,
                onApprove: { [weak self] in
                    Task { @MainActor in
                        self?.pendingApproval = nil
                        // Approving a destructive menu command grants "allow always" so
                        // DoraX runs it unattended next time.
                        AppMenuConsentStore.shared.allowAlways(
                            bundleId: targetBundleId, path: path)
                        continuation.resume(returning: true)
                    }
                },
                onDeny: { [weak self] in
                    Task { @MainActor in
                        self?.pendingApproval = nil
                        continuation.resume(returning: false)
                    }
                }
            )
            Task { @MainActor in self.pendingApproval = request }
        }
    }

    func runMenuPath(
        _ path: [String], targetBundleId: String, appName: String
    ) async -> (Bool, String) {
        let cleaned = path
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !cleaned.isEmpty else { return (false, "No menu path given") }

        guard await ensureMenuConsent(
            path: cleaned, targetBundleId: targetBundleId, appName: appName)
        else { return (false, "Cancelled") }

        let action = AdapterAction(
            id: "menu:\(targetBundleId):\(cleaned.joined(separator: ">"))",
            name: cleaned.joined(separator: " ▸ "),
            icon: "filemenu.and.selection",
            description: "Menu command in \(appName.isEmpty ? "the app" : appName)",
            type: .menubar,
            menuPath: cleaned,
            // Consent is settled above; the action's own flag would ask a second time.
            requiresApproval: false,
            isDestructive: AppMenuConsentStore.shared.isDestructive(path: cleaned))

        let result = await runAction(
            action, context: AXContext.empty, targetBundleId: targetBundleId)
        await MainActor.run { self.lastResult = result }
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
        migrateLegacyAdaptersIfNeeded()
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
            // Only skip old bundled sample files while reading the legacy ILauncher
            // directory. User-created DoraX adapters may legitimately be named
            // Photos.json, Obsidian.json, etc.; skipping them makes Create Adapter
            // appear to do nothing.
            if url.deletingLastPathComponent() == legacyAdaptersDirectory,
               legacySampleFileNames.contains(url.lastPathComponent) { continue }
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

        // De-duplicate by bundleId — keep the richest (most actions) so a stray
        // empty placeholder never shadows a real imported adapter, and the list
        // shows one row per app.
        var bestByBundle: [String: AppAdapter] = [:]
        for adapter in userAdapters {
            if let existing = bestByBundle[adapter.bundleId],
                existing.actions.count >= adapter.actions.count {
                continue
            }
            bestByBundle[adapter.bundleId] = adapter
        }
        var seen = Set<String>()
        let deduped = userAdapters.compactMap { adapter -> AppAdapter? in
            guard seen.insert(adapter.bundleId).inserted else { return nil }
            return bestByBundle[adapter.bundleId]
        }

        adapters = deduped
        mirrorVirtualScopeAdaptersIntoGlobalCommands(deduped)
        loadErrors = errors
        DoraXSpotlightIndexService.shared.scheduleRebuild(reason: "app-adapters")
        await seedStarterActionsIntoAdapters()
        await AdapterIntegrationSeeder.seedIfNeeded()
        AdapterSkillSeeder.seedIfNeeded()
    }

    /// Add the current built-in pack to every adapter once per catalog version.
    /// Existing actions win by id, preserving imports and user edits.
    private func seedStarterActionsIntoAdapters() async {
        let pending = adapters.filter {
            !$0.bundleId.hasPrefix("scope://")
                && !AdapterStarterActions.alreadySeeded($0.bundleId)
        }
        guard !pending.isEmpty else { return }
        for adapter in pending {
            var updated = adapter
            updated.actions.append(contentsOf: AdapterStarterActions.missingStarters(for: adapter))
            updated.isBuiltIn = false
            AdapterStarterActions.markSeeded(adapter.bundleId)
            persistAdapter(updated, to: adapter.sourceFileURL ?? adapterFileURL(for: updated))
        }
        await loadUserAdapters()
    }

    @discardableResult
    func mirrorVirtualScopeAdapterIntoGlobalCommands(_ adapter: AppAdapter) -> Int {
        let scopeId = adapter.bundleId.trimmingCharacters(in: .whitespacesAndNewlines)
        let adapterId = adapter.id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard scopeId.hasPrefix("scope://") || adapterId.hasPrefix("scope.") else { return 0 }

        var mirroredCount = 0
        let childCommands = adapter.actions.compactMap {
            globalSystemCommand(from: $0, adapter: adapter, scopeId: scopeId)
        }
        if let parent = globalScopeParentCommand(
            for: adapter,
            scopeId: scopeId,
            childCommands: childCommands
        ) {
            upsertMirroredSystemCommand(parent, importKey: adapterScopeParentImportKey(adapter, scopeId: scopeId))
            mirroredCount += 1
        }
        for command in childCommands {
            if let importKey = command.keywords.first(where: { $0.hasPrefix("adapter-action:") }) {
                upsertMirroredSystemCommand(command, importKey: importKey)
                mirroredCount += 1
            }
        }
        return mirroredCount
    }

    private func mirrorVirtualScopeAdaptersIntoGlobalCommands(_ adapters: [AppAdapter]) {
        for adapter in adapters {
            _ = mirrorVirtualScopeAdapterIntoGlobalCommands(adapter)
        }
    }

    private func globalSystemCommand(
        from action: AdapterAction,
        adapter: AppAdapter,
        scopeId: String
    ) -> SystemCommand? {
        let name = action.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }

        let scriptType: String
        let script: String
        switch action.type {
        case .shell, .cliTool:
            scriptType = "bash"
            script = (action.script ?? action.cliToolCommand ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        case .applescript:
            scriptType = "applescript"
            script = (action.script ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        case .shortcut:
            scriptType = "applescript"
            guard let shortcutName = action.shortcutName?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !shortcutName.isEmpty
            else { return nil }
            script = #"tell application "Shortcuts Events" to run shortcut "\#(shortcutName)""#
        case .jxa:
            scriptType = "jxa"
            script = (action.script ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        case .urlScheme:
            scriptType = "url"
            script = (action.urlScheme ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        case .openItem:
            scriptType = "file"
            script = (action.urlScheme ?? action.script ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        case .scriptFile:
            scriptType = "scriptFile"
            script = (action.scriptFile ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        case .aiPrompt:
            scriptType = "aiPrompt"
            script = (action.aiPromptTemplate ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        case .menubar, .pageJS:
            return nil
        }
        guard !script.isEmpty else { return nil }

        let importKey = adapterActionImportKey(action, adapter: adapter, scopeId: scopeId)
        var keywords = ([name, adapter.appName, adapter.id, scopeId, importKey] + action.triggers)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        keywords = Array(NSOrderedSet(array: keywords)) as? [String] ?? keywords

        return SystemCommand(
            name: name,
            icon: action.icon.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? adapter.icon
                : action.icon,
            keywords: keywords + ["adapter-child:\(scopeId.isEmpty ? adapter.id : scopeId)"],
            scriptType: scriptType,
            script: script,
            description: action.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "\(adapter.appName) action"
                : action.description,
            successTitle: name,
            successMessage: ""
        )
    }

    private func globalScopeParentCommand(
        for adapter: AppAdapter,
        scopeId: String,
        childCommands: [SystemCommand]
    ) -> SystemCommand? {
        let name = adapter.appName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !childCommands.isEmpty else { return nil }
        let normalizedScopeId = scopeId.isEmpty ? adapter.id : scopeId
        let first = childCommands[0]
        let childTerms = childCommands.flatMap { [$0.name, $0.description] + $0.keywords }
        var keywords = ([name, adapter.id, normalizedScopeId,
                         adapterScopeParentImportKey(adapter, scopeId: scopeId),
                         "adapter-scope:\(normalizedScopeId)"] + childTerms)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !$0.hasPrefix("adapter-action:") && !$0.hasPrefix("adapter-child:") }
        keywords = Array(NSOrderedSet(array: keywords)) as? [String] ?? keywords

        return SystemCommand(
            name: name,
            icon: adapter.icon.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? first.icon
                : adapter.icon,
            keywords: keywords,
            scriptType: first.scriptType,
            script: first.script,
            description: "\(childCommands.count) \(childCommands.count == 1 ? "action" : "actions")",
            successTitle: name,
            successMessage: ""
        )
    }

    private func upsertMirroredSystemCommand(_ command: SystemCommand, importKey: String) {
        if let existing = SystemCommandsRegistry.shared.commands.first(where: {
            $0.keywords.contains(importKey)
        }) {
            var updated = existing
            updated.name = command.name
            updated.icon = command.icon
            updated.keywords = command.keywords
            updated.scriptType = command.scriptType
            updated.script = command.script
            updated.description = command.description
            updated.successTitle = command.successTitle
            updated.successMessage = command.successMessage
            updated.interaction = command.interaction
            updated.sliderMin = command.sliderMin
            updated.sliderMax = command.sliderMax
            updated.sliderStep = command.sliderStep
            updated.valueScript = command.valueScript
            if updated != existing {
                SystemCommandsRegistry.shared.update(updated)
            }
        } else {
            SystemCommandsRegistry.shared.add(command)
        }
    }

    private func adapterActionImportKey(
        _ action: AdapterAction,
        adapter: AppAdapter,
        scopeId: String
    ) -> String {
        "adapter-action:\(scopeId.isEmpty ? adapter.id : scopeId):\(action.id)"
    }

    private func adapterScopeParentImportKey(_ adapter: AppAdapter, scopeId: String) -> String {
        "adapter-parent:\(scopeId.isEmpty ? adapter.id : scopeId)"
    }

    /// Create a user adapter JSON file for the given app if one does not already exist.
    /// If the app already has an in-memory adapter, persist that adapter instead of replacing it.
    func createAdapter(appName: String, bundleId: String, icon: String) async {
        let trimmedAppName = appName.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedBundleId = bundleId.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedIcon = icon.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedAppName.isEmpty, !trimmedBundleId.isEmpty else { return }

        if let existing = adapters.first(where: { $0.bundleId == trimmedBundleId }) {
            guard existing.sourceFileURL == nil else { return }

            let safeName = existing.appName.replacingOccurrences(of: "/", with: "-")
            let fileURL = adaptersDirectory.appendingPathComponent("\(safeName).json")

            var export = existing
            export.id = trimmedBundleId
            export.appName = existing.appName.isEmpty ? trimmedAppName : existing.appName
            export.bundleId = trimmedBundleId
            export.icon = existing.icon.isEmpty ? (trimmedIcon.isEmpty ? "app.fill" : trimmedIcon) : existing.icon
            export.isEnabled = true
            export.isBuiltIn = false

            persistAdapter(export, to: fileURL)
            await loadUserAdapters()
            return
        }

        let safeName = trimmedAppName.replacingOccurrences(of: "/", with: "-")
        let fileURL = adaptersDirectory.appendingPathComponent("\(safeName).json")
        let adapter = AppAdapter(
            id: trimmedBundleId,
            appName: trimmedAppName,
            bundleId: trimmedBundleId,
            icon: trimmedIcon.isEmpty ? "app.fill" : trimmedIcon,
            isEnabled: true,
            isBuiltIn: false,
            actions: AdapterStarterActions.starters(for: trimmedBundleId, appName: trimmedAppName)
        )
        AdapterStarterActions.markSeeded(trimmedBundleId)
        persistAdapter(adapter, to: fileURL)
        await loadUserAdapters()
    }

    func importAdapter(_ adapter: AppAdapter) async {
        let safeName = adapter.appName
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "-")
        let fallback = adapter.id
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "-")
        let fileName = (safeName.isEmpty ? fallback : safeName).isEmpty ? "ImportedAdapter" : (safeName.isEmpty ? fallback : safeName)
        var export = adapter
        export.id = export.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? export.bundleId : export.id
        export.appName = export.appName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? export.id : export.appName
        export.bundleId = export.bundleId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? export.id : export.bundleId
        export.icon = export.icon.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "app.fill" : export.icon
        export.isEnabled = true
        export.isBuiltIn = false

        // MERGE into an existing pack for the same app (by actionId): the AI can send a
        // follow-up pack with only NEW actions and Context-Dock adds them while keeping
        // every previously-installed action. Matching ids are updated in place; the rest
        // are preserved. (Delete the adapter first for a clean replace.)
        if let existing = adapters.first(where: { $0.bundleId == export.bundleId }) {
            var mergedActions = existing.actions
            for incoming in export.actions {
                if let idx = mergedActions.firstIndex(where: { $0.id == incoming.id }) {
                    mergedActions[idx] = incoming
                } else {
                    mergedActions.append(incoming)
                }
            }
            var mergedReaders = existing.contextReaders
            for r in export.contextReaders where !mergedReaders.contains(where: { $0.id == r.id }) {
                mergedReaders.append(r)
            }
            var merged = existing
            merged.isBuiltIn = false
            merged.isEnabled = true
            merged.actions = mergedActions
            merged.contextReaders = mergedReaders
            if merged.appName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                merged.appName = export.appName
            }
            if merged.icon.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                merged.icon = export.icon
            }
            let fileURL = existing.sourceFileURL
                ?? adaptersDirectory.appendingPathComponent("\(fileName).json")
            persistAdapter(merged, to: fileURL)
            await loadUserAdapters()
            return
        }

        let fileURL = adaptersDirectory.appendingPathComponent("\(fileName).json")
        persistAdapter(export, to: fileURL)
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

        syncCLIToolPackageIfNeeded(for: action)

        var export = base
        export.isBuiltIn = false
        export.actions = merged
        persistAdapter(export, to: fileURL)
        await loadUserAdapters()
    }

    /// Delete a custom action from an adapter (no-op for pure built-in adapters with no user file).
    func deleteAdapter(bundleId: String) async {
        guard let adapter = adapters.first(where: { $0.bundleId == bundleId }) else { return }
        if let url = adapter.sourceFileURL {
            try? FileManager.default.removeItem(at: url)
        } else {
            let safe = adapter.appName.replacingOccurrences(of: "/", with: "-")
            let url = adaptersDirectory.appendingPathComponent("\(safe).json")
            try? FileManager.default.removeItem(at: url)
        }
        await loadUserAdapters()
    }

    // MARK: - Adapter pack install / CRUD

    /// Install an imported adapter pack: replace any existing adapter for the same
    /// bundle id, write it as a single JSON file, and reload the in-memory index.
    /// Returns false if the installed adapter isn't present afterwards.
    @discardableResult
    func installImportedAdapter(_ adapter: AppAdapter) async -> Bool {
        let fm = FileManager.default
        try? fm.createDirectory(at: adaptersDirectory, withIntermediateDirectories: true)

        // Remove any existing on-disk adapter files for this bundle id (e.g. a
        // placeholder "System Settings.json" with 0 actions) so the import isn't
        // shadowed by a duplicate with the same bundleId.
        let existingFiles = (try? fm.contentsOfDirectory(
            at: adaptersDirectory, includingPropertiesForKeys: nil)) ?? []
        for file in existingFiles where file.pathExtension.lowercased() == "json" {
            if let data = try? Data(contentsOf: file),
                let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                (obj["bundleId"] as? String) == adapter.bundleId {
                try? fm.removeItem(at: file)
            }
        }

        let fileURL = adapterFileURL(for: adapter)
        persistAdapter(adapter, to: fileURL)
        let wrote = fm.fileExists(atPath: fileURL.path)
        await loadUserAdapters()
        return wrote && adapters.contains {
            $0.bundleId == adapter.bundleId && !$0.actions.isEmpty
        }
    }

    /// Duplicate an adapter under a new bundle id + name.
    func duplicateAdapter(bundleId: String) async {
        guard let base = adapters.first(where: { $0.bundleId == bundleId }) else { return }
        var copy = base
        copy.bundleId = "\(base.bundleId).copy"
        copy.id = copy.bundleId
        copy.appName = "\(base.appName) Copy"
        copy.isBuiltIn = false
        copy.sourceFileURL = nil
        persistAdapter(copy, to: adapterFileURL(for: copy))
        await loadUserAdapters()
    }

    /// Rename an adapter's display name.
    func renameAdapter(bundleId: String, to newName: String) async {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
            let base = adapters.first(where: { $0.bundleId == bundleId }) else { return }
        var updated = base
        updated.appName = trimmed
        updated.isBuiltIn = false
        persistAdapter(updated, to: base.sourceFileURL ?? adapterFileURL(for: updated))
        await loadUserAdapters()
    }

    /// The on-disk JSON URL for an adapter (existing source file or a name-derived path).
    func exportFileURL(for bundleId: String) -> URL? {
        guard let adapter = adapters.first(where: { $0.bundleId == bundleId }) else { return nil }
        if let url = adapter.sourceFileURL, FileManager.default.fileExists(atPath: url.path) {
            return url
        }
        let url = adapterFileURL(for: adapter)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private func adapterFileURL(for adapter: AppAdapter) -> URL {
        let safe = adapter.bundleId.isEmpty
            ? adapter.appName.replacingOccurrences(of: "/", with: "-")
            : adapter.bundleId
        return adaptersDirectory.appendingPathComponent("\(safe).json")
    }

    func deleteAction(id actionId: String, from bundleId: String) async {
        guard let base = adapters.first(where: { $0.bundleId == bundleId }) else { return }
        let safe = base.appName.replacingOccurrences(of: "/", with: "-")
        let fileURL = base.sourceFileURL
            ?? adaptersDirectory.appendingPathComponent("\(safe).json")

        let filtered = base.actions.filter { $0.id != actionId }
        var export = base
        export.isBuiltIn = false
        export.actions = filtered
        persistAdapter(export, to: fileURL)
        await loadUserAdapters()
    }

    // MARK: - Private execution

    private func syncCLIToolPackageIfNeeded(for action: AdapterAction) {
        guard action.type == .cliTool else { return }
        let command = action.cliToolCommand?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !command.isEmpty else { return }

        let packageManager = TerminalPackageManager.shared
        if let index = packageManager.packages.firstIndex(where: {
            $0.command.caseInsensitiveCompare(command) == .orderedSame
        }) {
            var package = packageManager.packages[index]
            let cleanedName = action.name.trimmingCharacters(in: .whitespacesAndNewlines)
            if package.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !cleanedName.isEmpty {
                package.name = cleanedName
            }
            if package.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                !action.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            {
                package.description = action.description
            }
            let mergedKeywords = Array(
                Set((package.keywords + action.triggers + [command, cleanedName]).filter { !$0.isEmpty })
            ).sorted()
            if mergedKeywords != package.keywords {
                package.keywords = mergedKeywords
            }
            packageManager.updatePackage(package)
            return
        }

        let cleanedName = action.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let package = TerminalPackage(
            name: cleanedName.isEmpty ? command : cleanedName,
            command: command,
            description: action.description.isEmpty ? "Added from App Actions" : action.description,
            keywords: Array(Set((action.triggers + [command, cleanedName]).filter { !$0.isEmpty })).sorted()
        )
        packageManager.addPackage(package)
    }

    private func persistAdapter(_ adapter: AppAdapter, to fileURL: URL) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        var export = adapter
        export.isBuiltIn = false
        if let data = try? encoder.encode(export),
           var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            json["isBuiltIn"] = false
            if let pretty = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]) {
                try? pretty.write(to: fileURL)
            }
        }
    }

    private func runAction(_ action: AdapterAction, context: AXContext, targetBundleId: String? = nil, query: String = "") async -> (Bool, String) {
        switch action.type {

        case .menubar:
            guard let path = action.menuPath else { return (false, "No menu path defined") }
            // Counted before resolveOrLaunchTargetApp, which may launch the app: one that
            // had to be started has not published its menu bar to accessibility by the
            // time it reports itself launched, and needs the longer wait.
            let wasRunning = targetBundleId.map { id in
                NSWorkspace.shared.runningApplications.contains {
                    $0.bundleIdentifier == id && !$0.isTerminated
                }
            } ?? true
            let explicitTargetApp = await resolveOrLaunchTargetApp(for: targetBundleId)
            let targetApp = explicitTargetApp ?? AppDelegate.shared?.previousFrontmostApp
            guard let frontApp = targetApp, let bundleID = frontApp.bundleIdentifier else {
                return (false, "No target app")
            }
            // This was `AXActionResolver.execute(…)` followed by `return (true, "Done")` —
            // a blind click that could not fail. Context Dock Chat reported "Done" for menu
            // commands that were greyed out, absent from the app, or sent somewhere else
            // entirely, and nothing downstream could tell the difference.
            //
            // The coordinator checks the item is present and enabled before clicking, tries
            // the item's own shortcut first, and says what actually happened. It is the same
            // one General AI's .verifiedMenu route uses, so the app now has one
            // menu-clicking implementation instead of two that disagreed about honesty.
            //
            // Some previously "successful" actions will start reporting failure. Those were
            // already failing; only the report is new.
            return await MenuExecutionCoordinator.shared.executeVerifiedMenuAction(
                bundleIdentifier: bundleID,
                path: path,
                allowSlowMenuBar: !wasRunning)

        case .applescript:
            guard let script = action.script else { return (false, "No script defined") }
            let appleScriptFile = action.scriptFile.flatMap { resolveScriptFile($0) }
            return await runAppleScript(inject(script, context: context, query: query), scriptFile: appleScriptFile)

        case .jxa:
            guard let script = action.script else { return (false, "No script defined") }
            let jxaFile = action.scriptFile.flatMap { resolveScriptFile($0) }
            return await runJXA(inject(script, context: context, query: query), scriptFile: jxaFile, context: context)

        case .shell:
            let shellFile = action.scriptFile.flatMap { resolveScriptFile($0) }
            let inlineScript = action.script.map { inject($0, context: context, query: query) } ?? ""
            guard shellFile != nil || !inlineScript.isEmpty else { return (false, "No script defined") }
            // Long-running download-style commands stream a live progress bar.
            let lower = (inlineScript + " " + action.id).lowercased()
            let showsProgress =
                lower.contains("yt-dlp") || lower.contains("youtube-dl")
                || lower.contains("wget") || lower.contains("curl -o")
                || lower.contains("download")
            return await runShell(
                inlineScript, scriptFile: shellFile, context: context,
                progressLabel: showsProgress ? action.name : nil, query: query)

        case .cliTool:
            guard let command = action.cliToolCommand, !command.isEmpty else {
                return (false, "No CLI tool selected")
            }
            return (true, command)

        case .urlScheme:
            guard let scheme = action.urlScheme else { return (false, "No URL scheme defined") }
            let resolved = inject(scheme, context: context, query: query)
            if let url = URL(string: resolved) {
                NSWorkspace.shared.open(url)
                return (true, "Opened: \(resolved)")
            }
            return (false, "Invalid URL: \(resolved)")

        case .openItem:
            guard let rawTarget = action.scriptFile ?? action.script ?? action.urlScheme, !rawTarget.isEmpty else {
                return (false, "No target path defined")
            }
            let resolvedTarget = inject(rawTarget, context: context, query: query)
            return openResolvedTarget(resolvedTarget)

        case .scriptFile:
            guard let rawPath = action.scriptFile ?? action.script, !rawPath.isEmpty else {
                return (false, "No script file defined")
            }
            let resolvedPath = inject(rawPath, context: context, query: query)
            return await runExternalScriptFile(resolvedPath, context: context, query: query)

        case .shortcut:
            guard let name = action.shortcutName else { return (false, "No shortcut name") }
            return await runShell("shortcuts run \"\(name)\"", context: context)

        case .aiPrompt:
            // ContentView handles this type: we return the resolved prompt so it can be injected
            let tmpl = action.aiPromptTemplate ?? action.description
            return (true, inject(tmpl, context: context, query: query))

        case .pageJS:
            guard let script = action.script, !script.isEmpty else {
                return (false, "No page script defined")
            }
            // Resolve context vars (including $PAGE_TEXT and $SELECTED_TEXT from bridge)
            let resolved = injectPageContext(script, context: context, query: query)

            let owner = targetBundleId
                ?? adapters.first { $0.actions.contains { $0.id == action.id } }?.bundleId
            let isWebApp = owner?.hasPrefix("com.apple.Safari.WebApp.") ?? false

            // Preferred path: run it through our own Safari Web Extension. This is the
            // only route that reaches a Safari Web App (they have no AppleScript
            // dictionary) and the only one that carries user activation.
            if let owner, let app = await resolveOrLaunchTargetApp(for: owner),
               await SafariExtensionCommandBridge.shared.isAvailable(in: app) {
                do {
                    // "pip" runs as a real function rather than injected source — gated
                    // media APIs need the activation that only a genuine call carries.
                    let output = isPictureInPictureScript(resolved)
                        ? try await SafariExtensionCommandBridge.shared.requestPictureInPicture(in: app)
                        : try await SafariExtensionCommandBridge.shared.runJavaScript(resolved, in: app)
                    if output.hasPrefix("JS error:") { return (false, output) }
                    return (true, output.isEmpty ? "Script executed" : output)
                } catch {
                    if isWebApp {
                        // No AppleScript fallback exists for web apps — report honestly.
                        return (false, error.localizedDescription)
                    }
                    // Real Safari: fall through to AppleScript below.
                }
            } else if isWebApp {
                return (false, """
                Context Dock isn't enabled as an extension in this web app. Open it, go to \
                Settings ▸ Extensions, turn on Context Dock and allow it for this site — \
                web apps expose no AppleScript interface, so there is no other route in.
                """)
            }
            // Execute directly in the active Safari page via SafariTabManager
            let result = await SafariTabManager.shared.executeJS(resolved)
            if result == nil {
                return (false, "Failed to write script to disk")
            }
            let output = result!
            if output.hasPrefix("JS error:") {
                let hint = output.contains("1728") || output.contains("not allowed") || output.contains("JavaScript from Apple Events")
                    ? "\(output)\n\nTip: In Safari, go to Develop menu → Allow JavaScript from Apple Events"
                    : output
                return (false, hint)
            }
            return (true, output.isEmpty ? "Script executed" : output)
        }
    }

    /// A userscript whose whole job is Picture-in-Picture. Detected so it can be run as a
    /// native function instead of injected source: `requestPictureInPicture()` demands
    /// transient user activation, which survives a real call but not an eval'd string.
    private func isPictureInPictureScript(_ source: String) -> Bool {
        let lower = source.lowercased()
        return lower.contains("requestpictureinpicture")
            || lower.contains("webkitsetpresentationmode")
    }

    private func resolvedTargetApp(for bundleId: String?) -> NSRunningApplication? {
        guard let bundleId, !bundleId.isEmpty else { return nil }

        let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId)
            .first { !$0.isTerminated }
        return running
    }

    /// Launch (or return the already-running) app for a bundle id, activating it. Public so
    /// General Chat can open a picked-but-closed focus app before warming its menu cache.
    func launchAndActivate(bundleId: String) async -> NSRunningApplication? {
        await resolveOrLaunchTargetApp(for: bundleId)
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

    private func adapterActionMatchScore(_ action: AdapterAction, query: String) -> Double {
        guard !query.isEmpty else { return 0 }

        let normalizedName = normalizedAdapterSearchText(action.name)
        let normalizedDescription = normalizedAdapterSearchText(action.description)
        let normalizedTriggers = action.triggers.map(normalizedAdapterSearchText)
        let normalizedCLICommand = normalizedAdapterSearchText(action.cliToolCommand ?? "")

        var score = 0.0

        if normalizedName == query {
            score = max(score, 120)
        }

        if normalizedName.contains(query) || query.contains(normalizedName) {
            score = max(score, 88)
        }

        let nameOverlap = tokenOverlapScore(normalizedName, query)
        if nameOverlap > 0 {
            score = max(score, 36 + Double(nameOverlap * 22))
        }

        // Category match ranks above description, below keyword (ranking tier 4).
        if let category = action.category, !category.isEmpty {
            let normalizedCategory = normalizedAdapterSearchText(category)
            if normalizedCategory == query {
                score = max(score, 72)
            } else if normalizedCategory.contains(query) || query.contains(normalizedCategory) {
                score = max(score, 50)
            }
            let categoryOverlap = tokenOverlapScore(normalizedCategory, query)
            if categoryOverlap > 0 {
                score = max(score, 22 + Double(categoryOverlap * 12))
            }
        }

        if !normalizedDescription.isEmpty {
            if normalizedDescription.contains(query) || query.contains(normalizedDescription) {
                score = max(score, 62)
            }
            let descriptionOverlap = tokenOverlapScore(normalizedDescription, query)
            if descriptionOverlap > 0 {
                score = max(score, 18 + Double(descriptionOverlap * 12))
            }
        }

        if !normalizedCLICommand.isEmpty {
            if normalizedCLICommand == query {
                score = max(score, 126)
            }
            if normalizedCLICommand.contains(query) || query.contains(normalizedCLICommand) {
                score = max(score, 100)
            }
            let cliOverlap = tokenOverlapScore(normalizedCLICommand, query)
            if cliOverlap > 0 {
                score = max(score, 44 + Double(cliOverlap * 20))
            }
        }

        for trigger in normalizedTriggers where !trigger.isEmpty {
            if trigger == query {
                score = max(score, 130)
            }
            if trigger.contains(query) || query.contains(trigger) {
                score = max(score, 96)
            }
            let triggerOverlap = tokenOverlapScore(trigger, query)
            if triggerOverlap > 0 {
                score = max(score, 42 + Double(triggerOverlap * 20))
            }
        }

        return score
    }

    private func normalizedAdapterSearchText(_ text: String) -> String {
        let lowered = text.lowercased()
        let scalars = lowered.unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) ? Character(scalar) : " "
        }
        return String(scalars)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    private func tokenOverlapScore(_ lhs: String, _ rhs: String) -> Int {
        let leftTokens = Set(lhs.split(separator: " ").map(String.init))
        let rightTokens = Set(rhs.split(separator: " ").map(String.init))
        return leftTokens.intersection(rightTokens).count
    }

    // MARK: - Script runners

    /// Resolve a scriptFile path: absolute paths pass through; relative paths anchor to AppAdapters dir.
    private func resolveScriptFile(_ path: String) -> URL? {
        guard !path.isEmpty else { return nil }
        if path.hasPrefix("/") { return URL(fileURLWithPath: path) }
        return adaptersDirectory.appendingPathComponent(path)
    }

    private func resolveOpenTarget(_ target: String) -> URL? {
        let trimmed = target.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let url = URL(string: trimmed), url.scheme != nil {
            return url
        }

        let expanded = (trimmed as NSString).expandingTildeInPath
        if expanded.hasPrefix("/") {
            return URL(fileURLWithPath: expanded)
        }

        return adaptersDirectory.appendingPathComponent(trimmed)
    }

    private func openResolvedTarget(_ target: String) -> (Bool, String) {
        guard let url = resolveOpenTarget(target) else {
            return (false, "Invalid target: \(target)")
        }

        if url.isFileURL {
            guard FileManager.default.fileExists(atPath: url.path) else {
                return (false, "File not found: \(url.path)")
            }
            let ok = NSWorkspace.shared.open(url)
            return (ok, ok ? "Opened: \(url.lastPathComponent)" : "Could not open \(url.lastPathComponent)")
        }

        let ok = NSWorkspace.shared.open(url)
        return (ok, ok ? "Opened: \(target)" : "Could not open \(target)")
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

    private func runShell(
        _ script: String, scriptFile: URL? = nil, context: AXContext,
        progressLabel: String? = nil, query: String? = nil
    ) async -> (Bool, String) {
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
            // The user's natural-language request, so a script-file adapter can parameterize
            // itself ($CD_QUERY) — e.g. a weather skill reading the location from it. Opt-in:
            // scripts that ignore it behave exactly as before.
            if let q = query?.trimmingCharacters(in: .whitespacesAndNewlines), !q.isEmpty {
                env["CD_QUERY"] = q
            }
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

            // Progress-reporting actions (yt-dlp, curl…) stream their output; parse a
            // trailing percentage and drive a determinate progress toast live.
            let toastID = "adapter-progress-\(UUID().uuidString)"
            if let label = progressLabel {
                Task { @MainActor in
                    AppToast.showProgress(label, id: toastID, progress: 0, tint: .blue)
                }
                var collected = Data()
                pipe.fileHandleForReading.readabilityHandler = { handle in
                    let chunk = handle.availableData
                    guard !chunk.isEmpty else { return }
                    collected.append(chunk)
                    guard let text = String(data: chunk, encoding: .utf8) else { return }
                    if let pct = Self.lastPercentage(in: text) {
                        Task { @MainActor in
                            AppToast.updateProgress(id: toastID, progress: pct / 100.0)
                        }
                    }
                }
                do {
                    try task.run()
                } catch {
                    pipe.fileHandleForReading.readabilityHandler = nil
                    Task { @MainActor in AppToast.hide() }
                    return (false, error.localizedDescription)
                }
                task.waitUntilExit()
                pipe.fileHandleForReading.readabilityHandler = nil
                let ok = task.terminationStatus == 0
                Task { @MainActor in
                    if ok {
                        AppToast.finishProgress(
                            id: toastID, message: "\(label) — done",
                            icon: "checkmark.circle", tint: .green)
                    } else {
                        AppToast.finishProgress(
                            id: toastID, message: "\(label) — failed",
                            icon: "exclamationmark.triangle", tint: .red)
                    }
                }
                let out = String(data: collected, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return (ok, out.isEmpty ? "Done" : out)
            }

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

    /// Extract the last "NN.N%" figure from a chunk of command output (yt-dlp, curl…).
    nonisolated private static func lastPercentage(in text: String) -> Double? {
        var last: Double?
        var index = text.startIndex
        while let range = text.range(of: #"(\d{1,3}(?:\.\d+)?)%"#, options: .regularExpression, range: index..<text.endIndex) {
            let match = text[range].dropLast()  // strip %
            if let value = Double(match), value >= 0, value <= 100 { last = value }
            index = range.upperBound
        }
        return last
    }

    private func runExternalScriptFile(
        _ rawPath: String, context: AXContext, query: String? = nil
    ) async -> (Bool, String) {
        guard let fileURL = resolveScriptFile(rawPath) ?? resolveOpenTarget(rawPath) else {
            return (false, "Invalid script file: \(rawPath)")
        }
        guard fileURL.isFileURL, FileManager.default.fileExists(atPath: fileURL.path) else {
            return (false, "Script file not found: \(fileURL.path)")
        }

        switch fileURL.pathExtension.lowercased() {
        case "sh", "bash", "zsh":
            return await runShell("", scriptFile: fileURL, context: context, query: query)
        case "py":
            return await runProcess(
                executable: "/usr/bin/env",
                arguments: ["python3", fileURL.path],
                context: context, query: query
            )
        case "js":
            return await runJXA("", scriptFile: fileURL, context: context)
        case "rb":
            return await runProcess(
                executable: "/usr/bin/env",
                arguments: ["ruby", fileURL.path],
                context: context, query: query
            )
        case "scpt", "applescript":
            return await runAppleScript("", scriptFile: fileURL)
        default:
            return await runProcess(
                executable: fileURL.path, arguments: [], context: context, query: query)
        }
    }

    private func runProcess(
        executable: String, arguments: [String], context: AXContext, query: String? = nil
    ) async -> (Bool, String) {
        await Task.detached(priority: .userInitiated) { () -> (Bool, String) in
            let task = Process()
            task.executableURL = URL(fileURLWithPath: executable)
            task.arguments = arguments
            var env = ProcessInfo.processInfo.environment
            env["PATH"] = "/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:" + (env["PATH"] ?? "")
            env["FRONTMOST_APP"] = context.appName
            env["FRONTMOST_BUNDLE"] = context.bundleId
            if let url = context.currentURL { env["CURRENT_URL"] = url }
            if let title = context.windowTitle { env["WINDOW_TITLE"] = title }
            if let sel = context.selectedText { env["AX_SELECTED_TEXT"] = sel }
            if let q = query?.trimmingCharacters(in: .whitespacesAndNewlines), !q.isEmpty {
                env["CD_QUERY"] = q
            }
            task.environment = env
            task.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser

            let pipe = Pipe()
            task.standardOutput = pipe
            task.standardError = pipe

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

    // MARK: - Context readers

    /// Run all contextReaders for the given adapter and return their output keyed by reader id.
    /// Called when L2 opens so the AI has richer, app-specific context.
    func runContextReaders(for bundleId: String, axContext: AXContext) async -> [String: String] {
        guard let adapter = adapter(for: bundleId) else { return [:] }
        var results: [String: String] = [:]
        for reader in adapter.contextReaders {
            let (ok, output) = await runReader(reader, context: axContext)
            if ok, !output.isEmpty { results[reader.id] = output }
        }
        return results
    }

    private func runReader(_ reader: AdapterContextReader, context: AXContext) async -> (Bool, String) {
        switch reader.type {
        case "applescript": return await runAppleScript(reader.script)
        case "jxa":         return await runJXA(reader.script, context: context)
        case "shell":       return await runShell(reader.script, context: context)
        default:            return (false, "Unknown reader type: \(reader.type)")
        }
    }

    // MARK: - Auto-generate adapter from menu tree

    private var autoGeneratedBundleIds: Set<String> = []

    /// If the frontmost app has no adapter, build a synthetic one from its live menu tree.
    /// Stored only in memory (not on disk) — vanishes on app restart, which is intentional.
    func autoGenerateAdapterIfNeeded(for app: NSRunningApplication) async {
        // Disabled: DoraX ships NO default adapter actions. Apps surface their commands
        // through the live menu pipeline; App Adapters only hold user-added actions.
        return

        guard let bundleId = app.bundleIdentifier, !bundleId.isEmpty,
              let appName  = app.localizedName,    !appName.isEmpty else { return }
        guard adapter(for: bundleId) == nil,
              !autoGeneratedBundleIds.contains(bundleId) else { return }

        autoGeneratedBundleIds.insert(bundleId)

        let pid = app.processIdentifier
        let menuItems = await MainActor.run {
            AXMenuReader.shared.allMenuItems(for: pid, maxDepth: 5)
        }

        guard !menuItems.isEmpty else { return }

        let generated = buildSyntheticAdapter(appName: appName, bundleId: bundleId, menuItems: menuItems)
        adapters.append(generated)
    }

    private func buildSyntheticAdapter(appName: String, bundleId: String,
                                       menuItems: [AXMenuItem]) -> AppAdapter {
        // Build one AdapterAction per menu leaf — limit to 40 most useful items.
        // Filter out recent-files / Open-Recent / reveal entries first: the Apple menu's
        // "Recent Items" (and apps' "Open Recent") list documents/apps/folders that are
        // NOT real actions (e.g. "Visual Studio Code.app", ".hammerspoon",
        // "Show "X" in Finder") and were polluting every adapter with garbage.
        let actions: [AdapterAction] = menuItems
            .filter { Self.isUsefulAdapterMenuItem($0) }
            .prefix(40).compactMap { item in
            guard !item.title.isEmpty else { return nil }
            let words = item.title.lowercased()
                .components(separatedBy: .init(charactersIn: " /…-"))
                .filter { $0.count > 1 }
            let parentBadge = item.path.dropLast().last ?? ""
            return AdapterAction(
                id: "\(bundleId).\(item.title.lowercased().replacingOccurrences(of: " ", with: "_"))",
                name: item.title,
                icon: syntheticMenuIcon(for: item.title),
                description: parentBadge.isEmpty ? item.title : "\(parentBadge) › \(item.title)",
                triggers: words,
                type: .menubar,
                menuPath: item.path,
                accentColor: nil
            )
        }

        return AppAdapter(
            id: bundleId, appName: appName, bundleId: bundleId,
            icon: "square.grid.2x2", isEnabled: true, isBuiltIn: false,
            actions: actions
        )
    }

    /// True for genuine action menu items; false for recent-files / file-path / reveal
    /// entries that pollute auto-generated adapters.
    static func isUsefulAdapterMenuItem(_ item: AXMenuItem) -> Bool {
        let title = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return false }
        let lower = title.lowercased()
        // Reveal companions and app/dotfile/path-looking titles.
        if lower.contains(" in finder") { return false }
        if lower.hasSuffix(".app") { return false }
        if title.hasPrefix(".") || title.hasPrefix("~") || title.contains("/") { return false }
        // file.ext-looking titles (short trailing extension), e.g. "report.pdf".
        if let dot = title.lastIndex(of: "."), dot != title.startIndex {
            let ext = title[title.index(after: dot)...]
            if (2...5).contains(ext.count), ext.allSatisfy({ $0.isLetter || $0.isNumber }) {
                return false
            }
        }
        // Anything living under a Recent/Open-Recent submenu.
        let pathLower = item.path.map { $0.lowercased() }
        if pathLower.contains(where: {
            $0.contains("recent") || $0 == "open recent" || $0.contains("recently")
        }) {
            return false
        }
        return true
    }

    private func syntheticMenuIcon(for title: String) -> String {
        let t = title.lowercased()
        if t.contains("new")    { return "plus.square" }
        if t.contains("open")   { return "folder" }
        if t.contains("save")   { return "square.and.arrow.down" }
        if t.contains("close")  { return "xmark.circle" }
        if t.contains("copy")   { return "doc.on.doc" }
        if t.contains("paste")  { return "clipboard" }
        if t.contains("cut")    { return "scissors" }
        if t.contains("undo")   { return "arrow.uturn.backward" }
        if t.contains("redo")   { return "arrow.uturn.forward" }
        if t.contains("find") || t.contains("search") { return "magnifyingglass" }
        if t.contains("print")  { return "printer" }
        if t.contains("share")  { return "square.and.arrow.up" }
        if t.contains("zoom")   { return "arrow.up.left.and.arrow.down.right" }
        if t.contains("prefer") || t.contains("setting") { return "gearshape" }
        if t.contains("quit") || t.contains("exit") { return "power" }
        if t.contains("help")   { return "questionmark.circle" }
        if t.contains("view")   { return "eye" }
        if t.contains("format") { return "textformat" }
        if t.contains("insert") { return "plus.circle" }
        if t.contains("window") { return "macwindow" }
        return "menubar.rectangle"
    }

    // MARK: - Context variable injection

    private func inject(_ text: String, context: AXContext, query: String = "") -> String {
        var s = text
        s = s.replacingOccurrences(of: "$CURRENT_URL",      with: context.currentURL   ?? "")
        s = s.replacingOccurrences(of: "$WINDOW_TITLE",     with: context.windowTitle  ?? "")
        s = s.replacingOccurrences(of: "$AX_SELECTED_TEXT", with: context.selectedText ?? "")
        s = s.replacingOccurrences(of: "$APP_NAME",         with: context.appName)
        s = s.replacingOccurrences(of: "$BUNDLE_ID",        with: context.bundleId)
        s = s.replacingOccurrences(of: "{{query}}",         with: query)
        return s
    }

    // Like inject(), but also resolves $PAGE_TEXT and $SELECTED_TEXT from SafariBrowserBridge.
    private func injectPageContext(_ text: String, context: AXContext, query: String = "") -> String {
        let bridge = SafariBrowserBridge.shared
        var s = inject(text, context: context, query: query)
        s = s.replacingOccurrences(of: "$PAGE_TEXT",     with: bridge.latestContext?.pageTextForAI ?? "")
        s = s.replacingOccurrences(of: "$SELECTED_TEXT", with: bridge.latestContext?.selectedText  ?? "")
        s = s.replacingOccurrences(of: "$PAGE_TITLE",    with: bridge.latestContext?.title         ?? "")
        return s
    }
}
