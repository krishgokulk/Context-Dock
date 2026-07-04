import Foundation

// GitHub capabilities using the `gh` CLI tool.
// Requires `gh` to be installed and authenticated (`gh auth login`).
// Risk levels:
//   github.list_issues  → .low  (read-only)
//   github.list_prs     → .low  (read-only)
//   github.get_repo     → .low  (read-only)
//   github.create_issue → .medium (creates content on GitHub)

@MainActor
enum GitHubMCPCapabilities {

    static func register(in registry: CapabilityRegistry) {
        registerListIssues(registry)
        registerListPRs(registry)
        registerGetRepo(registry)
        registerCreateIssue(registry)
    }

    // MARK: - github.list_issues

    private static func registerListIssues(_ registry: CapabilityRegistry) {
        registry.register(
            AICapability(
                id: "github.list_issues",
                title: "List GitHub Issues",
                appBundleID: nil,
                inputSchema: .init(fields: [
                    .init(name: "repo", description: "Repository in owner/name format (e.g. apple/swift). Uses current git repo if omitted.", required: false),
                    .init(name: "state", description: "Issue state: open, closed, or all (default: open)", required: false),
                    .init(name: "limit", description: "Max results (default 20)", required: false),
                ]),
                riskLevel: .low
            ) { request in
                guard AppSettings.shared.githubMCPEnabled else {
                    throw AICapabilityError.blocked("GitHub access is disabled in Settings.")
                }
                let state = request.input["state"] ?? "open"
                let limit = request.input["limit"] ?? "20"
                var args = ["issue", "list", "--state", state, "--limit", limit, "--json", "number,title,state,author,createdAt,url"]
                if let repo = request.input["repo"], !repo.isEmpty {
                    args += ["--repo", repo]
                }
                let output = await runGH(args)
                guard let output else {
                    return .init(success: false, output: "gh CLI not available or not authenticated. Run `gh auth login` in Terminal.")
                }
                return .init(success: true, output: formatIssueList(output, label: "Issues"))
            }
        )
    }

    // MARK: - github.list_prs

    private static func registerListPRs(_ registry: CapabilityRegistry) {
        registry.register(
            AICapability(
                id: "github.list_prs",
                title: "List GitHub Pull Requests",
                appBundleID: nil,
                inputSchema: .init(fields: [
                    .init(name: "repo", description: "Repository in owner/name format. Uses current git repo if omitted.", required: false),
                    .init(name: "state", description: "PR state: open, closed, merged, or all (default: open)", required: false),
                    .init(name: "limit", description: "Max results (default 20)", required: false),
                ]),
                riskLevel: .low
            ) { request in
                guard AppSettings.shared.githubMCPEnabled else {
                    throw AICapabilityError.blocked("GitHub access is disabled in Settings.")
                }
                let state = request.input["state"] ?? "open"
                let limit = request.input["limit"] ?? "20"
                var args = ["pr", "list", "--state", state, "--limit", limit, "--json", "number,title,state,author,createdAt,url"]
                if let repo = request.input["repo"], !repo.isEmpty {
                    args += ["--repo", repo]
                }
                let output = await runGH(args)
                guard let output else {
                    return .init(success: false, output: "gh CLI not available or not authenticated. Run `gh auth login` in Terminal.")
                }
                return .init(success: true, output: formatIssueList(output, label: "Pull Requests"))
            }
        )
    }

    // MARK: - github.get_repo

    private static func registerGetRepo(_ registry: CapabilityRegistry) {
        registry.register(
            AICapability(
                id: "github.get_repo",
                title: "Get GitHub Repository Info",
                appBundleID: nil,
                inputSchema: .init(fields: [
                    .init(name: "repo", description: "Repository in owner/name format. Uses current git repo if omitted.", required: false)
                ]),
                riskLevel: .low
            ) { request in
                guard AppSettings.shared.githubMCPEnabled else {
                    throw AICapabilityError.blocked("GitHub access is disabled in Settings.")
                }
                var args = ["repo", "view"]
                if let repo = request.input["repo"], !repo.isEmpty {
                    args.append(repo)
                }
                args += ["--json", "name,owner,description,stargazerCount,forkCount,isPrivate,defaultBranchRef,url,pushedAt,primaryLanguage"]
                let output = await runGH(args)
                guard let output, !output.isEmpty else {
                    return .init(success: false, output: "Could not fetch repo info. Make sure `gh` is installed and authenticated.")
                }
                return .init(success: true, output: formatRepoInfo(output))
            }
        )
    }

    // MARK: - github.create_issue

    private static func registerCreateIssue(_ registry: CapabilityRegistry) {
        registry.register(
            AICapability(
                id: "github.create_issue",
                title: "Create GitHub Issue",
                appBundleID: nil,
                inputSchema: .init(fields: [
                    .init(name: "title", description: "Issue title", required: true),
                    .init(name: "body", description: "Issue description", required: false),
                    .init(name: "repo", description: "Repository in owner/name format. Uses current git repo if omitted.", required: false),
                    .init(name: "label", description: "Comma-separated labels to apply", required: false),
                ]),
                riskLevel: .medium
            ) { request in
                guard AppSettings.shared.githubMCPEnabled else {
                    throw AICapabilityError.blocked("GitHub access is disabled in Settings.")
                }
                guard let title = request.input["title"], !title.isEmpty else {
                    throw AICapabilityError.missingInput("title")
                }
                var args = ["issue", "create", "--title", title]
                if let body = request.input["body"], !body.isEmpty {
                    args += ["--body", body]
                } else {
                    args += ["--body", ""]
                }
                if let repo = request.input["repo"], !repo.isEmpty {
                    args += ["--repo", repo]
                }
                if let label = request.input["label"], !label.isEmpty {
                    for l in label.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }) {
                        args += ["--label", l]
                    }
                }
                let output = await runGH(args)
                guard let output else {
                    return .init(success: false, output: "gh CLI not available or not authenticated.")
                }
                let url = output.trimmingCharacters(in: .whitespacesAndNewlines)
                return .init(success: true, output: "Issue created: \(url)")
            }
        )
    }

    // MARK: - Helpers

    private static func runGH(_ args: [String]) async -> String? {
        let ghPaths = ["/usr/local/bin/gh", "/opt/homebrew/bin/gh", "/usr/bin/gh"]
        guard let ghPath = ghPaths.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            return nil
        }
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: ghPath)
                proc.arguments = args
                let pipe = Pipe()
                proc.standardOutput = pipe
                proc.standardError = Pipe()
                do {
                    try proc.run()
                    proc.waitUntilExit()
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    continuation.resume(returning: String(data: data, encoding: .utf8))
                } catch {
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    private static func formatIssueList(_ json: String, label: String) -> String {
        guard let data = json.data(using: .utf8),
              let items = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              !items.isEmpty else {
            return json.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "No \(label.lowercased()) found."
                : json
        }
        let lines = items.map { item -> String in
            let num = item["number"] as? Int ?? 0
            let title = item["title"] as? String ?? "Untitled"
            let state = item["state"] as? String ?? ""
            let author = (item["author"] as? [String: Any])?["login"] as? String ?? ""
            return "#\(num) \(title) [\(state)] by \(author)"
        }
        return "\(label) (\(items.count)):\n" + lines.joined(separator: "\n")
    }

    private static func formatRepoInfo(_ json: String) -> String {
        guard let data = json.data(using: .utf8),
              let repo = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return json
        }
        var lines: [String] = []
        let owner = (repo["owner"] as? [String: Any])?["login"] as? String ?? ""
        let name = repo["name"] as? String ?? ""
        if !owner.isEmpty || !name.isEmpty { lines.append("Repo: \(owner)/\(name)") }
        if let desc = repo["description"] as? String, !desc.isEmpty { lines.append("Description: \(desc)") }
        if let lang = (repo["primaryLanguage"] as? [String: Any])?["name"] as? String { lines.append("Language: \(lang)") }
        if let stars = repo["stargazerCount"] as? Int { lines.append("Stars: \(stars)") }
        if let forks = repo["forkCount"] as? Int { lines.append("Forks: \(forks)") }
        if let issues = repo["openIssueCount"] as? Int { lines.append("Open issues: \(issues)") }
        if let isPrivate = repo["isPrivate"] as? Bool { lines.append("Visibility: \(isPrivate ? "private" : "public")") }
        if let branch = (repo["defaultBranchRef"] as? [String: Any])?["name"] as? String { lines.append("Default branch: \(branch)") }
        if let url = repo["url"] as? String { lines.append("URL: \(url)") }
        return lines.joined(separator: "\n")
    }
}
