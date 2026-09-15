// ProjectContextResolver.swift
// Resolves the project / workspace folder the frontmost app is actually working in.
//
// Why this exists: General Chat only ever knew a folder when Finder was frontmost
// (AIProviderService derived `currentFolder` from Finder alone). With an editor in front,
// every folder-relative capability fell back to the Finder folder or the home directory —
// so "what is the recent commit I did?" would have run `git log` in the wrong repository
// even once routing was correct.
//
// Resolution is per-app knowledge, not one trick, because the apps genuinely differ:
//
//   Xcode     exposes the open document through AXDocument on its focused window.
//   VS Code   exposes NOTHING through AX — verified against a live process: AXDocument and
//             AXURL are both empty, and the window title carries only a folder *name*
//             ("file — Context-Dock"), not a path. It does persist its open folders to
//             globalStorage/storage.json, which is exact and current.
//   Finder    already had a working path via AppleAppsAPI.
//
// Whatever a source returns is then walked up to the enclosing repository root, so a path
// pointing at a file deep in a checkout still yields the folder git commands belong in.

import AppKit
import Foundation

@MainActor
final class ProjectContextResolver {
    static let shared = ProjectContextResolver()

    private init() {}

    /// Bundle ids that store their workspace the way VS Code does. Forks keep the same
    /// storage shape, only the Application Support directory name changes.
    private static let vsCodeFamily: [String: String] = [
        "com.microsoft.VSCode": "Code",
    ]

    /// Markers that identify a project root, most specific first. `.git` wins because it is
    /// the boundary git commands care about.
    private static let rootMarkers = [".git", "Package.swift", "package.json", "Cargo.toml", "go.mod", "pyproject.toml"]

    private struct CacheEntry {
        let root: String?
        let at: Date
    }
    private var cache: [String: CacheEntry] = [:]
    private let cacheTTL: TimeInterval = 20

    // MARK: - Entry point

    /// The folder the given app is working in, or nil when it has no meaningful one.
    /// Pass the frontmost app; the result is already walked up to a repository root.
    func projectRoot(for app: NSRunningApplication) -> String? {
        guard let bundleId = app.bundleIdentifier else { return nil }
        if let hit = cache[bundleId], Date().timeIntervalSince(hit.at) < cacheTTL {
            return hit.root
        }
        let raw = rawWorkingPath(bundleId: bundleId, pid: app.processIdentifier)
        let root = raw.flatMap { Self.repositoryRoot(containing: $0) } ?? raw
        cache[bundleId] = CacheEntry(root: root, at: Date())
        return root
    }

    /// Convenience for callers that only have the frontmost app implicitly.
    func frontmostProjectRoot() -> String? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        return projectRoot(for: app)
    }

    /// The project the user is working in, asked from inside one of our own windows.
    ///
    /// To NSWorkspace, the chat window is a frontmost app like any other, so
    /// `frontmostProjectRoot()` answers "Context-Dock" — that is, no project — at exactly
    /// the moment someone types "test it" into it. The app that was in front before us is
    /// the one they mean. Same reasoning the browser and extension paths already use.
    func workingProjectRoot() -> String? {
        let ours = Bundle.main.bundleIdentifier
        if let app = NSWorkspace.shared.frontmostApplication,
            app.bundleIdentifier != ours,
            let root = projectRoot(for: app)
        {
            return root
        }
        guard let previous = AppDelegate.shared?.previousFrontmostApp,
            !previous.isTerminated,
            previous.bundleIdentifier != ours
        else { return nil }
        return projectRoot(for: previous)
    }

    func invalidate() { cache.removeAll() }

    // MARK: - Per-app sources

    private func rawWorkingPath(bundleId: String, pid: pid_t) -> String? {
        if bundleId == "com.apple.finder" {
            let folder = AppleAppsAPI.shared.getCurrentFolder()
            return folder.isEmpty ? nil : folder
        }
        if let storageDirectory = Self.vsCodeFamily[bundleId] {
            return Self.vsCodeWorkspaceFolder(storageDirectory: storageDirectory, pid: pid)
        }
        // Xcode and other AX-cooperative document apps.
        if let document = Self.axDocumentPath(pid: pid) { return document }
        return nil
    }

    /// VS Code's open folders, read from its own persisted state. `backupWorkspaces.folders`
    /// tracks the folders currently open in windows, which is what we want — the separate
    /// `profileAssociations.workspaces` map is historical and would go stale.
    private static func vsCodeWorkspaceFolder(storageDirectory: String, pid: pid_t) -> String? {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/\(storageDirectory)/User/globalStorage/storage.json")
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        var folders: [String] = []
        if let backup = json["backupWorkspaces"] as? [String: Any],
           let entries = backup["folders"] as? [[String: Any]] {
            folders = entries.compactMap { $0["folderUri"] as? String }
        }
        if folders.isEmpty, let single = json["folder"] as? String {
            folders = [single]
        }
        let paths = folders.compactMap { URL(string: $0)?.path }.filter { !$0.isEmpty }
        guard !paths.isEmpty else { return nil }
        guard paths.count > 1 else { return paths[0] }

        // Several windows open: the focused window's title ends in its folder name
        // ("someFile.swift — Context-Dock"), which is enough to pick the right one.
        if let title = axWindowTitle(pid: pid) {
            let trailing = title
                .components(separatedBy: "—")
                .last?
                .trimmingCharacters(in: .whitespaces)
            if let trailing, !trailing.isEmpty,
               let match = paths.first(where: { URL(fileURLWithPath: $0).lastPathComponent == trailing }) {
                return match
            }
        }
        return paths[0]
    }

    // MARK: - Accessibility reads

    private static func axDocumentPath(pid: pid_t) -> String? {
        let axApp = AXUIElementCreateApplication(pid)
        for attribute in [kAXFocusedWindowAttribute, kAXMainWindowAttribute] {
            var ref: CFTypeRef?
            guard AXUIElementCopyAttributeValue(axApp, attribute as CFString, &ref) == .success,
                  let raw = ref
            else { continue }
            let window = unsafeBitCast(raw, to: AXUIElement.self)
            var documentRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(
                    window, kAXDocumentAttribute as CFString, &documentRef) == .success,
                  let document = documentRef as? String,
                  !document.isEmpty
            else { continue }
            if let url = URL(string: document), url.isFileURL { return url.path }
            if document.hasPrefix("/") { return document }
        }
        return nil
    }

    private static func axWindowTitle(pid: pid_t) -> String? {
        let axApp = AXUIElementCreateApplication(pid)
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
                axApp, kAXFocusedWindowAttribute as CFString, &ref) == .success,
              let raw = ref
        else { return nil }
        let window = unsafeBitCast(raw, to: AXUIElement.self)
        var titleRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
                window, kAXTitleAttribute as CFString, &titleRef) == .success
        else { return nil }
        return titleRef as? String
    }

    // MARK: - Repository root

    /// Walks up from a file or folder until a project marker is found. Returns nil when the
    /// path is not inside a project, so callers can fall back rather than invent a root.
    static func repositoryRoot(containing path: String) -> String? {
        let fileManager = FileManager.default
        var directory = URL(fileURLWithPath: path)
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue {
            directory = directory.deletingLastPathComponent()
        }
        let home = fileManager.homeDirectoryForCurrentUser.path
        var depth = 0
        while directory.path.count > 1, directory.path != home, depth < 24 {
            for marker in rootMarkers
            where fileManager.fileExists(atPath: directory.appendingPathComponent(marker).path) {
                return directory.path
            }
            directory = directory.deletingLastPathComponent()
            depth += 1
        }
        return nil
    }
}
