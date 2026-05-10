//
//  CodeSuggestionSaver.swift
//  ILauncher
//
//  Saves AI-suggested code blocks as reusable L2 extensions
//  Handles proper naming, categorization, and persistence
//

import Foundation
import SwiftUI
import Combine

/// Manages saving code suggestions as L2 extensions
class CodeSuggestionSaver: ObservableObject {
    static let shared = CodeSuggestionSaver()

    // MARK: - Published State

    @Published var savedExtensions: [SavedL2Extension] = []
    @Published var showSaveSheet: Bool = false
    @Published var pendingSave: PendingSave?

    private let userDefaultsKey = "SavedL2Extensions"
    private let extensionDirectoryName = "L2Extensions"

    private init() {
        loadSavedExtensions()
    }

    // MARK: - Data Types

    struct SavedL2Extension: Identifiable, Codable {
        let id: UUID
        var name: String
        var displayName: String
        var description: String
        var command: String
        var scriptContent: String
        var fileTypes: [String]
        var category: String
        var createdAt: Date
        var lastUsed: Date?
        var useCount: Int

        init(name: String, displayName: String, description: String, command: String,
             scriptContent: String, fileTypes: [String], category: String = "L2") {
            self.id = UUID()
            self.name = name
            self.displayName = displayName
            self.description = description
            self.command = command
            self.scriptContent = scriptContent
            self.fileTypes = fileTypes
            self.category = category
            self.createdAt = Date()
            self.lastUsed = nil
            self.useCount = 0
        }
    }

    struct PendingSave {
        let codeBlock: String
        let command: String
        var suggestedName: String
        var description: String
        var fileTypes: [String]
        let sourceContext: String?
    }

    // MARK: - Code Block Parsing

    /// Parse a code block from AI response and prepare for saving
    func parseCodeBlock(from text: String, context: UserContext?) -> PendingSave? {
        // Extract code between ```bash or ``` blocks
        let patterns = [
            #"```(?:bash|sh|shell)\n([\s\S]*?)```"#,
            #"```\n([\s\S]*?)```"#,
            #"`([^`]+)`"#
        ]

        var extractedCode: String?

        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: []),
               let match = regex.firstMatch(in: text, options: [], range: NSRange(text.startIndex..., in: text)),
               let codeRange = Range(match.range(at: 1), in: text) {
                extractedCode = String(text[codeRange])
                break
            }
        }

        guard let code = extractedCode, !code.isEmpty else {
            return nil
        }

        // Generate name from command
        let suggestedName = generateNameFromCommand(code)

        // Detect file types from context or command
        let fileTypes = detectFileTypes(from: code, context: context)

        // Generate description
        let description = generateDescription(from: code)

        return PendingSave(
            codeBlock: code,
            command: extractCommandName(from: code),
            suggestedName: suggestedName,
            description: description,
            fileTypes: fileTypes,
            sourceContext: describeContext(context)
        )
    }

    /// Extract just the command name (e.g., "unzip" from "unzip file.zip")
    private func extractCommandName(from code: String) -> String {
        let firstLine = code.components(separatedBy: "\n").first ?? code
        let parts = firstLine.components(separatedBy: " ")
        return parts.first ?? code
    }

    /// Generate a human-readable name from command
    private func generateNameFromCommand(_ code: String) -> String {
        let command = extractCommandName(from: code)

        // Map common commands to friendly names
        let nameMapping: [String: String] = [
            "unzip": "Unzip Archive",
            "zip": "Create Zip Archive",
            "tar": "Extract Tar Archive",
            "gzip": "Gzip Compress",
            "gunzip": "Gzip Extract",
            "convert": "ImageMagick Convert",
            "ffmpeg": "FFmpeg Process",
            "gs": "Ghostscript Process",
            "pdftk": "PDF Toolkit",
            "sips": "Image Resize",
            "curl": "Download with cURL",
            "wget": "Download with wget",
            "7z": "7-Zip Process"
        ]

        return nameMapping[command] ?? command.capitalized
    }

    /// Detect relevant file types from command and context
    private func detectFileTypes(from code: String, context: UserContext?) -> [String] {
        var fileTypes: [String] = []

        // From context
        if case .filesSelected(let urls) = context {
            for url in urls {
                let ext = url.pathExtension.lowercased()
                if !ext.isEmpty && !fileTypes.contains(ext) {
                    fileTypes.append(ext)
                }
            }
        }

        // From command patterns
        let patterns: [String: [String]] = [
            "unzip|zip": ["zip"],
            "tar": ["tar", "gz", "tgz"],
            "7z": ["7z", "zip", "rar"],
            "ffmpeg": ["mp4", "mov", "avi", "mkv"],
            "convert|imagemagick": ["jpg", "jpeg", "png", "gif", "webp"],
            "gs|ghostscript": ["pdf"],
            "pdftk": ["pdf"]
        ]

        for (pattern, types) in patterns {
            if code.range(of: pattern, options: .regularExpression) != nil {
                for type in types {
                    if !fileTypes.contains(type) {
                        fileTypes.append(type)
                    }
                }
            }
        }

        return fileTypes
    }

    /// Generate description from command
    private func generateDescription(from code: String) -> String {
        let command = extractCommandName(from: code)

        let descriptions: [String: String] = [
            "unzip": "Extract files from a ZIP archive",
            "zip": "Create a ZIP archive from files",
            "tar": "Extract or create tar archives",
            "convert": "Convert or process images with ImageMagick",
            "ffmpeg": "Process video or audio files",
            "gs": "Process PDF files with Ghostscript",
            "pdftk": "Manipulate PDF files",
            "sips": "Resize or convert images",
            "curl": "Download files from URL",
            "wget": "Download files from URL"
        ]

        return descriptions[command] ?? "Run: \(code.prefix(50))"
    }

    private func describeContext(_ context: UserContext?) -> String? {
        guard let context = context else { return nil }

        switch context {
        case .filesSelected(let urls):
            if urls.count == 1 {
                return "For: \(urls[0].lastPathComponent)"
            } else {
                return "For: \(urls.count) files"
            }
        default:
            return nil
        }
    }

    // MARK: - Save Operations

    /// Initiate save flow with a code block
    func initiateSave(codeBlock: String, context: UserContext?) {
        if let pending = parseCodeBlock(from: codeBlock, context: context) {
            pendingSave = pending
            showSaveSheet = true
        }
    }

    /// Save the pending extension
    func savePendingExtension(name: String, description: String) {
        guard let pending = pendingSave else { return }

        let sanitizedName = sanitizeName(name)

        // Create script content
        let scriptContent = """
        #!/bin/bash
        # \(description)
        # Saved from ILauncher L2 AI suggestions
        # File types: \(pending.fileTypes.joined(separator: ", "))

        \(pending.codeBlock)
        """

        // Create extension
        let extension_ = SavedL2Extension(
            name: sanitizedName,
            displayName: name,
            description: description,
            command: pending.command,
            scriptContent: scriptContent,
            fileTypes: pending.fileTypes
        )

        // Save to array
        savedExtensions.append(extension_)
        persistExtensions()

        // Save to disk as actual script file
        saveToExtensionDirectory(extension_)

        // Reset state
        pendingSave = nil
        showSaveSheet = false

        // Refresh ExtensionManager
        ExtensionManager.shared.refresh()

        print("✅ [CodeSuggestionSaver] Saved extension: \(name)")
    }

    /// Cancel the save operation
    func cancelSave() {
        pendingSave = nil
        showSaveSheet = false
    }

    // MARK: - File Operations

    private func sanitizeName(_ name: String) -> String {
        return name
            .lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .replacingOccurrences(of: "[^a-z0-9-]", with: "", options: .regularExpression)
    }

    private func getExtensionDirectory() -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let appDir = appSupport.appendingPathComponent("ILauncher")
        let extDir = appDir.appendingPathComponent(extensionDirectoryName)

        // Create directory if needed
        try? FileManager.default.createDirectory(at: extDir, withIntermediateDirectories: true)

        return extDir
    }

    private func saveToExtensionDirectory(_ extension_: SavedL2Extension) {
        let extDir = getExtensionDirectory()
        let fileName = "\(extension_.name).sh"
        let fileURL = extDir.appendingPathComponent(fileName)

        do {
            try extension_.scriptContent.write(to: fileURL, atomically: true, encoding: .utf8)

            // Make executable
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: fileURL.path
            )

            print("✅ [CodeSuggestionSaver] Saved script to: \(fileURL.path)")

        } catch {
            print("❌ [CodeSuggestionSaver] Error saving script: \(error)")
        }
    }

    // MARK: - Persistence

    private func persistExtensions() {
        if let data = try? JSONEncoder().encode(savedExtensions) {
            UserDefaults.standard.set(data, forKey: userDefaultsKey)
        }
    }

    private func loadSavedExtensions() {
        if let data = UserDefaults.standard.data(forKey: userDefaultsKey),
           let extensions = try? JSONDecoder().decode([SavedL2Extension].self, from: data) {
            savedExtensions = extensions
        }
    }

    // MARK: - Usage Tracking

    func markAsUsed(_ extension_: SavedL2Extension) {
        if let index = savedExtensions.firstIndex(where: { $0.id == extension_.id }) {
            savedExtensions[index].lastUsed = Date()
            savedExtensions[index].useCount += 1
            persistExtensions()
        }
    }

    func deleteExtension(_ extension_: SavedL2Extension) {
        savedExtensions.removeAll { $0.id == extension_.id }
        persistExtensions()

        // Also delete the file
        let extDir = getExtensionDirectory()
        let fileURL = extDir.appendingPathComponent("\(extension_.name).sh")
        try? FileManager.default.removeItem(at: fileURL)

        ExtensionManager.shared.refresh()
    }

    // MARK: - Get as ScriptExtensions

    func getAsScriptExtensions() -> [ScriptExtension] {
        let extDir = getExtensionDirectory()

        return savedExtensions.map { ext in
            ScriptExtension(
                name: ext.name,
                displayName: ext.displayName,
                path: extDir.appendingPathComponent("\(ext.name).sh").path,
                type: .shell,
                category: .custom,
                isBuiltIn: false,
                builtInAction: nil
            )
        }
    }
}

// MARK: - Save Extension Sheet View

struct SaveExtensionSheet: View {
    @ObservedObject var saver = CodeSuggestionSaver.shared

    @State private var extensionName: String = ""
    @State private var extensionDescription: String = ""

    var body: some View {
        VStack(spacing: 16) {
            // Header
            HStack {
                Image(systemName: "square.and.arrow.down.fill")
                    .font(.title2)
                    .foregroundStyle(.blue)

                Text("Save as L2 Extension")
                    .font(.headline)

                Spacer()
            }

            if let pending = saver.pendingSave {
                // Code preview
                VStack(alignment: .leading, spacing: 8) {
                    Text("Command")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Text(pending.codeBlock)
                        .font(.system(.body, design: .monospaced))
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(NSColor.textBackgroundColor))
                        .cornerRadius(8)
                }

                // Name field
                VStack(alignment: .leading, spacing: 4) {
                    Text("Extension Name")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    TextField("e.g., Unzip Archive", text: $extensionName)
                        .textFieldStyle(.roundedBorder)
                }

                // Description field
                VStack(alignment: .leading, spacing: 4) {
                    Text("Description")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    TextField("What does this extension do?", text: $extensionDescription)
                        .textFieldStyle(.roundedBorder)
                }

                // File types
                if !pending.fileTypes.isEmpty {
                    HStack {
                        Text("Triggers for:")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        ForEach(pending.fileTypes, id: \.self) { type in
                            Text(".\(type)")
                                .font(.caption)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.blue.opacity(0.2))
                                .cornerRadius(4)
                        }
                    }
                }
            }

            Divider()

            // Buttons
            HStack {
                Button("Cancel") {
                    saver.cancelSave()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button("Save Extension") {
                    let name = extensionName.isEmpty ? (saver.pendingSave?.suggestedName ?? "Custom Extension") : extensionName
                    let desc = extensionDescription.isEmpty ? (saver.pendingSave?.description ?? "") : extensionDescription
                    saver.savePendingExtension(name: name, description: desc)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(saver.pendingSave == nil)
            }
        }
        .padding()
        .frame(width: 400)
        .onAppear {
            if let pending = saver.pendingSave {
                extensionName = pending.suggestedName
                extensionDescription = pending.description
            }
        }
    }
}

// MARK: - Preview

#Preview {
    SaveExtensionSheet()
}
