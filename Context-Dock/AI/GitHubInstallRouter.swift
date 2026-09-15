import AppKit
import Foundation

/// "install this" while looking at a GitHub repository.
///
/// A browser scope has browser tools, so a model asked to install something correctly
/// answers that it cannot — and then dead-ends. Installing is a real capability of this
/// Mac, not of Safari, so the request is answered here with a concrete command the user
/// approves, instead of being refused.
///
/// The command is built from the page URL and the local toolchain, never from model output,
/// which is why it can be offered directly as an approval card.
enum GitHubInstallRouter {
    struct Repository: Equatable {
        let owner: String
        let name: String
        let url: URL

        var cloneURL: String { "https://github.com/\(owner)/\(name).git" }
    }

    struct Plan {
        let summary: String
        let command: String
        let purpose: String
    }

    /// True when the phrase asks to get the thing running locally.
    static func isInstallIntent(_ query: String) -> Bool {
        let q = query.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return false }
        let verbs = [
            "install", "clone", "set it up", "set this up", "setup", "get this",
            "try this", "run this locally", "download this repo", "build this",
        ]
        return verbs.contains { q.contains($0) }
    }

    /// The repository a GitHub page is showing, if it is a repository page at all.
    static func repository(from url: URL) -> Repository? {
        guard let host = url.host?.lowercased(),
            host == "github.com" || host.hasSuffix(".github.com")
        else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" && !$0.isEmpty }
        guard parts.count >= 2 else { return nil }
        // Reserved first-level paths are pages, not owners.
        let reserved: Set<String> = [
            "features", "topics", "collections", "trending", "marketplace", "sponsors",
            "settings", "notifications", "explore", "orgs", "codespaces", "login", "about",
        ]
        let owner = parts[0]
        guard !reserved.contains(owner.lowercased()) else { return nil }
        let name = parts[1].replacingOccurrences(of: ".git", with: "")
        guard !name.isEmpty else { return nil }
        return Repository(owner: owner, name: name, url: url)
    }

    /// Homebrew first when the repo is packaged, otherwise a clone into the user's dev
    /// folder. Anything beyond that (build steps) belongs to the repo's own README, so the
    /// plan says so rather than inventing commands.
    static func plan(for repo: Repository) async -> Plan {
        if let formula = await homebrewFormula(named: repo.name) {
            return Plan(
                summary:
                    "`\(repo.name)` is packaged for Homebrew, so installing it is one command. "
                    + "That is the cleanest route — it stays updatable with `brew upgrade`.",
                command: "brew install \(formula)",
                purpose: "Install \(repo.name) with Homebrew"
            )
        }
        let destination = cloneDestination(for: repo)
        return Plan(
            summary:
                "No Homebrew package matches `\(repo.name)`, so this clones the repository to "
                + "`\(destination)`. Build and run steps live in the repo's README — I can read "
                + "it once the clone finishes.",
            command: "git clone \(repo.cloneURL) \(shellQuoted(destination))",
            purpose: "Clone \(repo.owner)/\(repo.name)"
        )
    }

    // MARK: - Local toolchain

    /// `brew info` exits non-zero for an unknown formula, so success is the answer.
    private static func homebrewFormula(named name: String) async -> String? {
        guard FileManager.default.fileExists(atPath: "/opt/homebrew/bin/brew")
            || FileManager.default.fileExists(atPath: "/usr/local/bin/brew")
        else { return nil }
        let probe = "brew info --formula \(shellQuoted(name)) >/dev/null 2>&1 && echo ok"
        let result: (success: Bool, output: String)? = await withTaskGroup(
            of: (success: Bool, output: String)?.self
        ) { group in
            group.addTask {
                // This probe only cares whether brew knows the formula; the exit code is
                // carried by `success` already.
                let run = await TerminalCommandExecutor.shared.runPreApproved(probe)
                return (run.success, run.output)
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        guard let result, result.success,
            result.output.trimmingCharacters(in: .whitespacesAndNewlines).contains("ok")
        else { return nil }
        return name
    }

    private static func cloneDestination(for repo: Repository) -> String {
        let home = NSHomeDirectory()
        // Prefer the folder the user already keeps work in.
        for candidate in ["/Developer", "/Projects", "/Code", "/Documents"] {
            let path = home + candidate
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
                isDirectory.boolValue
            {
                return path + "/" + repo.name
            }
        }
        return home + "/" + repo.name
    }

    private static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
