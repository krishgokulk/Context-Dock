// SkillFolder.swift
// Context-Dock
//
// Skills as files on disk, the way Claude Code and Codex take them.
//
// `AdapterSkill.fromSkillMarkdown` has always been able to read a `SKILL.md` — YAML
// frontmatter, markdown body — but there was nowhere to put one. A skill could only be typed
// into Settings, which means it could not be version-controlled, shared, diffed, or written
// by another agent. This is the folder:
//
//     ~/Library/Application Support/Context-Dock/skills/<slug>/SKILL.md
//
// Drop a file in, it is available; edit it, the change lands without a relaunch. The file is
// the source of truth for anything it defines — a disk-backed skill is re-read at launch and
// on change, so an edit made in Settings to one of these is replaced by what the file says.
// Skills typed into Settings are untouched by any of this.
//
// The folder is also where DoraX's own description of itself lives. Every surface — Global
// Context, the corner chat, a CLI scope, clipboard, selection, General Chat, app adapters —
// ships a skill saying what it is, what it can do and what it must not do, seeded here as
// plain markdown the user can read and edit. They are found through `skills.list` and read
// through `skills.read`, so they cost nothing in a prompt until a model goes looking.

import Foundation

@MainActor
enum SkillFolder {

    /// Skills that belong to DoraX itself rather than to an installed app.
    ///
    /// Not a real bundle id, deliberately: `instructionsBlock(for:)` is keyed by bundle id,
    /// so nothing pastes these into a prompt wholesale. They are found and read on demand,
    /// which is the whole point of writing them down.
    static let globalBundleID = "dorax.global"

    static var url: URL {
        let support = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return support.appendingPathComponent("Context-Dock/skills", isDirectory: true)
    }

    /// The id a file-backed skill keeps for life, derived from its folder name.
    ///
    /// Stable so that re-reading the folder replaces a skill rather than adding a second
    /// copy of it beside the first on every launch.
    static func stableID(forSlug slug: String) -> String { "skillmd.\(slug)" }

    static func isFileBacked(_ skill: AdapterSkill) -> Bool {
        skill.id.hasPrefix("skillmd.")
    }

    // MARK: - Reading

    /// Every `SKILL.md` in the folder, parsed.
    static func load() -> [AdapterSkill] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: url, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
        else { return [] }

        return entries.compactMap { entry -> AdapterSkill? in
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: entry.path, isDirectory: &isDirectory) else { return nil }
            // Both shapes people actually use: a folder holding SKILL.md, the way Claude
            // packages one, and a bare `<name>.md` dropped in on its own.
            let file = isDirectory.boolValue
                ? entry.appendingPathComponent("SKILL.md")
                : entry
            guard file.pathExtension.lowercased() == "md",
                let text = try? String(contentsOf: file, encoding: .utf8)
            else { return nil }
            let slug = isDirectory.boolValue
                ? entry.lastPathComponent
                : entry.deletingPathExtension().lastPathComponent
            return parse(text, slug: slug)
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// One file's text as a skill.
    static func parse(_ text: String, slug: String) -> AdapterSkill? {
        let bundleID = frontmatterValue("bundle_id", in: text)
            ?? frontmatterValue("bundleid", in: text)
            ?? globalBundleID
        guard var skill = AdapterSkill.fromSkillMarkdown(
            text, bundleId: bundleID, fallbackName: slug.replacingOccurrences(of: "-", with: " "))
        else { return nil }
        skill = AdapterSkill(
            id: stableID(forSlug: slug),
            adapterBundleId: skill.adapterBundleId,
            name: skill.name,
            summary: skill.summary,
            instructions: skill.instructions,
            version: skill.version,
            isEnabled: frontmatterValue("enabled", in: text)?.lowercased() != "false")
        return skill
    }

    /// A single frontmatter value, including one nested a level under `metadata:`.
    ///
    /// Deliberately small: the existing parser owns name, description and version, and this
    /// only needs the two keys it does not read.
    static func frontmatterValue(_ key: String, in text: String) -> String? {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        let leading = normalized.drop { $0 == "\u{FEFF}" || $0 == "\n" || $0 == " " }
        guard leading.hasPrefix("---") else { return nil }
        let afterOpen = leading.dropFirst(3).drop { $0 == "\n" }
        guard let close = afterOpen.range(of: "\n---") else { return nil }
        let front = afterOpen[afterOpen.startIndex..<close.lowerBound]

        for rawLine in front.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.lowercased().hasPrefix("\(key):") else { continue }
            let value = line.dropFirst(key.count + 1)
                .trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            return value.isEmpty ? nil : value
        }
        return nil
    }

    // MARK: - Syncing into the store

    /// Read the folder into `SkillStore`, and drop file-backed skills whose files are gone.
    @discardableResult
    static func sync() -> Int {
        let onDisk = load()
        let liveIDs = Set(onDisk.map(\.id))

        // A file the user deleted is a skill they removed. Without this the store keeps
        // steering chats with instructions that no longer exist anywhere they can see.
        for stale in SkillStore.shared.skills
        where isFileBacked(stale) && !liveIDs.contains(stale.id) {
            SkillStore.shared.remove(id: stale.id)
        }
        for skill in onDisk {
            // Whatever the file says, including whether it is switched on. A file-backed
            // skill edited in Settings would otherwise disagree with its own file, and one
            // of the two has to win — the one the user can diff.
            SkillStore.shared.upsert(skill)
        }
        return onDisk.count
    }

    // MARK: - Writing

    /// Write a skill to the folder as `SKILL.md`, so it can be edited and shared.
    @discardableResult
    static func export(_ skill: AdapterSkill, slug: String? = nil) -> URL? {
        let folder = url.appendingPathComponent(
            slug ?? slugify(skill.name), isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: folder, withIntermediateDirectories: true)
            let file = folder.appendingPathComponent("SKILL.md")
            try markdown(for: skill).write(to: file, atomically: true, encoding: .utf8)
            return file
        } catch {
            return nil
        }
    }

    static func markdown(for skill: AdapterSkill) -> String {
        var front = """
            ---
            name: \(skill.name)
            description: \(skill.summary)
            """
        if skill.adapterBundleId != globalBundleID {
            front += "\nbundle_id: \(skill.adapterBundleId)"
        }
        front += """

            metadata:
              version: \(skill.version)
            ---

            """
        return front + skill.instructions + "\n"
    }

    static func slugify(_ name: String) -> String {
        let lowered = name.lowercased()
        let mapped = lowered.map { character -> Character in
            character.isLetter || character.isNumber ? character : "-"
        }
        let collapsed = String(mapped)
            .split(separator: "-", omittingEmptySubsequences: true)
            .joined(separator: "-")
        return collapsed.isEmpty ? "skill" : collapsed
    }

    // MARK: - DoraX's own skills

    /// Write the built-in surface skills that are not already on disk.
    ///
    /// Per file, never per folder: a later version that documents a new surface adds that
    /// one file without touching the six the user may have edited. An existing file is never
    /// overwritten — the user's copy of a skill is theirs.
    static func seedBuiltInsIfMissing() {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        for skill in DoraXSurfaceSkills.all {
            let folder = url.appendingPathComponent(skill.slug, isDirectory: true)
            let file = folder.appendingPathComponent("SKILL.md")
            guard !FileManager.default.fileExists(atPath: file.path) else { continue }
            try? FileManager.default.createDirectory(
                at: folder, withIntermediateDirectories: true)
            try? skill.markdown.write(to: file, atomically: true, encoding: .utf8)
        }
    }

    // MARK: - Watching

    private static var watcher: DispatchSourceFileSystemObject?
    private static var debounce: Task<Void, Never>?

    /// Seed, read, and keep reading as the folder changes.
    static func start() {
        seedBuiltInsIfMissing()
        sync()
        watch()
    }

    private static func watch() {
        guard watcher == nil else { return }
        let descriptor = open(url.path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor, eventMask: [.write, .rename, .delete],
            queue: .main)
        source.setEventHandler {
            // Editors save in bursts — write, rename, truncate — and re-reading on each
            // one both wastes work and can read a half-written file.
            debounce?.cancel()
            debounce = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 400_000_000)
                guard !Task.isCancelled else { return }
                sync()
            }
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        watcher = source
    }
}
