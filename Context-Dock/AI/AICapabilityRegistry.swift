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

struct AICapability {
    let id: String
    let title: String
    let appBundleID: String?
    let inputSchema: AICapabilityInputSchema
    let riskLevel: AICapabilityRiskLevel
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

    func promptBlock(for bundleID: String?) -> String {
        let entries = capabilities(for: bundleID).map { capability in
            let fields = capability.inputSchema.fields.map(\.name).joined(separator: ", ")
            return "- \(capability.id): \(capability.title) | risk=\(capability.riskLevel.rawValue) | input=[\(fields)]"
        }
        return "Registered capabilities:\n" + entries.joined(separator: "\n")
    }

    private func registerBuiltIns() {
        GitCapabilities.register(in: self)
        TailscaleCapabilities.register(in: self)
        XcodeCapabilities.register(in: self)
        FinderFileChangeCapabilities.register(in: self)
        // Apple Notes MCP — only registered when explicitly enabled
        if AppSettings.shared.noteMCPEnabled {
            AppleNotesMCPCapabilities.register(in: self)
        }

        register(
            AICapability(
                id: "menu.execute",
                title: "Execute Frontmost App Menu",
                appBundleID: nil,
                inputSchema: .init(fields: [
                    .init(name: "menuPath", description: "Menu path separated by >", required: true)
                ]),
                riskLevel: .medium
            ) { request in
                guard let rawPath = request.input["menuPath"], !rawPath.isEmpty else {
                    throw AICapabilityError.missingInput("menuPath")
                }
                let path = rawPath.split(separator: ">").map {
                    String($0).trimmingCharacters(in: .whitespacesAndNewlines)
                }
                let pid = AXContextReader.shared.current.pid
                guard pid != 0 else {
                    return .init(success: false, output: "No frontmost app is available")
                }
                let success = AXMenuReader.shared.clickMenuItem(path: path, in: pid)
                return .init(
                    success: success,
                    output: success ? "Executed \(path.joined(separator: " > "))" : "Menu action is unavailable now"
                )
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
                guard let snapshot = AXWebReader.shared.cachedSnapshot(for: live.pid),
                      !snapshot.text.isEmpty
                else {
                    return .init(
                        success: false,
                        output: "Page text is not ready. Refresh browser context and try again."
                    )
                }
                let response = try await AIProviderRouter.shared.send(
                    AIRequest(
                        text: "Summarize this page concisely.",
                        context: .url(snapshot.url),
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
                                url: snapshot.url,
                                title: snapshot.title
                            ),
                            menuCapabilities: live.menuItems.filter(\.enabled).map(\.fullPath),
                            registeredCapabilities: CapabilityRegistry.shared
                                .capabilities(for: live.bundleId)
                                .map(\.id)
                        ),
                        additionalContextPrompt: "Page content:\n\(snapshot.text)"
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
                let result = await TerminalAIBridge.shared.processAICommand(command, purpose: purpose)
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
