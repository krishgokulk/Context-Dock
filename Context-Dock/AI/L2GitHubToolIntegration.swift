import Foundation
import AppKit
import Combine

// MARK: - GitHub Tool Integration for L2
// Intelligent handling of GitHub tool links - discovers, installs, and registers tools

// MARK: - Data Models

/// Represents a tool discovered from GitHub
struct GitHubTool: Identifiable, Codable {
    let id: UUID
    let name: String
    let fullName: String                    // owner/repo
    let description: String
    let repositoryURL: URL
    let homepage: URL?
    let language: String?
    let topics: [String]
    let stars: Int
    let latestRelease: GitHubRelease?
    let installMethods: [InstallMethod]
    let capabilities: [String]              // AI-detected capabilities
    let detectedAt: Date
    var isInstalled: Bool
    var installedVersion: String?
    var installedPath: String?

    /// How this tool can be installed
    enum InstallMethod: String, Codable, CaseIterable {
        case homebrew = "brew"
        case cargo = "cargo"
        case npm = "npm"
        case pip = "pip"
        case go = "go"
        case gitClone = "git"
        case binary = "binary"
        case script = "script"

        var displayName: String {
            switch self {
            case .homebrew: return "Homebrew"
            case .cargo: return "Cargo (Rust)"
            case .npm: return "npm"
            case .pip: return "pip (Python)"
            case .go: return "Go Install"
            case .gitClone: return "Git Clone"
            case .binary: return "Binary Download"
            case .script: return "Install Script"
            }
        }

        var requiresApproval: Bool {
            switch self {
            case .homebrew, .cargo, .npm, .pip, .go:
                return true  // Package manager - medium risk
            case .gitClone:
                return true  // Clones code
            case .binary, .script:
                return true  // Higher risk - downloads executables
            }
        }
    }
}

/// GitHub release information
struct GitHubRelease: Codable {
    let tagName: String
    let name: String?
    let publishedAt: Date?
    let assets: [ReleaseAsset]
    let body: String?               // Release notes (markdown)

    struct ReleaseAsset: Codable {
        let name: String
        let downloadURL: URL
        let size: Int
        let contentType: String
    }
}

/// Parsed README information
struct GitHubREADME: Codable {
    let content: String
    let installInstructions: [String]
    let usageExamples: [String]
    let detectedCapabilities: [String]
    let dependencies: [String]
}

/// Result of analyzing a GitHub URL
struct GitHubAnalysis {
    let tool: GitHubTool
    let readme: GitHubREADME?
    let suggestedInstallMethod: GitHubTool.InstallMethod
    let installCommand: String
    let riskAssessment: RiskAssessment

    struct RiskAssessment {
        let level: RiskLevel
        let reasons: [String]
        let recommendations: [String]

        enum RiskLevel: String {
            case low = "Low"
            case medium = "Medium"
            case high = "High"
            case unknown = "Unknown"

            var color: String {
                switch self {
                case .low: return "green"
                case .medium: return "yellow"
                case .high: return "orange"
                case .unknown: return "gray"
                }
            }
        }
    }
}

// MARK: - GitHub Tool Manager

/// Manages GitHub tool discovery, analysis, and installation
@MainActor
final class GitHubToolManager: ObservableObject {
    static let shared = GitHubToolManager()

    // MARK: - Published State
    @Published var discoveredTools: [GitHubTool] = []
    @Published var isAnalyzing: Bool = false
    @Published var currentAnalysis: GitHubAnalysis?
    @Published var error: String?

    // MARK: - Configuration
    private let cacheDirectory: URL
    private let toolRegistryKey = "l2_github_tools"
    private var githubToken: String? // Optional for higher rate limits

    // Package manager detection patterns
    private let installPatterns: [GitHubTool.InstallMethod: [String]] = [
        .homebrew: ["brew install", "homebrew", "brew tap"],
        .cargo: ["cargo install", "crates.io", "Cargo.toml"],
        .npm: ["npm install", "npx", "package.json", "yarn add"],
        .pip: ["pip install", "pip3 install", "setup.py", "pyproject.toml"],
        .go: ["go install", "go get", "go.mod"],
        .gitClone: ["git clone", "clone the repository"],
        .binary: ["download the binary", "releases page", "prebuilt"],
        .script: ["curl", "wget", "install.sh", "setup.sh"]
    ]

    private init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        cacheDirectory = appSupport.appendingPathComponent("ILauncher/GitHubTools")
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        loadCachedTools()
    }

    // MARK: - Public API

    /// Detect if a string contains a GitHub URL and analyze it
    func detectAndAnalyze(input: String) async -> GitHubAnalysis? {
        guard let url = extractGitHubURL(from: input) else {
            return nil
        }
        return await analyzeRepository(url: url)
    }

    /// Analyze a GitHub repository URL
    func analyzeRepository(url: URL) async -> GitHubAnalysis? {
        isAnalyzing = true
        error = nil

        defer { isAnalyzing = false }

        do {
            // 1. Parse the URL to get owner/repo
            guard let (owner, repo) = parseGitHubURL(url) else {
                error = "Invalid GitHub URL format"
                return nil
            }

            // 2. Fetch repository metadata
            let repoData = try await fetchRepositoryInfo(owner: owner, repo: repo)

            // 3. Fetch README
            let readme = try? await fetchREADME(owner: owner, repo: repo)

            // 4. Fetch latest release
            let release = try? await fetchLatestRelease(owner: owner, repo: repo)

            // 5. Detect install methods from README
            let installMethods = detectInstallMethods(from: readme?.content ?? "")

            // 6. AI-analyze capabilities
            let capabilities = await analyzeCapabilities(
                readme: readme?.content,
                description: repoData.description,
                topics: repoData.topics
            )

            // 7. Create GitHubTool
            let tool = GitHubTool(
                id: UUID(),
                name: repo,
                fullName: "\(owner)/\(repo)",
                description: repoData.description ?? "No description",
                repositoryURL: url,
                homepage: repoData.homepage,
                language: repoData.language,
                topics: repoData.topics,
                stars: repoData.stars,
                latestRelease: release,
                installMethods: installMethods.isEmpty ? [.gitClone] : installMethods,
                capabilities: capabilities,
                detectedAt: Date(),
                isInstalled: checkIfInstalled(name: repo),
                installedVersion: nil,
                installedPath: nil
            )

            // 8. Determine best install method and command
            let (suggestedMethod, installCommand) = determineBestInstallMethod(
                tool: tool,
                readme: readme
            )

            // 9. Assess risk
            let risk = assessRisk(tool: tool, method: suggestedMethod)

            // 10. Create analysis result
            let analysis = GitHubAnalysis(
                tool: tool,
                readme: readme,
                suggestedInstallMethod: suggestedMethod,
                installCommand: installCommand,
                riskAssessment: risk
            )

            currentAnalysis = analysis

            // Cache the tool
            cacheDiscoveredTool(tool)

            return analysis

        } catch {
            self.error = "Failed to analyze: \(error.localizedDescription)"
            return nil
        }
    }

    /// Install a tool using the specified method
    func installTool(_ tool: GitHubTool, method: GitHubTool.InstallMethod, customCommand: String? = nil) async -> InstallResult {
        let command = customCommand ?? generateInstallCommand(tool: tool, method: method)

        // Use TerminalAIBridge for safe execution with approval
        let purpose = "Install \(tool.name) from GitHub (\(tool.fullName))"

        // This will show approval dialog via TerminalAIBridge
        let (success, output) = await TerminalAIBridge.shared.processAICommand(
            command,
            purpose: purpose
        )

        if success {
            // Update tool status
            var updatedTool = tool
            updatedTool.isInstalled = true
            updatedTool.installedVersion = tool.latestRelease?.tagName

            // Detect installed path
            if let path = detectInstalledPath(name: tool.name) {
                updatedTool.installedPath = path
            }

            // Update cache
            updateCachedTool(updatedTool)

            // Register with L2's tool system
            await registerWithL2(tool: updatedTool)

            return InstallResult(
                success: true,
                tool: updatedTool,
                output: output,
                error: nil
            )
        } else {
            return InstallResult(
                success: false,
                tool: tool,
                output: output,
                error: "Installation failed or was cancelled"
            )
        }
    }

    struct InstallResult {
        let success: Bool
        let tool: GitHubTool
        let output: String
        let error: String?
    }

    // MARK: - URL Parsing

    /// Extract GitHub URL from text
    func extractGitHubURL(from text: String) -> URL? {
        // Pattern: https://github.com/owner/repo or github.com/owner/repo
        let patterns = [
            #"https?://github\.com/[\w\-\.]+/[\w\-\.]+"#,
            #"github\.com/[\w\-\.]+/[\w\-\.]+"#
        ]

        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
                let range = NSRange(text.startIndex..., in: text)
                if let match = regex.firstMatch(in: text, options: [], range: range) {
                    var urlString = String(text[Range(match.range, in: text)!])
                    if !urlString.hasPrefix("http") {
                        urlString = "https://" + urlString
                    }
                    // Clean up - remove trailing paths like /tree/main, /blob, etc.
                    if let url = URL(string: urlString) {
                        let pathComponents = url.pathComponents.filter { $0 != "/" }
                        if pathComponents.count >= 2 {
                            let cleanURL = "https://github.com/\(pathComponents[0])/\(pathComponents[1])"
                            return URL(string: cleanURL)
                        }
                    }
                }
            }
        }
        return nil
    }

    /// Parse owner and repo from GitHub URL
    func parseGitHubURL(_ url: URL) -> (owner: String, repo: String)? {
        let pathComponents = url.pathComponents.filter { $0 != "/" }
        guard pathComponents.count >= 2 else { return nil }

        let owner = pathComponents[0]
        var repo = pathComponents[1]

        // Remove .git suffix if present
        if repo.hasSuffix(".git") {
            repo = String(repo.dropLast(4))
        }

        return (owner, repo)
    }

    // MARK: - GitHub API

    struct RepositoryData {
        let description: String?
        let homepage: URL?
        let language: String?
        let topics: [String]
        let stars: Int
        let defaultBranch: String
    }

    /// Fetch repository information from GitHub API
    func fetchRepositoryInfo(owner: String, repo: String) async throws -> RepositoryData {
        let url = URL(string: "https://api.github.com/repos/\(owner)/\(repo)")!
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github.v3+json", forHTTPHeaderField: "Accept")
        if let token = githubToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw GitHubError.apiError("Failed to fetch repository info")
        }

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]

        return RepositoryData(
            description: json["description"] as? String,
            homepage: (json["homepage"] as? String).flatMap { URL(string: $0) },
            language: json["language"] as? String,
            topics: json["topics"] as? [String] ?? [],
            stars: json["stargazers_count"] as? Int ?? 0,
            defaultBranch: json["default_branch"] as? String ?? "main"
        )
    }

    /// Fetch README content
    func fetchREADME(owner: String, repo: String) async throws -> GitHubREADME {
        let url = URL(string: "https://api.github.com/repos/\(owner)/\(repo)/readme")!
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github.v3+json", forHTTPHeaderField: "Accept")
        if let token = githubToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw GitHubError.apiError("Failed to fetch README")
        }

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]

        // README is base64 encoded
        guard let contentBase64 = json["content"] as? String,
              let contentData = Data(base64Encoded: contentBase64.replacingOccurrences(of: "\n", with: "")),
              let content = String(data: contentData, encoding: .utf8) else {
            throw GitHubError.parseError("Failed to decode README")
        }

        // Parse README for useful information
        return parseREADME(content)
    }

    /// Fetch latest release
    func fetchLatestRelease(owner: String, repo: String) async throws -> GitHubRelease {
        let url = URL(string: "https://api.github.com/repos/\(owner)/\(repo)/releases/latest")!
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github.v3+json", forHTTPHeaderField: "Accept")
        if let token = githubToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw GitHubError.apiError("No releases found")
        }

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]

        let assets: [GitHubRelease.ReleaseAsset] = (json["assets"] as? [[String: Any]] ?? []).compactMap { asset in
            guard let name = asset["name"] as? String,
                  let urlString = asset["browser_download_url"] as? String,
                  let downloadURL = URL(string: urlString) else {
                return nil
            }
            return GitHubRelease.ReleaseAsset(
                name: name,
                downloadURL: downloadURL,
                size: asset["size"] as? Int ?? 0,
                contentType: asset["content_type"] as? String ?? "unknown"
            )
        }

        // Parse published date
        var publishedDate: Date? = nil
        if let dateString = json["published_at"] as? String {
            let formatter = ISO8601DateFormatter()
            publishedDate = formatter.date(from: dateString)
        }

        return GitHubRelease(
            tagName: json["tag_name"] as? String ?? "unknown",
            name: json["name"] as? String,
            publishedAt: publishedDate,
            assets: assets,
            body: json["body"] as? String
        )
    }

    // MARK: - Analysis Helpers

    /// Parse README to extract useful information
    func parseREADME(_ content: String) -> GitHubREADME {
        let lines = content.components(separatedBy: "\n")
        var installInstructions: [String] = []
        var usageExamples: [String] = []
        var capabilities: [String] = []
        var dependencies: [String] = []

        var inInstallSection = false
        var inUsageSection = false
        var inCodeBlock = false
        var currentCodeBlock = ""

        for line in lines {
            let lowercased = line.lowercased()

            // Track code blocks
            if line.hasPrefix("```") {
                if inCodeBlock {
                    // End of code block
                    if inInstallSection && !currentCodeBlock.isEmpty {
                        installInstructions.append(currentCodeBlock.trimmingCharacters(in: .whitespacesAndNewlines))
                    } else if inUsageSection && !currentCodeBlock.isEmpty {
                        usageExamples.append(currentCodeBlock.trimmingCharacters(in: .whitespacesAndNewlines))
                    }
                    currentCodeBlock = ""
                }
                inCodeBlock.toggle()
                continue
            }

            if inCodeBlock {
                currentCodeBlock += line + "\n"
                continue
            }

            // Detect sections
            if lowercased.contains("install") && (line.hasPrefix("#") || line.hasPrefix("##")) {
                inInstallSection = true
                inUsageSection = false
            } else if (lowercased.contains("usage") || lowercased.contains("example")) && (line.hasPrefix("#") || line.hasPrefix("##")) {
                inInstallSection = false
                inUsageSection = true
            } else if line.hasPrefix("#") {
                inInstallSection = false
                inUsageSection = false
            }

            // Extract capabilities from feature lists
            if line.hasPrefix("- ") || line.hasPrefix("* ") {
                let feature = String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                if feature.count < 100 { // Reasonable length for a capability
                    capabilities.append(feature)
                }
            }

            // Detect dependencies
            if lowercased.contains("requires") || lowercased.contains("dependencies") {
                if let range = line.range(of: "`[^`]+`", options: .regularExpression) {
                    let dep = String(line[range]).replacingOccurrences(of: "`", with: "")
                    dependencies.append(dep)
                }
            }
        }

        return GitHubREADME(
            content: content,
            installInstructions: installInstructions,
            usageExamples: usageExamples,
            detectedCapabilities: Array(capabilities.prefix(20)), // Limit
            dependencies: dependencies
        )
    }

    /// Detect install methods from README content
    func detectInstallMethods(from content: String) -> [GitHubTool.InstallMethod] {
        let lowercased = content.lowercased()
        var methods: [GitHubTool.InstallMethod] = []

        for (method, patterns) in installPatterns {
            for pattern in patterns {
                if lowercased.contains(pattern.lowercased()) {
                    if !methods.contains(method) {
                        methods.append(method)
                    }
                    break
                }
            }
        }

        return methods
    }

    /// AI-analyze capabilities from README and metadata
    func analyzeCapabilities(readme: String?, description: String?, topics: [String]) async -> [String] {
        // Combine all text for analysis
        var text = ""
        if let desc = description { text += desc + "\n" }
        if let readme = readme { text += readme }
        text += "\nTopics: " + topics.joined(separator: ", ")

        // For now, extract keywords. In full implementation, use AI provider
        var capabilities: [String] = []

        // Common capability keywords
        let capabilityKeywords = [
            "search", "find", "list", "filter", "sort",
            "convert", "transform", "compress", "optimize",
            "download", "upload", "sync", "backup",
            "generate", "create", "build", "compile",
            "analyze", "parse", "extract", "process",
            "encrypt", "decrypt", "hash", "sign",
            "format", "lint", "validate", "check",
            "monitor", "watch", "track", "log"
        ]

        let lowercased = text.lowercased()
        for keyword in capabilityKeywords {
            if lowercased.contains(keyword) {
                capabilities.append(keyword)
            }
        }

        // Add topics as capabilities
        capabilities.append(contentsOf: topics.prefix(5))

        return Array(Set(capabilities)).sorted()
    }

    /// Determine best install method
    func determineBestInstallMethod(tool: GitHubTool, readme: GitHubREADME?) -> (method: GitHubTool.InstallMethod, command: String) {
        // Priority order based on reliability and safety
        let priority: [GitHubTool.InstallMethod] = [
            .homebrew,  // Most trusted
            .cargo,     // Rust package manager
            .npm,       // Node package manager
            .pip,       // Python package manager
            .go,        // Go install
            .binary,    // Pre-built binaries
            .gitClone,  // Clone and build
            .script     // Install scripts (least preferred)
        ]

        for method in priority {
            if tool.installMethods.contains(method) {
                let command = generateInstallCommand(tool: tool, method: method)
                return (method, command)
            }
        }

        // Fallback to git clone
        return (.gitClone, "git clone \(tool.repositoryURL.absoluteString)")
    }

    /// Generate install command for a method
    func generateInstallCommand(tool: GitHubTool, method: GitHubTool.InstallMethod) -> String {
        switch method {
        case .homebrew:
            // Check if there's a tap needed
            return "brew install \(tool.name)"

        case .cargo:
            return "cargo install \(tool.name)"

        case .npm:
            return "npm install -g \(tool.name)"

        case .pip:
            return "pip3 install \(tool.name)"

        case .go:
            return "go install \(tool.fullName)@latest"

        case .gitClone:
            return "git clone \(tool.repositoryURL.absoluteString) && cd \(tool.name) && make install"

        case .binary:
            if let release = tool.latestRelease,
               let asset = release.assets.first(where: { $0.name.contains("darwin") || $0.name.contains("macos") }) {
                return "curl -L \(asset.downloadURL.absoluteString) -o /tmp/\(asset.name) && chmod +x /tmp/\(asset.name)"
            }
            return "# Download binary from: \(tool.repositoryURL.absoluteString)/releases"

        case .script:
            return "curl -fsSL \(tool.repositoryURL.absoluteString)/raw/main/install.sh | bash"
        }
    }

    /// Assess risk of installing a tool
    func assessRisk(tool: GitHubTool, method: GitHubTool.InstallMethod) -> GitHubAnalysis.RiskAssessment {
        var level: GitHubAnalysis.RiskAssessment.RiskLevel = .medium
        var reasons: [String] = []
        var recommendations: [String] = []

        // Check stars (popularity indicator)
        if tool.stars > 1000 {
            level = .low
            reasons.append("Popular repository with \(tool.stars) stars")
        } else if tool.stars < 50 {
            level = .high
            reasons.append("Low popularity (\(tool.stars) stars)")
            recommendations.append("Review the code before installing")
        }

        // Check install method
        switch method {
        case .homebrew:
            reasons.append("Installing via Homebrew (trusted package manager)")
        case .cargo, .npm, .pip, .go:
            reasons.append("Installing via official package manager")
        case .script:
            level = .high
            reasons.append("Install script downloads and executes code")
            recommendations.append("Review the install script first")
        case .binary:
            level = .high
            reasons.append("Binary download - cannot verify source")
            recommendations.append("Verify checksum if available")
        case .gitClone:
            reasons.append("Building from source")
            recommendations.append("Review Makefile/build scripts")
        }

        // Check for releases
        if tool.latestRelease == nil {
            reasons.append("No official releases")
            recommendations.append("Consider waiting for stable release")
        }

        return GitHubAnalysis.RiskAssessment(
            level: level,
            reasons: reasons,
            recommendations: recommendations
        )
    }

    // MARK: - Installation Helpers

    /// Check if a tool is already installed
    func checkIfInstalled(name: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = [name]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    /// Detect installed path
    func detectInstalledPath(name: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = [name]

        let pipe = Pipe()
        process.standardOutput = pipe

        do {
            try process.run()
            process.waitUntilExit()

            if process.terminationStatus == 0 {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        } catch {}

        return nil
    }

    /// Register tool with L2's tool system
    func registerWithL2(tool: GitHubTool) async {
        // Create a TerminalTool for L2AITaskExecutor
        // This integrates the GitHub tool into L2's existing tool ecosystem

        // The tool is now available for L2 to use in task execution
        // Store in UserDefaults for persistence
        saveToolToRegistry(tool)

        #if DEBUG
        print("[L2] Registered GitHub tool: \(tool.name) with capabilities: \(tool.capabilities)")
        #endif
    }

    // MARK: - Persistence

    /// Load cached tools from disk
    func loadCachedTools() {
        guard let data = UserDefaults.standard.data(forKey: toolRegistryKey),
              let tools = try? JSONDecoder().decode([GitHubTool].self, from: data) else {
            return
        }
        discoveredTools = tools
    }

    /// Cache a discovered tool
    func cacheDiscoveredTool(_ tool: GitHubTool) {
        // Remove existing if present
        discoveredTools.removeAll { $0.fullName == tool.fullName }
        discoveredTools.append(tool)
        saveToolRegistry()
    }

    /// Update a cached tool
    func updateCachedTool(_ tool: GitHubTool) {
        if let index = discoveredTools.firstIndex(where: { $0.fullName == tool.fullName }) {
            discoveredTools[index] = tool
        } else {
            discoveredTools.append(tool)
        }
        saveToolRegistry()
    }

    /// Save tool to registry
    func saveToolToRegistry(_ tool: GitHubTool) {
        updateCachedTool(tool)
    }

    /// Save all tools
    func saveToolRegistry() {
        if let data = try? JSONEncoder().encode(discoveredTools) {
            UserDefaults.standard.set(data, forKey: toolRegistryKey)
        }
    }

    /// Get installed GitHub tools
    func getInstalledTools() -> [GitHubTool] {
        return discoveredTools.filter { $0.isInstalled }
    }

    /// Get tool by name
    func getTool(named name: String) -> GitHubTool? {
        return discoveredTools.first { $0.name == name || $0.fullName == name }
    }

    // MARK: - Errors

    enum GitHubError: Error, LocalizedError {
        case apiError(String)
        case parseError(String)
        case installError(String)

        var errorDescription: String? {
            switch self {
            case .apiError(let msg): return "GitHub API Error: \(msg)"
            case .parseError(let msg): return "Parse Error: \(msg)"
            case .installError(let msg): return "Install Error: \(msg)"
            }
        }
    }
}

// MARK: - L2 Integration Extension

extension GitHubToolManager {

    /// Process a user query that might contain GitHub URLs
    /// Returns a formatted response for L2UnifiedAssistant
    func processQuery(_ query: String) async -> L2GitHubResponse? {
        // Check if query contains GitHub URL
        guard let url = extractGitHubURL(from: query) else {
            return nil
        }

        // Analyze the repository
        guard let analysis = await analyzeRepository(url: url) else {
            return L2GitHubResponse(
                type: .error,
                message: error ?? "Failed to analyze repository",
                tool: nil,
                suggestedActions: []
            )
        }

        // Build response
        let tool = analysis.tool
        var message = """
        ## 📦 \(tool.name)

        **Repository:** [\(tool.fullName)](\(tool.repositoryURL.absoluteString))
        **Description:** \(tool.description)
        **Language:** \(tool.language ?? "Unknown")
        **Stars:** ⭐ \(tool.stars)

        ### Capabilities
        \(tool.capabilities.map { "- \($0)" }.joined(separator: "\n"))

        ### Installation
        **Recommended:** \(analysis.suggestedInstallMethod.displayName)
        ```bash
        \(analysis.installCommand)
        ```

        ### Risk Assessment: \(analysis.riskAssessment.level.rawValue)
        \(analysis.riskAssessment.reasons.map { "- \($0)" }.joined(separator: "\n"))
        """

        if !analysis.riskAssessment.recommendations.isEmpty {
            message += "\n\n**Recommendations:**\n"
            message += analysis.riskAssessment.recommendations.map { "- \($0)" }.joined(separator: "\n")
        }

        // Build actions
        var actions: [L2GitHubAction] = []

        if !tool.isInstalled {
            actions.append(L2GitHubAction(
                id: "install",
                label: "Install \(tool.name)",
                icon: "arrow.down.circle",
                action: .install(method: analysis.suggestedInstallMethod)
            ))

            // Add alternative install methods
            for method in tool.installMethods where method != analysis.suggestedInstallMethod {
                actions.append(L2GitHubAction(
                    id: "install_\(method.rawValue)",
                    label: "Install via \(method.displayName)",
                    icon: "arrow.down.circle",
                    action: .install(method: method)
                ))
            }
        } else {
            message += "\n\n✅ **Already installed**"
            if let path = tool.installedPath {
                message += " at `\(path)`"
            }
        }

        actions.append(L2GitHubAction(
            id: "open",
            label: "Open in Browser",
            icon: "safari",
            action: .openURL(tool.repositoryURL)
        ))

        if let release = tool.latestRelease {
            actions.append(L2GitHubAction(
                id: "releases",
                label: "View Release \(release.tagName)",
                icon: "tag",
                action: .openURL(URL(string: "\(tool.repositoryURL.absoluteString)/releases")!)
            ))
        }

        return L2GitHubResponse(
            type: .analysis,
            message: message,
            tool: tool,
            suggestedActions: actions
        )
    }
}

// MARK: - Response Models

struct L2GitHubResponse {
    enum ResponseType {
        case analysis
        case installed
        case error
    }

    let type: ResponseType
    let message: String
    let tool: GitHubTool?
    let suggestedActions: [L2GitHubAction]
}

struct L2GitHubAction: Identifiable {
    let id: String
    let label: String
    let icon: String
    let action: ActionType

    enum ActionType {
        case install(method: GitHubTool.InstallMethod)
        case openURL(URL)
        case copyCommand(String)
    }
}
