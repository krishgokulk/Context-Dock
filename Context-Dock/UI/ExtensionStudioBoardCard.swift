// ExtensionStudioBoardCard.swift
// Context-Dock
//
// Unified In-Sheet AI Extension, Global Command, App Plugin (.doraxpack v2), and
// Dynamic Notch Action Studio (`provider:studio`).
//
// Runs 100% inside the 680 × 440 Launcher Result Sheet (zero separate windows), reusing:
// - `SystemCommandsRegistry.shared` for Global Commands, Live List Extensions (`provider:custom`),
//   and Quicklinks
// - `UserSelectionExtensionStore.shared` for custom Selection Scope file/text extensions whose
//   output displays right inside the Result Sheet (just like `Extract Text`)
// - `PluginCreatorModel` + `AgenticAIPackBuilder` + `StorePackInstaller.installV2` for per-app
//   and global `.doraxpack` v2 packs
// - `NotchPinStore.shared` + `PluginNotchView` for Dynamic Island Notch quick actions & wings

import AppKit
import Combine
import Foundation
import SwiftUI

// MARK: - User Selection Scope Extension Store

struct UserSelectionExtensionItem: Codable, Identifiable, Equatable {
    enum ExecutionKind: String, Codable, CaseIterable, Identifiable {
        case aiPrompt = "aiPrompt"
        case bash = "bash"
        case python = "python"
        case applescript = "applescript"

        var id: String { rawValue }
        var label: String {
            switch self {
            case .aiPrompt: return "AI Prompt"
            case .bash: return "Shell (zsh/bash)"
            case .python: return "Python 3"
            case .applescript: return "AppleScript"
            }
        }
    }

    enum OutputPresentation: String, Codable, CaseIterable, Identifiable {
        case showInSheet = "sheet"
        case copyToClipboard = "copy"

        var id: String { rawValue }
        var label: String {
            switch self {
            case .showInSheet: return "Show Output in Result Sheet"
            case .copyToClipboard: return "Copy Result to Clipboard"
            }
        }
    }

    var id: UUID = UUID()
    var name: String
    var icon: String
    var description: String
    var fileExtensions: [String]   // Empty = all files/text; e.g. ["pdf", "txt"]
    var executionKind: ExecutionKind
    var body: String               // Prompt template or script ($CD_FILE, $CD_TEXT, $CD_QUERY)
    var outputPresentation: OutputPresentation = .showInSheet
    var isEnabled: Bool = true

    static let rowIDPrefix = "user-sel-ext:"
    var actionRowID: String { Self.rowIDPrefix + id.uuidString }
}

@MainActor
final class UserSelectionExtensionStore: ObservableObject {
    static let shared = UserSelectionExtensionStore()

    @Published private(set) var items: [UserSelectionExtensionItem] = []

    private let storageURL: URL = {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Context-Dock/selection", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("user-selection-extensions.json")
    }()

    private init() {
        load()
    }

    func load() {
        guard let data = try? Data(contentsOf: storageURL),
            let decoded = try? JSONDecoder().decode([UserSelectionExtensionItem].self, from: data)
        else { return }
        items = decoded
    }

    func save() {
        guard let data = try? JSONEncoder().encode(items) else { return }
        try? data.write(to: storageURL, options: .atomic)
    }

    func add(_ item: UserSelectionExtensionItem) {
        items.insert(item, at: 0)
        save()
    }

    func remove(id: UUID) {
        items.removeAll { $0.id == id }
        save()
    }

    func item(forRowID rowID: String) -> UserSelectionExtensionItem? {
        guard rowID.hasPrefix(UserSelectionExtensionItem.rowIDPrefix) else { return nil }
        let rawUUID = String(rowID.dropFirst(UserSelectionExtensionItem.rowIDPrefix.count))
        guard let uuid = UUID(uuidString: rawUUID) else { return nil }
        return items.first { $0.id == uuid && $0.isEnabled }
    }

    func matchingRows(for snapshot: SelectionSnapshot, query: String) -> [SelectionActionRow] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let selectedExts = Set(snapshot.filePaths.map { URL(fileURLWithPath: $0).pathExtension.lowercased() })
        return items.compactMap { item in
            guard item.isEnabled else { return nil }
            if !item.fileExtensions.isEmpty {
                let allowed = Set(item.fileExtensions.map { $0.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ". ")) })
                if !allowed.isEmpty && selectedExts.isDisjoint(with: allowed) { return nil }
            }
            if !q.isEmpty {
                let hay = "\(item.name) \(item.description)".lowercased()
                guard hay.contains(q) else { return nil }
            }
            return SelectionActionRow(
                id: item.actionRowID,
                title: item.name,
                icon: item.icon.isEmpty ? "bolt.horizontal.circle" : item.icon,
                badge: "User Extension",
                accentColorName: "purple",
                kind: .perform
            )
        }
    }

    func execute(
        _ item: UserSelectionExtensionItem,
        fileURL: URL?,
        selectedText: String,
        query: String
    ) async -> String {
        let fileText = fileURL.map { LocalFileTextExtractor.extractText(from: $0) } ?? selectedText
        switch item.executionKind {
        case .aiPrompt:
            let expanded = item.body
                .replacingOccurrences(of: "{file}", with: fileURL?.path ?? "")
                .replacingOccurrences(of: "{selection}", with: String(fileText.prefix(12_000)))
                .replacingOccurrences(of: "{text}", with: String(fileText.prefix(12_000)))
                .replacingOccurrences(of: "{query}", with: query)
            let promptText = expanded.contains(fileText.prefix(80)) || fileText.isEmpty
                ? expanded
                : "\(expanded)\n\n---\nContent:\n\(String(fileText.prefix(12_000)))"
            do {
                return try await PanelAssistant.ask(
                    promptText,
                    title: item.name,
                    subtitle: item.description,
                    extraPrompt: "Return clean, direct output ready to read or copy.",
                    history: [],
                    provider: AppSettings.shared.selectedAIProvider
                )
            } catch {
                return "AI error: \(error.localizedDescription)"
            }

        case .bash, .python, .applescript:
            return await Task.detached(priority: .userInitiated) {
                let process = Process()
                var env = ProcessInfo.processInfo.environment
                env["CD_FILE"] = fileURL?.path ?? ""
                env["CD_TEXT"] = String(fileText.prefix(32_000))
                env["CD_SELECTION"] = String(fileText.prefix(32_000))
                env["CD_QUERY"] = query
                process.environment = env

                switch item.executionKind {
                case .bash:
                    process.executableURL = URL(fileURLWithPath: "/bin/zsh")
                    process.arguments = ["-lc", item.body]
                case .python:
                    process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
                    process.arguments = ["-c", item.body]
                case .applescript:
                    process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
                    process.arguments = ["-e", item.body]
                case .aiPrompt:
                    break
                }

                let out = Pipe()
                let err = Pipe()
                process.standardOutput = out
                process.standardError = err
                process.standardInput = FileHandle.nullDevice
                do {
                    try process.run()
                    process.waitUntilExit()
                    let outStr = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                    let errStr = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                    let combined = outStr.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !combined.isEmpty { return combined }
                    let errTrimmed = errStr.trimmingCharacters(in: .whitespacesAndNewlines)
                    return errTrimmed.isEmpty ? "(Completed with no output)" : errTrimmed
                } catch {
                    return "Execution error: \(error.localizedDescription)"
                }
            }.value
        }
    }
}

// MARK: - Studio Target & State

enum ExtensionStudioTarget: String, CaseIterable, Identifiable {
    case globalCommand = "global"
    case selectionExtension = "selection"
    case appPlugin = "appPlugin"
    case notchAction = "notch"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .globalCommand: return "Global Command"
        case .selectionExtension: return "Selection Action"
        case .appPlugin: return "App Plugin"
        case .notchAction: return "Notch Action"
        }
    }

    var symbol: String {
        switch self {
        case .globalCommand: return "command.square.fill"
        case .selectionExtension: return "sparkles.rectangle.stack"
        case .appPlugin: return "shippingbox.fill"
        case .notchAction: return "menubar.dock.rectangle"
        }
    }
}

enum ExtensionStudioPackMode: String, CaseIterable, Identifiable {
    case createNew = "create"
    case upgradeExisting = "upgrade"
    case importRaycast = "raycast"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .createNew: return "Create"
        case .upgradeExisting: return "Upgrade AI"
        case .importRaycast: return "Import Raycast"
        }
    }

    var symbol: String {
        switch self {
        case .createNew: return "plus.square"
        case .upgradeExisting: return "wand.and.stars"
        case .importRaycast: return "square.and.arrow.down"
        }
    }
}

@MainActor
final class ExtensionStudioModel: ObservableObject {
    static let shared = ExtensionStudioModel()

    @Published var target: ExtensionStudioTarget = .globalCommand
    @Published var packStudioMode: ExtensionStudioPackMode = .createNew
    @Published var selectedUpgradePackID: String = ""
    @Published var upgradeInstruction: String = ""
    @Published var raycastSourceText: String = ""
    @Published var raycastMergeTargetPackID: String = ""
    @Published var name: String = ""
    @Published var icon: String = "sparkles"
    @Published var keywordsText: String = ""
    @Published var fileFilterText: String = ""   // e.g. "pdf, txt" for Selection Action
    @Published var globalCommandMode: String = "bash" // "bash" | "aiPrompt" | "url" | "list"
    @Published var selectionExecKind: UserSelectionExtensionItem.ExecutionKind = .aiPrompt
    @Published var scriptOrPrompt: String = ""
    @Published var targetBundleID: String = ""
    @Published var pinToNotchOnSave: Bool = false

    @Published var isGeneratingAI = false
    @Published var isTesting = false
    @Published var testOutput: String = ""
    @Published var statusMessage: String?
    @Published var previewContextFileURL: URL?

    var pluginCreator = PluginCreatorModel(text: PluginCreatorPane.starter)

    func configure(
        initialTarget: ExtensionStudioTarget,
        contextFile: URL? = nil,
        bundleID: String? = nil,
        upgradePackID: String? = nil,
        packStudioMode explicitMode: ExtensionStudioPackMode? = nil
    ) {
        target = initialTarget
        previewContextFileURL = contextFile
        statusMessage = nil
        if let upgradePackID, !upgradePackID.isEmpty {
            selectedUpgradePackID = upgradePackID
            packStudioMode = explicitMode ?? .upgradeExisting
        } else if let explicitMode {
            packStudioMode = explicitMode
        }
        if selectedUpgradePackID.isEmpty {
            selectedUpgradePackID = DoraxPackV3Registry.shared.packs.first?.id ?? "youtube"
        }
        if let contextFile, fileFilterText.isEmpty {
            let ext = contextFile.pathExtension.lowercased()
            if !ext.isEmpty { fileFilterText = ext }
        }
        if let bundleID, !bundleID.isEmpty, !bundleID.hasPrefix("syscmd://") {
            targetBundleID = bundleID
            pluginCreator.selectedTargetBundleID = bundleID
        } else if let prev = AppDelegate.shared?.previousFrontmostApp?.bundleIdentifier,
            prev != Bundle.main.bundleIdentifier
        {
            targetBundleID = prev
            pluginCreator.selectedTargetBundleID = prev
        }
    }

    /// Uses AI (`PanelAssistant` / `PluginCreatorModel.draft`) to synthesize a complete command,
    /// selection extension, `.doraxpack` v2 plugin, or Notch wing/action from a natural-language prompt.
    func generateWithAI(prompt rawPrompt: String) async {
        let description = rawPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !description.isEmpty, !isGeneratingAI else { return }
        isGeneratingAI = true
        statusMessage = nil
        defer { isGeneratingAI = false }

        if target == .appPlugin || (target == .notchAction && !description.isEmpty && scriptOrPrompt.isEmpty && name.isEmpty) {
            pluginCreator.request = target == .notchAction
                ? "\(description). Include a compact Dynamic Island `notch` presentation (`wing` + `page`)."
                : description
            await pluginCreator.draft()
            if let manifest = pluginCreator.previewManifest {
                name = manifest.name
                icon = manifest.icon
                keywordsText = manifest.keywords.joined(separator: ", ")
                statusMessage = "AI drafted \(manifest.name) (.doraxpack v2)"
                return
            }
        }

        let sysPrompt = """
        Generate a macOS launcher extension specification as strict JSON (no markdown fences) with keys:
        {"name":"Short Title","icon":"sparkles","keywords":"word1, word2","mode":"bash|aiPrompt|url|list","body":"script, URL with {query}, or AI prompt"}
        Rules:
        - For Selection Scope tasks on files/text, use $CD_FILE, $CD_TEXT, $CD_QUERY in bash, or {selection} / {file} in aiPrompt.
        - For live list commands (mode="list"), print JSON lines: {"id":"...","title":"...","badge":"..."}.
        - For URL quicklinks (mode="url"), output e.g. https://github.com/search?q={query}.
        """
        do {
            let reply = try await PanelAssistant.ask(
                description,
                title: "DoraX Extension Studio",
                subtitle: "Synthesize macOS Global Command / Selection Extension",
                extraPrompt: sysPrompt,
                history: [],
                provider: AppSettings.shared.selectedAIProvider
            )
            applyAISynthesizedJSON(reply, fallbackRequest: description)
        } catch {
            // Instant deterministic fallback template when offline or no provider key set
            if name.isEmpty {
                name = String(description.prefix(32)).capitalized
            }
            if target == .selectionExtension {
                selectionExecKind = .aiPrompt
                scriptOrPrompt = "\(description)\n\nContent:\n{selection}"
            } else {
                globalCommandMode = "bash"
                scriptOrPrompt = "echo \"Running: \(description.replacingOccurrences(of: "\"", with: ""))\""
            }
            statusMessage = "Created starter template (configure AI provider for full synthesis)"
        }
    }

    private func applyAISynthesizedJSON(_ raw: String, fallbackRequest: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let jsonSlice: String = {
            if let start = trimmed.firstIndex(of: "{"), let end = trimmed.lastIndex(of: "}") {
                return String(trimmed[start...end])
            }
            return trimmed
        }()
        if let data = jsonSlice.data(using: .utf8),
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        {
            if let n = obj["name"] as? String, !n.isEmpty { name = n }
            if let ic = obj["icon"] as? String, !ic.isEmpty { icon = ic }
            if let kw = obj["keywords"] as? String { keywordsText = kw }
            if let mode = obj["mode"] as? String {
                globalCommandMode = mode
                if mode == "aiPrompt" { selectionExecKind = .aiPrompt }
                else if mode == "bash" || mode == "list" { selectionExecKind = .bash }
            }
            if let body = obj["body"] as? String, !body.isEmpty {
                scriptOrPrompt = body
            }
            statusMessage = "✨ Synthesized “\(name)” with AI — review, test, or save!"
        } else {
            if name.isEmpty { name = String(fallbackRequest.prefix(28)).capitalized }
            scriptOrPrompt = trimmed
            statusMessage = "✨ Drafted script/prompt — ready to test or save"
        }
    }

    func runDryTest() async {
        isTesting = true
        defer { isTesting = false }

        if target == .appPlugin {
            await pluginCreator.runTest()
            testOutput = pluginCreator.runStatus?.text ?? "Plugin validated."
            return
        }

        let tempItem = UserSelectionExtensionItem(
            name: name.isEmpty ? "Test" : name,
            icon: icon,
            description: name,
            fileExtensions: [],
            executionKind: target == .selectionExtension
                ? selectionExecKind
                : (globalCommandMode == "aiPrompt" ? .aiPrompt : .bash),
            body: scriptOrPrompt
        )
        testOutput = await UserSelectionExtensionStore.shared.execute(
            tempItem,
            fileURL: previewContextFileURL,
            selectedText: "Sample selection text for testing",
            query: "test"
        )
    }

    @discardableResult
    func saveCurrent() -> Bool {
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        switch target {
        case .appPlugin:
            if (try? pluginCreator.save()) == true {
                if pinToNotchOnSave, let manifest = pluginCreator.previewManifest,
                    let capID = manifest.capabilities?.first?.id
                {
                    let bid = manifest.targetApp?.bundleId ?? targetBundleID
                    if !bid.isEmpty { NotchPinStore.shared.toggle(capID, for: bid) }
                }
                statusMessage = "✓ Installed App Plugin (.doraxpack v2)"
                return true
            }
            statusMessage = "Fix manifest diagnostics before saving"
            return false

        case .selectionExtension:
            guard !cleanName.isEmpty, !scriptOrPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                statusMessage = "Enter a name and prompt/script first"
                return false
            }
            let exts = fileFilterText
                .split(whereSeparator: { $0 == "," || $0 == " " })
                .map { String($0).replacingOccurrences(of: ".", with: "").lowercased() }
                .filter { !$0.isEmpty }
            let item = UserSelectionExtensionItem(
                name: cleanName,
                icon: icon.isEmpty ? "sparkles" : icon,
                description: "Custom Selection Action",
                fileExtensions: exts,
                executionKind: selectionExecKind,
                body: scriptOrPrompt,
                outputPresentation: .showInSheet
            )
            UserSelectionExtensionStore.shared.add(item)
            statusMessage = "✓ Saved “\(cleanName)” to Selection Scope!"
            return true

        case .globalCommand, .notchAction:
            if target == .notchAction, pluginCreator.previewManifest != nil, cleanName.isEmpty {
                let ok = (try? pluginCreator.save()) == true
                statusMessage = ok ? "✓ Installed Notch Plugin" : "Could not save Notch Plugin"
                return ok
            }
            guard !cleanName.isEmpty, !scriptOrPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                statusMessage = "Enter a name and script/URL/prompt first"
                return false
            }
            var kws = keywordsText
                .split(whereSeparator: { $0 == "," })
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            if globalCommandMode == "list" && !kws.contains(where: { $0.hasPrefix("provider:") }) {
                kws.append("provider:custom")
                kws.append("query:live")
            }
            let scriptType: String = {
                switch globalCommandMode {
                case "url": return "url"
                case "aiPrompt": return "aiPrompt"
                default: return "bash"
                }
            }()
            let cmd = SystemCommand(
                name: cleanName,
                icon: icon.isEmpty ? "bolt.fill" : icon,
                keywords: kws.isEmpty ? [cleanName.lowercased()] : kws,
                scriptType: scriptType,
                script: scriptOrPrompt,
                description: target == .notchAction ? "Notch & Global Action" : "Custom Global Command"
            )
            SystemCommandsRegistry.shared.add(cmd)

            // Register in CapabilityRegistry so it can ALSO be pinned directly to Dynamic Notch!
            let capID = "user.syscmd.\(cmd.id.uuidString)"
            let targetBid = targetBundleID.isEmpty ? "global" : targetBundleID
            let capability = AICapability(
                id: capID,
                title: cleanName,
                appBundleID: targetBid == "global" ? nil : targetBid,
                inputSchema: AICapabilityInputSchema(fields: []),
                riskLevel: .low,
                runsWithoutAdapter: true,
                executor: { _ in
                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: "/bin/zsh")
                    process.arguments = ["-lc", cmd.script]
                    process.standardInput = FileHandle.nullDevice
                    try? process.run()
                    return AICapabilityExecutionResult(success: true, output: "Ran \(cleanName)")
                }
            )
            CapabilityRegistry.shared.register(capability)
            if target == .notchAction || pinToNotchOnSave {
                let pinBundle = targetBundleID.isEmpty
                    ? (AppDelegate.shared?.previousFrontmostApp?.bundleIdentifier ?? "com.apple.finder")
                    : targetBundleID
                if !NotchPinStore.shared.isPinned(capID, for: pinBundle) {
                    NotchPinStore.shared.toggle(capID, for: pinBundle)
                }
            }
            statusMessage = target == .notchAction
                ? "✓ Saved & Pinned “\(cleanName)” to Dynamic Notch!"
                : "✓ Saved “\(cleanName)” to Global Commands!"
            return true
        }
    }
}

// MARK: - Unified In-Sheet Studio View (`680 × 440`)

struct ExtensionStudioBoardCard: View {
    @ObservedObject var prompt: AppChatPromptModel
    @ObservedObject var studio = ExtensionStudioModel.shared
    @ObservedObject private var pluginCreator = ExtensionStudioModel.shared.pluginCreator
    @ObservedObject private var notchPins = NotchPinStore.shared
    @ObservedObject private var adapterManager = AppAdapterManager.shared
    @ObservedObject private var v3Registry = DoraxPackV3Registry.shared
    @Environment(\.sharesOneCard) private var sharesOneCard

    @State private var selectedV3Template: DoraxPackV3Template = .appCompanion
    @State private var v3Synthesis: DoraxPackV3SynthesisResult? = nil
    @State private var isSynthesizingV3: Bool = false
    @State private var upgradePatch: DoraxPackV3Patch? = nil
    @State private var isProposingUpgrade: Bool = false
    @State private var raycastImportResult: RaycastImportResult? = nil
    @State private var isImportingRaycast: Bool = false

    var onCloseOverride: (() -> Void)? = nil

    private var activeAppBundleID: String {
        if !studio.targetBundleID.isEmpty { return studio.targetBundleID }
        return AppDelegate.shared?.previousFrontmostApp?.bundleIdentifier ?? "com.apple.finder"
    }

    private var activeBrowserApp: NSRunningApplication? {
        if !studio.targetBundleID.isEmpty,
           let matched = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == studio.targetBundleID && !$0.isTerminated })
        {
            return matched
        }
        return AppDelegate.shared?.previousFrontmostApp
    }

    private var activeFrontmostContextLabel: String {
        if let url = DoraxContextBridge.activeBrowserURL(for: activeBrowserApp) {
            let host = DoraxPackScope.normalizedHost(from: url)
            if !host.isEmpty { return host }
        }
        return AppDelegate.shared?.previousFrontmostApp?.localizedName ?? "Frontmost App"
    }

    var body: some View {
        VStack(spacing: 0) {
            // Target Mode Bar
            HStack(spacing: 6) {
                ForEach(ExtensionStudioTarget.allCases) { item in
                    Button {
                        withAnimation(FluidMotion.selectionGlide) {
                            studio.target = item
                        }
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: item.symbol)
                                .font(.system(size: 10.5, weight: .semibold))
                            Text(item.title)
                                .font(.system(size: 11.5, weight: .semibold))
                        }
                        .foregroundStyle(studio.target == item ? Color.accentColor : .secondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(studio.target == item
                                    ? Color.accentColor.opacity(0.16)
                                    : Color.primary.opacity(0.05))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(
                                    studio.target == item
                                        ? Color.accentColor.opacity(0.45)
                                        : Color.white.opacity(0.08),
                                    lineWidth: 1
                                )
                        )
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
                if studio.isGeneratingAI {
                    HStack(spacing: 5) {
                        ProgressView().controlSize(.mini)
                        Text("AI synthesizing…")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.horizontal, 14)
            .frame(height: 38)

            Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1)

            // Split Two-Column Body: Left = Authoring Form, Right = Live Preview / Notch Pins / Dry Run
            HStack(alignment: .top, spacing: 0) {
                leftEditorColumn
                    .frame(width: 356)
                Rectangle().fill(Color.white.opacity(0.08)).frame(width: 1)
                rightPreviewColumn
                    .frame(maxWidth: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            studioFooter
        }
        .frame(width: 680, height: 440, alignment: .topLeading)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .background {
            if sharesOneCard {
                Rectangle().fill(Color.white.opacity(0.10)).frame(height: 1)
                    .frame(maxHeight: .infinity, alignment: .top)
            } else {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(Color(nsColor: .windowBackgroundColor).opacity(0.75))
                    .background(GlassBackground(cornerRadius: 22, isDark: nil))
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
                    )
                    .shadow(color: .black.opacity(0.35), radius: 20, y: 10)
            }
        }
        .onAppear {
            ScopedListKeyBridge.shared.run = {
                let typed = prompt.query.trimmingCharacters(in: .whitespacesAndNewlines)
                if !typed.isEmpty {
                    let req = typed
                    prompt.query = ""
                    Task { await studio.generateWithAI(prompt: req) }
                    return true
                }
                return studio.saveCurrent()
            }
        }
        .onDisappear {
            ScopedListKeyBridge.shared.run = nil
        }
    }

    // MARK: Left Column — Editor

    @ViewBuilder
    private var leftEditorColumn: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 10) {
                if studio.target == .appPlugin {
                    // Phase 1 & 2 Sub-Mode Bar: Create | Upgrade AI | Import Raycast
                    HStack(spacing: 5) {
                        ForEach(ExtensionStudioPackMode.allCases) { mode in
                            Button {
                                studio.packStudioMode = mode
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: mode.symbol)
                                        .font(.system(size: 9.5, weight: .semibold))
                                    Text(mode.title)
                                        .font(.system(size: 10.5, weight: .semibold))
                                        .lineLimit(1)
                                        .fixedSize(horizontal: true, vertical: false)
                                }
                                .foregroundStyle(studio.packStudioMode == mode ? Color.accentColor : .secondary)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 5)
                                .frame(maxWidth: .infinity)
                                .background(
                                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                                        .fill(studio.packStudioMode == mode ? Color.accentColor.opacity(0.18) : Color.white.opacity(0.05))
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    switch studio.packStudioMode {
                    case .createNew:
                        HStack(spacing: 6) {
                            Text("Target")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.secondary)
                            Picker("", selection: $studio.targetBundleID) {
                                Text("Frontmost").tag("")
                                if !studio.targetBundleID.isEmpty,
                                   !adapterManager.adapters.contains(where: { $0.bundleId == studio.targetBundleID })
                                {
                                    Text(AppDelegate.shared?.previousFrontmostApp?.localizedName ?? studio.targetBundleID)
                                        .tag(studio.targetBundleID)
                                }
                                ForEach(adapterManager.adapters.filter { !$0.bundleId.isEmpty }, id: \.bundleId) { a in
                                    Text(a.appName.isEmpty ? a.bundleId : a.appName).tag(a.bundleId)
                                }
                            }
                            .labelsHidden()
                            .controlSize(.small)
                            .frame(maxWidth: 100)
                            .onChange(of: studio.targetBundleID) { _, bid in
                                studio.pluginCreator.selectedTargetBundleID = bid
                            }
                            Spacer(minLength: 4)
                            Button {
                                Task {
                                    isSynthesizingV3 = true
                                    let activeURL = DoraxContextBridge.activeBrowserURL(for: activeBrowserApp)
                                    let res = await DoraxPackV3Builder.buildForTarget(
                                        bundleID: activeAppBundleID,
                                        appName: activeFrontmostContextLabel,
                                        activeURL: activeURL,
                                        template: nil)
                                    v3Synthesis = res
                                    pluginCreator.text = res.packJSONText
                                    isSynthesizingV3 = false
                                }
                            } label: {
                                Label(
                                    isSynthesizingV3 ? "Building v3…" : "Create for \(activeFrontmostContextLabel)",
                                    systemImage: "wand.and.stars"
                                )
                                .font(.system(size: 10.5, weight: .semibold))
                                .lineLimit(1)
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                        }

                        // Starter Templates Strip (.doraxpack v3)
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 6) {
                                ForEach(DoraxPackV3Template.allCases) { tpl in
                                    Button {
                                        selectedV3Template = tpl
                                        Task {
                                            isSynthesizingV3 = true
                                            let activeURL = DoraxContextBridge.activeBrowserURL(for: activeBrowserApp)
                                            let res = await DoraxPackV3Builder.buildForTarget(
                                                bundleID: activeAppBundleID,
                                                appName: activeFrontmostContextLabel,
                                                activeURL: activeURL,
                                                template: tpl)
                                            v3Synthesis = res
                                            pluginCreator.text = res.packJSONText
                                            isSynthesizingV3 = false
                                        }
                                    } label: {
                                        Label(tpl.title, systemImage: tpl.icon)
                                            .font(.system(size: 10, weight: .medium))
                                            .padding(.horizontal, 7)
                                            .padding(.vertical, 4)
                                            .background(
                                                RoundedRectangle(cornerRadius: 6)
                                                    .fill(selectedV3Template == tpl ? Color.accentColor.opacity(0.2) : Color.white.opacity(0.06))
                                            )
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }

                        Text("pack.json (.doraxpack v3)")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                        TextEditor(text: $pluginCreator.text)
                            .font(.system(size: 11, design: .monospaced))
                            .scrollContentBackground(.hidden)
                            .padding(8)
                            .frame(height: 156)
                            .background(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(Color.black.opacity(0.22))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .strokeBorder(Color.white.opacity(0.09), lineWidth: 1)
                            )

                    case .upgradeExisting:
                        UpgradePackStudioLeftView(
                            studio: studio,
                            v3Registry: v3Registry,
                            upgradePatch: $upgradePatch,
                            isProposingUpgrade: $isProposingUpgrade)

                    case .importRaycast:
                        ImportRaycastStudioLeftView(
                            studio: studio,
                            v3Registry: v3Registry,
                            raycastImportResult: $raycastImportResult,
                            isImportingRaycast: $isImportingRaycast)
                    }
                } else {
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Icon")
                                .font(.system(size: 10.5, weight: .medium))
                                .foregroundStyle(.secondary)
                            TextField("sparkles", text: $studio.icon)
                                .textFieldStyle(.plain)
                                .font(.system(size: 12, design: .monospaced))
                                .padding(.horizontal, 8)
                                .frame(width: 78, height: 28)
                                .background(Color.black.opacity(0.20), in: RoundedRectangle(cornerRadius: 7))
                        }
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Name")
                                .font(.system(size: 10.5, weight: .medium))
                                .foregroundStyle(.secondary)
                            TextField("e.g. Extract Emails / GitHub Search", text: $studio.name)
                                .textFieldStyle(.plain)
                                .font(.system(size: 12.5, weight: .medium))
                                .padding(.horizontal, 8)
                                .frame(height: 28)
                                .background(Color.black.opacity(0.20), in: RoundedRectangle(cornerRadius: 7))
                        }
                    }

                    if studio.target == .selectionExtension {
                        HStack(spacing: 8) {
                            Picker("Runner", selection: $studio.selectionExecKind) {
                                ForEach(UserSelectionExtensionItem.ExecutionKind.allCases) { k in
                                    Text(k.label).tag(k)
                                }
                            }
                            .controlSize(.small)
                            TextField("Exts (blank=all, or pdf,txt)", text: $studio.fileFilterText)
                                .textFieldStyle(.plain)
                                .font(.system(size: 11.5))
                                .padding(.horizontal, 8)
                                .frame(height: 26)
                                .background(Color.black.opacity(0.20), in: RoundedRectangle(cornerRadius: 6))
                        }
                    } else {
                        HStack(spacing: 8) {
                            Picker("Type", selection: $studio.globalCommandMode) {
                                Text("Shell Script").tag("bash")
                                Text("Live List (JSON)").tag("list")
                                Text("AI Command").tag("aiPrompt")
                                Text("Quicklink URL").tag("url")
                            }
                            .controlSize(.small)
                            TextField("Keywords / Alias", text: $studio.keywordsText)
                                .textFieldStyle(.plain)
                                .font(.system(size: 11.5))
                                .padding(.horizontal, 8)
                                .frame(height: 26)
                                .background(Color.black.opacity(0.20), in: RoundedRectangle(cornerRadius: 6))
                        }
                    }

                    Text(editorLabel)
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(.secondary)

                    TextEditor(text: $studio.scriptOrPrompt)
                        .font(.system(size: 11.5, design: .monospaced))
                        .scrollContentBackground(.hidden)
                        .padding(8)
                        .frame(height: 168)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(Color.black.opacity(0.22))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(Color.white.opacity(0.09), lineWidth: 1)
                        )

                    Toggle("Also pin to Dynamic Island Notch for frontmost app", isOn: $studio.pinToNotchOnSave)
                        .toggleStyle(.checkbox)
                        .font(.system(size: 11.5))
                }
            }
            .padding(14)
        }
    }

    private var editorLabel: String {
        if studio.target == .selectionExtension {
            return studio.selectionExecKind == .aiPrompt
                ? "AI Prompt (uses {selection}, {file}, {query}) — Output opens in Result Sheet"
                : "Script (uses $CD_FILE, $CD_TEXT, $CD_QUERY) — Output opens in Result Sheet"
        }
        switch studio.globalCommandMode {
        case "url": return "Quicklink URL (use {query} for search terms)"
        case "list": return "Rows Script — print {\"id\":\"...\",\"title\":\"...\",\"badge\":\"...\"} per line"
        case "aiPrompt": return "AI Prompt Template (uses $CD_QUERY, $CD_TEXT)"
        default: return "Shell Command (uses $CD_QUERY)"
        }
    }

    // MARK: Right Column — Live Preview, Notch Pin Manager & Test Runner

    @ViewBuilder
    private var rightPreviewColumn: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 10) {
                if let msg = studio.statusMessage {
                    Text(msg)
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(.green)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.green.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                }

                if studio.target == .notchAction {
                    notchPinManagerCard
                }

                if studio.target == .appPlugin, studio.packStudioMode == .upgradeExisting, let patch = upgradePatch {
                    UpgradePatchReviewCardView(
                        patch: patch,
                        studio: studio,
                        v3Registry: v3Registry,
                        upgradePatch: $upgradePatch)
                } else if studio.target == .appPlugin, studio.packStudioMode == .importRaycast, let imported = raycastImportResult {
                    RaycastImportReviewCardView(
                        imported: imported,
                        studio: studio,
                        v3Registry: v3Registry,
                        raycastImportResult: $raycastImportResult)
                } else if studio.target == .appPlugin, studio.packStudioMode == .upgradeExisting,
                          let activePack = v3Registry.pack(id: studio.selectedUpgradePackID) ?? v3Registry.packs.first
                {
                    VStack(alignment: .leading, spacing: 6) {
                        Label(activePack.name, systemImage: activePack.metadata.icon)
                            .font(.system(size: 13, weight: .semibold))
                        Text(activePack.metadata.description)
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                        HStack(spacing: 8) {
                            Text("v\(activePack.metadata.version)")
                                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Color.white.opacity(0.08), in: Capsule())
                            Text("\((activePack.metadata.commands ?? []).count) commands")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(.secondary)
                        }
                        Text("Describe what to add or change on the left, then click Propose Upgrade with AI.")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
                } else if studio.target == .appPlugin, studio.packStudioMode == .importRaycast {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("Raycast Import Ready", systemImage: "square.and.arrow.down")
                            .font(.system(size: 13, weight: .semibold))
                        Text("Supports # @raycast.* script commands (.sh, .py, .applescript), local Raycast extension folders (package.json), and Raycast Store / GitHub URLs.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
                } else if studio.target == .appPlugin, let syn = v3Synthesis {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Label(syn.review.packName, systemImage: syn.pack.metadata.icon)
                                .font(.system(size: 13, weight: .semibold))
                            Spacer()
                            Text("v3 · \(syn.review.targetLabel)")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(.secondary)
                        }

                        // 1. Schema & Diagnostic Check
                        let errs = syn.review.diagnostics.filter { $0.severity == .error }
                        HStack(spacing: 6) {
                            Image(systemName: errs.isEmpty ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                                .foregroundStyle(errs.isEmpty ? .green : .orange)
                            Text(errs.isEmpty
                                ? "Schema & Diagnostics: 0 errors"
                                : "\(errs.count) diagnostic error(s)")
                                .font(.system(size: 11, weight: .medium))
                        }

                        // 2. Permission & Hook Review Card
                        if !syn.review.contextFieldsRead.isEmpty || !syn.review.hookSummaries.isEmpty || !syn.review.domains.isEmpty {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Permissions & Hooks Review")
                                    .font(.system(size: 10.5, weight: .semibold))
                                    .foregroundStyle(.secondary)
                                if !syn.review.domains.isEmpty {
                                    Text("Domains: \(syn.review.domains.joined(separator: ", "))")
                                        .font(.system(size: 10.5))
                                }
                                if !syn.review.contextFieldsRead.isEmpty {
                                    Text("Context: \(syn.review.contextFieldsRead.joined(separator: ", "))")
                                        .font(.system(size: 10.5))
                                }
                                ForEach(syn.review.hookSummaries, id: \.self) { h in
                                    Text("Hook: \(h)").font(.system(size: 10.5)).foregroundStyle(.orange)
                                }
                            }
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.black.opacity(0.18), in: RoundedRectangle(cornerRadius: 8))
                        }

                        // 3. Read-Only Live Dry Run Preview
                        if let dry = syn.review.dryRunOutput {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Live Dry-Run Preview (\(dry.items.count) items)")
                                    .font(.system(size: 10.5, weight: .semibold))
                                    .foregroundStyle(.secondary)
                                ForEach(dry.items.prefix(3)) { item in
                                    HStack(spacing: 6) {
                                        Image(systemName: item.icon ?? "sparkles").font(.system(size: 10))
                                        Text(item.title).font(.system(size: 11)).lineLimit(1)
                                        Spacer()
                                    }
                                }
                                if let detail = dry.detail, dry.items.isEmpty {
                                    Text(String(detail.markdown.prefix(160)))
                                        .font(.system(size: 10.5, design: .monospaced))
                                        .lineLimit(3)
                                }
                            }
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
                        }

                        // 4. One-Click Install
                        HStack(spacing: 8) {
                            Button("Install Pack (.doraxpack v3)") {
                                do {
                                    let installed = try DoraxPackV3Builder.approveAndInstall(syn)
                                    studio.statusMessage = "Installed \(installed.name) (.doraxpack v3)"
                                    v3Synthesis = nil
                                } catch {
                                    studio.statusMessage = "Install failed: \(error.localizedDescription)"
                                }
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                            .disabled(syn.review.hasBlockingErrors)

                            Button("Dismiss") { v3Synthesis = nil }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                        }
                    }
                    .padding(10)
                    .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
                } else if studio.target == .appPlugin, let pending = studio.pluginCreator.pendingPackResult {
                    OwnerReviewCardView(
                        card: pending.reviewCard,
                        errorMessage: studio.pluginCreator.packBuildError,
                        onApprove: {
                            _ = try? studio.pluginCreator.approvePendingPack()
                            studio.statusMessage = studio.pluginCreator.packInstallStatus
                        },
                        onDismiss: {
                            studio.pluginCreator.dismissPendingPack()
                        }
                    )
                } else if studio.target == .appPlugin, let manifest = studio.pluginCreator.previewManifest {
                    VStack(alignment: .leading, spacing: 6) {
                        Label(manifest.name, systemImage: manifest.icon)
                            .font(.system(size: 13, weight: .semibold))
                        Text(manifest.description)
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                        if !manifest.declaredPresentations.isEmpty {
                            PluginPreviewHarness(manifest: manifest, live: studio.pluginCreator.live)
                        }
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
                } else {
                    // Live Result Row Preview
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Live Result Sheet Preview")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                        HStack(spacing: 10) {
                            Image(systemName: studio.icon.isEmpty ? "sparkles" : studio.icon)
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(Color.accentColor)
                                .frame(width: 28, height: 28)
                                .background(Color.accentColor.opacity(0.15), in: RoundedRectangle(cornerRadius: 7))
                            VStack(alignment: .leading, spacing: 1) {
                                Text(studio.name.isEmpty ? "Untitled Extension" : studio.name)
                                    .font(.system(size: 13, weight: .semibold))
                                Text(studio.target.title)
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "return")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                        .padding(10)
                        .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
                    }
                }

                // Dry-Run Output Box
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Dry-Run Output")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button {
                            Task { await studio.runDryTest() }
                        } label: {
                            Label(studio.isTesting ? "Running…" : "Test Run", systemImage: "play.fill")
                                .font(.system(size: 11, weight: .semibold))
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(studio.isTesting)
                    }
                    Text(studio.testOutput.isEmpty
                        ? "Click Test Run to verify output inside this sheet before saving."
                        : studio.testOutput)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(studio.testOutput.isEmpty ? .secondary : .primary)
                        .textSelection(.enabled)
                        .padding(8)
                        .frame(maxWidth: .infinity, minHeight: 90, alignment: .topLeading)
                        .background(Color.black.opacity(0.20), in: RoundedRectangle(cornerRadius: 8))
                }
            }
            .padding(14)
        }
    }

    private var notchPinManagerCard: some View {
        let bid = activeAppBundleID
        let caps = CapabilityRegistry.shared.capabilities(for: bid).prefix(10)
        let count = notchPins.pinnedIDs(for: bid).count
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("Dynamic Notch Quick Actions (\(count)/\(NotchPinStore.maxPinsPerApp))", systemImage: "menubar.dock.rectangle")
                    .font(.system(size: 11, weight: .semibold))
                Spacer()
                Text(bid.components(separatedBy: ".").last ?? bid)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }
            ForEach(Array(caps), id: \.id) { cap in
                let pinned = notchPins.isPinned(cap.id, for: bid)
                Button {
                    notchPins.toggle(cap.id, for: bid)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: pinned ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 12))
                            .foregroundStyle(pinned ? Color.accentColor : .secondary)
                        Text(cap.title)
                            .font(.system(size: 11.5, weight: .medium))
                            .lineLimit(1)
                        Spacer()
                    }
                    .padding(.vertical, 3)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(10)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: Footer

    private var studioFooter: some View {
        VStack(spacing: 0) {
            Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1)
            HStack(spacing: 8) {
                BoardFooter.pill {
                    Button {
                        if let onCloseOverride {
                            onCloseOverride()
                        } else {
                            _ = prompt.leaveScopeForGlobal()
                        }
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 9.5, weight: .bold))
                                .foregroundStyle(.secondary)
                            Text("AI Extension & Plugin Studio")
                                .font(.system(size: 11.5, weight: .medium))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                }

                Spacer()

                if !prompt.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    BoardFooter.pill {
                        Button {
                            let req = prompt.query
                            prompt.query = ""
                            Task { await studio.generateWithAI(prompt: req) }
                        } label: {
                            BoardFooter.action("Generate with AI", keys: ["↩"])
                        }
                        .buttonStyle(.plain)
                    }
                }

                BoardFooter.pill {
                    Button {
                        _ = studio.saveCurrent()
                    } label: {
                        BoardFooter.action("Save & Install", keys: ["⌘", "↩"])
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.return, modifiers: .command)
                }
            }
            .padding(.horizontal, 12)
            .frame(height: BoardFooter.height - 1)
        }
        .frame(height: BoardFooter.height)
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.55))
    }
}
