// AppAgentScript.swift
// Context-Dock
//
// A script an app's profile declares, and the rules that decide whether it may run.
//
// The profile says `scripts: [tabs-to-md.sh]`; the file sits beside it in the app's own folder.
// That is the whole feature — except that "run the file named in this text" is the sentence every
// arbitrary-execution bug is written in, so the interesting part is what is refused:
//
//   * a name the profile did not declare, so the file system is not a menu;
//   * a path with a directory in it, so `../../../usr/bin/osascript` cannot be reached;
//   * a file outside the app's scripts folder after symlinks are resolved;
//   * a file that is not executable, which fails clearly rather than as a shell error.
//
// The run itself goes through the plugin script runner, which already learned the hard parts:
// pipes read before wait, stdin closed, the environment merged over the real one, a timeout that
// terminates.

import Foundation

enum AppAgentScript {

    enum Refusal: Error, Equatable {
        case notDeclared(String)
        case unsafeName(String)
        case outsideScriptsFolder(String)
        case missing(String)
        case notExecutable(String)

        var message: String {
            switch self {
            case .notDeclared(let name):
                return "\(name) is not declared in this app's AGENT.md. Add it to `scripts:` "
                    + "first — a script the profile does not name is not a script this chat may run."
            case .unsafeName(let name):
                return "\(name) is not a plain file name. A script is named, not pathed."
            case .outsideScriptsFolder(let name):
                return "\(name) resolves outside the app's scripts folder."
            case .missing(let name):
                return "\(name) is declared but not on disk."
            case .notExecutable(let name):
                return "\(name) is not executable. `chmod +x` it and try again."
            }
        }
    }

    /// The scripts folder for an app, beside its AGENT.md.
    static func folder(forBundleID bundleID: String, root: URL) -> URL {
        root
            .appendingPathComponent(bundleID.lowercased(), isDirectory: true)
            .appendingPathComponent("scripts", isDirectory: true)
    }

    /// A plain file name: no separators, no traversal, no hidden files.
    static func isPlainName(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed.count <= 120 else { return false }
        guard !trimmed.contains("/"), !trimmed.contains("\\") else { return false }
        guard trimmed != ".", trimmed != "..", !trimmed.hasPrefix(".") else { return false }
        return true
    }

    /// The file to run, or why not.
    ///
    /// `declared` is the profile's own list, passed in rather than read here so the rule can be
    /// tested without a profile on disk — and so there is exactly one place that decides.
    static func resolve(
        name: String, declared: [String], bundleID: String, root: URL,
        fileManager: FileManager = .default
    ) -> Result<URL, Refusal> {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard isPlainName(trimmed) else { return .failure(.unsafeName(trimmed)) }
        guard declared.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame })
        else { return .failure(.notDeclared(trimmed)) }

        let folder = folder(forBundleID: bundleID, root: root)
        let candidate = folder.appendingPathComponent(trimmed)
        guard fileManager.fileExists(atPath: candidate.path) else {
            return .failure(.missing(trimmed))
        }
        // After symlinks. A declared name pointing at a link out of the folder is the same
        // escape as a path, written differently.
        let resolved = candidate.resolvingSymlinksInPath()
        let resolvedFolder = folder.resolvingSymlinksInPath()
        guard resolved.path.hasPrefix(resolvedFolder.path + "/") else {
            return .failure(.outsideScriptsFolder(trimmed))
        }
        guard fileManager.isExecutableFile(atPath: resolved.path) else {
            return .failure(.notExecutable(trimmed))
        }
        return .success(resolved)
    }

    /// What a script is told about the turn that asked for it.
    ///
    /// Same `CD_*` names plugins already use, because a person who has written one plugin
    /// script should not have to learn a second vocabulary. An absent value sets no variable at
    /// all, so a script can tell "nothing selected" from "empty selection".
    static func environment(
        appName: String, bundleID: String, query: String, selection: [URL] = [],
        value: String? = nil
    ) -> [String: String] {
        var env = [
            "CD_APP_NAME": appName,
            "CD_BUNDLE_ID": bundleID,
            "CD_QUERY": query,
        ]
        if !selection.isEmpty {
            env["CD_SELECTION"] = selection.map(\.path).joined(separator: "\n")
            env["CD_SELECTION_COUNT"] = String(selection.count)
        }
        if let value, !value.isEmpty { env["CD_VALUE"] = value }
        return env
    }
}
