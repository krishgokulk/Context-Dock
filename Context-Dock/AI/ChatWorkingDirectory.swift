// ChatWorkingDirectory.swift
// Context-Dock
//
// Where a thread's commands run.
//
// Every shell path in the app ran in the user's home directory. Ask a folder thread
// for a file listing and it listed home; ask a thread about a project for its last
// commit and git answered "not a git repository", because it was standing in the wrong
// place. Worse, a command that wrote `> summary.txt` did create a file — in home, under
// a name nothing in the conversation could point at, so the panel showed nothing and
// the user was told the write had failed.
//
// A thread that is about a directory runs there. Everything else still runs in home,
// which is the only safe default for a scope that is not about a place.

import AppKit
import Foundation

@MainActor
enum ChatWorkingDirectory {
    static var home: URL { FileManager.default.homeDirectoryForCurrentUser }

    /// The directory a thread's commands should run in.
    static func resolve(for scope: GeneralChatScope?) -> URL {
        guard let scope else { return home }
        switch scope {
        case .folder:
            return scope.folderURL.flatMap(existingDirectory) ?? home
        case .app(let bundleId):
            return appDirectory(bundleId: bundleId) ?? home
        case .cli, .thread, .general:
            // A CLI tool is not a place, and a general thread is about everything. Home
            // is the only honest answer; a guess here would silently write files into
            // whatever directory happened to be frontmost.
            return home
        }
    }

    /// What the thread's app is currently working in, when it will say.
    ///
    /// ProjectContextResolver is the same source the system prompt already quotes as the
    /// working directory, so the model's instructions and the shell now agree. They did
    /// not before: the prompt named an editor's project root while every command ran in
    /// home, which is how a thread about a repository was told "not a git repository".
    private static func appDirectory(bundleId: String) -> URL? {
        if bundleId == "com.apple.finder" {
            let context = AXContextReader.shared.current
            if context.bundleId == bundleId,
                let raw = context.currentURL,
                let decoded = raw.replacingOccurrences(of: "file://", with: "")
                    .removingPercentEncoding,
                !decoded.isEmpty,
                let directory = existingDirectory(URL(fileURLWithPath: decoded))
            {
                return directory
            }
            let folder = AppleAppsAPI.shared.getCurrentFolder()
            guard !folder.isEmpty else { return nil }
            return existingDirectory(URL(fileURLWithPath: folder))
        }
        guard let running = NSRunningApplication
            .runningApplications(withBundleIdentifier: bundleId).first,
            let root = ProjectContextResolver.shared.projectRoot(for: running)
        else { return nil }
        return existingDirectory(URL(fileURLWithPath: root))
    }

    private static func existingDirectory(_ url: URL) -> URL? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
            isDirectory.boolValue
        else { return nil }
        return url
    }
}
