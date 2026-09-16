import AppKit
import Foundation

/// What the app reads back from the machine to check a specialist's report.
///
/// Only the facts the report should have cited. `AIWorkerVerification` treats a reading the
/// report does not mention as a contradiction, so reading the app's version back on a
/// question about a linker error would call a correct answer a lie. The goal decides which
/// readings are taken; the scope decides where they come from.
enum AIWorkerReadings {
    struct Probes {
        var appVersion: (String) -> String?
        var gitBranch: (URL) -> String?
        var gitHead: (URL) -> String?

        static let live = Probes(
            appVersion: liveAppVersion, gitBranch: liveGitBranch, gitHead: liveGitHead)
    }

    // Whole words, not substrings: "report" contains "repo" and "ahead" contains "head".
    private static let versionWords: Set<String> = [
        "version", "versions", "update", "updated", "updates", "upgrade", "installed",
        "outdated", "latest", "release",
    ]
    private static let repositoryWords: Set<String> = [
        "branch", "commit", "commits", "git", "repository", "repo", "checkout", "merge",
    ]

    static func take(for task: AIWorkerTask, probes: Probes = .live)
        -> [AIWorkerVerification.Reading]
    {
        let words = Set(
            task.goal.lowercased()
                .split { !$0.isLetter && !$0.isNumber }
                .map(String.init))
        var readings: [AIWorkerVerification.Reading] = []

        if !versionWords.isDisjoint(with: words),
            let bundleID = task.authority.allowedAppBundleIDs.first
        {
            let name = task.authority.scopeDescription
                .split(separator: " and ").first.map(String.init) ?? bundleID
            let version = probes.appVersion(bundleID)
            readings.append(
                .init(
                    subject: "\(name) version", value: version ?? "unreadable",
                    succeeded: version != nil))
        }

        if !repositoryWords.isDisjoint(with: words),
            let directory = task.authority.allowedPaths.first
        {
            let branch = probes.gitBranch(directory)
            readings.append(
                .init(subject: "branch", value: branch ?? "unreadable", succeeded: branch != nil))
            let head = probes.gitHead(directory)
            readings.append(
                .init(subject: "HEAD", value: head ?? "unreadable", succeeded: head != nil))
        }

        return readings
    }

    // MARK: - Live probes

    private static func liveAppVersion(_ bundleID: String) -> String? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID),
            let bundle = Bundle(url: url)
        else { return nil }
        let short = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        return short?.isEmpty == false ? short : nil
    }

    private static func liveGitBranch(_ directory: URL) -> String? {
        git(["rev-parse", "--abbrev-ref", "HEAD"], in: directory)
    }

    private static func liveGitHead(_ directory: URL) -> String? {
        git(["rev-parse", "--short", "HEAD"], in: directory)
    }

    /// Only inside a repository: `git` run elsewhere climbs to whatever parent has one, which
    /// is a reading about somewhere the user did not point at.
    private static func git(_ arguments: [String], in directory: URL) -> String? {
        guard FileManager.default.fileExists(
            atPath: directory.appendingPathComponent(".git").path)
        else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = directory
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return output?.isEmpty == false ? output : nil
    }
}
