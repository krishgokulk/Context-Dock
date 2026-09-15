//
//  ShortcutRunner.swift
//  ILauncher
//
//  Universal Shortcut Runner v2 - JSON Payload System
//  Executes shortcuts with unified context bundle
//

import Foundation
import AppKit

/// Universal shortcut runner using JSON payload system
class ShortcutRunner {
    static let shared = ShortcutRunner()

    private init() {}

    // MARK: - Context Bundle Structure

    struct ContextBundle: Codable {
        let targetShortcut: String
        let context: Context

        struct Context: Codable {
            let files: [FileInfo]
            let urls: [String]
            let text: String?
            let frontmostApp: FrontmostApp?

            struct FileInfo: Codable {
                let path: String
                let name: String
                let type: String
            }

            struct FrontmostApp: Codable {
                let bundleId: String
                let name: String
            }
        }
    }

    // MARK: - Run Shortcut with Context

    /// Execute shortcut with universal context bundle
    /// - Parameters:
    ///   - shortcutName: Name of the target shortcut to execute
    ///   - fileURLs: Selected files (from Finder, search results, etc.)
    ///   - text: Selected or detected text
    ///   - urls: Browser URLs or other URLs
    ///   - frontmostApp: Current frontmost app info
    func runShortcut(
        named shortcutName: String,
        fileURLs: [URL] = [],
        text: String? = nil,
        urls: [String] = [],
        frontmostApp: (bundleId: String, name: String)? = nil
    ) async throws -> String {

        #if DEBUG
        print("🚀 [ShortcutRunner] Preparing to run '\(shortcutName)'")
        #endif

        // Build context bundle
        let files = fileURLs.map { url in
            ContextBundle.Context.FileInfo(
                path: url.path,
                name: url.lastPathComponent,
                type: url.pathExtension
            )
        }

        let frontmost = frontmostApp.map {
            ContextBundle.Context.FrontmostApp(
                bundleId: $0.bundleId,
                name: $0.name
            )
        }

        let context = ContextBundle.Context(
            files: files,
            urls: urls,
            text: text,
            frontmostApp: frontmost
        )

        let bundle = ContextBundle(
            targetShortcut: shortcutName,
            context: context
        )

        // Convert to JSON
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let jsonData = try encoder.encode(bundle)
        guard let jsonString = String(data: jsonData, encoding: .utf8) else {
            throw RunnerError.jsonEncodingFailed
        }

        #if DEBUG
        print("📦 [ShortcutRunner] Context Bundle:")
        #endif
        #if DEBUG
        print(jsonString)
        #endif

        // Execute via ILauncher Runner v2
        return try await executeRunner(withPayload: jsonString)
    }

    // MARK: - Runner Execution

    private func executeRunner(withPayload payload: String) async throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
        process.arguments = ["run", "ILauncher Runner v2", "--input-path", "-"]

        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()

        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        try process.run()

        // Write JSON payload to stdin
        if let data = payload.data(using: .utf8) {
            inputPipe.fileHandleForWriting.write(data)
        }
        inputPipe.fileHandleForWriting.closeFile()

        // Wait for completion
        process.waitUntilExit()

        // Read output
        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()

        let output = String(data: outputData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let error = String(data: errorData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        if process.terminationStatus != 0 {
            #if DEBUG
            print("❌ [ShortcutRunner] Error: \(error)")
            #endif
            throw RunnerError.executionFailed(error)
        }

        #if DEBUG
        print("✅ [ShortcutRunner] Success: \(output)")
        #endif
        return output
    }

    // MARK: - Convenience Methods

    /// Run shortcut with files only
    func runWithFiles(_ shortcutName: String, files: [URL]) async throws -> String {
        return try await runShortcut(named: shortcutName, fileURLs: files)
    }

    /// Run shortcut with text only
    func runWithText(_ shortcutName: String, text: String) async throws -> String {
        return try await runShortcut(named: shortcutName, text: text)
    }

    /// Run shortcut with URL only
    func runWithURL(_ shortcutName: String, url: String) async throws -> String {
        return try await runShortcut(named: shortcutName, urls: [url])
    }

    /// Run shortcut with combined context (files + text + URLs)
    func runWithCombinedContext(
        _ shortcutName: String,
        files: [URL] = [],
        text: String? = nil,
        url: String? = nil,
        frontmostApp: NSRunningApplication? = nil
    ) async throws -> String {

        var urls: [String] = []
        if let url = url {
            urls.append(url)
        }

        let appInfo = frontmostApp.map { app in
            (bundleId: app.bundleIdentifier ?? "", name: app.localizedName ?? "")
        }

        return try await runShortcut(
            named: shortcutName,
            fileURLs: files,
            text: text,
            urls: urls,
            frontmostApp: appInfo
        )
    }

    // MARK: - Runner Installation Check

    /// Check if ILauncher Runner v2 is installed
    func isRunnerInstalled() -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
        process.arguments = ["list"]

        let pipe = Pipe()
        process.standardOutput = pipe

        do {
            try process.run()
            process.waitUntilExit()

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let output = String(data: data, encoding: .utf8) {
                return output.contains("ILauncher Runner v2")
            }
        } catch {
            #if DEBUG
            print("❌ Failed to check Runner installation: \(error)")
            #endif
        }

        return false
    }

    // MARK: - Direct Input Mode (No Runner v2 Needed!)

    /// Run shortcut with DIRECT input - bypasses Runner v2 completely
    /// This sends files, text, or URLs directly as input to the shortcut
    /// Use this for simple shortcuts that just need files or text as input
    func runDirectly(
        _ shortcutName: String,
        with input: DirectInput
    ) async throws -> String {

        #if DEBUG
        print("🎯 [ShortcutRunner] DIRECT MODE - Running '\(shortcutName)' with direct input")
        #endif

        // Multiple files: the `shortcuts` CLI's --input-path takes ONE path. Passing several
        // as newline text made the shortcut receive path STRINGS instead of the actual images
        // — so a "Convert Photos" shortcut found no image input and popped the share sheet.
        // Run the shortcut once per file (each as a real --input-path file) and aggregate.
        if case .files(let urls) = input, urls.count > 1 {
            var outputs: [String] = []
            for url in urls {
                let out = try await runDirectly(shortcutName, with: .files([url]))
                if !out.isEmpty { outputs.append(out) }
            }
            return outputs.joined(separator: "\n")
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
        
        // Setup pipes
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        
        var needsStdinInput = false
        var stdinData: Data?

        switch input {
        case .files(let urls):
            #if DEBUG
            print("📁 [ShortcutRunner] Direct input: \(urls.count) file(s)")
            #endif
            let filePaths = urls.map { $0.path }

            if filePaths.count == 1 {
                // Single file - pass via --input-path
                process.arguments = ["run", shortcutName, "--input-path", filePaths[0]]
                #if DEBUG
                print("   File: \(filePaths[0])")
                #endif
            } else {
                // Multiple files - pass paths via stdin (one per line)
                let filesText = filePaths.joined(separator: "\n")
                process.arguments = ["run", shortcutName, "--input-path", "-"]
                stdinData = filesText.data(using: .utf8)
                needsStdinInput = true
                #if DEBUG
                print("   Multiple files via stdin:")
                #endif
                for (index, path) in filePaths.enumerated() {
                    #if DEBUG
                    print("     \(index + 1). \(path)")
                    #endif
                }
            }

        case .text(let text):
            #if DEBUG
            print("📝 [ShortcutRunner] Direct input: Text (\(text.count) chars)")
            #endif
            // Text must be passed via stdin with --input-path -
            process.arguments = ["run", shortcutName, "--input-path", "-"]
            stdinData = text.data(using: .utf8)
            needsStdinInput = true
            #if DEBUG
            print("   Text: \(text.prefix(100))\(text.count > 100 ? "..." : "")")
            #endif

        case .url(let urlString):
            #if DEBUG
            print("🌐 [ShortcutRunner] Direct input: URL")
            #endif
            // URL as text via stdin
            process.arguments = ["run", shortcutName, "--input-path", "-"]
            stdinData = urlString.data(using: .utf8)
            needsStdinInput = true
            #if DEBUG
            print("   URL: \(urlString)")
            #endif
        }

        // Setup process pipes
        if needsStdinInput {
            process.standardInput = inputPipe
        }
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        #if DEBUG
        print("🚀 [ShortcutRunner] Executing: shortcuts \(process.arguments!.joined(separator: " "))")
        #endif

        try process.run()
        
        // Write stdin data if needed
        if needsStdinInput, let data = stdinData {
            inputPipe.fileHandleForWriting.write(data)
            inputPipe.fileHandleForWriting.closeFile()
        }

        process.waitUntilExit()

        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()

        let output = String(data: outputData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let error = String(data: errorData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        if process.terminationStatus != 0 {
            #if DEBUG
            print("❌ [ShortcutRunner] Direct execution failed with code \(process.terminationStatus)")
            #endif
            if !error.isEmpty {
                #if DEBUG
                print("   Error: \(error)")
                #endif
            }
            throw RunnerError.executionFailed(error)
        }

        #if DEBUG
        print("✅ [ShortcutRunner] Direct execution completed successfully")
        #endif
        if !output.isEmpty {
            #if DEBUG
            print("   Output: \(output.prefix(200))\(output.count > 200 ? "..." : "")")
            #endif
        }

        return output
    }

    /// Direct input types
    enum DirectInput {
        case files([URL])           // Files as direct input
        case text(String)            // Text as direct input
        case url(String)             // URL as text input
    }

    // MARK: - Errors

    enum RunnerError: Error, LocalizedError {
        case jsonEncodingFailed
        case executionFailed(String)
        case runnerNotInstalled

        var errorDescription: String? {
            switch self {
            case .jsonEncodingFailed:
                return "Failed to encode context as JSON"
            case .executionFailed(let message):
                return "Shortcut execution failed: \(message)"
            case .runnerNotInstalled:
                return "ILauncher Runner v2 is not installed. Please install it from Settings."
            }
        }
    }
}

// MARK: - Example Payloads (for documentation)

extension ShortcutRunner {

    /// Example payload for PDF file + Safari URL + selected text
    static var examplePayload: String {
        """
        {
          "targetShortcut": "Summarise PDF",
          "context": {
            "files": [
              {
                "path": "/Users/username/Desktop/KRISHGOKUL_J_CV.pdf",
                "name": "KRISHGOKUL_J_CV.pdf",
                "type": "pdf"
              }
            ],
            "urls": [
              "https://github.com/anthropics/claude"
            ],
            "text": "This is additional context or notes",
            "frontmostApp": {
              "bundleId": "com.apple.finder",
              "name": "Finder"
            }
          }
        }
        """
    }

    /// Example: Files only (multiple PDFs)
    static var exampleFilesOnly: String {
        """
        {
          "targetShortcut": "Merge PDFs",
          "context": {
            "files": [
              {
                "path": "/Users/username/Documents/doc1.pdf",
                "name": "doc1.pdf",
                "type": "pdf"
              },
              {
                "path": "/Users/username/Documents/doc2.pdf",
                "name": "doc2.pdf",
                "type": "pdf"
              }
            ],
            "urls": [],
            "text": null,
            "frontmostApp": {
              "bundleId": "com.apple.finder",
              "name": "Finder"
            }
          }
        }
        """
    }

    /// Example: Text only
    static var exampleTextOnly: String {
        """
        {
          "targetShortcut": "Translate Selected Text",
          "context": {
            "files": [],
            "urls": [],
            "text": "What is machine learning?",
            "frontmostApp": {
              "bundleId": "com.apple.Notes",
              "name": "Notes"
            }
          }
        }
        """
    }

    /// Example: URL only (Safari)
    static var exampleURLOnly: String {
        """
        {
          "targetShortcut": "Download File",
          "context": {
            "files": [],
            "urls": [
              "https://example.com/downloads/file.zip"
            ],
            "text": null,
            "frontmostApp": {
              "bundleId": "com.apple.Safari",
              "name": "Safari"
            }
          }
        }
        """
    }
}
