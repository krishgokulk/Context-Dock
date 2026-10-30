// AppPetManifest.swift
// Context-Dock
//
// Schema and loading for App Pet manifests and /mods behavior presets (#341).
// Follows canonical design (docs/superpowers/specs/2026-10-27-app-pets-combined-chat-design.md §4 & §7).

import AppKit
import Foundation
import OSLog

// MARK: - Plan Detail & Verification Emphasis

/// Detail level requested for the planning and reasoning phase of an App Pet turn.
enum AppPetPlanDetail: String, Codable, Hashable, Sendable, CaseIterable {
    case concise
    case normal
    case detailed
    case stepByStep

    var promptInstruction: String {
        switch self {
        case .concise:
            return "Planning emphasis: Be concise and direct. State only the direct outcome."
        case .normal:
            return "Planning emphasis: Standard plan clarity."
        case .detailed:
            return "Planning emphasis: Provide structured reasoning and comprehensive explanations."
        case .stepByStep:
            return "Planning emphasis: Break down the plan into explicit, verifiable steps."
        }
    }
}

/// Verification emphasis requested for an App Pet turn.
enum AppPetVerificationEmphasis: String, Codable, Hashable, Sendable, CaseIterable {
    case standard
    case strictReceipt
    case verifyBeforeAnswer

    var promptInstruction: String {
        switch self {
        case .standard:
            return "Verification emphasis: Standard verification."
        case .strictReceipt:
            return "Verification emphasis: Require explicit verifiable receipts before reporting success."
        case .verifyBeforeAnswer:
            return "Verification emphasis: Re-read and verify actual machine state before producing the final response."
        }
    }
}

// MARK: - Tool Parameter & Custom Tool

/// A typed parameter definition for a custom tool declared by an App Pet manifest.
struct AppPetToolParameter: Codable, Hashable, Sendable {
    let name: String
    let type: String
    let description: String
    let required: Bool

    init(name: String, type: String = "string", description: String, required: Bool = true) {
        self.name = name
        self.type = type
        self.description = description
        self.required = required
    }
}

/// A custom tool declared by an App Pet manifest or mode.
///
/// Safety invariant: Declaring a tool can NEVER widen scope outside the Pet's authorized app
/// or bypass host approval policies. Action and execution gates apply equally to custom tools.
struct AppPetCustomTool: Codable, Hashable, Sendable, Identifiable {
    let id: String
    let name: String
    let description: String
    let commandTemplate: String?
    let parameters: [AppPetToolParameter]
    let isReadOnly: Bool
    let appBundleID: String?

    init(
        id: String,
        name: String,
        description: String,
        commandTemplate: String? = nil,
        parameters: [AppPetToolParameter] = [],
        isReadOnly: Bool = true,
        appBundleID: String? = nil
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.commandTemplate = commandTemplate
        self.parameters = parameters
        self.isReadOnly = isReadOnly
        self.appBundleID = appBundleID
    }
}

// MARK: - Capability Filtering

/// Bounded capability filter for an App Pet or mode overlay.
///
/// Invariant: Filtering can ONLY narrow authority (e.g. read-only filter), NEVER broaden it
/// or bypass host approval cards.
struct AppPetCapabilityFilter: Codable, Hashable, Sendable {
    var allowedPrefixes: [String]
    var excludedCapabilities: [String]
    var readOnlyOnly: Bool

    static let allowAll = AppPetCapabilityFilter(
        allowedPrefixes: [],
        excludedCapabilities: [],
        readOnlyOnly: false
    )

    static let readOnly = AppPetCapabilityFilter(
        allowedPrefixes: [],
        excludedCapabilities: [],
        readOnlyOnly: true
    )

    init(
        allowedPrefixes: [String] = [],
        excludedCapabilities: [String] = [],
        readOnlyOnly: Bool = false
    ) {
        self.allowedPrefixes = allowedPrefixes
        self.excludedCapabilities = excludedCapabilities
        self.readOnlyOnly = readOnlyOnly
    }

    /// Evaluates whether a capability id with known read-only status is permitted.
    func isAllowed(capabilityID: String, isReadOnly: Bool) -> Bool {
        if readOnlyOnly && !isReadOnly {
            return false
        }
        if excludedCapabilities.contains(capabilityID) {
            return false
        }
        if !allowedPrefixes.isEmpty {
            return allowedPrefixes.contains { capabilityID.hasPrefix($0) }
        }
        return true
    }

    /// Narrows a list of capability descriptors using this filter.
    func filter<T>(
        items: [T],
        idKey: (T) -> String,
        isReadOnlyKey: (T) -> Bool
    ) -> [T] {
        items.filter { isAllowed(capabilityID: idKey($0), isReadOnly: isReadOnlyKey($0)) }
    }
}

// MARK: - AppPetModeManifest

/// Preset behavior mode supported by an App Pet (§7).
///
/// A mode may change:
/// - the profile instructions used for the turn;
/// - which relevant capabilities are shortlisted first;
/// - plan detail, response style and verification emphasis;
/// - default attachment/context preferences inside the same scope.
///
/// A mode may NOT change:
/// - app scope or connected participants;
/// - route authority, risk or approval requirements;
/// - provider privacy ceiling;
/// - token, round, time or no-progress safety budgets.
struct AppPetModeManifest: Codable, Hashable, Sendable, Identifiable {
    let id: String
    let name: String
    let summary: String
    let icon: String?
    let systemPromptOverlay: String
    let preferredCapabilities: [String]
    let capabilityFilter: AppPetCapabilityFilter?
    let customTools: [AppPetCustomTool]
    let planDetail: AppPetPlanDetail
    let responseStyle: String?
    let verificationEmphasis: AppPetVerificationEmphasis

    init(
        id: String,
        name: String,
        summary: String,
        icon: String? = nil,
        systemPromptOverlay: String = "",
        preferredCapabilities: [String] = [],
        capabilityFilter: AppPetCapabilityFilter? = nil,
        customTools: [AppPetCustomTool] = [],
        planDetail: AppPetPlanDetail = .normal,
        responseStyle: String? = nil,
        verificationEmphasis: AppPetVerificationEmphasis = .standard
    ) {
        self.id = id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.summary = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        self.icon = icon
        self.systemPromptOverlay = systemPromptOverlay
        self.preferredCapabilities = preferredCapabilities
        self.capabilityFilter = capabilityFilter
        self.customTools = customTools
        self.planDetail = planDetail
        self.responseStyle = responseStyle
        self.verificationEmphasis = verificationEmphasis
    }

    var effectiveFilter: AppPetCapabilityFilter {
        capabilityFilter ?? .allowAll
    }

    var responseStyleInstruction: String {
        guard let responseStyle, !responseStyle.isEmpty else { return "" }
        return "\nResponse style: \(responseStyle)"
    }
}

// MARK: - AppPetManifest

/// Complete manifest definition for an App Pet profile (§4 & §7).
struct AppPetManifest: Codable, Hashable, Sendable, Identifiable {
    let id: String
    let appName: String
    let bundleID: String?
    let cliCommand: String?
    let summary: String?
    let defaultMode: String?
    let customPrompt: String?
    let customTools: [AppPetCustomTool]
    let capabilityFilter: AppPetCapabilityFilter?
    let modes: [AppPetModeManifest]

    init(
        id: String,
        appName: String,
        bundleID: String? = nil,
        cliCommand: String? = nil,
        summary: String? = nil,
        defaultMode: String? = nil,
        customPrompt: String? = nil,
        customTools: [AppPetCustomTool] = [],
        capabilityFilter: AppPetCapabilityFilter? = nil,
        modes: [AppPetModeManifest] = []
    ) {
        self.id = id.trimmingCharacters(in: .whitespacesAndNewlines)
        self.appName = appName.trimmingCharacters(in: .whitespacesAndNewlines)
        self.bundleID = bundleID?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.cliCommand = cliCommand?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        self.summary = summary?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.defaultMode = defaultMode?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        self.customPrompt = customPrompt
        self.customTools = customTools
        self.capabilityFilter = capabilityFilter
        self.modes = modes
    }

    var petID: AppPetID {
        if let cliCommand, !cliCommand.isEmpty {
            return .cli(command: cliCommand)
        }
        if let bundleID, !bundleID.isEmpty {
            return .app(bundleID: bundleID)
        }
        return .app(bundleID: id)
    }

    /// Finds a mode by case-insensitive name or ID.
    func mode(named name: String) -> AppPetModeManifest? {
        let needle = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return nil }
        return modes.first {
            $0.id == needle || $0.name.lowercased() == needle
        }
    }

    /// Returns the configured default mode or the first declared mode.
    func defaultOrFirstMode() -> AppPetModeManifest? {
        if let defaultMode, let found = mode(named: defaultMode) {
            return found
        }
        return modes.first
    }
}

// MARK: - AppPetManifestRegistry

/// Registry holding built-in and user-customized App Pet manifests.
final class AppPetManifestRegistry: @unchecked Sendable {
    static let shared = AppPetManifestRegistry()

    private let lock = NSLock()
    private var manifests: [String: AppPetManifest] = [:]
    private static let log = Logger(subsystem: "com.krishgokul.ContextDock", category: "PetManifestRegistry")

    init() {
        registerBuiltIns()
    }

    // MARK: - Registration & Loading

    func register(_ manifest: AppPetManifest) {
        lock.lock()
        defer { lock.unlock() }
        let key = manifest.petID.canonicalKey
        manifests[key] = manifest
    }

    /// Decodes a manifest from JSON data and registers it.
    @discardableResult
    func load(from data: Data) throws -> AppPetManifest {
        let decoder = JSONDecoder()
        let manifest = try decoder.decode(AppPetManifest.self, from: data)
        register(manifest)
        return manifest
    }

    /// Loads a manifest from a file URL.
    @discardableResult
    func load(from fileURL: URL) throws -> AppPetManifest {
        let data = try Data(contentsOf: fileURL)
        return try load(from: data)
    }

    /// Scans a directory for `.json` App Pet manifests.
    func loadDirectory(_ directoryURL: URL) {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: directoryURL, includingPropertiesForKeys: nil) else {
            return
        }
        for file in files where file.pathExtension.lowercased() == "json" {
            do {
                try load(from: file)
            } catch {
                Self.log.error("Failed to load pet manifest from \(file.lastPathComponent): \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Retrieval

    func manifest(for petID: AppPetID) -> AppPetManifest {
        lock.lock()
        defer { lock.unlock() }
        let key = petID.canonicalKey
        if let found = manifests[key] {
            return found
        }
        // Fallback generic manifest
        return Self.makeGenericManifest(for: petID)
    }

    func manifest(forBundleID bundleID: String) -> AppPetManifest? {
        manifest(for: .app(bundleID: bundleID))
    }

    func manifest(forAppName name: String) -> AppPetManifest? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        lock.lock()
        defer { lock.unlock() }
        return manifests.values.first {
            $0.appName.caseInsensitiveCompare(trimmed) == .orderedSame
        }
    }

    /// Returns the supported modes for an App Pet.
    func supportedModes(for petID: AppPetID) -> [AppPetModeManifest] {
        manifest(for: petID).modes
    }

    /// Resolves a mode for an App Pet by name or id.
    func resolveMode(named name: String, for petID: AppPetID) -> AppPetModeManifest? {
        manifest(for: petID).mode(named: name)
    }

    // MARK: - Built-in Manifests

    private func registerBuiltIns() {
        for manifest in Self.defaultManifests {
            register(manifest)
        }
    }

    static var defaultManifests: [AppPetManifest] {
        [
            safariManifest,
            finderManifest,
            messagesManifest,
            terminalManifest,
            notesManifest,
            mailManifest
        ]
    }

    // 1. Safari
    static let safariManifest = AppPetManifest(
        id: "com.apple.Safari",
        appName: "Safari",
        bundleID: "com.apple.Safari",
        summary: "Safari browser companion with browsing, deep research, comparison, and automation modes.",
        defaultMode: "browse",
        modes: [
            AppPetModeManifest(
                id: "browse",
                name: "Browse",
                summary: "Fast browsing, active tab reading, and quick link navigation.",
                icon: "safari",
                systemPromptOverlay: "Safari Browse mode: prioritize reading the current active webpage, following links, and answering quick navigation questions.",
                preferredCapabilities: ["browser.page", "browser.history", "safari.tabs"],
                planDetail: .concise
            ),
            AppPetModeManifest(
                id: "research",
                name: "Research",
                summary: "Deep research across open tabs, history, and page content with citations.",
                icon: "text.magnifyingglass",
                systemPromptOverlay: "Safari Research mode: synthesize information across multiple open tabs and history. Provide structured synthesis with citations and source URLs.",
                preferredCapabilities: ["browser.page", "safari.tabs", "browser.history"],
                planDetail: .detailed,
                responseStyle: "Structured findings with citations and source tab titles"
            ),
            AppPetModeManifest(
                id: "compare",
                name: "Compare",
                summary: "Side-by-side comparison across multiple tabs and pages.",
                icon: "arrow.triangle.swap",
                systemPromptOverlay: "Safari Compare mode: compare and contrast subjects across different tabs and pages. Structure your output in a clear comparative table or bulleted contrasts.",
                preferredCapabilities: ["safari.tabs", "browser.page"],
                planDetail: .detailed,
                responseStyle: "Comparative table with criteria, similarities, and differences"
            ),
            AppPetModeManifest(
                id: "automate",
                name: "Automate",
                summary: "Form filling, bookmark management, and page automation.",
                icon: "gearshape.2",
                systemPromptOverlay: "Safari Automate mode: automate repetitive browser actions, bookmark organization, and form assistance with explicit verification.",
                preferredCapabilities: ["app.insertText", "app.menu.click"],
                planDetail: .stepByStep,
                verificationEmphasis: .strictReceipt
            )
        ]
    )

    // 2. Finder
    static let finderManifest = AppPetManifest(
        id: "com.apple.finder",
        appName: "Finder",
        bundleID: "com.apple.finder",
        summary: "Finder workspace companion for file search, organization, batch operations, and file inspection.",
        defaultMode: "find",
        modes: [
            AppPetModeManifest(
                id: "find",
                name: "Find",
                summary: "Fast file search, spotlight lookup, and directory traversal.",
                icon: "magnifyingglass",
                systemPromptOverlay: "Finder Find mode: locate files, search metadata, and list directory contents. Answer file location queries directly.",
                preferredCapabilities: ["finder.list", "finder.search", "finder.info"],
                planDetail: .concise
            ),
            AppPetModeManifest(
                id: "organize",
                name: "Organize",
                summary: "Folder grouping, tagging, renaming, and filing.",
                icon: "folder.badge.gearshape",
                systemPromptOverlay: "Finder Organize mode: help clean up folders, group related files, tag documents, and prepare file moves with clear confirmation.",
                preferredCapabilities: ["finder.organize", "finder.move", "finder.tag"],
                planDetail: .stepByStep,
                verificationEmphasis: .verifyBeforeAnswer
            ),
            AppPetModeManifest(
                id: "batch",
                name: "Batch",
                summary: "Batch operations, batch conversions, and multi-file actions.",
                icon: "square.stack.3d.up",
                systemPromptOverlay: "Finder Batch mode: process sets of files together. Present a summary of items to be affected before performing multi-file operations.",
                preferredCapabilities: ["finder.batch", "finder.rename"],
                planDetail: .stepByStep,
                verificationEmphasis: .strictReceipt
            ),
            AppPetModeManifest(
                id: "inspect",
                name: "Inspect",
                summary: "Read-only file inspection, metadata analysis, and checksums.",
                icon: "info.circle",
                systemPromptOverlay: "Finder Inspect mode: examine file headers, properties, sizes, and metadata in read-only mode without modifying files.",
                preferredCapabilities: ["finder.info", "finder.list"],
                capabilityFilter: .readOnly,
                planDetail: .detailed,
                responseStyle: "Technical file metadata and structure summary"
            )
        ]
    )

    // 3. Messages
    static let messagesManifest = AppPetManifest(
        id: "com.apple.MobileSMS",
        appName: "Messages",
        bundleID: "com.apple.MobileSMS",
        summary: "Messages companion for reading conversations, drafting replies, and sending with confirmation.",
        defaultMode: "read",
        modes: [
            AppPetModeManifest(
                id: "read",
                name: "Read",
                summary: "Read recent messages, unread threads, and search history.",
                icon: "bubble.left",
                systemPromptOverlay: "Messages Read mode: inspect recent messages and search message conversations in read-only mode.",
                preferredCapabilities: ["messages.read", "messages.search"],
                capabilityFilter: .readOnly,
                planDetail: .concise
            ),
            AppPetModeManifest(
                id: "draft",
                name: "Draft",
                summary: "Prepare message drafts, verify recipients, and format replies without sending.",
                icon: "pencil",
                systemPromptOverlay: "Messages Draft mode: compose message drafts, verify phrasing and recipients. Never send directly in draft mode.",
                preferredCapabilities: ["messages.read"],
                capabilityFilter: .readOnly,
                planDetail: .normal,
                responseStyle: "Draft message preview with recipient"
            ),
            AppPetModeManifest(
                id: "send",
                name: "Send",
                summary: "Review and send messages with verified outbound receipts.",
                icon: "paperplane",
                systemPromptOverlay: "Messages Send mode: prepare message sends with recipient confirmation and verified outbound receipts.",
                preferredCapabilities: ["messages.send"],
                planDetail: .stepByStep,
                verificationEmphasis: .strictReceipt
            )
        ]
    )

    // 4. Terminal
    static let terminalManifest = AppPetManifest(
        id: "com.apple.Terminal",
        appName: "Terminal",
        bundleID: "com.apple.Terminal",
        cliCommand: "terminal",
        summary: "Terminal shell companion for command explanation, system diagnosis, and supervised command execution.",
        defaultMode: "explain",
        modes: [
            AppPetModeManifest(
                id: "explain",
                name: "Explain",
                summary: "Explain shell commands, syntax, flags, and scripts in read-only mode.",
                icon: "questionmark.circle",
                systemPromptOverlay: "Terminal Explain mode: explain commands, options, and shell syntax without executing modifying actions.",
                preferredCapabilities: ["man.read"],
                capabilityFilter: .readOnly,
                planDetail: .detailed,
                responseStyle: "Clear command breakdown with flag explanations"
            ),
            AppPetModeManifest(
                id: "diagnose",
                name: "Diagnose",
                summary: "Diagnose system errors, logs, network, and process issues.",
                icon: "stethoscope",
                systemPromptOverlay: "Terminal Diagnose mode: inspect logs, check processes, and diagnose machine issues with read-only commands.",
                preferredCapabilities: ["system.logs", "system.processes"],
                capabilityFilter: .readOnly,
                planDetail: .detailed,
                responseStyle: "Diagnostic summary and root-cause analysis"
            ),
            AppPetModeManifest(
                id: "run",
                name: "Run",
                summary: "Execute verified commands with safety approvals.",
                icon: "terminal",
                systemPromptOverlay: "Terminal Run mode: prepare and execute approved shell commands with full approval cards.",
                preferredCapabilities: ["terminal.execute"],
                planDetail: .stepByStep,
                verificationEmphasis: .strictReceipt
            )
        ]
    )

    // 5. Notes
    static let notesManifest = AppPetManifest(
        id: "com.apple.Notes",
        appName: "Notes",
        bundleID: "com.apple.Notes",
        summary: "Apple Notes companion for searching, drafting, and organizing notes.",
        defaultMode: "search",
        modes: [
            AppPetModeManifest(
                id: "search",
                name: "Search",
                summary: "Search notes and folders in read-only mode.",
                icon: "magnifyingglass",
                systemPromptOverlay: "Notes Search mode: search existing notes by title and content.",
                preferredCapabilities: ["notes.search"],
                capabilityFilter: .readOnly,
                planDetail: .concise
            ),
            AppPetModeManifest(
                id: "draft",
                name: "Draft",
                summary: "Draft structured notes and outlines.",
                icon: "note.text.badge.plus",
                systemPromptOverlay: "Notes Draft mode: compose structured notes, markdown summaries, and outlines.",
                preferredCapabilities: ["notes.create"],
                planDetail: .normal
            ),
            AppPetModeManifest(
                id: "organize",
                name: "Organize",
                summary: "Move, tag, and organize notes.",
                icon: "folder",
                systemPromptOverlay: "Notes Organize mode: categorize and organize existing notes into folders.",
                preferredCapabilities: ["notes.organize"],
                planDetail: .stepByStep,
                verificationEmphasis: .strictReceipt
            )
        ]
    )

    // 6. Mail
    static let mailManifest = AppPetManifest(
        id: "com.apple.mail",
        appName: "Mail",
        bundleID: "com.apple.mail",
        summary: "Apple Mail companion for reading, drafting, and sending emails.",
        defaultMode: "read",
        modes: [
            AppPetModeManifest(
                id: "read",
                name: "Read",
                summary: "Read emails and search mailboxes in read-only mode.",
                icon: "envelope.open",
                systemPromptOverlay: "Mail Read mode: search unread messages and summarize mail threads in read-only mode.",
                preferredCapabilities: ["mail.search", "mail.read"],
                capabilityFilter: .readOnly,
                planDetail: .concise
            ),
            AppPetModeManifest(
                id: "draft",
                name: "Draft",
                summary: "Draft email responses without sending.",
                icon: "pencil.and.outline",
                systemPromptOverlay: "Mail Draft mode: prepare clean, professional email drafts without sending.",
                preferredCapabilities: ["mail.search"],
                capabilityFilter: .readOnly,
                planDetail: .normal,
                responseStyle: "Draft subject and body preview"
            ),
            AppPetModeManifest(
                id: "send",
                name: "Send",
                summary: "Send reviewed emails with outbound approval.",
                icon: "paperplane",
                systemPromptOverlay: "Mail Send mode: review recipients, subject, and body before outbound send approval.",
                preferredCapabilities: ["mail.send"],
                planDetail: .stepByStep,
                verificationEmphasis: .strictReceipt
            )
        ]
    )

    // Generic Fallback
    static func makeGenericManifest(for petID: AppPetID) -> AppPetManifest {
        let appName: String = {
            switch petID.normalized {
            case .app(let bundleID):
                if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
                    return FileManager.default.displayName(atPath: url.path)
                }
                return bundleID
            case .cli(let command):
                return command
            }
        }()

        return AppPetManifest(
            id: petID.dockBundleID,
            appName: appName,
            bundleID: petID.bundleID,
            cliCommand: petID.cliCommand,
            summary: "Assistant companion for \(appName).",
            defaultMode: "assist",
            modes: [
                AppPetModeManifest(
                    id: "assist",
                    name: "Assist",
                    summary: "General app assistance and workflow queries.",
                    icon: "sparkles",
                    systemPromptOverlay: "Assist mode: provide focused assistance for \(appName).",
                    preferredCapabilities: [],
                    planDetail: .normal
                ),
                AppPetModeManifest(
                    id: "inspect",
                    name: "Inspect",
                    summary: "Inspect active window, menu items, and UI state.",
                    icon: "eye",
                    systemPromptOverlay: "Inspect mode: read-only inspection of \(appName) menus, windows, and state.",
                    preferredCapabilities: ["app.menu.list"],
                    capabilityFilter: .readOnly,
                    planDetail: .concise
                ),
                AppPetModeManifest(
                    id: "automate",
                    name: "Automate",
                    summary: "Execute actions and menu commands.",
                    icon: "gearshape",
                    systemPromptOverlay: "Automate mode: execute verified tasks and menu commands in \(appName).",
                    preferredCapabilities: ["app.menu.click"],
                    planDetail: .stepByStep,
                    verificationEmphasis: .strictReceipt
                )
            ]
        )
    }
}
