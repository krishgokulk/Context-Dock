//
//  LayeredExtensionManager.swift
//  ILauncher
//
//  Manages extensions with layer-based organization and smart discovery
//

import Foundation
import AppKit
import Combine

@MainActor
class LayeredExtensionManager: ObservableObject {
    static let shared = LayeredExtensionManager()

    @Published var allExtensions: [ILExtension] = []
    @Published var extensionChains: [ExtensionChain] = []
    @Published var recentlyUsed: [ILExtension] = []

    // Extension library paths
    private let libraryBasePath: URL
    private let userExtensionsPath: URL

    init() {
        // Setup extension library paths
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        self.libraryBasePath = documentsPath.appendingPathComponent("ILauncher/Extensions")
        self.userExtensionsPath = libraryBasePath.appendingPathComponent("User-Created")

        // Create directories if needed
        createExtensionDirectories()

        // Load extensions asynchronously so init doesn't block main thread
        Task { await self.loadExtensions() }
    }

    // MARK: - Directory Setup
    private func createExtensionDirectories() {
        let fm = FileManager.default
        let directories = [
            "L1-Search/file-actions",
            "L1-Search/app-actions",
            "L1-Search/folder-actions",
            "L2-Context/browser",
            "L2-Context/finder",
            "L2-Context/mail",
            "L2-Context/text-editor",
            "L2-Context/code-editor",
            "L3-Browser/page-enhancers",
            "L3-Browser/extractors",
            "L3-Browser/productivity",
            "L3-Browser/privacy",
            "Cross-Layer",
            "User-Created"
        ]

        for dir in directories {
            let path = libraryBasePath.appendingPathComponent(dir)
            try? fm.createDirectory(at: path, withIntermediateDirectories: true)
        }
    }

    // MARK: - Extension Loading

    /// Async version — offloads all file I/O to a background thread so the main thread stays responsive.
    func loadExtensions() async {
        let libPath = libraryBasePath  // capture let-constant; safe across threads

        // Run all disk I/O on a background thread — including the per-extension reads.
        // Decoding used to run here on the MainActor: a single read that blocks (a file in a
        // TCC-protected location, an evicted iCloud file, a stalled mount) froze the main
        // thread before the menu bar item and hotkeys were installed, so the app looked
        // launched but had no icon and answered nothing, not even Quit.
        let discovered = await Task.detached(priority: .userInitiated) { [libPath] in
            LayeredExtensionManager.discoverExtensionMetadataURLs(at: libPath)
                .compactMap { LayeredExtensionManager.loadExtensionFromMetadata($0) }
        }.value
        let scanned = await Task.detached(priority: .userInitiated) {
            let s = LayeredExtensionManager.loadScanned()
            return s
        }.value

        // Merge on MainActor
        var extensions = ILExtension.allBuiltIn
        extensions.append(contentsOf: discovered)
        extensions.append(contentsOf: scanned)
        allExtensions = extensions

        #if DEBUG
        print("✅ Loaded \(allExtensions.count) extensions")
        #endif
        printExtensionBreakdown()
    }

    private func printExtensionBreakdown() {
        let l1Count = allExtensions.filter { $0.layer == .l1_search }.count
        let l2Count = allExtensions.filter { $0.layer == .l2_context }.count
        let l3Count = allExtensions.filter { $0.layer == .l3_browser }.count
        let crossCount = allExtensions.filter { $0.layer == .crossLayer }.count

        #if DEBUG
        print("   L1 (Search): \(l1Count)")
        #endif
        #if DEBUG
        print("   L2 (Context): \(l2Count)")
        #endif
        #if DEBUG
        print("   L3 (Browser): \(l3Count)")
        #endif
        #if DEBUG
        print("   Cross-Layer: \(crossCount)")
        #endif
    }

    // MARK: - Extension Discovery (nonisolated static — safe to call from Task.detached)

    private nonisolated static func discoverExtensionMetadataURLs(at libraryBasePath: URL) -> [URL] {
        var discovered: [URL] = []
        let fm = FileManager.default
        let layerPaths = [
            libraryBasePath.appendingPathComponent("L1-Search"),
            libraryBasePath.appendingPathComponent("L2-Context"),
            libraryBasePath.appendingPathComponent("L3-Browser"),
            libraryBasePath.appendingPathComponent("Cross-Layer")
        ]
        for layerPath in layerPaths {
            guard let enumerator = fm.enumerator(at: layerPath, includingPropertiesForKeys: nil) else { continue }
            for case let fileURL as URL in enumerator {
                if fileURL.lastPathComponent == "extension.json" {
                    discovered.append(fileURL)
                }
            }
        }
        return discovered
    }

    private nonisolated static func loadExtensionFromMetadata(_ metadataURL: URL) -> ILExtension? {
        do {
            let data = try Data(contentsOf: metadataURL)
            var ext = try JSONDecoder().decode(ILExtension.self, from: data)
            let scriptURL = metadataURL.deletingLastPathComponent().appendingPathComponent(ext.scriptPath)
            if FileManager.default.fileExists(atPath: scriptURL.path) {
                ext.scriptContent = try? String(contentsOf: scriptURL)
            }
            return ext
        } catch {
            #if DEBUG
            print("⚠️ Failed to load extension from \(metadataURL.path): \(error)")
            #endif
            return nil
        }
    }

    private nonisolated static func loadScanned() -> [ILExtension] {
        ExtensionScanner.shared.getExtensions().compactMap { scriptExt -> ILExtension? in
            let layer: ExtensionLayer
            switch scriptExt.category {
            case .starter: layer = .l1_search
            case .ai:      layer = .l2_context
            case .status:  layer = .l1_search
            case .web:     layer = .l3_browser
            case .custom:  layer = .l1_search
            }
            let scriptType: ILExtension.ScriptType
            switch scriptExt.type {
            case .shell:       scriptType = .bash
            case .python:      scriptType = .python
            case .appleScript: scriptType = .applescript
            case .javascript:  scriptType = .javascript
            case .ruby:        scriptType = .bash
            }
            return ILExtension(
                name: scriptExt.displayName,
                description: scriptExt.description ?? "Extension from \(scriptExt.category.displayName)",
                icon: scriptExt.type.icon,
                layer: layer,
                tags: [.automation, .offline],
                category: scriptExt.category.displayName.lowercased(),
                triggers: [.keyword([scriptExt.name.lowercased()])],
                scriptPath: scriptExt.path,
                scriptType: scriptType,
                isBuiltIn: false
            )
        }
    }


    // MARK: - Smart Extension Discovery

    /// Find extensions matching current context
    func discoverExtensions(
        for searchText: String,
        selectedFiles: [URL],
        selectedText: String? = nil,
        frontmostApp: String?,
        layer: ExtensionLayer?
    ) -> [ExtensionDiscoveryResult] {
        var results: [ExtensionDiscoveryResult] = []

        let hasSelection = !selectedFiles.isEmpty || (selectedText != nil && !(selectedText!.isEmpty))

        for ext in allExtensions where ext.enabled {
            // Filter by layer if specified
            if let targetLayer = layer, ext.layer != targetLayer && ext.layer != .crossLayer {
                continue
            }

            var score: Double = 0.0
            var matchReasons: [ExtensionDiscoveryResult.MatchReason] = []

            // 1. Keyword matching
            if !searchText.isEmpty && ext.matchesKeyword(searchText) {
                score += 0.4
                matchReasons.append(.keywordMatch(searchText))
            }

            // 2. File type matching
            if !selectedFiles.isEmpty {
                for file in selectedFiles {
                    let fileExtension = file.pathExtension
                    if ext.matchesFileType(fileExtension) {
                        score += 0.3
                        matchReasons.append(.fileTypeMatch(fileExtension))
                        break
                    }
                }
            }

            // 3. Context matching (frontmost app)
            if ext.matchesContext(frontmostApp: frontmostApp) {
                score += 0.3
                matchReasons.append(.contextMatch(frontmostApp ?? ""))
            }

            // 4. Selection trigger — fires when any file or text is selected
            let hasSelectionTrigger = ext.triggers.contains(.selection)
            if hasSelectionTrigger && hasSelection {
                score += 0.35
                matchReasons.append(.alwaysAvailable)
            }

            // 5. Usage frequency boost
            if ext.usageCount > 0 {
                let usageBoost = min(Double(ext.usageCount) / 100.0, 0.2)
                score += usageBoost
                if ext.usageCount > 10 {
                    matchReasons.append(.frequentlyUsed)
                }
            }

            // 6. Recent usage boost
            if let lastUsed = ext.lastUsed {
                let hoursSinceUse = Date().timeIntervalSince(lastUsed) / 3600
                if hoursSinceUse < 24 {
                    score += 0.1
                }
            }

            // 7. Always available extensions — always shown in L2
            if ext.triggers.contains(.always) {
                score = max(score, 0.25)  // guarantee above threshold
                matchReasons.append(.alwaysAvailable)
            }

            // Add to results if score is high enough
            if score >= 0.25 {
                let primaryReason = matchReasons.first ?? .alwaysAvailable
                results.append(ExtensionDiscoveryResult(
                    ilExtension: ext,
                    relevanceScore: score,
                    matchReason: primaryReason
                ))
            }
        }

        // Sort by relevance score
        return results.sorted { $0.relevanceScore > $1.relevanceScore }
    }

    /// Find extensions for specific layer
    func extensions(for layer: ExtensionLayer) -> [ILExtension] {
        allExtensions.filter { $0.layer == layer || $0.layer == .crossLayer }
    }

    /// Find extensions by category within a layer
    func extensions(for layer: ExtensionLayer, category: String) -> [ILExtension] {
        allExtensions.filter {
            ($0.layer == layer || $0.layer == .crossLayer) && $0.category == category
        }
    }

    /// Find extensions with specific tag
    func extensions(withTag tag: ExtensionTag) -> [ILExtension] {
        allExtensions.filter { $0.tags.contains(tag) }
    }

    /// Suggest extension chains based on current selection
    func suggestChains(for extensions: [ILExtension]) -> [ExtensionChain] {
        var chains: [ExtensionChain] = []

        // Common chain patterns
        if extensions.contains(where: { $0.name == "Compress Images" }) {
            // Compress → Convert → Upload chain
            let compressExt = extensions.first { $0.name == "Compress Images" }
            let convertExt = extensions.first { $0.name == "Convert Image Format" }

            if let compress = compressExt, let convert = convertExt {
                chains.append(ExtensionChain(
                    name: "Optimize & Convert Images",
                    extensions: [compress, convert],
                    autoExecute: false
                ))
            }
        }

        return chains
    }

    // MARK: - Extension Execution
    func execute(extension ext: ILExtension, with input: [URL]) async throws -> String {
        // Record usage
        if let index = allExtensions.firstIndex(where: { $0.id == ext.id }) {
            allExtensions[index].recordUsage()
            addToRecentlyUsed(allExtensions[index])
        }

        // Execute based on script type
        switch ext.scriptType {
        case .bash:
            return try await executeBashScript(ext, input: input)
        case .javascript:
            return try await executeJavaScript(ext, input: input)
        case .applescript:
            return try await executeAppleScript(ext, input: input)
        case .python:
            return try await executePythonScript(ext, input: input)
        case .swift:
            return try await executeSwiftScript(ext, input: input)
        }
    }

    private func executeBashScript(_ ext: ILExtension, input: [URL]) async throws -> String {
        guard var scriptContent = ext.scriptContent else {
            throw LayeredExtensionError.scriptNotFound
        }

        // Substitute {placeholder} → $CD_VAR so values arrive safely via env, not inline injection
        let placeholderMap: [String: String] = [
            "{currentURL}":    "$CD_URL",
            "{selectedText}":  "$CD_TEXT",
            "{selectedFile}":  "$CD_FILE",
            "{selectedFiles}": "$CD_FILES",
            "{appName}":       "$CD_APP",
            "{bundleId}":      "$CD_BUNDLE",
            "{windowTitle}":   "$CD_TITLE",
            "{clipboardText}": "$CD_CLIPBOARD",
            "{pageContent}":   "$CD_PAGE",
        ]
        for (placeholder, envVar) in placeholderMap {
            scriptContent = scriptContent.replacingOccurrences(of: placeholder, with: envVar)
        }

        // Build context environment
        let ctx = AXContextReader.shared.current
        let filePaths = input.map { $0.path }
        let contextEnv: [String: String] = [
            "CD_URL":       ctx.currentURL ?? "",
            "CD_TEXT":      ctx.selectedText ?? "",
            "CD_FILE":      ctx.selectedFilePaths.first ?? filePaths.first ?? "",
            "CD_FILES":     ctx.selectedFilePaths.isEmpty ? filePaths.joined(separator: "\n") : ctx.selectedFilePaths.joined(separator: "\n"),
            "CD_APP":       ctx.appName,
            "CD_BUNDLE":    ctx.bundleId,
            "CD_TITLE":     ctx.windowTitle ?? "",
            "CD_CLIPBOARD": NSPasteboard.general.string(forType: .string) ?? "",
            "CD_PAGE":      "",
        ]
        let processEnv = ProcessInfo.processInfo.environment.merging(contextEnv) { _, new in new }

        // Write temp script
        let tempScript = FileManager.default.temporaryDirectory.appendingPathComponent("ext_\(ext.id.uuidString).sh")
        try scriptContent.write(to: tempScript, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tempScript.path)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [tempScript.path] + filePaths
        process.environment = processEnv

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        try process.run()
        process.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""

        try? FileManager.default.removeItem(at: tempScript)
        return output
    }

    private func executeJavaScript(_ ext: ILExtension, input: [URL]) async throws -> String {
        // For browser extensions - this would be injected via WKWebView
        guard let scriptContent = ext.scriptContent else {
            throw LayeredExtensionError.scriptNotFound
        }
        return scriptContent
    }

    private func executeAppleScript(_ ext: ILExtension, input: [URL]) async throws -> String {
        guard var scriptContent = ext.scriptContent else {
            throw LayeredExtensionError.scriptNotFound
        }

        // Substitute {placeholder} with quoted AppleScript string literals
        let ctx = AXContextReader.shared.current
        let substitutions: [String: String] = [
            "{currentURL}":    ctx.currentURL ?? "",
            "{selectedText}":  ctx.selectedText ?? "",
            "{selectedFile}":  ctx.selectedFilePaths.first ?? input.first?.path ?? "",
            "{appName}":       ctx.appName,
            "{bundleId}":      ctx.bundleId,
            "{windowTitle}":   ctx.windowTitle ?? "",
            "{clipboardText}": NSPasteboard.general.string(forType: .string) ?? "",
        ]
        for (placeholder, value) in substitutions {
            let escaped = value.replacingOccurrences(of: "\"", with: "\\\"")
            scriptContent = scriptContent.replacingOccurrences(of: placeholder, with: escaped)
        }

        var error: NSDictionary?
        guard let script = NSAppleScript(source: scriptContent) else {
            throw LayeredExtensionError.scriptCompilationFailed
        }

        let output = script.executeAndReturnError(&error)
        if let error = error {
            throw LayeredExtensionError.executionFailed(error.description)
        }
        return output.stringValue ?? ""
    }

    private func executePythonScript(_ ext: ILExtension, input: [URL]) async throws -> String {
        // Similar to bash but with python3 interpreter
        return ""
    }

    private func executeSwiftScript(_ ext: ILExtension, input: [URL]) async throws -> String {
        // Would require swift compilation - advanced feature
        return ""
    }

    // MARK: - Recently Used
    private func addToRecentlyUsed(_ ext: ILExtension) {
        recentlyUsed.removeAll { $0.id == ext.id }
        recentlyUsed.insert(ext, at: 0)

        if recentlyUsed.count > 10 {
            recentlyUsed = Array(recentlyUsed.prefix(10))
        }
    }

    // MARK: - Extension Management
    func addExtension(_ ext: ILExtension) {
        saveExtension(ext)
        Task { await self.loadExtensions() }
        #if DEBUG
        print("✅ Extension '\(ext.name)' added and reloaded")
        #endif
    }

    func updateExtension(_ ext: ILExtension) {
        saveExtension(ext)
        Task { await self.loadExtensions() }
        #if DEBUG
        print("✅ Extension '\(ext.name)' updated and reloaded")
        #endif
    }

    func deleteExtension(_ ext: ILExtension) {
        deleteExtensionFiles(ext)
        Task { await self.loadExtensions() }
        #if DEBUG
        print("✅ Extension '\(ext.name)' deleted and reloaded")
        #endif
    }

    private func saveExtension(_ ext: ILExtension) {
        // Determine save path based on layer
        let layerPath: URL
        switch ext.layer {
        case .l1_search:
            layerPath = libraryBasePath.appendingPathComponent("L1-Search/\(ext.category)")
        case .l2_context:
            layerPath = libraryBasePath.appendingPathComponent("L2-Context/\(ext.category)")
        case .l3_browser:
            layerPath = libraryBasePath.appendingPathComponent("L3-Browser/\(ext.category)")
        case .crossLayer:
            layerPath = libraryBasePath.appendingPathComponent("Cross-Layer")
        }

        let extPath = layerPath.appendingPathComponent(ext.id.uuidString)
        try? FileManager.default.createDirectory(at: extPath, withIntermediateDirectories: true)

        // Save metadata
        let metadataPath = extPath.appendingPathComponent("extension.json")
        if let data = try? JSONEncoder().encode(ext) {
            try? data.write(to: metadataPath)
        }

        // Save script if inline
        if let scriptContent = ext.scriptContent {
            let scriptExt = ext.scriptType.fileExtension
            let scriptPath = extPath.appendingPathComponent("script.\(scriptExt)")
            try? scriptContent.write(to: scriptPath, atomically: true, encoding: .utf8)
        }
    }

    private func deleteExtensionFiles(_ ext: ILExtension) {
        // Delete extension folder
        let layerPath: URL
        switch ext.layer {
        case .l1_search:
            layerPath = libraryBasePath.appendingPathComponent("L1-Search/\(ext.category)")
        case .l2_context:
            layerPath = libraryBasePath.appendingPathComponent("L2-Context/\(ext.category)")
        case .l3_browser:
            layerPath = libraryBasePath.appendingPathComponent("L3-Browser/\(ext.category)")
        case .crossLayer:
            layerPath = libraryBasePath.appendingPathComponent("Cross-Layer")
        }

        let extPath = layerPath.appendingPathComponent(ext.id.uuidString)
        try? FileManager.default.removeItem(at: extPath)
    }
}

// MARK: - Extension Errors
enum LayeredExtensionError: Error, LocalizedError {
    case scriptNotFound
    case scriptCompilationFailed
    case executionFailed(String)
    case permissionDenied(String)

    var errorDescription: String? {
        switch self {
        case .scriptNotFound:
            return "Extension script not found"
        case .scriptCompilationFailed:
            return "Failed to compile extension script"
        case .executionFailed(let details):
            return "Extension execution failed: \(details)"
        case .permissionDenied(let permission):
            return "Permission required: \(permission)"
        }
    }
}

// MARK: - Script Type Extension
extension ILExtension.ScriptType {
    var fileExtension: String {
        switch self {
        case .bash: return "sh"
        case .javascript: return "js"
        case .applescript: return "scpt"
        case .python: return "py"
        case .swift: return "swift"
        }
    }
}
