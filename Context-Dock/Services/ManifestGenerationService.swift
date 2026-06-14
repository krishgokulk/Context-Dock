import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

// MARK: - Manifest Generation Service
// Turns raw `--help` text into a structured ToolManifest using:
//   1. Apple FoundationModels (on-device LLM, macOS 26+) — primary
//   2. Ollama (local Llama) — secondary fallback
//   3. Keyword / subcommand analysis — final fallback (always works)

@MainActor
class ManifestGenerationService {
    static let shared = ManifestGenerationService()

    // MARK: - Public Entry Point

    /// Generate (or update) a manifest for the given tool. Saves to ToolManifestDB automatically.
    func generateAndSave(
        toolName: String,
        binaryPath: String,
        helpText: String
    ) async {
        #if DEBUG
        print("🔬 [ManifestGen] Generating manifest for '\(toolName)'...")
        #endif

        let manifest: ToolManifest

        // 1. Try on-device Apple Intelligence (macOS 26+)
        if #available(macOS 26.0, *),
           let m = await generateWithFoundationModels(toolName: toolName, binaryPath: binaryPath, helpText: helpText) {
            manifest = m
        }
        // 2. Try Ollama (local Llama running at localhost:11434)
        else if let m = await generateWithOllama(toolName: toolName, binaryPath: binaryPath, helpText: helpText) {
            manifest = m
        }
        // 3. Keyword fallback — always succeeds
        else {
            manifest = generateFromKeywords(toolName: toolName, binaryPath: binaryPath, helpText: helpText)
        }

        ToolManifestDB.shared.save(manifest)

        // Also update the intent registry with what the AI found
        let pkg = TerminalPackageManager.shared.packages.first { $0.command == toolName }
            ?? TerminalPackage(name: toolName, command: toolName, description: manifest.description,
                               helpText: helpText)
        await L2IntentRegistry.shared.autoAssignIntent(for: pkg)

        #if DEBUG
        print("✅ [ManifestGen] Done — '\(toolName)' → \(manifest.primaryIntent) (AI:\(manifest.generatedByAI), model:\(manifest.aiModelUsed ?? "keyword"))")
        #endif
    }

    // MARK: - Strategy 1: Apple FoundationModels

    @available(macOS 26.0, *)
    private func generateWithFoundationModels(
        toolName: String,
        binaryPath: String,
        helpText: String
    ) async -> ToolManifest? {
        do {
            let session = LanguageModelSession()
            let prompt = buildPrompt(toolName: toolName, helpText: helpText)
            let response = try await session.respond(to: prompt)
            return parseResponse(response.content, toolName: toolName, binaryPath: binaryPath, model: "apple-on-device")
        } catch {
            #if DEBUG
            print("⚠️ [ManifestGen] FoundationModels error: \(error.localizedDescription)")
            #endif
            return nil
        }
    }

    // MARK: - Strategy 2: Ollama

    private func generateWithOllama(
        toolName: String,
        binaryPath: String,
        helpText: String
    ) async -> ToolManifest? {
        guard let url = URL(string: "http://localhost:11434/api/generate") else { return nil }

        let prompt = buildPrompt(toolName: toolName, helpText: helpText)
        let body: [String: Any] = [
            "model": "llama3.2",
            "prompt": prompt,
            "stream": false,
            "options": ["temperature": 0.1, "num_predict": 800]
        ]

        guard let data = try? JSONSerialization.data(withJSONObject: body) else { return nil }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = data
        req.timeoutInterval = 20

        do {
            let (responseData, _) = try await URLSession.shared.data(for: req)
            if let json = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any],
               let text = json["response"] as? String {
                return parseResponse(text, toolName: toolName, binaryPath: binaryPath, model: "ollama-llama3.2")
            }
        } catch {
            // Ollama not running — silently fall through
        }
        return nil
    }

    // MARK: - Strategy 3: Keyword Fallback

    private func generateFromKeywords(toolName: String, binaryPath: String, helpText: String) -> ToolManifest {
        let pm = TerminalPackageManager.shared
        let tempPkg = TerminalPackage(name: toolName, command: toolName,
                                      description: toolName, helpText: helpText)
        let intents = L2IntentRegistry.shared.detectIntents(for: tempPkg)

        let primaryIntent = intents.first?.rawValue ?? L2ToolIntent.systemMonitor.rawValue
        let requiresPTY = intents.first?.requiresPTY ?? false

        // Build basic command templates from parsed subcommands
        let subcommands = pm.parseSubcommands(from: helpText)
        var commands: [String: String] = [:]
        let semanticPrefixes = ["play", "search", "download", "stop", "pause", "next",
                                "list", "add", "remove", "show", "get", "set", "run"]
        for sub in subcommands.prefix(8) {
            let needsArg = semanticPrefixes.contains(sub)
            commands[sub] = needsArg ? "\(toolName) \(sub) {query}" : "\(toolName) \(sub)"
        }
        if commands.isEmpty {
            commands["run"] = "\(toolName) {query}"
        }

        let description = pm.parseUsagePattern(from: helpText)
            ?? extractFirstDescription(from: helpText, toolName: toolName)

        return ToolManifest(
            toolName: toolName,
            binaryPath: binaryPath,
            primaryIntent: primaryIntent,
            description: description,
            commands: commands,
            requiresPTY: requiresPTY,
            generatedAt: Date(),
            generatedByAI: false,
            aiModelUsed: nil
        )
    }

    // MARK: - Prompt Builder

    private func buildPrompt(toolName: String, helpText: String) -> String {
        let intentOptions = L2ToolIntent.allCases.map { $0.rawValue }.joined(separator: " | ")
        return """
        Analyze this CLI tool's --help output and generate a JSON manifest.

        Tool name: \(toolName)

        --help output:
        \(String(helpText.prefix(2500)))

        Return ONLY valid JSON (no markdown, no explanation):
        {
          "primaryIntent": "<one of: \(intentOptions)>",
          "description": "<one concise sentence>",
          "requiresPTY": <true if TUI/ncurses/interactive fullscreen, false otherwise>,
          "commands": {
            "<semantic_name>": "<\(toolName) command_template with {param} for variable parts>"
          }
        }

        Rules for commands:
        - Use semantic names like: play_search, stop, pause, next, download, search, volume_up
        - Use {query} for search terms, {url} for URLs, {file} for file paths, {number} for numbers
        - Include 3-8 most commonly useful commands
        - If requiresPTY is true, include control commands (stop, pause, next)
        """
    }

    // MARK: - JSON Parser

    private func parseResponse(
        _ text: String,
        toolName: String,
        binaryPath: String,
        model: String
    ) -> ToolManifest? {
        // Extract JSON block — handle markdown code fences or raw JSON
        var jsonText = text
        if let fenceStart = text.range(of: "```json\n") ?? text.range(of: "```\n"),
           let fenceEnd = text.range(of: "\n```", options: .backwards) {
            jsonText = String(text[fenceStart.upperBound..<fenceEnd.lowerBound])
        } else if let braceStart = text.firstIndex(of: "{"),
                  let braceEnd = text.lastIndex(of: "}") {
            jsonText = String(text[braceStart...braceEnd])
        }

        guard let data = jsonText.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            #if DEBUG
            print("⚠️ [ManifestGen] Failed to parse JSON from \(model) response")
            #endif
            return nil
        }

        let primaryIntent = json["primaryIntent"] as? String ?? L2ToolIntent.systemMonitor.rawValue
        let description = json["description"] as? String ?? "\(toolName) CLI tool"
        let requiresPTY = json["requiresPTY"] as? Bool ?? false
        let commands = json["commands"] as? [String: String] ?? ["\(toolName)": "\(toolName) {query}"]

        // Validate: primaryIntent must be a known intent
        let knownIntents = Set(L2ToolIntent.allCases.map { $0.rawValue })
        let validIntent = knownIntents.contains(primaryIntent) ? primaryIntent : L2ToolIntent.systemMonitor.rawValue

        return ToolManifest(
            toolName: toolName,
            binaryPath: binaryPath,
            primaryIntent: validIntent,
            description: description,
            commands: commands,
            requiresPTY: requiresPTY,
            generatedAt: Date(),
            generatedByAI: true,
            aiModelUsed: model
        )
    }

    // MARK: - Helpers

    private func extractFirstDescription(from helpText: String, toolName: String) -> String {
        let lines = helpText.components(separatedBy: .newlines)
        for line in lines {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.count > 10
                && !t.lowercased().hasPrefix(toolName.lowercased())
                && !t.hasPrefix("-")
                && !t.lowercased().hasPrefix("usage")
                && !t.lowercased().hasPrefix("version") {
                return String(t.prefix(100))
            }
        }
        return "\(toolName) CLI tool"
    }
}
