import Foundation

@MainActor
enum GitCapabilities {
    static func register(in registry: CapabilityRegistry) {
        registerReadOnly(
            id: "git.status",
            title: "Git Status",
            command: "git status --short --branch",
            purpose: "Inspect repository status",
            registry: registry
        )
        registerReadOnly(
            id: "git.diff",
            title: "Git Diff",
            command: "git diff --stat && git diff",
            purpose: "Inspect uncommitted repository changes",
            registry: registry
        )
        registerReadOnly(
            id: "git.log",
            title: "Git Recent Commits",
            command: "git log --oneline --decorate -20",
            purpose: "Inspect recent repository commits",
            registry: registry
        )
        registerReadOnly(
            id: "git.branches",
            title: "Git Branches",
            command: "git branch --all --verbose --no-abbrev",
            purpose: "Inspect repository branches",
            registry: registry
        )
    }

    private static func registerReadOnly(
        id: String,
        title: String,
        command: String,
        purpose: String,
        registry: CapabilityRegistry
    ) {
        registry.register(
            AICapability(
                id: id,
                title: title,
                appBundleID: nil,
                inputSchema: .init(fields: [
                    .init(
                        name: "path",
                        description: "Repository directory; defaults to current Finder folder",
                        required: false
                    )
                ]),
                riskLevel: .low
            ) { request in
                let directory = workingDirectory(from: request)
                let scopedCommand = "cd \(shellQuote(directory)) && \(command)"
                let result = await TerminalAIBridge.shared.processAICommand(
                    scopedCommand,
                    purpose: purpose
                )
                return .init(success: result.success, output: result.output)
            }
        )
    }

    private static func workingDirectory(from request: AICapabilityExecutionRequest) -> String {
        if let path = request.input["path"], !path.isEmpty { return path }
        if case .filesSelected(let urls) = request.context, let first = urls.first {
            return first.hasDirectoryPath ? first.path : first.deletingLastPathComponent().path
        }
        let finderFolder = AppleAppsAPI.shared.getCurrentFolder()
        return finderFolder.isEmpty ? FileManager.default.homeDirectoryForCurrentUser.path : finderFolder
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
