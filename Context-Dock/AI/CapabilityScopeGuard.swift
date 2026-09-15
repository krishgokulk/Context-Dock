// CapabilityScopeGuard.swift
// Context-Dock
//
// The edge of a folder chat, enforced in one place.
//
// A thread scoped to ~/Documents/Invoices promises that it is about that folder. Sixteen
// file capabilities each resolve their own paths, and asking every one of them to also
// police the boundary means the seventeenth will not — and the failure mode is a model
// that was told "clean this up", read "~/Desktop" out of the conversation, and trashed
// files nobody was talking about.
//
// So the check runs before the executor does, over the arguments as written. It is not a
// sandbox — nothing here stops code that wants to reach outside — it is the difference
// between a tool acting on what the user pointed at and a tool acting on a path a model
// composed.

import Foundation

enum CapabilityScopeGuard {

    /// Capabilities that would act *on* the scope's own folder rather than inside it.
    /// Trashing, moving or renaming the directory a conversation is about leaves the thread
    /// pointing at nothing, which is never what "tidy this up" meant.
    ///
    /// finder.organize is deliberately absent: it rearranges files *within* a folder, so
    /// naming the scope root is exactly how it is meant to be called.
    private static let rootProtectedIDs: [String: String] = [
        "finder.trash": "trash",
        "finder.moveFiles": "move",
        "finder.renameFiles": "rename",
    ]

    /// Why this call may not run, or nil when it may.
    static func violation(
        capabilityID: String, input: [String: String], context: UserContext, scopeRoot: URL?
    ) -> String? {
        guard let scopeRoot else { return nil }
        let root = normalized(scopeRoot)

        for url in candidatePaths(input: input, context: context) {
            let candidate = normalized(url)
            guard !isInside(candidate, root: root) else { continue }
            return
                "\(candidate.path) is outside this chat's folder (\(root.path)). This thread "
                + "only acts on what is inside it — open a chat for that folder to work there."
        }

        if let verb = rootProtectedIDs[capabilityID] {
            for url in candidatePaths(input: input, context: context)
            where normalized(url).path == root.path {
                return
                    "That would \(verb) \(root.lastPathComponent) itself, the folder this "
                    + "chat is about. Name the files inside it, or do it in Finder if you "
                    + "mean the folder."
            }
        }

        return nil
    }

    /// Every filesystem path this call would touch: the ones written as arguments, and the
    /// selection it would fall back to when none were.
    ///
    /// Values that are not paths — a rename pattern, a folder name, a search term — are
    /// skipped rather than guessed at. A boundary check that rejected `{name}-{n}` would
    /// teach the user to ignore it.
    static func candidatePaths(input: [String: String], context: UserContext) -> [URL] {
        var urls: [URL] = []
        for value in input.values {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix("/") || trimmed.hasPrefix("~/") else { continue }
            urls.append(URL(fileURLWithPath: (trimmed as NSString).expandingTildeInPath))
        }
        if case .filesSelected(let selected) = context { urls.append(contentsOf: selected) }
        return urls
    }

    // MARK: - Path comparison

    /// Symlinks resolved and `..` removed before comparing. `/tmp/../Users/x` and a
    /// symlinked path both name real locations, and a prefix check on the text alone would
    /// let either walk straight out of the folder it was measured against.
    private static func normalized(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }

    private static func isInside(_ url: URL, root: URL) -> Bool {
        if url.path == root.path { return true }
        let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
        return url.path.hasPrefix(rootPath)
    }
}
