import Foundation
import SwiftUI

// MARK: - L2 GitHub Bridge
// Integrates GitHub tool discovery with L2UnifiedAssistant

/// Bridge between L2 queries and GitHub tool management
@MainActor
class L2GitHubBridge {
    static let shared = L2GitHubBridge()

    private let toolManager = GitHubToolManager.shared

    private init() {}

    // MARK: - Query Processing

    /// Check if a query contains a GitHub URL and should be handled
    func shouldHandle(query: String) -> Bool {
        return toolManager.extractGitHubURL(from: query) != nil
    }

    /// Process a query containing a GitHub URL
    /// Returns an L2Response that can be displayed in the L2 interface
    func processGitHubQuery(_ query: String) async -> L2GitHubBridgeResponse {
        // Extract GitHub URL
        guard let url = toolManager.extractGitHubURL(from: query) else {
            return L2GitHubBridgeResponse(
                success: false,
                message: "No GitHub URL found in query",
                analysis: nil,
                actions: []
            )
        }

        // Check if user wants to install or just analyze
        let queryLower = query.lowercased()
        let wantsInstall = queryLower.contains("install") ||
                          queryLower.contains("add") ||
                          queryLower.contains("setup") ||
                          queryLower.contains("get")

        // Analyze the repository
        guard let analysis = await toolManager.analyzeRepository(url: url) else {
            return L2GitHubBridgeResponse(
                success: false,
                message: toolManager.error ?? "Failed to analyze repository",
                analysis: nil,
                actions: []
            )
        }

        // Build response message
        let message = buildResponseMessage(analysis: analysis, wantsInstall: wantsInstall)

        // Build available actions
        let actions = buildActions(analysis: analysis)

        return L2GitHubBridgeResponse(
            success: true,
            message: message,
            analysis: analysis,
            actions: actions
        )
    }

    // MARK: - Response Building

    private func buildResponseMessage(analysis: GitHubAnalysis, wantsInstall: Bool) -> String {
        let tool = analysis.tool

        var message = """
        ## 📦 \(tool.name)

        | Property | Value |
        |----------|-------|
        | **Repository** | [\(tool.fullName)](\(tool.repositoryURL.absoluteString)) |
        | **Description** | \(tool.description) |
        | **Language** | \(tool.language ?? "Unknown") |
        | **Stars** | ⭐ \(formatNumber(tool.stars)) |
        | **Status** | \(tool.isInstalled ? "✅ Installed" : "⬇️ Not installed") |

        """

        // Capabilities
        if !tool.capabilities.isEmpty {
            message += "\n### 🛠 Capabilities\n"
            message += tool.capabilities.prefix(8).map { "- \($0)" }.joined(separator: "\n")
            message += "\n"
        }

        // Latest release
        if let release = tool.latestRelease {
            message += "\n### 📋 Latest Release: `\(release.tagName)`\n"
            if let date = release.publishedAt {
                message += "Released: \(date.formatted(date: .abbreviated, time: .omitted))\n"
            }
        }

        // Installation
        message += "\n### 💻 Installation\n"
        message += "**Recommended method:** \(analysis.suggestedInstallMethod.displayName)\n"
        message += "```bash\n\(analysis.installCommand)\n```\n"

        // Alternative methods
        let alternatives = tool.installMethods.filter { $0 != analysis.suggestedInstallMethod }
        if !alternatives.isEmpty {
            message += "\n**Alternative methods:**\n"
            for method in alternatives {
                let cmd = toolManager.generateInstallCommand(tool: tool, method: method)
                message += "- \(method.displayName): `\(cmd)`\n"
            }
        }

        // Risk assessment
        message += "\n### ⚠️ Risk Assessment: **\(analysis.riskAssessment.level.rawValue)**\n"
        for reason in analysis.riskAssessment.reasons {
            message += "- \(reason)\n"
        }

        if !analysis.riskAssessment.recommendations.isEmpty {
            message += "\n**Recommendations:**\n"
            for rec in analysis.riskAssessment.recommendations {
                message += "- ⚡ \(rec)\n"
            }
        }

        // If user wants to install
        if wantsInstall && !tool.isInstalled {
            message += "\n---\n"
            message += "**Ready to install?** Click the Install button or I can run the command for you.\n"
        } else if tool.isInstalled {
            message += "\n---\n"
            message += "✅ This tool is already installed"
            if let path = tool.installedPath {
                message += " at `\(path)`"
            }
            message += ". You can use it right away!\n"
        }

        return message
    }

    private func buildActions(analysis: GitHubAnalysis) -> [L2GitHubBridgeAction] {
        var actions: [L2GitHubBridgeAction] = []

        if !analysis.tool.isInstalled {
            // Primary install action
            actions.append(L2GitHubBridgeAction(
                id: "install_primary",
                title: "Install via \(analysis.suggestedInstallMethod.displayName)",
                icon: "arrow.down.circle.fill",
                isPrimary: true,
                actionType: .install(method: analysis.suggestedInstallMethod, command: analysis.installCommand)
            ))

            // Alternative install methods
            for method in analysis.tool.installMethods where method != analysis.suggestedInstallMethod {
                let cmd = toolManager.generateInstallCommand(tool: analysis.tool, method: method)
                actions.append(L2GitHubBridgeAction(
                    id: "install_\(method.rawValue)",
                    title: "Install via \(method.displayName)",
                    icon: "arrow.down.circle",
                    isPrimary: false,
                    actionType: .install(method: method, command: cmd)
                ))
            }
        }

        // Open in browser
        actions.append(L2GitHubBridgeAction(
            id: "open_browser",
            title: "Open in Browser",
            icon: "safari",
            isPrimary: false,
            actionType: .openURL(analysis.tool.repositoryURL)
        ))

        // Copy install command
        actions.append(L2GitHubBridgeAction(
            id: "copy_command",
            title: "Copy Install Command",
            icon: "doc.on.clipboard",
            isPrimary: false,
            actionType: .copyToClipboard(analysis.installCommand)
        ))

        // View releases
        if analysis.tool.latestRelease != nil {
            let releasesURL = URL(string: "\(analysis.tool.repositoryURL.absoluteString)/releases")!
            actions.append(L2GitHubBridgeAction(
                id: "view_releases",
                title: "View Releases",
                icon: "tag",
                isPrimary: false,
                actionType: .openURL(releasesURL)
            ))
        }

        return actions
    }

    // MARK: - Action Execution

    /// Execute an action from the response
    func executeAction(_ action: L2GitHubBridgeAction, tool: GitHubTool) async -> ActionResult {
        switch action.actionType {
        case .install(let method, let command):
            let result = await toolManager.installTool(tool, method: method, customCommand: command)
            return ActionResult(
                success: result.success,
                message: result.success
                    ? "Successfully installed \(tool.name)!"
                    : result.error ?? "Installation failed",
                output: result.output
            )

        case .openURL(let url):
            NSWorkspace.shared.open(url)
            return ActionResult(success: true, message: "Opened in browser", output: nil)

        case .copyToClipboard(let text):
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            return ActionResult(success: true, message: "Copied to clipboard", output: nil)
        }
    }

    struct ActionResult {
        let success: Bool
        let message: String
        let output: String?
    }

    // MARK: - Helpers

    private func formatNumber(_ num: Int) -> String {
        if num >= 1000 {
            return String(format: "%.1fk", Double(num) / 1000.0)
        }
        return "\(num)"
    }
}

// MARK: - Response Models

struct L2GitHubBridgeResponse {
    let success: Bool
    let message: String
    let analysis: GitHubAnalysis?
    let actions: [L2GitHubBridgeAction]
}

struct L2GitHubBridgeAction: Identifiable {
    let id: String
    let title: String
    let icon: String
    let isPrimary: Bool
    let actionType: ActionType

    enum ActionType {
        case install(method: GitHubTool.InstallMethod, command: String)
        case openURL(URL)
        case copyToClipboard(String)
    }
}

// MARK: - L2UnifiedAssistant Extension

extension L2UnifiedAssistant {

    /// Check if query contains GitHub URL and handle it
    func handleGitHubURL(in query: String) async -> L2Response? {
        let bridge = L2GitHubBridge.shared

        guard bridge.shouldHandle(query: query) else {
            return nil
        }

        let response = await bridge.processGitHubQuery(query)

        // Convert to L2Response format - create actions that execute the GitHub actions
        var actions: [L2Response.L2Action] = []

        for action in response.actions {
            // Capture action details for the closure
            let actionType = action.actionType
            let tool = response.analysis?.tool

            actions.append(L2Response.L2Action(
                title: action.title,
                icon: action.icon,
                action: {
                    if let tool = tool {
                        _ = await bridge.executeAction(
                            L2GitHubBridgeAction(
                                id: action.id,
                                title: action.title,
                                icon: action.icon,
                                isPrimary: action.isPrimary,
                                actionType: actionType
                            ),
                            tool: tool
                        )
                    }
                }
            ))
        }

        // Build data dictionary
        var data: [String: Any]? = nil
        if let analysis = response.analysis {
            data = [
                "tool": analysis.tool.name,
                "installed": analysis.tool.isInstalled,
                "source": "github"
            ]
        }

        return L2Response(
            message: response.message,
            data: data,
            actions: actions,
            suggestedFollowUps: response.success ? [
                "Run \(response.analysis?.tool.name ?? "the tool")",
                "Show installed tools",
                "What can \(response.analysis?.tool.name ?? "it") do?"
            ] : []
        )
    }
}

// MARK: - GitHub Tools Settings View

/// Settings view for managing discovered GitHub tools
struct GitHubToolsSettingsView: View {
    @StateObject private var manager = GitHubToolManager.shared
    @State private var searchText = ""
    @State private var selectedTool: GitHubTool?
    @State private var showAnalysis = false

    var filteredTools: [GitHubTool] {
        if searchText.isEmpty {
            return manager.discoveredTools
        }
        return manager.discoveredTools.filter {
            $0.name.localizedCaseInsensitiveContains(searchText) ||
            $0.description.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("GitHub Tools")
                    .font(.headline)

                Spacer()

                Text("\(manager.discoveredTools.count) discovered")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding()

            // Search
            TextField("Search tools...", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal)

            Divider()
                .padding(.top, 8)

            // List
            if filteredTools.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "shippingbox")
                        .font(.system(size: 40))
                        .foregroundColor(.secondary)

                    Text("No GitHub tools discovered yet")
                        .font(.headline)

                    Text("Paste a GitHub URL in L2 to analyze and install tools")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding()
            } else {
                List(filteredTools) { tool in
                    GitHubToolRow(tool: tool)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            selectedTool = tool
                            showAnalysis = true
                        }
                }
            }
        }
        .sheet(isPresented: $showAnalysis) {
            if let tool = selectedTool,
               let analysis = manager.currentAnalysis,
               analysis.tool.id == tool.id {
                GitHubToolAnalysisView(analysis: analysis)
            } else if let tool = selectedTool {
                // Re-analyze
                GitHubToolReanalysisView(tool: tool)
            }
        }
    }
}

struct GitHubToolRow: View {
    let tool: GitHubTool

    var body: some View {
        HStack(spacing: 12) {
            // Status indicator
            Circle()
                .fill(tool.isInstalled ? Color.green : Color.gray)
                .frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(tool.name)
                        .fontWeight(.medium)

                    if let lang = tool.language {
                        Text(lang)
                            .font(.caption2)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 2)
                            .background(Color.blue.opacity(0.1))
                            .cornerRadius(4)
                    }
                }

                Text(tool.description)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            HStack(spacing: 4) {
                Image(systemName: "star.fill")
                    .foregroundColor(.yellow)
                    .font(.caption2)
                Text("\(tool.stars)")
                    .font(.caption)
            }
        }
        .padding(.vertical, 4)
    }
}

struct GitHubToolReanalysisView: View {
    let tool: GitHubTool
    @StateObject private var manager = GitHubToolManager.shared
    @State private var analysis: GitHubAnalysis?
    @State private var isLoading = true
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Group {
            if isLoading {
                VStack {
                    ProgressView()
                    Text("Analyzing \(tool.name)...")
                        .foregroundColor(.secondary)
                }
                .frame(width: 400, height: 300)
            } else if let analysis = analysis {
                GitHubToolAnalysisView(analysis: analysis)
            } else {
                VStack {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.largeTitle)
                        .foregroundColor(.orange)
                    Text("Failed to analyze repository")
                    Button("Close") { dismiss() }
                }
                .frame(width: 400, height: 300)
            }
        }
        .task {
            analysis = await manager.analyzeRepository(url: tool.repositoryURL)
            isLoading = false
        }
    }
}

// MARK: - Preview

#Preview("GitHub Tools Settings") {
    GitHubToolsSettingsView()
        .frame(width: 500, height: 400)
}
