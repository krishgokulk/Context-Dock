// Context-Dock/Services/Plugins/StorePackInstaller.swift
// Context-Dock
//
// Automatic App Binding for Store / Packs (Spec 2026-11-05 §3):
// When a pack is installed from Store / Packs or saved in the Pack Creator:
// 1. Reads `target_app.bundle_id`.
// 2. If `bundle_id` targets an app (e.g. `com.apple.Safari`, `notion.id`):
//    - Binds capabilities and actions directly into that app's `AppAdapter` (`AppAdapterManager`)
//      and `ScopeInventory`.
//    - Registers `utcp_endpoints` into `APIConnectionStore` & `UTCPToolBridge` for that app.
//    - Registers `skills` into `SkillStore` scoped to that app's `bundle_id`.
//    - Writes `agent.instructions` into the app's `AGENT.md` (`AppAgentProfileStore`) when empty.
// 3. If `bundle_id` is global or nil:
//    - Registers tools into Global Context (`SystemCommandsRegistry`, `SkillStore` global scope).

import Foundation

struct StorePackBindResult: Equatable {
    let packID: String
    let boundBundleID: String?
    let appName: String
    let isGlobal: Bool
    let registeredCapabilityIDs: [String]
    let registeredUTCPConnectionIDs: [String]
    let registeredSkillIDs: [String]
    let registeredGlobalCommandIDs: [String]
}

@MainActor
enum StorePackInstaller {

    /// Installs a pack manifest and automatically binds its capabilities, UTCP endpoints,
    /// and skills to the matching `target_app.bundle_id` (or Global Context when nil / "global").
    @discardableResult
    static func install(
        _ manifest: PluginManifest,
        into pluginRoot: URL? = nil,
        persistToDisk: Bool = !AppDelegate.isHostingTests
    ) throws -> StorePackBindResult {
        if let root = pluginRoot {
            _ = try PluginInstaller.install(
                [manifest],
                into: root,
                packID: "store-packs",
                packName: "Installed Store Packs")
            if root == PluginInstaller.userRoot {
                PluginRegistry.shared.reload()
            }
        } else if persistToDisk {
            _ = try PluginInstaller.install(
                [manifest],
                into: PluginInstaller.userRoot,
                packID: "store-packs",
                packName: "Installed Store Packs")
            PluginRegistry.shared.reload()
        }

        let rawBundleID = manifest.targetApp?.bundleId.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let isGlobal = rawBundleID.isEmpty || rawBundleID.lowercased() == "global"

        if isGlobal {
            return bindToGlobalContext(manifest, persistToDisk: persistToDisk)
        } else {
            let appName = manifest.targetApp?.name.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return bindToApp(
                manifest,
                bundleID: rawBundleID,
                appName: appName.isEmpty ? rawBundleID : appName,
                persistToDisk: persistToDisk)
        }
    }

    // MARK: - App Binding

    private static func bindToApp(
        _ manifest: PluginManifest,
        bundleID: String,
        appName: String,
        persistToDisk: Bool
    ) -> StorePackBindResult {
        let actions = buildAdapterActions(from: manifest)
        AppAdapterManager.shared.bindPackActions(
            bundleId: bundleID,
            appName: appName,
            icon: manifest.icon,
            actions: actions,
            persistToDisk: persistToDisk)

        var utcpIDs: [String] = []
        for endpoint in manifest.utcpEndpoints ?? [] {
            let specJSON = endpoint.specJSON ?? synthesizeUTCPManualJSON(from: endpoint, packName: manifest.name)
            // Avoid duplicating an existing connection with the same name & bundleId
            let existing = APIConnectionStore.shared.connections(for: bundleID)
                .first { $0.name.caseInsensitiveCompare(endpoint.name) == .orderedSame }
            if let existing {
                APIConnectionStore.shared.disconnect(id: existing.id)
            }
            let conn = APIConnectionStore.shared.connect(
                name: endpoint.name,
                baseURL: endpoint.baseURL,
                apiKey: "",
                bundleId: bundleID,
                specText: specJSON)
            utcpIDs.append(conn.id)
        }

        var skillIDs: [String] = []
        for packSkill in manifest.skills ?? [] {
            let stableID = "pack.\(manifest.id).skill.\(packSkill.id)"
            let skill = AdapterSkill(
                id: stableID,
                adapterBundleId: bundleID,
                name: packSkill.name,
                summary: packSkill.summary.isEmpty ? manifest.description : packSkill.summary,
                instructions: packSkill.instructions,
                version: manifest.version ?? "1.0",
                isEnabled: true)
            SkillStore.shared.upsert(skill)
            skillIDs.append(stableID)
        }

        if persistToDisk,
           let instructions = manifest.agent?.instructions.trimmingCharacters(in: .whitespacesAndNewlines),
           !instructions.isEmpty {
            let profileURL = AppAgentProfileStore.shared.fileURL(forBundleID: bundleID)
            let existingText = (try? String(contentsOf: profileURL, encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if existingText.isEmpty {
                try? FileManager.default.createDirectory(
                    at: profileURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true)
                try? instructions.write(to: profileURL, atomically: true, encoding: .utf8)
                AppAgentProfileStore.shared.invalidate(bundleID: bundleID)
            }
        }

        return StorePackBindResult(
            packID: manifest.id,
            boundBundleID: bundleID,
            appName: appName,
            isGlobal: false,
            registeredCapabilityIDs: actions.map(\.id),
            registeredUTCPConnectionIDs: utcpIDs,
            registeredSkillIDs: skillIDs,
            registeredGlobalCommandIDs: [])
    }

    // MARK: - Global Binding

    private static func bindToGlobalContext(
        _ manifest: PluginManifest,
        persistToDisk: Bool
    ) -> StorePackBindResult {
        var commandIDs: [String] = []
        for cap in manifest.capabilities ?? [] {
            let scriptType: String = {
                switch cap.type.lowercased() {
                case "applescript": return "applescript"
                case "jxa": return "jxa"
                default: return "bash"
                }
            }()
            let script = cap.script ?? "echo \"\(cap.name)\""
            let existing = SystemCommandsRegistry.shared.commands.first {
                $0.name.caseInsensitiveCompare(cap.name) == .orderedSame
            }
            if let existing {
                commandIDs.append(existing.id.uuidString)
            } else {
                let cmd = SystemCommand(
                    name: cap.name,
                    icon: manifest.icon,
                    keywords: cap.triggers.isEmpty ? [cap.name.lowercased()] : cap.triggers,
                    scriptType: scriptType,
                    script: script,
                    description: cap.intent,
                    enabled: true)
                if persistToDisk {
                    SystemCommandsRegistry.shared.add(cmd)
                    SystemCommandsRegistryObserver.shared.reload()
                    CapabilityRegistry.shared.refreshGlobalCommands()
                }
                commandIDs.append(cmd.id.uuidString)
            }
        }

        var skillIDs: [String] = []
        for packSkill in manifest.skills ?? [] {
            let stableID = "pack.\(manifest.id).skill.\(packSkill.id)"
            let skill = AdapterSkill(
                id: stableID,
                adapterBundleId: "",
                name: packSkill.name,
                summary: packSkill.summary.isEmpty ? manifest.description : packSkill.summary,
                instructions: packSkill.instructions,
                version: manifest.version ?? "1.0",
                isEnabled: true,
                surfaceId: DoraXSurface.generalChat.rawValue)
            SkillStore.shared.upsert(skill)
            skillIDs.append(stableID)
        }

        return StorePackBindResult(
            packID: manifest.id,
            boundBundleID: nil,
            appName: "Global",
            isGlobal: true,
            registeredCapabilityIDs: (manifest.capabilities ?? []).map(\.id),
            registeredUTCPConnectionIDs: [],
            registeredSkillIDs: skillIDs,
            registeredGlobalCommandIDs: commandIDs)
    }

    // MARK: - Helpers

    static func buildAdapterActions(from manifest: PluginManifest) -> [AdapterAction] {
        var out: [AdapterAction] = []
        var seen = Set<String>()

        for cap in manifest.capabilities ?? [] {
            let actionID = "pack.\(manifest.id).\(cap.id)"
            guard seen.insert(actionID).inserted else { continue }
            let actionType = mapActionType(cap.type, menuPath: cap.menuPath, urlScheme: cap.urlScheme, script: cap.script)
            let isWrite = cap.safety.lowercased() != "read"
            out.append(
                AdapterAction(
                    id: actionID,
                    name: cap.name,
                    icon: manifest.icon,
                    description: cap.intent.isEmpty ? manifest.description : cap.intent,
                    triggers: cap.triggers.isEmpty ? [cap.name] : cap.triggers,
                    category: manifest.name,
                    type: actionType,
                    menuPath: cap.menuPath,
                    script: actionType == .aiPrompt ? nil : cap.script,
                    urlScheme: cap.urlScheme,
                    aiPromptTemplate: actionType == .aiPrompt ? (cap.script ?? cap.intent) : nil,
                    requiresApproval: isWrite,
                    isDestructive: cap.safety.lowercased() == "high"))
        }

        for (key, pluginAction) in manifest.actions.sorted(by: { $0.key < $1.key }) {
            let actionID = "pack.\(manifest.id).\(key)"
            guard seen.insert(actionID).inserted else { continue }
            let title = pluginAction.title ?? key
            let actionType = mapActionType(pluginAction.type, menuPath: nil, urlScheme: pluginAction.value, script: pluginAction.script)
            let isWrite = pluginAction.risk != .read
            out.append(
                AdapterAction(
                    id: actionID,
                    name: title,
                    icon: manifest.icon,
                    description: manifest.description,
                    triggers: [title] + manifest.keywords,
                    category: manifest.name,
                    type: actionType,
                    script: pluginAction.script,
                    urlScheme: pluginAction.value,
                    requiresApproval: isWrite,
                    isDestructive: pluginAction.risk == .high))
        }

        return out
    }

    private static func mapActionType(
        _ raw: String,
        menuPath: [String]?,
        urlScheme: String?,
        script: String?
    ) -> AdapterActionType {
        if let menuPath, !menuPath.isEmpty { return .menubar }
        switch raw.lowercased() {
        case "menubar", "menu": return .menubar
        case "applescript": return .applescript
        case "jxa": return .jxa
        case "shell", "bash": return .shell
        case "shortcut": return .shortcut
        case "urlscheme", "url", "deeplink", "open": return .urlScheme
        case "pagejs": return .pageJS
        case "clitool": return .cliTool
        default:
            if let urlScheme, !urlScheme.isEmpty { return .urlScheme }
            return .aiPrompt
        }
    }

    static func synthesizeUTCPManualJSON(from endpoint: PluginPackUTCPEndpoint, packName: String) -> String {
        let base = endpoint.baseURL.hasSuffix("/")
            ? String(endpoint.baseURL.dropLast())
            : endpoint.baseURL
        let path = endpoint.path.hasPrefix("/") ? endpoint.path : "/" + endpoint.path
        let escapedDesc = endpoint.description
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let escapedName = endpoint.id
            .replacingOccurrences(of: " ", with: "_")
            .lowercased()
        let escapedPack = packName
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return """
        {
          "utcp_version": "1.0",
          "name": "\(escapedPack)",
          "description": "\(escapedDesc.isEmpty ? endpoint.name : escapedDesc)",
          "protocols": {
            "http": {
              "baseURL": "\(base)"
            }
          },
          "tools": [
            {
              "name": "\(escapedName)",
              "description": "\(escapedDesc.isEmpty ? endpoint.name : escapedDesc)",
              "execution": {
                "http": {
                  "method": "\(endpoint.method)",
                  "path": "\(path)"
                }
              }
            }
          ]
        }
        """
    }
}

// MARK: - Curated Store Pack Catalog

enum StorePackCatalog {
    static let all: [PluginManifest] = [
        notionWorkspacePack,
        safariResearchPack,
        linearWorkspacePack,
        finderOrganizerPack,
        githubGlobalPack
    ]

    static let notionWorkspacePack = PluginManifest(
        id: "notion-enhanced",
        name: "Notion Workspace Pack",
        version: "1.0.0",
        icon: "doc.text.fill",
        description: "Search Notion pages, append meeting notes, and query databases via direct UTCP & app capabilities.",
        keywords: ["notion", "notes", "wiki", "database"],
        agent: PluginAgent(
            instructions: "# Notion\nPrefer direct UTCP API reads before driving the Notion window. Always ask before overwriting existing page blocks.",
            skills: ["notion-meeting-notes"],
            tools: ["search-pages", "new-page"]),
        targetApp: PluginTargetApp(bundleId: "notion.id", name: "Notion"),
        capabilities: [
            PluginPackCapability(
                id: "search-pages",
                name: "Quick Find in Notion",
                intent: "Open Quick Find or search the active Notion workspace.",
                triggers: ["search notion", "find page", "quick find"],
                type: "aiPrompt",
                script: "Search the active Notion workspace for the user's query.",
                safety: "read"),
            PluginPackCapability(
                id: "new-page",
                name: "Create Notion Page",
                intent: "Create a new structured page in Notion.",
                triggers: ["new notion page", "create page"],
                type: "menubar",
                menuPath: ["File", "New Page"],
                safety: "write")
        ],
        utcpEndpoints: [
            PluginPackUTCPEndpoint(
                id: "notion_search",
                name: "Notion Search API",
                baseURL: "https://api.notion.com",
                method: "POST",
                path: "/v1/search",
                description: "Search Notion pages and databases directly via UTCP.",
                requiresAuth: true)
        ],
        skills: [
            PluginPackSkill(
                id: "notion-meeting-notes",
                name: "Meeting Notes Formatter",
                summary: "Formats rough transcript notes into Decisions, Action Items, and Owners for Notion.",
                instructions: "Structure meeting summaries into: ## Summary, ## Key Decisions, and ## Action Items (with @owner and due date).")
        ]
    )

    static let safariResearchPack = PluginManifest(
        id: "safari-research-pack",
        name: "Safari Research & Reader Pack",
        version: "1.0.0",
        icon: "safari.fill",
        description: "Extract structured citations, summarize open tabs, and toggle Reader view in Safari.",
        keywords: ["safari", "research", "tabs", "reader"],
        agent: PluginAgent(
            instructions: "# Safari\nPrefer headless tab & page content reads (`safari.currentTab`, `safari.pageContent`) before UI automation.",
            skills: ["safari-citation-extractor"],
            tools: ["summarize-tab", "toggle-reader"]),
        targetApp: PluginTargetApp(bundleId: "com.apple.Safari", name: "Safari"),
        capabilities: [
            PluginPackCapability(
                id: "summarize-tab",
                name: "Summarize Active Tab",
                intent: "Read and summarize the active Safari tab's article key points.",
                triggers: ["summarize tab", "tldr page", "read article"],
                type: "aiPrompt",
                script: "Read the active Safari page content and provide a concise 5-bullet summary.",
                safety: "read"),
            PluginPackCapability(
                id: "toggle-reader",
                name: "Toggle Reader View",
                intent: "Switch the frontmost Safari tab into distraction-free Reader mode.",
                triggers: ["reader view", "show reader"],
                type: "menubar",
                menuPath: ["View", "Show Reader"],
                safety: "read")
        ],
        skills: [
            PluginPackSkill(
                id: "safari-citation-extractor",
                name: "Research Citation & Claim Extractor",
                summary: "Extracts primary claims, quotes, and markdown links from the current web page.",
                instructions: "When researching in Safari, cite the exact page title and URL, list primary claims with direct quotes, and flag unverified assertions.")
        ]
    )

    static let linearWorkspacePack = PluginManifest(
        id: "linear-workspace-pack",
        name: "Linear Issue Tracker Pack",
        version: "1.0.0",
        icon: "checklist.checked",
        description: "Triage Linear issues, inspect sprint cycles, and draft bug reports with reproduction steps.",
        keywords: ["linear", "issues", "triage", "sprint"],
        agent: PluginAgent(
            instructions: "# Linear\nUse direct UTCP reads for issue lookup and ask before changing issue state or assignee.",
            skills: ["linear-bug-triage"],
            tools: ["my-assigned-issues", "create-linear-issue"]),
        targetApp: PluginTargetApp(bundleId: "com.linear", name: "Linear"),
        capabilities: [
            PluginPackCapability(
                id: "my-assigned-issues",
                name: "List Assigned Issues",
                intent: "Inspect currently assigned Linear issues and priorities.",
                triggers: ["my issues", "assigned linear issues", "sprint tasks"],
                type: "aiPrompt",
                script: "List my active assigned issues in Linear grouped by priority.",
                safety: "read"),
            PluginPackCapability(
                id: "create-linear-issue",
                name: "Draft Linear Issue",
                intent: "Draft a new issue in Linear with title, repro steps, and priority.",
                triggers: ["new issue", "file bug in linear"],
                type: "menubar",
                menuPath: ["File", "New Issue"],
                safety: "write")
        ],
        utcpEndpoints: [
            PluginPackUTCPEndpoint(
                id: "linear_graphql",
                name: "Linear API",
                baseURL: "https://api.linear.app",
                method: "POST",
                path: "/graphql",
                description: "Query Linear issues, projects, and cycles via UTCP.",
                requiresAuth: true)
        ],
        skills: [
            PluginPackSkill(
                id: "linear-bug-triage",
                name: "Structured Bug Report Skill",
                summary: "Formats bug reports with Steps to Reproduce, Expected vs Actual, and Severity.",
                instructions: "Always include: 1) Environment, 2) Steps to Reproduce, 3) Expected Behavior, 4) Actual Behavior.")
        ]
    )

    static let finderOrganizerPack = PluginManifest(
        id: "finder-organizer-pack",
        name: "Finder Power Organizer Pack",
        version: "1.0.0",
        icon: "folder.fill.badge.gearshape",
        description: "Inspect recent downloads, summarize folder contents, and create organized project folders.",
        keywords: ["finder", "files", "downloads", "organize"],
        targetApp: PluginTargetApp(bundleId: "com.apple.finder", name: "Finder"),
        capabilities: [
            PluginPackCapability(
                id: "inspect-selection",
                name: "Summarize Selected Folder",
                intent: "Read and categorize files in the current Finder folder without moving anything.",
                triggers: ["summarize folder", "what is in this folder"],
                type: "aiPrompt",
                script: "Inspect the current Finder folder and group files by type and recent modification date.",
                safety: "read"),
            PluginPackCapability(
                id: "new-folder",
                name: "Create New Folder",
                intent: "Create a new folder in the active Finder window.",
                triggers: ["new folder", "create folder"],
                type: "menubar",
                menuPath: ["File", "New Folder"],
                safety: "write")
        ],
        skills: [
            PluginPackSkill(
                id: "finder-safe-organization",
                name: "Non-Destructive File Organization",
                summary: "Proposes folder groupings before moving any files and never deletes files.",
                instructions: "When asked to clean up a folder, first present a dry-run table of proposed folder destinations and wait for confirmation.")
        ]
    )

    static let githubGlobalPack = PluginManifest(
        id: "github-global-pack",
        name: "GitHub PR & Repo Pack",
        version: "1.0.0",
        icon: "chevron.left.forwardslash.chevron.right",
        description: "Global Context pack for checking open pull requests, CI status, and review checklists anywhere on your Mac.",
        keywords: ["github", "pr", "pull request", "ci"],
        targetApp: nil,
        capabilities: [
            PluginPackCapability(
                id: "gh-open-prs",
                name: "List Open Pull Requests",
                intent: "List open pull requests in the current repository using gh CLI.",
                triggers: ["open prs", "github pull requests"],
                type: "bash",
                script: "gh pr list --limit 10",
                safety: "read")
        ],
        skills: [
            PluginPackSkill(
                id: "github-pr-review",
                name: "PR Review Checklist",
                summary: "Checks diff safety, test coverage, and breaking changes during PR reviews.",
                instructions: "Review pull requests for: correctness, security boundaries, deterministic tests, and migration safety.")
        ]
    )
}
