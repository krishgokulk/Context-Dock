import Foundation
import SwiftUI
import Combine

// MARK: - Tool Manifest Model
// Replaces keyword-only detection with a rich per-tool schema stored as JSON files.

struct ToolManifest: Codable, Identifiable {
    var id: UUID = UUID()
    let toolName: String
    let binaryPath: String
    let primaryIntent: String      // L2ToolIntent.rawValue
    var description: String
    var commands: [String: String] // semantic name → shell template, e.g. "play_search" → "ymc play {query}"
    var requiresPTY: Bool
    var generatedAt: Date
    var generatedByAI: Bool
    var aiModelUsed: String?

    /// Interpolate parameters into a command template.
    /// e.g. buildCommand("play_search", params: ["query": "lo-fi beats"])
    ///      → "ymc play 'lo-fi beats'"
    func buildCommand(_ semanticName: String, params: [String: String] = [:]) -> String? {
        guard var template = commands[semanticName] else { return nil }
        for (key, value) in params {
            template = template.replacingOccurrences(of: "{\(key)}", with: value)
        }
        return template
    }

    /// All available command names for display / AI injection.
    var commandSummary: String {
        commands.map { "\($0.key): \($0.value)" }.joined(separator: "\n")
    }
}

// MARK: - Manifest Database
// Stores one JSON file per tool in ~/Library/Application Support/ILauncher/ToolManifests/

@MainActor
class ToolManifestDB: ObservableObject {
    static let shared = ToolManifestDB()

    @Published var manifests: [String: ToolManifest] = [:]  // toolName → manifest

    private let dir: URL

    init() {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!
        dir = appSupport.appendingPathComponent("ILauncher/ToolManifests", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        loadAll()
    }

    // MARK: - CRUD

    func save(_ manifest: ToolManifest) {
        manifests[manifest.toolName] = manifest
        let file = dir.appendingPathComponent("\(manifest.toolName).json")
        if let data = try? JSONEncoder().encode(manifest) {
            try? data.write(to: file, options: .atomic)
        }
        #if DEBUG
        print("💾 [ManifestDB] Saved manifest for '\(manifest.toolName)' (AI: \(manifest.generatedByAI))")
        #endif
    }

    func manifest(for toolName: String) -> ToolManifest? {
        manifests[toolName]
    }

    func remove(_ toolName: String) {
        manifests.removeValue(forKey: toolName)
        let file = dir.appendingPathComponent("\(toolName).json")
        try? FileManager.default.removeItem(at: file)
    }

    /// Build an AI-readable summary of all known tool manifests for injection into prompts.
    func promptSummary() -> String {
        guard !manifests.isEmpty else { return "" }
        var lines = ["Known tool manifests:"]
        for (name, m) in manifests {
            lines.append("  \(name) (\(m.primaryIntent)):")
            for (sem, cmd) in m.commands {
                lines.append("    \(sem): \(cmd)")
            }
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Private

    private func loadAll() {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil
        ) else { return }

        for file in files where file.pathExtension == "json" {
            if let data = try? Data(contentsOf: file),
               let m = try? JSONDecoder().decode(ToolManifest.self, from: data) {
                manifests[m.toolName] = m
            }
        }
        if !manifests.isEmpty {
            #if DEBUG
            print("📋 [ManifestDB] Loaded \(manifests.count) tool manifests")
            #endif
        }
    }
}
