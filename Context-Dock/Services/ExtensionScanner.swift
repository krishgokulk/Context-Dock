//
//  ExtensionScanner.swift
//  ILauncher
//
//  Automatically discovers and executes shell scripts, Python scripts, etc.
//  from AIExtensions, StatusExtensions, and StarterExtensions directories
//

import Foundation
import AppKit

/// Represents a script-based extension
struct ScriptExtension: Identifiable {
    let id = UUID()
    let name: String
    let displayName: String
    let path: String
    let type: ScriptType
    let category: Category
    var isBuiltIn: Bool = false
    var builtInAction: BuiltInExtension? = nil
    var description: String? = nil

    // For terminal-based extensions
    var terminalCommand: String? = nil
    var requiresTool: String? = nil

    // For app-based extensions
    var targetApp: DefaultAppResolver.DefaultApp? = nil

    // MARK: - Convenience Initializers

    /// Standard initializer for file-based extensions
    init(name: String, displayName: String, path: String, type: ScriptType, category: Category,
         isBuiltIn: Bool = false, builtInAction: BuiltInExtension? = nil) {
        self.name = name
        self.displayName = displayName
        self.path = path
        self.type = type
        self.category = category
        self.isBuiltIn = isBuiltIn
        self.builtInAction = builtInAction
    }

    /// Initializer for dynamically created extensions (app-based, terminal-based)
    init(name: String, displayName: String, category: Category, type: ScriptType,
         scriptPath: String?, isBuiltIn: Bool, builtInAction: BuiltInExtension?,
         description: String? = nil, terminalCommand: String? = nil,
         requiresTool: String? = nil, targetApp: DefaultAppResolver.DefaultApp? = nil) {
        self.name = name
        self.displayName = displayName
        self.path = scriptPath ?? ""
        self.type = type
        self.category = category
        self.isBuiltIn = isBuiltIn
        self.builtInAction = builtInAction
        self.description = description
        self.terminalCommand = terminalCommand
        self.requiresTool = requiresTool
        self.targetApp = targetApp
    }

    enum ScriptType: String {
        case shell = "sh"
        case python = "py"
        case appleScript = "scpt"
        case javascript = "js"
        case ruby = "rb"

        var interpreter: String {
            switch self {
            case .shell: return "/bin/bash"
            case .python: return "/usr/bin/python3"
            case .appleScript: return "/usr/bin/osascript"
            case .javascript: return "/usr/bin/osascript" // Using osascript for JXA
            case .ruby: return "/usr/bin/ruby"
            }
        }

        var icon: String {
            switch self {
            case .shell: return "terminal.fill"
            case .python: return "chevron.left.forwardslash.chevron.right"
            case .appleScript: return "applescript.fill"
            case .javascript: return "curlybraces"
            case .ruby: return "diamond.fill"
            }
        }
    }

    enum Category {
        case ai          // AIExtensions
        case status      // StatusExtensions
        case starter     // StarterExtensions
        case web         // Web userscripts
        case custom      // User custom

        var displayName: String {
            switch self {
            case .ai: return "AI Extension"
            case .status: return "Status Extension"
            case .starter: return "Starter Extension"
            case .web: return "Web Extension"
            case .custom: return "Custom Extension"
            }
        }
    }

    /// Execute the script with given input
    func execute(with input: String) async throws -> String {
        // Check if it's a built-in extension
        if isBuiltIn, let builtInAction = builtInAction {
            print("🔧 [ScriptExtension] Executing built-in action: \(displayName)")
            return try await builtInAction.execute(with: input)
        }

        // Check if it's an app-based extension
        if let app = targetApp {
            print("🔧 [ScriptExtension] Opening with app: \(app.displayName)")
            let paths = input.components(separatedBy: "\n").filter { !$0.isEmpty }
            for path in paths {
                let url = URL(fileURLWithPath: path)
                _ = DefaultAppResolver.shared.openFile(url, with: app)
            }
            return "Opened with \(app.displayName)"
        }

        // Check if it's a terminal-based extension
        if let command = terminalCommand {
            print("🔧 [ScriptExtension] Executing terminal command: \(command)")
            let paths = input.components(separatedBy: "\n").filter { !$0.isEmpty }
            guard let firstPath = paths.first else {
                return "No file provided"
            }

            // Replace placeholders
            var finalCommand = command
                .replacingOccurrences(of: "$FILE", with: firstPath)
                .replacingOccurrences(of: "\"$FILE\"", with: "\"\(firstPath)\"")

            // Handle output file
            let outputPath = firstPath.replacingOccurrences(of: ".", with: "_output.")
            finalCommand = finalCommand
                .replacingOccurrences(of: "$OUTPUT", with: outputPath)
                .replacingOccurrences(of: "\"$OUTPUT\"", with: "\"\(outputPath)\"")

            // Execute via TerminalAIBridge
            let (success, output) = await TerminalAIBridge.shared.processAICommand(
                finalCommand,
                purpose: "Execute \(requiresTool ?? "command")"
            )

            if success {
                return output.isEmpty ? "Command executed successfully" : output
            } else {
                throw ExtensionError.executionFailed(output)
            }
        }

        // Execute external script
        print("🔧 [ScriptExtension] Executing external script: \(path)")
        let process = Process()

        // Set up the process
        if type == .appleScript {
            process.executableURL = URL(fileURLWithPath: type.interpreter)
            process.arguments = [path, input]
        } else {
            process.executableURL = URL(fileURLWithPath: type.interpreter)
            process.arguments = [path, input]
        }

        // Capture output
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        // Run the process
        try process.run()
        process.waitUntilExit()

        // Read output
        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()

        let output = String(data: outputData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let error = String(data: errorData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        if process.terminationStatus != 0 && !error.isEmpty {
            throw ExtensionError.executionFailed(error)
        }

        return output
    }

    /// Execute with file URL
    func execute(withFile fileURL: URL) async throws -> String {
        return try await execute(with: fileURL.path)
    }

    /// Execute with multiple files
    func execute(withFiles fileURLs: [URL]) async throws -> String {
        let paths = fileURLs.map { $0.path }.joined(separator: "\n")
        return try await execute(with: paths)
    }
}

/// Extension execution errors
enum ExtensionError: Error, LocalizedError {
    case executionFailed(String)
    case scriptNotFound
    case invalidScriptType

    var errorDescription: String? {
        switch self {
        case .executionFailed(let message):
            return "Script execution failed: \(message)"
        case .scriptNotFound:
            return "Script file not found"
        case .invalidScriptType:
            return "Unsupported script type"
        }
    }
}

/// Scans and manages script extensions
class ExtensionScanner {
    static let shared = ExtensionScanner()

    private var cachedExtensions: [ScriptExtension] = []
    private var lastScanDate: Date?

    private init() {}

    /// Get all available extensions (cached)
    func getExtensions() -> [ScriptExtension] {
        // Re-scan if cache is older than 5 minutes
        if let lastScan = lastScanDate, Date().timeIntervalSince(lastScan) < 300 {
            return cachedExtensions
        }

        cachedExtensions = scanExtensions()
        lastScanDate = Date()
        return cachedExtensions
    }

    /// Force refresh extensions
    func refresh() {
        cachedExtensions = scanExtensions()
        lastScanDate = Date()
    }

    /// Scan all extension directories
    private func scanExtensions() -> [ScriptExtension] {
        var extensions: [ScriptExtension] = []

        // Define extension directories relative to app
        let extensionDirs: [(name: String, category: ScriptExtension.Category)] = [
            ("AIExtensions", .ai),
            ("StatusExtensions", .status),
            ("StarterExtensions", .starter)
        ]

        // Get base URL (parent of ILauncher directory)
        let baseURL = Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent()

        print("🔍 [ExtensionScanner] Scanning extensions from: \(baseURL.path)")

        for (dirName, category) in extensionDirs {
            let dirURL = baseURL.appendingPathComponent(dirName)

            guard FileManager.default.fileExists(atPath: dirURL.path) else {
                print("⚠️ [ExtensionScanner] Directory not found: \(dirURL.path)")
                continue
            }

            do {
                let files = try FileManager.default.contentsOfDirectory(
                    at: dirURL,
                    includingPropertiesForKeys: [.isExecutableKey],
                    options: [.skipsHiddenFiles]
                )

                for file in files {
                    let fileExtension = file.pathExtension.lowercased()

                    // Check if it's a supported script type
                    guard let scriptType = ScriptExtension.ScriptType(rawValue: fileExtension) else {
                        continue
                    }

                    // Get file name without extension
                    let fileName = file.deletingPathExtension().lastPathComponent

                    // Skip certain files
                    if fileName.hasPrefix(".") || fileName == "README" {
                        continue
                    }

                    // Convert filename to display name (e.g., "count-words" -> "Count Words")
                    let displayName = fileName
                        .replacingOccurrences(of: "-", with: " ")
                        .replacingOccurrences(of: "_", with: " ")
                        .split(separator: " ")
                        .map { $0.capitalized }
                        .joined(separator: " ")

                    let scriptExtension = ScriptExtension(
                        name: fileName,
                        displayName: displayName,
                        path: file.path,
                        type: scriptType,
                        category: category
                    )

                    extensions.append(scriptExtension)
                    print("✅ [ExtensionScanner] Found: \(displayName) (\(scriptType.rawValue))")
                }

            } catch {
                print("❌ [ExtensionScanner] Error scanning \(dirName): \(error)")
            }
        }

        print("📦 [ExtensionScanner] Total extensions found: \(extensions.count)")
        return extensions
    }

    /// Execute an extension by name
    func execute(extensionName: String, with input: String) async throws -> String {
        let extensions = getExtensions()

        guard let ext = extensions.first(where: {
            $0.name.lowercased() == extensionName.lowercased() ||
            $0.displayName.lowercased() == extensionName.lowercased()
        }) else {
            throw ExtensionError.scriptNotFound
        }

        return try await ext.execute(with: input)
    }
}

// MARK: - Integration with SearchResult

extension ScriptExtension {
    /// Convert to SearchResult for display in ILauncher
    func toSearchResult(context: ExecutionContext) -> SearchResult {
        return SearchResult(
            title: displayName,
            subtitle: category.displayName,
            icon: NSImage(systemSymbolName: type.icon, accessibilityDescription: nil),
            action: {
                Task {
                    do {
                        let input = context.getInputForExtension(self)
                        let result = try await self.execute(with: input)

                        // Show result notification
                        self.showResultNotification(result)

                    } catch {
                        // Show error
                        self.showErrorNotification(error)
                    }
                }
            },
            type: .extensionCommand,
            filePath: path,
            contactData: nil
        )
    }

    private func showResultNotification(_ result: String) {
        DispatchQueue.main.async {
            let notification = NSUserNotification()
            notification.title = self.displayName
            notification.informativeText = result.isEmpty ? "Completed" : result
            notification.soundName = NSUserNotificationDefaultSoundName
            NSUserNotificationCenter.default.deliver(notification)
        }
    }

    private func showErrorNotification(_ error: Error) {
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "Extension Error"
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }
}

// MARK: - Execution Context

struct ExecutionContext {
    let selectedText: String?
    let selectedFiles: [URL]
    let selectedURLs: [String]
    let frontmostApp: (bundleId: String, name: String)?

    /// Get appropriate input for extension based on context
    func getInputForExtension(_ ext: ScriptExtension) -> String {
        // Priority: files > text > clipboard

        if !selectedFiles.isEmpty {
            return selectedFiles.map { $0.path }.joined(separator: "\n")
        }

        if let text = selectedText, !text.isEmpty {
            return text
        }

        // Try clipboard as fallback
        if let clipboardText = NSPasteboard.general.string(forType: .string) {
            return clipboardText
        }

        return ""
    }
}
