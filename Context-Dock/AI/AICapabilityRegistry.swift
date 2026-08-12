import AppKit
import Combine
import Foundation

enum AICapabilityRiskLevel: String, Codable {
    case low
    case medium
    case high
    case critical

    var requiresApproval: Bool {
        self == .medium || self == .high
    }
}

struct AICapabilityInputField: Codable {
    let name: String
    let description: String
    let required: Bool
}

struct AICapabilityInputSchema: Codable {
    let fields: [AICapabilityInputField]
}

struct AICapabilityExecutionRequest {
    let input: [String: String]
    let context: UserContext
}

struct AICapabilityExecutionResult {
    let success: Bool
    let output: String
}

/// Whether a capability's entire authority comes from the user's explicit selection.
///
/// Selection Scope is opened on a piece of text or a file the user picked, and its promise
/// is that it acts on that and nothing else. Enforcing this by listing permitted capability
/// ids would rot: every new capability defaults to allowed-by-omission or forgotten, and the
/// list stops describing anything. So a capability declares what it needs and what it
/// touches, and the scope decides.
///
/// Three questions, all of which must be answered narrowly for a capability to run here:
/// what does it read, what does it change, and what does it aim at.
struct SelectionSafety {
    enum InputAuthority {
        /// Everything it operates on comes from the explicit selection.
        case selectionOnly
        /// It reads app or system state the user did not select. Never selection-safe.
        case systemOrApp
    }

    enum SideEffect {
        case none
        case clipboard
        /// Rewrites the selected text in place.
        case selectionReplacement
        /// Changes something the selection does not name — files, apps, system state.
        case unrelatedState
    }

    enum TargetScope {
        case currentSelection
        case appOrSystem
    }

    let inputAuthority: InputAuthority
    let sideEffect: SideEffect
    let targetScope: TargetScope

    /// The default is deliberately the strict one. A capability that has not thought about
    /// Selection Scope is not selection-safe, so adding one can never widen this scope by
    /// omission — the failure mode an allowlist has by construction.
    static let unsafe = SelectionSafety(
        inputAuthority: .systemOrApp, sideEffect: .unrelatedState, targetScope: .appOrSystem)

    /// Reads the selection and produces an answer or a clipboard write. Summarise, explain,
    /// translate, copy-as.
    static let readsSelection = SelectionSafety(
        inputAuthority: .selectionOnly, sideEffect: .clipboard, targetScope: .currentSelection)

    /// Rewrites the selected text in place.
    static let rewritesSelection = SelectionSafety(
        inputAuthority: .selectionOnly, sideEffect: .selectionReplacement,
        targetScope: .currentSelection)

    var isSelectionSafe: Bool {
        guard inputAuthority == .selectionOnly, targetScope == .currentSelection else {
            return false
        }
        switch sideEffect {
        case .none, .clipboard, .selectionReplacement: return true
        case .unrelatedState: return false
        }
    }
}

struct AICapability {
    let id: String
    let title: String
    let appBundleID: String?
    let inputSchema: AICapabilityInputSchema
    let riskLevel: AICapabilityRiskLevel
    /// What this may touch when the conversation is scoped to a selection. Defaults to
    /// unsafe, so a capability is only reachable from Selection Scope if it says so.
    var selectionSafety: SelectionSafety = .unsafe
    let executor: @MainActor (AICapabilityExecutionRequest) async throws -> AICapabilityExecutionResult
}

struct AIActionPlan: Codable {
    let capability: String
    let input: [String: String]
    let explanation: String
}

enum AICapabilityError: LocalizedError {
    case unknownCapability(String)
    case missingInput(String)
    case approvalRequired(String)
    case blocked(String)
    case invalidPlan

    var errorDescription: String? {
        switch self {
        case .unknownCapability(let id): return "Unknown capability: \(id)"
        case .missingInput(let name): return "Missing capability input: \(name)"
        case .approvalRequired(let title): return "Approval required before executing \(title)"
        case .blocked(let reason): return reason
        case .invalidPlan: return "AI returned an invalid action plan"
        }
    }
}

@MainActor
final class CapabilityRegistry {
    static let shared = CapabilityRegistry()

    private var capabilitiesByID: [String: AICapability] = [:]

    private init() {
        registerBuiltIns()
    }

    var all: [AICapability] {
        capabilitiesByID.values.sorted { $0.id < $1.id }
    }

    func capability(id: String) -> AICapability? {
        capabilitiesByID[id]
    }

    func capabilities(for bundleID: String?) -> [AICapability] {
        all.filter { $0.appBundleID == nil || $0.appBundleID == bundleID }
    }

    func register(_ capability: AICapability) {
        capabilitiesByID[capability.id] = capability
    }

    func registerAppleNotesMCPIfNeeded() {
        guard AppSettings.shared.noteMCPEnabled else { return }
        guard capabilitiesByID["notes.search"] == nil else { return }
        AppleNotesMCPCapabilities.register(in: self)
    }

    func promptBlock(for bundleID: String?) -> String {
        let entries = capabilities(for: bundleID).map { capability in
            let fields = capability.inputSchema.fields.map(\.name).joined(separator: ", ")
            return "- \(capability.id): \(capability.title) | risk=\(capability.riskLevel.rawValue) | input=[\(fields)]"
        }
        return [
            "Registered capabilities:\n" + entries.joined(separator: "\n"),
            AppWorkflowToolCatalog.shared.promptBlock(for: bundleID)
        ].joined(separator: "\n\n")
    }

    /// Re-register the user's Global Commands as capabilities. Call after the
    /// command registry changes (or before a chat) so newly-added commands are
    /// visible to the AI without a relaunch.
    func refreshGlobalCommands() {
        for id in capabilitiesByID.keys where id.hasPrefix(GlobalCommandCapabilities.idPrefix) {
            capabilitiesByID.removeValue(forKey: id)
        }
        GlobalCommandCapabilities.register(in: self)
    }

    /// Re-register the built-in Apple/GitHub MCP capabilities to match the CURRENT
    /// enable flags. registerBuiltIns only runs once at launch, so toggling an MCP
    /// in Settings did nothing until relaunch — call this before every chat (and on
    /// toggle) so enabled MCPs are immediately available in both chat surfaces.
    func refreshBuiltInMCPs() {
        let families: [(prefix: String, enabled: Bool, register: () -> Void)] = [
            ("notes.", AppSettings.shared.noteMCPEnabled,
                { AppleNotesMCPCapabilities.register(in: self) }),
            ("calendar.", AppSettings.shared.calendarMCPEnabled,
                { AppleCalendarMCPCapabilities.register(in: self) }),
            ("contacts.", AppSettings.shared.contactsMCPEnabled,
                { AppleContactsMCPCapabilities.register(in: self) }),
            ("reminders.", AppSettings.shared.remindersMCPEnabled,
                { AppleRemindersMCPCapabilities.register(in: self) }),
            ("photos.", AppSettings.shared.photosMCPEnabled,
                { ApplePhotosMCPCapabilities.register(in: self) }),
            ("mail.", AppSettings.shared.mailMCPEnabled,
                { AppleMailMCPCapabilities.register(in: self) }),
            ("music.", AppSettings.shared.musicMCPEnabled,
                { AppleMusicMCPCapabilities.register(in: self) }),
            ("messages.", AppSettings.shared.messagesMCPEnabled,
                { AppleMessagesMCPCapabilities.register(in: self) }),
            ("github.", AppSettings.shared.githubMCPEnabled,
                { GitHubMCPCapabilities.register(in: self) }),
        ]
        for family in families {
            let present = capabilitiesByID.keys.contains { $0.hasPrefix(family.prefix) }
            if family.enabled, !present {
                family.register()
            } else if !family.enabled, present {
                for id in capabilitiesByID.keys where id.hasPrefix(family.prefix) {
                    capabilitiesByID.removeValue(forKey: id)
                }
            }
        }
    }

    private func registerBuiltIns() {
        DoraXSurfaceCapabilities.register(in: self)
        GitCapabilities.register(in: self)
        TailscaleCapabilities.register(in: self)
        XcodeCapabilities.register(in: self)
        ProjectBuildCapabilities.register(in: self)
        LocalDataCapabilities.register(in: self)
        AppControlCapabilities.register(in: self)
        FinderFileChangeCapabilities.register(in: self)
        FinderCoworkerCapabilities.register(in: self)
        AppWorkflowToolCatalog.shared.register(in: self)
        GlobalCommandCapabilities.register(in: self)
        // Apple Notes MCP — only registered when explicitly enabled
        if AppSettings.shared.noteMCPEnabled {
            AppleNotesMCPCapabilities.register(in: self)
        }
        // Apple system app MCP capabilities — each guarded by its own flag
        if AppSettings.shared.calendarMCPEnabled {
            AppleCalendarMCPCapabilities.register(in: self)
        }
        if AppSettings.shared.contactsMCPEnabled {
            AppleContactsMCPCapabilities.register(in: self)
        }
        if AppSettings.shared.remindersMCPEnabled {
            AppleRemindersMCPCapabilities.register(in: self)
        }
        if AppSettings.shared.photosMCPEnabled {
            ApplePhotosMCPCapabilities.register(in: self)
        }
        if AppSettings.shared.mailMCPEnabled {
            AppleMailMCPCapabilities.register(in: self)
        }
        if AppSettings.shared.musicMCPEnabled {
            AppleMusicMCPCapabilities.register(in: self)
        }
        if AppSettings.shared.messagesMCPEnabled {
            AppleMessagesMCPCapabilities.register(in: self)
        }
        if AppSettings.shared.githubMCPEnabled {
            GitHubMCPCapabilities.register(in: self)
        }

        register(
            AICapability(
                id: "system.captureScreenshot",
                title: "Capture the Screen",
                appBundleID: nil,
                inputSchema: .init(fields: [
                    .init(name: "mode", description: "screen, window, or region", required: true),
                    .init(name: "destination", description: "file or clipboard", required: true),
                ]),
                // Screen contents may contain private information, so capture always uses
                // the normal inline approval flow even though it does not modify user data.
                riskLevel: .medium
            ) { request in
                let mode = request.input["mode"] ?? "screen"
                let destination = request.input["destination"] ?? "file"
                guard ["screen", "window", "region"].contains(mode),
                      ["file", "clipboard"].contains(destination)
                else {
                    return .init(success: false, output: "Unsupported screenshot options.")
                }

                var arguments: [String] = []
                if mode == "window" { arguments.append("-w") }
                if mode == "region" { arguments.append("-i") }
                if destination == "clipboard" { arguments.append("-c") }

                var outputURL: URL?
                if destination == "file" {
                    let formatter = DateFormatter()
                    formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
                    let filename = "Screenshot \(formatter.string(from: Date())).png"
                    let desktop = FileManager.default.urls(
                        for: .desktopDirectory, in: .userDomainMask).first
                    outputURL = desktop?.appendingPathComponent(filename)
                    guard let outputURL else {
                        return .init(success: false, output: "I couldn't locate the Desktop folder.")
                    }
                    arguments.append(outputURL.path)
                }

                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                process.arguments = arguments
                do {
                    try process.run()
                    await withCheckedContinuation { continuation in
                        process.terminationHandler = { _ in continuation.resume() }
                    }
                } catch {
                    return .init(success: false, output: "Screenshot failed: \(error.localizedDescription)")
                }
                guard process.terminationStatus == 0 else {
                    return .init(
                        success: false,
                        output: mode == "screen"
                            ? "The screenshot could not be captured. Check Screen Recording permission."
                            : "Screenshot selection was cancelled or could not be captured.")
                }
                if let outputURL {
                    guard FileManager.default.fileExists(atPath: outputURL.path) else {
                        return .init(success: false, output: "The screenshot command finished, but no file was created.")
                    }
                    // Remember it: the next question about what the app is doing wrong should
                    // be able to show the agent this shot rather than describe it.
                    WorkbenchEvidence.shared.recordCapture(outputURL)
                    return .init(success: true, output: "Saved screenshot to \(outputURL.path).")
                }
                return .init(success: true, output: "Copied screenshot to the clipboard.")
            }
        )

        register(
            AICapability(
                id: "menu.execute",
                title: "Execute Verified App Menu",
                appBundleID: nil,
                inputSchema: .init(fields: [
                    .init(name: "menuPath", description: "Menu path separated by >", required: true),
                    .init(name: "targetBundleID", description: "Optional app bundle ID for cross-app menu execution", required: false)
                ]),
                riskLevel: .medium
            ) { request in
                guard let rawPath = request.input["menuPath"], !rawPath.isEmpty else {
                    throw AICapabilityError.missingInput("menuPath")
                }
                let path = rawPath.split(separator: ">").map {
                    String($0).trimmingCharacters(in: .whitespacesAndNewlines)
                }
                if let targetBundleID = request.input["targetBundleID"]?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                   !targetBundleID.isEmpty {
                    let isCurrentFrontmostScope = AXContextReader.shared.current.bundleId
                        .caseInsensitiveCompare(targetBundleID) == .orderedSame
                    guard isCurrentFrontmostScope
                        || AppAdapterManager.shared.adapter(for: targetBundleID) != nil
                    else {
                        return .init(
                            success: false,
                            output: "That app is neither the current frontmost scope nor enabled in App Adapters, so its menu cannot be executed.")
                    }
                    let result = await MenuExecutionCoordinator.shared.executeVerifiedMenuAction(
                        bundleIdentifier: targetBundleID,
                        path: path
                    )
                    return .init(success: result.success, output: result.message)
                }
                let pid = AXContextReader.shared.current.pid
                guard pid != 0 else {
                    return .init(success: false, output: "No frontmost app is available")
                }
                guard let app = NSWorkspace.shared.runningApplications.first(where: {
                    $0.processIdentifier == pid && !$0.isTerminated
                }), let bundleID = app.bundleIdentifier else {
                    return .init(success: false, output: "The scoped app is not running.")
                }
                let result = await MenuExecutionCoordinator.shared.executeVerifiedMenuAction(
                    bundleIdentifier: bundleID,
                    path: path
                )
                return .init(success: result.success, output: result.message)
            }
        )

        register(
            AICapability(
                id: "terminal.suggestCommand",
                title: "Suggest Terminal Command",
                appBundleID: nil,
                inputSchema: .init(fields: [
                    .init(name: "command", description: "Complete suggested command", required: true),
                    .init(name: "purpose", description: "Reason for suggestion", required: true),
                ]),
                riskLevel: .low
            ) { request in
                guard let command = request.input["command"], !command.isEmpty else {
                    throw AICapabilityError.missingInput("command")
                }
                let classification = TerminalCommandClassifier.shared.classify(command)
                guard classification.canExecute else {
                    throw AICapabilityError.blocked(
                        classification.blockedReason ?? "Suggested command is blocked"
                    )
                }
                return .init(
                    success: true,
                    output: "\(command)\n\nRisk: \(classification.riskLevel.displayName)\n\(classification.explanation)"
                )
            }
        )

        register(
            AICapability(
                id: "finder.reveal",
                title: "Reveal File In Finder",
                appBundleID: nil,
                inputSchema: .init(fields: [
                    .init(name: "path", description: "Absolute file path", required: true)
                ]),
                riskLevel: .low
            ) { request in
                guard let path = request.input["path"], !path.isEmpty else {
                    throw AICapabilityError.missingInput("path")
                }
                let success = AppleAppsAPI.shared.revealInFinder(path)
                return .init(success: success, output: success ? "Revealed \(path)" : "Could not reveal \(path)")
            }
        )

        register(
            AICapability(
                id: "finder.renamePlan",
                title: "Create Finder Rename Plan",
                appBundleID: "com.apple.finder",
                inputSchema: .init(fields: [
                    .init(name: "pattern", description: "Proposed rename pattern", required: true)
                ]),
                riskLevel: .low
            ) { request in
                guard let pattern = request.input["pattern"], !pattern.isEmpty else {
                    throw AICapabilityError.missingInput("pattern")
                }
                let files: [String]
                if case .filesSelected(let urls) = request.context {
                    files = urls.map(\.lastPathComponent)
                } else {
                    files = AXContextReader.shared.current.selectedFilePaths.map {
                        URL(fileURLWithPath: $0).lastPathComponent
                    }
                }
                guard !files.isEmpty else {
                    return .init(success: false, output: "Select files before creating a rename plan")
                }
                let preview = files.prefix(20).enumerated().map {
                    "\($0.element) -> \(pattern.replacingOccurrences(of: "{n}", with: String($0.offset + 1)))"
                }.joined(separator: "\n")
                return .init(success: true, output: "Rename preview only:\n\(preview)")
            }
        )

        register(
            AICapability(
                id: "safari.summarizePage",
                title: "Summarize Current Safari Page",
                appBundleID: "com.apple.Safari",
                inputSchema: .init(fields: []),
                riskLevel: .low
            ) { _ in
                let live = AXContextReader.shared.current
                let extensionContext = SafariBrowserBridge.shared.isFresh
                    ? SafariBrowserBridge.shared.currentContext() : nil
                let snapshot = AXWebReader.shared.cachedSnapshot(for: live.pid)
                let pageText = extensionContext?.pageTextForAI ?? snapshot?.text ?? ""
                let pageURL = extensionContext?.url ?? snapshot?.url ?? ""
                let pageTitle = extensionContext?.title ?? snapshot?.title ?? ""
                guard !pageText.isEmpty else {
                    return .init(
                        success: false,
                        output: "Page text is not ready. Reload the page and allow the Context Dock Safari Extension for this website."
                    )
                }
                let compacted = MarkItDownService.compact(
                    pageText, for: "summarize this page", limit: 5_000)
                let response = try await AIProviderRouter.shared.send(
                    AIRequest(
                        text: "Summarize this page concisely.",
                        context: .url(pageURL),
                        source: .contextDock,
                        liveContext: ContextSnapshot(
                            frontmostApp: live.appName,
                            bundleIdentifier: live.bundleId,
                            windowTitle: live.windowTitle,
                            selectedText: live.selectedText,
                            selectedTextSource: live.appName,
                            selectedTextCharacterCount: live.selectedText?.count ?? 0,
                            selectedFiles: live.selectedFilePaths,
                            currentDirectory: nil,
                            browserContext: BrowserContextSnapshot(
                                url: pageURL,
                                title: pageTitle
                            ),
                            menuCapabilities: live.menuItems.filter(\.enabled).map(\.fullPath),
                            registeredCapabilities: CapabilityRegistry.shared
                                .capabilities(for: live.bundleId)
                                .map(\.id)
                        ),
                        additionalContextPrompt: "Page content:\n\(compacted)"
                    )
                )
                return .init(success: true, output: response)
            }
        )

        register(
            AICapability(
                id: "terminal.runCommand",
                title: "Run Terminal Command",
                appBundleID: nil,
                inputSchema: .init(fields: [
                    .init(name: "command", description: "Complete command to preview and run", required: true),
                    .init(name: "purpose", description: "Reason for running command", required: true),
                ]),
                riskLevel: .medium
            ) { request in
                guard let command = request.input["command"], !command.isEmpty else {
                    throw AICapabilityError.missingInput("command")
                }
                let purpose = request.input["purpose"] ?? "AI suggested command"
                let result = await TerminalCommandExecutor.shared.run(command, purpose: purpose)
                return .init(success: result.success, output: result.output)
            }
        )

        register(
            AICapability(
                id: "finder.directAction",
                title: "Run Finder Direct Action",
                appBundleID: "com.apple.finder",
                inputSchema: .init(fields: [
                    .init(name: "menuPath", description: "Menu path separated by >", required: true)
                ]),
                riskLevel: .high
            ) { request in
                guard let rawPath = request.input["menuPath"], !rawPath.isEmpty else {
                    throw AICapabilityError.missingInput("menuPath")
                }
                let path = rawPath.split(separator: ">").map {
                    String($0).trimmingCharacters(in: .whitespacesAndNewlines)
                }
                switch await FinderActionService.shared.executeDirectActionIfNeeded(path: path) {
                case .handled(let success, let message, _, _):
                    return .init(success: success, output: message)
                case .notHandled:
                    return .init(success: false, output: "Finder direct action is not registered")
                }
            }
        )

        register(
            AICapability(
                id: "extension.run",
                title: "Run Context-Dock Extension",
                appBundleID: nil,
                inputSchema: .init(fields: [
                    .init(name: "extensionID", description: "Registered extension UUID", required: true)
                ]),
                riskLevel: .medium
            ) { request in
                guard let rawID = request.input["extensionID"],
                      let id = UUID(uuidString: rawID),
                      let manifest = ExtensionRegistry.shared.manifests.first(where: { $0.id == id })
                else {
                    throw AICapabilityError.unknownCapability("extension.run:\(request.input["extensionID"] ?? "")")
                }
                let scope: ExtensionScope = request.context.hasExplicitSelection
                    ? .globalWithSelection : .contextDock
                let context = ExtensionContext.collect(scope: scope, userContext: request.context)
                let output = try await ExtensionRunner.shared.execute(manifest, context: context)
                return .init(success: true, output: output)
            }
        )
    }
}

@MainActor
final class AIResponseParser {
    static let shared = AIResponseParser()

    private init() {}

    func parseActionPlan(_ response: String) throws -> AIActionPlan {
        let cleaned = response
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = cleaned.data(using: .utf8),
              let plan = try? JSONDecoder().decode(AIActionPlan.self, from: data)
        else {
            throw AICapabilityError.invalidPlan
        }
        guard !plan.capability.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AICapabilityError.invalidPlan
        }
        guard CapabilityRegistry.shared.capability(id: plan.capability) != nil else {
            throw AICapabilityError.unknownCapability(plan.capability)
        }
        return plan
    }
}

@MainActor
final class AIExecutionEngine {
    static let shared = AIExecutionEngine()

    private init() {}

    func execute(
        _ plan: AIActionPlan,
        context: UserContext,
        approved: Bool = false
    ) async throws -> AICapabilityExecutionResult {
        guard let capability = CapabilityRegistry.shared.capability(id: plan.capability) else {
            throw AICapabilityError.unknownCapability(plan.capability)
        }
        if capability.riskLevel == .critical {
            throw AICapabilityError.blocked("Capability is blocked")
        }
        if capability.riskLevel.requiresApproval && !approved {
            throw AICapabilityError.approvalRequired(capability.title)
        }
        for field in capability.inputSchema.fields where field.required {
            guard let value = plan.input[field.name], !value.isEmpty else {
                throw AICapabilityError.missingInput(field.name)
            }
        }
        return try await capability.executor(.init(input: plan.input, context: context))
    }

    func executeWithApproval(
        _ plan: AIActionPlan,
        context: UserContext
    ) async throws -> AICapabilityExecutionResult {
        guard let capability = CapabilityRegistry.shared.capability(id: plan.capability) else {
            throw AICapabilityError.unknownCapability(plan.capability)
        }
        if capability.riskLevel.requiresApproval {
            let approved = await AICapabilityApprovalCenter.shared.requestApproval(
                plan: plan,
                capability: capability,
                context: context
            )
            guard approved else {
                AIAuditHistory.shared.record(
                    capabilityID: capability.id,
                    risk: capability.riskLevel,
                    approved: false,
                    success: false,
                    summary: "Denied by user"
                )
                throw AICapabilityError.approvalRequired(capability.title)
            }
        }
        do {
            let result = try await execute(plan, context: context, approved: true)
            AIAuditHistory.shared.record(
                capabilityID: capability.id,
                risk: capability.riskLevel,
                approved: capability.riskLevel.requiresApproval,
                success: result.success,
                summary: result.output
            )
            return result
        } catch {
            AIAuditHistory.shared.record(
                capabilityID: capability.id,
                risk: capability.riskLevel,
                approved: capability.riskLevel.requiresApproval,
                success: false,
                summary: error.localizedDescription
            )
            throw error
        }
    }

    func suggestedCommandPlan(command: String, purpose: String) throws -> AIActionPlan {
        let classification = TerminalCommandClassifier.shared.classify(command)
        guard classification.canExecute else {
            throw AICapabilityError.blocked(
                classification.blockedReason ?? "Suggested command is blocked"
            )
        }
        return AIActionPlan(
            capability: "terminal.runCommand",
            input: ["command": command, "purpose": purpose],
            explanation: classification.explanation
        )
    }

    func executeUnifiedWithApproval(
        _ plan: AIActionPlan,
        context: UserContext
    ) async -> AIUnifiedExecutionResult {
        do {
            let result = try await executeWithApproval(plan, context: context)
            return AIUnifiedExecutionResult(
                capabilityID: plan.capability,
                success: result.success,
                output: result.output,
                sideEffects: result.success ? [plan.explanation] : [],
                verification: verificationStatus(
                    for: plan,
                    succeeded: result.success,
                    output: result.output),
                error: result.success ? nil : result.output
            )
        } catch {
            return AIUnifiedExecutionResult(
                capabilityID: plan.capability,
                success: false,
                output: "",
                sideEffects: [],
                verification: .unverified,
                error: error.localizedDescription
            )
        }
    }

    /// Keep receipts truthful: only routes that perform their own concrete artifact
    /// read-back are marked verified. All other successful executors are explicitly
    /// distinguished from independent verification.
    private func verificationStatus(
        for plan: AIActionPlan,
        succeeded: Bool,
        output: String
    ) -> AIVerificationStatus {
        guard succeeded else { return .unverified }
        if plan.capability == "system.captureScreenshot",
           plan.input["destination"] != "clipboard" {
            // The screenshot executor checks that its output file exists before success.
            return .verified
        }
        if selfReadBackCapabilities.contains(plan.capability),
           !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .verified
        }
        return .executorConfirmed
    }

    private var selfReadBackCapabilities: Set<String> {
        [
            "calendar.list",
            "calendar.search",
            "calendar.today",
            "contacts.details",
            "contacts.search",
            "git.branches",
            "git.diff",
            "git.log",
            "git.status",
            "github.get_repo",
            "github.list_issues",
            "github.list_prs",
            "mcp.listTools",
            "notes.extract_tasks",
            "notes.read",
            "notes.search",
            "notes.summarize",
            "reminders.list",
            "reminders.today",
            "tailscale.netcheck",
            "tailscale.status",
            "xcode.list",
            "xcode.showBuildSettings",
        ]
    }
}

@MainActor
final class AICapabilityApprovalCenter: ObservableObject {
    static let shared = AICapabilityApprovalCenter()

    struct PendingApproval: Identifiable {
        let id = UUID()
        let plan: AIActionPlan
        let capability: AICapability
        let context: UserContext
        let continuation: CheckedContinuation<Bool, Never>
    }

    @Published private(set) var pending: PendingApproval?
    private var expiryTask: Task<Void, Never>?

    private init() {}

    func requestApproval(plan: AIActionPlan, capability: AICapability, context: UserContext) async -> Bool {
        await withCheckedContinuation { continuation in
            expiryTask?.cancel()
            pending = PendingApproval(
                plan: plan,
                capability: capability,
                context: context,
                continuation: continuation
            )
            expiryTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 60_000_000_000)
                guard !Task.isCancelled else { return }
                self?.deny()
            }
        }
    }

    func approve() {
        guard let pending else { return }
        expiryTask?.cancel()
        expiryTask = nil
        self.pending = nil
        pending.continuation.resume(returning: true)
    }

    func deny() {
        guard let pending else { return }
        expiryTask?.cancel()
        expiryTask = nil
        self.pending = nil
        pending.continuation.resume(returning: false)
    }
}

struct AIAuditEntry: Codable, Identifiable {
    let id: UUID
    let timestamp: Date
    let capabilityID: String
    let risk: AICapabilityRiskLevel
    let approved: Bool
    let success: Bool
    let summary: String
}

@MainActor
final class AIAuditHistory: ObservableObject {
    static let shared = AIAuditHistory()

    @Published private(set) var entries: [AIAuditEntry] = []
    private let fileURL: URL

    private init() {
        let directory = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!.appendingPathComponent("Context-Dock", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        fileURL = directory.appendingPathComponent("ai-audit.json")
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([AIAuditEntry].self, from: data) {
            entries = decoded
        }
    }

    func record(
        capabilityID: String,
        risk: AICapabilityRiskLevel,
        approved: Bool,
        success: Bool,
        summary: String
    ) {
        entries.append(
            AIAuditEntry(
                id: UUID(),
                timestamp: Date(),
                capabilityID: capabilityID,
                risk: risk,
                approved: approved,
                success: success,
                summary: String(summary.prefix(2_000))
            )
        )
        if entries.count > 500 { entries.removeFirst(entries.count - 500) }
        if let data = try? JSONEncoder().encode(entries) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}

private extension UserContext {
    var hasExplicitSelection: Bool {
        switch self {
        case .filesSelected, .textSelected, .url, .contactSelected: return true
        case .appFocused, .none: return false
        }
    }
}
