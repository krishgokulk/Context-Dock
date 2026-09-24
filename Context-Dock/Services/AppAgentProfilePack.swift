// AppAgentProfilePack.swift
// Context-Dock
//
// An app's agent, as one file to hand to somebody.
//
// A profile is worth sharing precisely because it is the part nobody can discover: the routes to
// prefer, the things never to do, the script that turns this app's state into something useful.
// Sharing it as "copy this Markdown, then also these two shell files, and chmod them" is how a
// good setup stays on one Mac.
//
// A pack is a folder — `Safari.dxagent/` with `AGENT.md` and `scripts/` inside — zipped with
// `ditto`, which is already on every Mac and preserves the executable bit that a script needs and
// a naive zip drops.
//
// Importing is deliberately not "trust and run". Scripts arrive **without** the executable bit
// unless the user says otherwise, because a pack is someone else's code and the moment it becomes
// runnable should be a decision, not a side effect of opening a file.

import Foundation

enum AppAgentProfilePack {

    static let fileExtension = "dxagent"

    struct Contents: Equatable {
        let profile: AppAgentProfile
        /// Script file names carried in the pack, whether or not the profile declares them.
        let scripts: [String]
        /// Names declared in the profile with no file in the pack. Reported rather than
        /// silently dropped: a profile promising a script it does not carry will fail at the
        /// moment someone asks for it, which is the worst time to find out.
        let missingScripts: [String]
    }

    enum PackError: LocalizedError {
        case noProfile
        case archiveFailed(String)

        var errorDescription: String? {
            switch self {
            case .noProfile: return "That pack has no AGENT.md in it."
            case .archiveFailed(let message): return message
            }
        }
    }

    /// What a folder holds, without unpacking anything into the user's config.
    ///
    /// Reading before installing is the whole shape of a safe import: the caller shows this,
    /// the user agrees, and only then does `install` write.
    static func inspect(folder: URL, fileManager: FileManager = .default) throws -> Contents {
        let profileURL = folder.appendingPathComponent("AGENT.md")
        guard let text = try? String(contentsOf: profileURL, encoding: .utf8) else {
            throw PackError.noProfile
        }
        let profile = AppAgentProfile.parse(text)
        let scriptsFolder = folder.appendingPathComponent("scripts", isDirectory: true)
        let scripts = ((try? fileManager.contentsOfDirectory(
            at: scriptsFolder, includingPropertiesForKeys: nil)) ?? [])
            .map(\.lastPathComponent)
            .filter { !$0.hasPrefix(".") }
            .sorted()
        let declared = profile.tools.scripts ?? []
        let missing = declared.filter { name in
            !scripts.contains { $0.caseInsensitiveCompare(name) == .orderedSame }
        }
        return Contents(profile: profile, scripts: scripts, missingScripts: missing)
    }

    /// Copy a pack's folder into the app's own config.
    ///
    /// - Parameter makeScriptsExecutable: false by default. A pack is someone else's code, and
    ///   the moment it becomes runnable is a decision the user makes, not a consequence of
    ///   importing. The Agent page offers it as its own tick.
    static func install(
        folder: URL, forBundleID bundleID: String, into root: URL,
        makeScriptsExecutable: Bool = false, fileManager: FileManager = .default
    ) throws -> Contents {
        let contents = try inspect(folder: folder, fileManager: fileManager)
        let destination = root.appendingPathComponent(bundleID.lowercased(), isDirectory: true)
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)

        let profileURL = destination.appendingPathComponent("AGENT.md")
        if fileManager.fileExists(atPath: profileURL.path) {
            try fileManager.removeItem(at: profileURL)
        }
        try fileManager.copyItem(
            at: folder.appendingPathComponent("AGENT.md"), to: profileURL)

        guard !contents.scripts.isEmpty else { return contents }
        let scriptsDestination = destination.appendingPathComponent("scripts", isDirectory: true)
        try fileManager.createDirectory(at: scriptsDestination, withIntermediateDirectories: true)
        for name in contents.scripts {
            let source = folder.appendingPathComponent("scripts/\(name)")
            let target = scriptsDestination.appendingPathComponent(name)
            if fileManager.fileExists(atPath: target.path) {
                try fileManager.removeItem(at: target)
            }
            try fileManager.copyItem(at: source, to: target)
            try fileManager.setAttributes(
                [.posixPermissions: makeScriptsExecutable ? 0o755 : 0o644],
                ofItemAtPath: target.path)
        }
        return contents
    }

    /// Lay an app's profile and scripts out as a pack folder, ready to zip.
    static func export(
        forBundleID bundleID: String, appName: String, from root: URL, to parent: URL,
        fileManager: FileManager = .default
    ) throws -> URL {
        let source = root.appendingPathComponent(bundleID.lowercased(), isDirectory: true)
        let profileURL = source.appendingPathComponent("AGENT.md")
        guard fileManager.fileExists(atPath: profileURL.path) else { throw PackError.noProfile }

        let safeName = appName.isEmpty ? bundleID : appName
        let packFolder = parent.appendingPathComponent(
            "\(safeName).\(fileExtension)", isDirectory: true)
        if fileManager.fileExists(atPath: packFolder.path) {
            try fileManager.removeItem(at: packFolder)
        }
        try fileManager.createDirectory(at: packFolder, withIntermediateDirectories: true)
        try fileManager.copyItem(
            at: profileURL, to: packFolder.appendingPathComponent("AGENT.md"))

        let scripts = source.appendingPathComponent("scripts", isDirectory: true)
        if fileManager.fileExists(atPath: scripts.path) {
            try fileManager.copyItem(
                at: scripts, to: packFolder.appendingPathComponent("scripts", isDirectory: true))
        }
        return packFolder
    }
}
