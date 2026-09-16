//  SkillStore.swift
//  Context-Dock
//
//  Skills = reusable, adapter-scoped instruction bundles (prompts / workflows /
//  reasoning) that feed AIProviderRouter as extra context for scoped chat. They
//  are NOT executable permissions — no capability runs from a Skill. Optional,
//  versioned, editable, import/exportable.

import Combine
import Foundation

struct AdapterSkill: Identifiable, Codable, Equatable {
    let id: String
    var adapterBundleId: String
    var name: String
    var summary: String
    var instructions: String      // the reusable prompt / workflow body
    var version: String
    var isEnabled: Bool
    var updatedAt: Date
    /// A `DoraXSurface` raw value when this skill steers one product surface rather than one
    /// app. Empty for every skill written before scopes existed, which is what keeps them
    /// app-scoped. See `scope` in SkillScope.swift.
    var surfaceId: String
    /// Whether this skill's whole body is pasted into its scope's prompt every turn.
    ///
    /// Off by default: a skill costs a name and a summary, and its body arrives through
    /// `skills.read` when a turn needs it. Pinning is the user saying "this one always
    /// applies" and paying for it — and it still only applies inside the skill's own scope.
    var isPinned: Bool

    init(id: String = UUID().uuidString, adapterBundleId: String, name: String,
         summary: String = "", instructions: String, version: String = "1.0",
         isEnabled: Bool = true, updatedAt: Date = Date(), surfaceId: String = "",
         isPinned: Bool = false) {
        self.id = id; self.adapterBundleId = adapterBundleId; self.name = name
        self.summary = summary; self.instructions = instructions; self.version = version
        self.isEnabled = isEnabled; self.updatedAt = updatedAt; self.surfaceId = surfaceId
        self.isPinned = isPinned
    }

    /// Decoded by hand for one reason: `surfaceId` is newer than the store on disk. The
    /// synthesised decoder fails on a key it cannot find, and a throw here is not one missing
    /// field — it is every skill the user has written, silently gone at launch.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        adapterBundleId = try container.decode(String.self, forKey: .adapterBundleId)
        name = try container.decode(String.self, forKey: .name)
        summary = try container.decodeIfPresent(String.self, forKey: .summary) ?? ""
        instructions = try container.decode(String.self, forKey: .instructions)
        version = try container.decodeIfPresent(String.self, forKey: .version) ?? "1.0"
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
        surfaceId = try container.decodeIfPresent(String.self, forKey: .surfaceId) ?? ""
        isPinned = try container.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false
    }

    /// Parse a web `SKILL.md` (Claude / Osaurus style — YAML frontmatter + markdown body)
    /// into an editable AdapterSkill for `bundleId`. Frontmatter keys used: `name`,
    /// `description` → summary, `metadata.version` (or top-level `version`) → version.
    /// Everything after the closing `---` becomes the instructions body. Files with no
    /// frontmatter still import: the first `# Heading` (or filename) is the name and the
    /// whole text is the body.
    static func fromSkillMarkdown(
        _ text: String, bundleId: String, fallbackName: String = "Imported Skill"
    ) -> AdapterSkill? {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        var name = ""
        var summary = ""
        var version = "1.0"
        var body = normalized

        // Frontmatter must be the very first line (allowing a leading BOM/whitespace).
        let leading = normalized.drop { $0 == "\u{FEFF}" || $0 == "\n" || $0 == " " }
        if leading.hasPrefix("---") {
            let afterOpen = leading.dropFirst(3).drop { $0 == "\n" }
            if let closeRange = afterOpen.range(of: "\n---") {
                let front = String(afterOpen[afterOpen.startIndex..<closeRange.lowerBound])
                body = String(afterOpen[closeRange.upperBound...])
                    .drop { $0 == "\n" || $0 == " " || $0 == "-" }
                    .description
                for rawLine in front.split(separator: "\n", omittingEmptySubsequences: false) {
                    let line = String(rawLine)
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    func value(after key: String) -> String? {
                        guard trimmed.lowercased().hasPrefix(key) else { return nil }
                        let raw = trimmed.dropFirst(key.count).trimmingCharacters(in: .whitespaces)
                        return raw.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                    }
                    if let v = value(after: "name:"), name.isEmpty { name = v }
                    else if let v = value(after: "description:"), summary.isEmpty { summary = v }
                    else if let v = value(after: "version:") { version = v }
                }
            }
        }

        let trimmedBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty {
            if let heading = trimmedBody.split(separator: "\n").first(where: {
                $0.trimmingCharacters(in: .whitespaces).hasPrefix("# ")
            }) {
                name = heading.trimmingCharacters(in: .whitespaces)
                    .replacingOccurrences(of: "# ", with: "")
            }
        }
        if name.isEmpty { name = fallbackName }
        guard !trimmedBody.isEmpty else { return nil }

        return AdapterSkill(
            adapterBundleId: bundleId,
            name: name,
            summary: summary,
            instructions: trimmedBody,
            version: version.isEmpty ? "1.0" : version
        )
    }
}

@MainActor
final class SkillStore: ObservableObject {
    static let shared = SkillStore()

    @Published private(set) var skills: [AdapterSkill] = []

    private let fileURL: URL = {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return support.appendingPathComponent("DoraX/Skills.json", isDirectory: false)
    }()

    private init() { load() }

    /// An app's own skills. A skill written for a surface is excluded even when it carries
    /// this bundle id — it was exported from somewhere, and the surface is what it steers.
    func skills(for bundleId: String) -> [AdapterSkill] {
        skills.filter { $0.adapterBundleId == bundleId && $0.surfaceId.isEmpty }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// The skills that steer one product surface: the ones written for it, plus the global
    /// ones, which apply everywhere by definition.
    func skills(steering surface: DoraXSurface) -> [AdapterSkill] {
        skills.filter { $0.steers(surface) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// What a surface is told about its own skills: their names and what each is for, and
    /// where the body is.
    ///
    /// Names and summaries, not bodies — a surface skill is read on demand through
    /// `skills.read`, the way `skills.list` always intended. Pasting seven bodies into every
    /// turn is the prompt-bloat path this scope was added to avoid, and a surface skill is
    /// long by nature: it describes a whole product layer.
    func surfaceInstructionsBlock(for surface: DoraXSurface) -> String {
        let active = skills(steering: surface).filter { $0.isEnabled && !$0.instructions.isEmpty }
        guard !active.isEmpty else { return "" }
        let pinned = active.filter(\.isPinned)
        let listed = active.filter { !$0.isPinned }

        var sections: [String] = []
        if !listed.isEmpty {
            let rows = listed.prefix(12).map { skill -> String in
                let summary = skill.summary.isEmpty
                    ? "no summary — read it before relying on it" : skill.summary
                return "- \(skill.name): \(summary)"
            }
            sections.append("""
                SKILLS FOR THIS SURFACE (\(surface.displayName)) — names and summaries only:
                \(rows.joined(separator: "\n"))
                Read one with the skills.read capability, by name, when the turn needs its \
                rules. These describe how this surface works; follow the one you read over any \
                guess about what the surface can do.
                """)
        }
        if !pinned.isEmpty {
            let bodies = pinned
                .map { "## Skill: \($0.name)\n\($0.instructions)" }
                .joined(separator: "\n\n")
            sections.append(
                "PINNED SKILLS (always in force on \(surface.displayName)):\n\(bodies)")
        }
        return sections.joined(separator: "\n\n")
    }

    /// Pin or unpin one skill. A pinned skill's body is in force every turn inside its own
    /// scope; an unpinned one waits to be read.
    func setPinned(_ pinned: Bool, id: String) {
        guard let idx = skills.firstIndex(where: { $0.id == id }) else { return }
        skills[idx].isPinned = pinned
        save()
        // A file-backed skill's file is the source of truth — the next folder sync would
        // otherwise put the pin straight back to what the file says.
        if SkillFolder.isFileBacked(skills[idx]) {
            SkillFolder.export(skills[idx], slug: SkillFolder.slug(forStableID: skills[idx].id))
        }
    }

    func upsert(_ skill: AdapterSkill) {
        var s = skill
        s.updatedAt = Date()
        if let idx = skills.firstIndex(where: { $0.id == s.id }) {
            skills[idx] = s
        } else {
            skills.append(s)
        }
        save()
    }

    func remove(id: String) {
        skills.removeAll { $0.id == id }
        save()
    }

    func setEnabled(_ enabled: Bool, id: String) {
        guard let idx = skills.firstIndex(where: { $0.id == id }) else { return }
        skills[idx].isEnabled = enabled
        save()
    }

    /// Enabled skills for an app, as a system-prompt block. Empty when the app has none.
    ///
    /// Names and summaries, with bodies only for the skills the user pinned. This used to
    /// paste every enabled body into every scoped turn, which made the prompt-bloat path the
    /// live one and left `skills.list` / `skills.read` — the cheap, on-demand pair the
    /// registry was designed around — as decoration. Progressive disclosure is the default
    /// now, and pinning is the user's opt-out of it.
    func instructionsBlock(for bundleId: String) -> String {
        let active = skills(for: bundleId).filter { $0.isEnabled && !$0.instructions.isEmpty }
        guard !active.isEmpty else { return "" }
        let pinned = active.filter(\.isPinned)
        let listed = active.filter { !$0.isPinned }

        var sections: [String] = []
        if !listed.isEmpty {
            let rows = listed.map { skill -> String in
                let summary = skill.summary.isEmpty
                    ? "no summary — read it before relying on it" : skill.summary
                return "- \(skill.name): \(summary)"
            }
            sections.append("""
                ADAPTER SKILLS (available for this app — names and summaries only):
                \(rows.joined(separator: "\n"))
                Read one with the skills.read capability, by name, when the turn needs its \
                rules. Do not guess at a skill's contents from its summary.
                """)
        }
        if !pinned.isEmpty {
            let bodies = pinned
                .map { "## Skill: \($0.name)\n\($0.instructions)" }
                .joined(separator: "\n\n")
            sections.append("PINNED SKILLS (always in force for this app):\n\(bodies)")
        }
        return sections.joined(separator: "\n\n")
    }

    // MARK: - Import / Export

    func exportData(for bundleId: String) -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try? encoder.encode(skills(for: bundleId))
    }

    @discardableResult
    func importData(_ data: Data, into bundleId: String) -> Int {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let incoming = try? decoder.decode([AdapterSkill].self, from: data) else { return 0 }
        for var skill in incoming {
            skill.adapterBundleId = bundleId
            upsert(skill)
        }
        return incoming.count
    }

    // MARK: - Persistence

    private func load() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: fileURL),
            let decoded = try? decoder.decode([AdapterSkill].self, from: data)
        else { return }
        skills = decoded
    }

    private func save() {
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(skills) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}
