//
//  UserGlobalExtensionStore.swift
//  Context-Dock
//
//  User-authored Global Context extensions.
//
//  A global *command* runs once and reports a result. An *extension* opens a panel
//  and stays: it lists rows produced by a script, each row can run an action, and it
//  can host AI. Built-ins like Wi-Fi and Process Monitor already behave this way —
//  this lets a user build the same thing without shipping Swift.
//
//  Stored as JSON at ~/Library/Application Support/Context-Dock/global/extensions.json
//

import Foundation
import Combine

// MARK: - Model

struct UserGlobalExtension: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    var icon: String
    var description: String
    var keywords: [String]
    var isEnabled: Bool

    /// Script that prints the panel's rows — one per line. `Title | subtitle` splits
    /// into two lines in the UI; a bare line is just a title.
    var rowsScriptType: String
    var rowsScript: String

    /// Runs when a row is activated. The chosen row's raw text arrives as $CD_ROW.
    var rowActionScriptType: String
    var rowActionScript: String

    /// When on, the panel gains a chat composer wired to the app's AI stack.
    var aiEnabled: Bool
    /// Extra system prompt for this panel's AI, appended after the global one.
    var aiPrompt: String

    init(
        id: UUID = UUID(),
        name: String,
        icon: String = "square.grid.2x2",
        description: String = "",
        keywords: [String] = [],
        isEnabled: Bool = true,
        rowsScriptType: String = "bash",
        rowsScript: String = "",
        rowActionScriptType: String = "bash",
        rowActionScript: String = "",
        aiEnabled: Bool = false,
        aiPrompt: String = ""
    ) {
        self.id = id
        self.name = name
        self.icon = icon
        self.description = description.isEmpty ? name : description
        self.keywords = keywords
        self.isEnabled = isEnabled
        self.rowsScriptType = rowsScriptType
        self.rowsScript = rowsScript
        self.rowActionScriptType = rowActionScriptType
        self.rowActionScript = rowActionScript
        self.aiEnabled = aiEnabled
        self.aiPrompt = aiPrompt
    }

    // Tolerant decode so hand-written / AI-generated JSON only needs id+name.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decode(String.self, forKey: .name)
        icon = try c.decodeIfPresent(String.self, forKey: .icon) ?? "square.grid.2x2"
        description = try c.decodeIfPresent(String.self, forKey: .description) ?? name
        keywords = try c.decodeIfPresent([String].self, forKey: .keywords) ?? []
        isEnabled = try c.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        rowsScriptType = try c.decodeIfPresent(String.self, forKey: .rowsScriptType) ?? "bash"
        rowsScript = try c.decodeIfPresent(String.self, forKey: .rowsScript) ?? ""
        rowActionScriptType = try c.decodeIfPresent(String.self, forKey: .rowActionScriptType) ?? "bash"
        rowActionScript = try c.decodeIfPresent(String.self, forKey: .rowActionScript) ?? ""
        aiEnabled = try c.decodeIfPresent(Bool.self, forKey: .aiEnabled) ?? false
        aiPrompt = try c.decodeIfPresent(String.self, forKey: .aiPrompt) ?? ""
    }

    enum CodingKeys: String, CodingKey {
        case id, name, icon, description, keywords, isEnabled
        case rowsScriptType, rowsScript, rowActionScriptType, rowActionScript
        case aiEnabled, aiPrompt
    }

    /// Does this extension answer to what the user typed?
    func matches(query: String) -> Bool {
        let q = query.lowercased().trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return false }
        if name.lowercased().contains(q) { return true }
        return keywords.contains { $0.lowercased().contains(q) }
    }
}

/// One line printed by a rows script.
struct UserExtensionRow: Identifiable, Equatable {
    let id = UUID()
    let title: String
    let subtitle: String
    /// The original line, handed to the row action as $CD_ROW.
    let raw: String

    init(rawLine: String) {
        raw = rawLine
        let parts = rawLine.components(separatedBy: "|")
        if parts.count >= 2 {
            title = parts[0].trimmingCharacters(in: .whitespaces)
            subtitle = parts.dropFirst().joined(separator: "|")
                .trimmingCharacters(in: .whitespaces)
        } else {
            title = rawLine.trimmingCharacters(in: .whitespaces)
            subtitle = ""
        }
    }
}

// MARK: - Store

@MainActor
final class UserGlobalExtensionStore: ObservableObject {
    static let shared = UserGlobalExtensionStore()

    @Published private(set) var extensions: [UserGlobalExtension] = []

    private let fileURL: URL = {
        let support = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return support
            .appendingPathComponent("Context-Dock/global", isDirectory: true)
            .appendingPathComponent("extensions.json")
    }()

    private init() { load() }

    var enabledExtensions: [UserGlobalExtension] { extensions.filter(\.isEnabled) }

    func matching(query: String) -> [UserGlobalExtension] {
        enabledExtensions.filter { $0.matches(query: query) }
    }

    func add(_ ext: UserGlobalExtension) {
        extensions.append(ext)
        persist()
    }

    func update(_ ext: UserGlobalExtension) {
        guard let idx = extensions.firstIndex(where: { $0.id == ext.id }) else { return }
        extensions[idx] = ext
        persist()
    }

    func remove(_ ext: UserGlobalExtension) {
        extensions.removeAll { $0.id == ext.id }
        persist()
    }

    // MARK: - Persistence

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([UserGlobalExtension].self, from: data)
        else { return }
        extensions = decoded
    }

    private func persist() {
        let snapshot = extensions
        let url = fileURL
        Task.detached(priority: .utility) {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            guard let data = try? encoder.encode(snapshot) else { return }
            try? FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
        }
    }
}

// MARK: - Script runner

/// Runs an extension's scripts off the main thread and hands back stdout. Deliberately
/// separate from LauncherView's runner, which is bound to dock toast feedback.
struct UserExtensionScriptError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

enum UserExtensionScriptRunner {

    static func rows(for ext: UserGlobalExtension,
                     envVars: [String: String]) async -> Result<[UserExtensionRow], UserExtensionScriptError> {
        let script = resolve(ext.rowsScript, envVars: envVars)
        guard !script.isEmpty else { return .success([]) }

        switch await run(type: ext.rowsScriptType, script: script, envVars: envVars) {
        case .failure(let error):
            return .failure(error)
        case .success(let output):
            let rows = output
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .map(UserExtensionRow.init(rawLine:))
            return .success(rows)
        }
    }

    static func runRowAction(for ext: UserGlobalExtension,
                             row: UserExtensionRow,
                             envVars: [String: String]) async -> Result<String, UserExtensionScriptError> {
        var env = envVars
        env["CD_ROW"] = row.raw
        let script = resolve(ext.rowActionScript, envVars: env)
        guard !script.isEmpty else { return .success("") }
        return await run(type: ext.rowActionScriptType, script: script, envVars: env)
    }

    static func resolve(_ value: String, envVars: [String: String]) -> String {
        var resolved = value
        for (key, envValue) in envVars {
            resolved = resolved.replacingOccurrences(of: "{\(key)}", with: envValue)
            resolved = resolved.replacingOccurrences(of: "$\(key)", with: envValue)
        }
        return resolved.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func run(type: String, script: String,
                            envVars: [String: String]) async -> Result<String, UserExtensionScriptError> {
        let (executable, arguments): (String, [String]) = {
            switch type.lowercased() {
            case "applescript": return ("/usr/bin/osascript", ["-e", script])
            case "jxa":         return ("/usr/bin/osascript", ["-l", "JavaScript", "-e", script])
            default:            return ("/bin/zsh", ["-lc", script])
            }
        }()

        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = arguments

                var environment = ProcessInfo.processInfo.environment
                for (k, v) in envVars { environment[k] = v }
                process.environment = environment

                let stdout = Pipe()
                let stderr = Pipe()
                process.standardOutput = stdout
                process.standardError = stderr

                do {
                    try process.run()
                } catch {
                    continuation.resume(returning: .failure(UserExtensionScriptError(message: error.localizedDescription)))
                    return
                }

                let outData = stdout.fileHandleForReading.readDataToEndOfFile()
                let errData = stderr.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()

                let out = String(data: outData, encoding: .utf8) ?? ""
                let err = String(data: errData, encoding: .utf8) ?? ""

                if process.terminationStatus != 0 {
                    let message = err.isEmpty ? "Exited with code \(process.terminationStatus)" : err
                    continuation.resume(returning: .failure(UserExtensionScriptError(
                        message: message.trimmingCharacters(in: .whitespacesAndNewlines))))
                    return
                }
                continuation.resume(returning: .success(
                    out.trimmingCharacters(in: .whitespacesAndNewlines)))
            }
        }
    }
}
