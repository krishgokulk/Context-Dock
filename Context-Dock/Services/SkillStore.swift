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

    init(id: String = UUID().uuidString, adapterBundleId: String, name: String,
         summary: String = "", instructions: String, version: String = "1.0",
         isEnabled: Bool = true, updatedAt: Date = Date()) {
        self.id = id; self.adapterBundleId = adapterBundleId; self.name = name
        self.summary = summary; self.instructions = instructions; self.version = version
        self.isEnabled = isEnabled; self.updatedAt = updatedAt
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

    func skills(for bundleId: String) -> [AdapterSkill] {
        skills.filter { $0.adapterBundleId == bundleId }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
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

    /// Enabled skills for an app, joined as a system-prompt block for the AI.
    /// Empty when the app has no enabled skills.
    func instructionsBlock(for bundleId: String) -> String {
        let active = skills(for: bundleId).filter { $0.isEnabled && !$0.instructions.isEmpty }
        guard !active.isEmpty else { return "" }
        let body = active.map { "## Skill: \($0.name)\n\($0.instructions)" }.joined(separator: "\n\n")
        return "ADAPTER SKILLS (reusable instructions for this app):\n\(body)"
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
