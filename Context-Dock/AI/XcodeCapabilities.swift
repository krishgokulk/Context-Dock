import Foundation

@MainActor
enum XcodeCapabilities {
    static func register(in registry: CapabilityRegistry) {
        registerReadOnly(
            id: "xcode.list",
            title: "List Xcode Project",
            command: "xcodebuild -list",
            purpose: "Inspect Xcode project schemes and targets",
            registry: registry
        )
        registerReadOnly(
            id: "xcode.showBuildSettings",
            title: "Show Xcode Build Settings",
            command: "xcodebuild -showBuildSettings",
            purpose: "Inspect Xcode project build settings",
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
                appBundleID: "com.apple.dt.Xcode",
                inputSchema: .init(fields: [
                    .init(
                        name: "path",
                        description: "Project directory; defaults to current Finder folder",
                        required: false
                    )
                ]),
                riskLevel: .low
            ) { request in
                let path = projectDirectory(from: request)
                let scopedCommand = "cd \(shellQuote(path)) && \(command)"
                let result = await TerminalCommandExecutor.shared.run(
                    scopedCommand,
                    purpose: purpose
                )
                return .init(success: result.success, output: result.output)
            }
        )
    }

    private static func projectDirectory(from request: AICapabilityExecutionRequest) -> String {
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
