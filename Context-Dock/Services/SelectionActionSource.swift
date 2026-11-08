// SelectionActionSource.swift
// Context-Dock
//
// Standalone action source for captured selections, extracted out of DockCore (Issue #83).
// Evaluates SelectionSnapshot directly without mutating DockCore.selectionScopePayload.

import AppKit
import Foundation

@MainActor
final class SelectionActionSource: SelectionActionProviding {
    static let shared = SelectionActionSource()

    weak var host: (any SelectionActionHost)?

    var effectiveHost: any SelectionActionHost {
        host ?? DefaultSelectionActionHost.shared
    }

    init(host: (any SelectionActionHost)? = nil) {
        self.host = host
    }

    // MARK: - SelectionActionProviding

    func selectionRows(for snapshot: SelectionSnapshot, query: String) -> [SelectionActionRow] {
        selectionRows(for: snapshot, query: query, includeShare: false)
    }

    func selectionRows(
        for snapshot: SelectionSnapshot,
        query: String,
        includeShare: Bool
    ) -> [SelectionActionRow] {
        guard !snapshot.isEmpty else { return [] }
        let pills = buildPills(for: snapshot, query: query, includeShare: includeShare)
        return pills.filter { !$0.isSeparator }.map(Self.selectionRow(from:))
    }

    @discardableResult
    func runSelectionRow(id: String, query: String, for snapshot: SelectionSnapshot) -> Bool {
        guard !snapshot.isEmpty else { return false }
        let pills = buildPills(for: snapshot, query: query, includeShare: false)
        guard let pill = pills.first(where: { $0.id == id })
            ?? buildPills(for: snapshot, query: "", includeShare: false).first(where: { $0.id == id }),
            pill.isEnabled
        else { return false }
        pill.execute()
        return true
    }

    @discardableResult
    func replaceSelection(with text: String, for snapshot: SelectionSnapshot) -> Bool {
        guard !text.isEmpty, !snapshot.text.isEmpty,
              let app = NSRunningApplication.runningApplications(
                withBundleIdentifier: snapshot.bundleID
              ).first(where: { !$0.isTerminated })
        else { return false }
        return SelectionPasteback.pasteText(text, targetPID: app.processIdentifier)
    }

    // MARK: - Row Mapping

    static func selectionRow(from pill: DockPill) -> SelectionActionRow {
        let kind: SelectionActionRow.Kind
        if let prompt = pill.selectionAIPrompt {
            kind = .ask(prompt: prompt)
        } else if pill.isShareAction || isShareRowID(pill.id) {
            kind = .share
        } else {
            kind = .perform
        }
        return SelectionActionRow(
            id: pill.id,
            title: pill.name,
            icon: pill.icon,
            badge: pill.badge,
            accentColorName: pill.accentColorName,
            kind: kind,
            approval: pill.runApproval
        )
    }

    static func isShareRowID(_ id: String) -> Bool {
        id == "selection-share" || id.hasPrefix("share-") || id.hasPrefix("sharing-action-")
    }

    // MARK: - Pill Composition Pipeline

    func buildPills(
        for snapshot: SelectionSnapshot,
        query q: String,
        includeShare: Bool = true
    ) -> [DockPill] {
        guard !snapshot.isEmpty else { return [] }
        let core = DockEngine.shared.core
        let selectedURLs = snapshot.filePaths.map { URL(fileURLWithPath: $0) }
        let selectionContext = SelectionActions.context(for: snapshot)

        let finderFilePills = core.buildFinderFilePills(urls: selectedURLs, query: q)
        let finderMenuTitleSet = Set(finderFilePills.map { DockTextMatch.normalized($0.name) })
        let macOSExtensionPills = core.buildMacOSExtensionActionPills(
            context: selectionContext,
            fileURLs: selectedURLs,
            query: q,
            excludingTitles: finderMenuTitleSet,
            includeSharing: includeShare
        )
        let extensionTitleSet = finderMenuTitleSet.union(
            macOSExtensionPills.map { DockTextMatch.normalized($0.name) }
        )
        let finderMenuPills = core.buildFinderSelectionMenuPills(
            selectedURLs: selectedURLs,
            query: q,
            excludingTitles: extensionTitleSet,
            allowedRootNames: ["file", "quick actions", "services", "open with", "tags"]
        )

        var sel: [DockPill] = []
        sel.append(selectionScopeAskAIPill(for: snapshot, query: q))
        sel.append(contentsOf: selectionScopeCopyPill(for: snapshot, query: q))
        sel.append(contentsOf: core.buildCustomSelectionExtensionPills(
            context: selectionContext,
            selectedPaths: snapshot.filePaths,
            query: q,
            excludingTitles: extensionTitleSet
        ))
        sel.append(contentsOf: selectionScopeBuiltInWorkflowPills(for: snapshot, query: q))
        sel.append(contentsOf: buildContextDockSelectionAIPills(for: snapshot, query: q))
        sel.append(contentsOf: finderFilePills)
        sel.append(contentsOf: macOSExtensionPills)
        sel.append(contentsOf: finderMenuPills)
        sel.append(contentsOf: buildGlobalSelectionSharePills(for: snapshot, query: q))
        if includeShare {
            sel.append(contentsOf: buildShareQueryDestinationPills(for: snapshot, query: q))
        }

        let rankedSelection = core.dedupeRankedDockPills(
            core.rankDockPills(
                sel,
                rawQuery: q,
                rankingQuery: q,
                scopedBundleId: "com.apple.finder",
                scopedAppName: "Finder",
                isExplicitAppScope: false,
                includeNonMatching: q.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            )
        )
        if rankedSelection.contains(where: { $0.rankingKind == "selectionAI" }) {
            return rankedSelection
        }
        return [selectionScopeAskAIPill(for: snapshot, query: q)] + rankedSelection
    }

    // MARK: - Individual Pill Builders

    func selectionScopeAskAIPill(for snapshot: SelectionSnapshot, query q: String) -> DockPill {
        let typed = q.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = typed.isEmpty ? "Ask AI — what would you like to do?" : "Ask AI: \(typed)"
        var pill = DockPill(
            id: "selection-ask-ai",
            name: title,
            icon: "sparkles",
            accentColorName: "purple",
            badge: "Selection",
            execute: { [weak self] in
                self?.effectiveHost.enterSelectionChat(prompt: typed, snapshot: snapshot)
            }
        )
        pill.selectionAIPrompt = typed
        pill.rankingKind = "selectionAI"
        pill.rankingScore = 100_000
        pill.trackingIdentifier = "selection-ask-ai"
        pill.searchTerms = ["ask", "ai", "chat", "selection", "what", "do"]
        return pill
    }

    func selectionScopeCopyPill(for snapshot: SelectionSnapshot, query q: String) -> [DockPill] {
        guard !snapshot.isEmpty else { return [] }
        let normalizedQuery = DockTextMatch.normalized(q)
        let searchable = DockTextMatch.normalized("copy selection clipboard path")
        guard normalizedQuery.isEmpty || searchable.contains(normalizedQuery) else { return [] }

        let title: String
        let icon: String
        let isURL: Bool
        if !snapshot.filePaths.isEmpty {
            title = snapshot.filePaths.count == 1 ? "Copy File" : "Copy Files"
            icon = "doc.on.clipboard"
            isURL = false
        } else {
            let trimmed = snapshot.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" {
                title = "Copy Link"
                icon = "link"
                isURL = true
            } else {
                title = "Copy Text"
                icon = "doc.on.doc"
                isURL = false
            }
        }

        var pill = DockPill(
            id: "selection-copy",
            name: title,
            icon: icon,
            accentColorName: "teal",
            badge: "Selection",
            execute: { [weak self] in
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                if !snapshot.filePaths.isEmpty {
                    let urls = snapshot.filePaths.map { URL(fileURLWithPath: $0) }
                    pasteboard.writeObjects(urls as [NSURL])
                    self?.effectiveHost.showFeedback(
                        title: "Copied \(urls.count == 1 ? "file" : "\(urls.count) files")",
                        icon: "doc.on.clipboard",
                        success: true
                    )
                } else if isURL {
                    pasteboard.setString(snapshot.text, forType: .string)
                    self?.effectiveHost.showFeedback(title: "Copied link", icon: "link", success: true)
                } else {
                    pasteboard.setString(snapshot.text, forType: .string)
                    self?.effectiveHost.showFeedback(title: "Copied selected text", icon: "doc.on.doc", success: true)
                }
            }
        )
        pill.rankingKind = "payload"
        pill.rankingScore = 95_000
        pill.trackingIdentifier = "selection-copy"
        pill.searchTerms = ["copy", "clipboard", "selection", "text", "file", "files", "link"]
        return [pill]
    }

    func selectionScopeBuiltInWorkflowPills(for snapshot: SelectionSnapshot, query q: String) -> [DockPill] {
        if !snapshot.filePaths.isEmpty {
            let urls = snapshot.filePaths.map { URL(fileURLWithPath: $0) }
            return selectionScopeFileWorkflowPills(for: snapshot, urls: urls, query: q)
        }
        let trimmed = snapshot.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" {
            return selectionScopeURLWorkflowPills(for: snapshot, query: q)
        }
        return selectionScopeTextWorkflowPills(for: snapshot, query: q)
    }

    func selectionScopeTextWorkflowPills(for snapshot: SelectionSnapshot, query q: String) -> [DockPill] {
        let actions: [(id: String, name: String, icon: String, prompt: String, terms: String)] = [
            ("rewrite", "Rewrite", "pencil.and.scribble", "Rewrite this clearly. Return only the replacement text.", "rewrite improve clear professional"),
            ("bullets", "Make bullets", "list.bullet", "Convert this into concise bullet points. Return only the replacement text.", "bullet list key points"),
            ("fix", "Fix grammar", "checkmark.seal", "Fix grammar, spelling, and clarity. Return only the corrected replacement text.", "grammar spelling correct fix"),
            ("shorten", "Shorten", "text.badge.minus", "Shorten this while preserving meaning. Return only the replacement text.", "shorten concise trim"),
            ("table", "Make table", "tablecells", "Convert this into a clean Markdown table if possible. Return only the replacement text.", "table markdown format"),
        ]
        return actions.compactMap { selectionScopeAIPill($0, for: snapshot, query: q, badge: "Text") }
    }

    func selectionScopeURLWorkflowPills(for snapshot: SelectionSnapshot, query q: String) -> [DockPill] {
        let actions: [(id: String, name: String, icon: String, prompt: String, terms: String)] = [
            ("summarize-url", "Summarize Link", "link.badge.plus", "Summarize this URL and list why it may be useful.", "url link summarize"),
            ("extract-tasks-url", "Extract Tasks", "checklist", "Extract actionable tasks or follow-ups from this URL context.", "tasks todo follow up"),
            ("save-note-url", "Note Summary", "note.text", "Create a short note summary for this URL.", "note summary save"),
        ]
        return actions.compactMap { selectionScopeAIPill($0, for: snapshot, query: q, badge: "Link") }
    }

    func selectionScopeFileWorkflowPills(for snapshot: SelectionSnapshot, urls: [URL], query q: String) -> [DockPill] {
        guard !urls.isEmpty else { return [] }
        var pills: [DockPill] = []
        pills.append(contentsOf: selectionScopeFileUtilityPills(for: snapshot, urls: urls, query: q))
        pills.append(contentsOf: selectionScopeDocumentAIPills(for: snapshot, urls: urls, query: q))
        pills.append(contentsOf: selectionScopeMediaAIPills(for: snapshot, urls: urls, query: q))
        pills.append(contentsOf: selectionScopeImageTransformPills(for: snapshot, urls: urls, query: q))
        pills.append(contentsOf: selectionScopeArchivePills(for: snapshot, urls: urls, query: q))
        return pills
    }

    func selectionScopeAIPill(
        _ action: (id: String, name: String, icon: String, prompt: String, terms: String),
        for snapshot: SelectionSnapshot,
        query q: String,
        badge: String
    ) -> DockPill? {
        let normalizedQuery = DockTextMatch.normalized(q)
        let searchable = DockTextMatch.normalized("\(action.name) \(action.prompt) \(action.terms)")
        guard normalizedQuery.isEmpty || searchable.contains(normalizedQuery) else { return nil }
        let prompt = action.prompt
        var pill = DockPill(
            id: "selection-workflow-ai-\(action.id)",
            name: action.name,
            icon: action.icon,
            accentColorName: "purple",
            badge: badge,
            execute: { [weak self] in
                self?.effectiveHost.enterSelectionChat(prompt: prompt, snapshot: snapshot)
            }
        )
        pill.selectionAIPrompt = prompt
        pill.rankingKind = "selectionWorkflow"
        pill.rankingScore = 94_000
        pill.trackingIdentifier = "selection-workflow-ai:\(action.id)"
        pill.searchTerms = [action.name, action.prompt, action.terms, "selection", "ai"]
        return pill
    }

    func selectionScopeFileUtilityPills(for snapshot: SelectionSnapshot, urls: [URL], query q: String) -> [DockPill] {
        let label = urls.count == 1 ? urls[0].lastPathComponent : "\(urls.count) items"
        let actions: [(id: String, name: String, icon: String, terms: String, run: () -> Void)] = [
            ("open", "Open", "arrow.up.forward.app", "open launch file", {
                urls.forEach { NSWorkspace.shared.open($0) }
            }),
            ("reveal", "Reveal in Finder", "folder", "reveal finder show enclosing", {
                NSWorkspace.shared.activateFileViewerSelecting(urls)
            }),
            ("copy-path", "Copy Path", "point.topleft.down.curvedto.point.bottomright.up", "copy path pathname filepath", { [weak self] in
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setString(urls.map(\.path).joined(separator: "\n"), forType: .string)
                self?.effectiveHost.showFeedback(title: "Copied path for \(label)", icon: "doc.on.clipboard", success: true)
            }),
        ]
        return actions.compactMap { action in
            let normalizedQuery = DockTextMatch.normalized(q)
            let searchable = DockTextMatch.normalized("\(action.name) \(action.terms)")
            guard normalizedQuery.isEmpty || searchable.contains(normalizedQuery) else { return nil }
            var pill = DockPill(
                id: "selection-file-\(action.id)",
                name: action.name,
                icon: action.icon,
                accentColorName: "blue",
                badge: label,
                execute: action.run
            )
            pill.rankingKind = "selectionWorkflow"
            pill.rankingScore = 93_000
            pill.trackingIdentifier = "selection-file:\(action.id)"
            pill.searchTerms = [action.name, action.terms, "selection", "file"]
            return pill
        }
    }

    func selectionScopeDocumentAIPills(for snapshot: SelectionSnapshot, urls: [URL], query q: String) -> [DockPill] {
        let documentExts: Set<String> = ["pdf", "txt", "md", "rtf", "doc", "docx", "pages", "csv", "json", "xml", "html"]
        guard urls.contains(where: { documentExts.contains($0.pathExtension.lowercased()) }) else { return [] }
        let actions: [(id: String, name: String, icon: String, prompt: String, terms: String)] = [
            ("extract-text", "Extract Text", "doc.text.viewfinder", "Extract all readable text from this document. Preserve headings and important structure.", "ocr extract text document pdf"),
            ("make-summary", "Document Brief", "doc.richtext", "Create a concise document brief with summary, key points, and action items.", "brief summarize document"),
            ("find-actions", "Find Action Items", "checklist", "Extract action items, owners, dates, and follow-ups from this document.", "tasks action items todo"),
        ]
        return actions.compactMap { selectionScopeAIPill($0, for: snapshot, query: q, badge: "Document") }
    }

    func selectionScopeMediaAIPills(for snapshot: SelectionSnapshot, urls: [URL], query q: String) -> [DockPill] {
        let imageExts: Set<String> = ["png", "jpg", "jpeg", "heic", "webp", "tiff", "gif"]
        let videoExts: Set<String> = ["mov", "mp4", "m4v", "avi", "mkv", "webm"]
        let audioExts: Set<String> = ["mp3", "m4a", "wav", "aiff", "flac", "aac"]
        let hasImage = urls.contains { imageExts.contains($0.pathExtension.lowercased()) }
        let hasVideo = urls.contains { videoExts.contains($0.pathExtension.lowercased()) }
        let hasAudio = urls.contains { audioExts.contains($0.pathExtension.lowercased()) }
        var actions: [(id: String, name: String, icon: String, prompt: String, terms: String)] = []
        if hasImage {
            actions += [
                ("describe-image", "Describe Image", "photo", "Describe this image precisely. Include visible text, objects, layout, and likely purpose.", "image photo describe"),
                ("ocr-image", "OCR Image", "text.viewfinder", "Extract all readable text from this image. Return only the extracted text.", "ocr image text extract"),
                ("alt-text", "Write Alt Text", "accessibility", "Write concise accessibility alt text for this image.", "alt accessibility image"),
            ]
        }
        if hasVideo {
            actions += [
                ("video-brief", "Video Brief", "film", "Analyze this selected video file context and create a short brief: likely content, metadata, and useful next actions.", "video summarize media"),
            ]
            if selectionScopeExecutableExists("ffmpeg") {
                actions += [
                    ("extract-audio", "Extract Audio Plan", "waveform", "Give the exact safe extraction plan for this selected video using ffmpeg, including output filename.", "extract audio ffmpeg video"),
                ]
            }
        }
        if hasAudio {
            actions += [
                ("audio-brief", "Audio Brief", "waveform", "Analyze this selected audio file context and create a short brief with metadata and likely next actions.", "audio summarize media"),
            ]
        }
        return actions.compactMap { selectionScopeAIPill($0, for: snapshot, query: q, badge: "Media") }
    }

    func selectionScopeImageTransformPills(for snapshot: SelectionSnapshot, urls: [URL], query q: String) -> [DockPill] {
        let imageExts: Set<String> = ["png", "jpg", "jpeg", "heic", "tiff"]
        let imageURLs = urls.filter { imageExts.contains($0.pathExtension.lowercased()) }
        guard !imageURLs.isEmpty else { return [] }
        let actions: [(id: String, name: String, icon: String, terms: String, run: () -> Void)] = [
            ("to-jpeg", "Convert to JPEG", "photo.badge.arrow.down", "convert jpg jpeg image", { [weak self] in
                self?.runSipsImageTransform(imageURLs, format: "jpeg", suffix: "jpeg", quality: nil)
            }),
            ("to-png", "Convert to PNG", "photo.badge.arrow.down", "convert png image", { [weak self] in
                self?.runSipsImageTransform(imageURLs, format: "png", suffix: "png", quality: nil)
            }),
            ("compress", "Compress Image", "arrow.down.right.and.arrow.up.left", "compress reduce size image", { [weak self] in
                self?.runSipsImageTransform(imageURLs, format: "jpeg", suffix: "compressed.jpg", quality: "72")
            }),
        ]
        return actions.compactMap { action in
            let normalizedQuery = DockTextMatch.normalized(q)
            let searchable = DockTextMatch.normalized("\(action.name) \(action.terms)")
            guard normalizedQuery.isEmpty || searchable.contains(normalizedQuery) else { return nil }
            var pill = DockPill(
                id: "selection-image-\(action.id)",
                name: action.name,
                icon: action.icon,
                accentColorName: "pink",
                badge: imageURLs.count == 1 ? imageURLs[0].lastPathComponent : "\(imageURLs.count) images",
                execute: action.run
            )
            pill.rankingKind = "selectionMedia"
            pill.rankingScore = 92_000
            pill.trackingIdentifier = "selection-image:\(action.id)"
            pill.searchTerms = [action.name, action.terms, "selection", "media", "image"]
            return pill
        }
    }

    func selectionScopeArchivePills(for snapshot: SelectionSnapshot, urls: [URL], query q: String) -> [DockPill] {
        guard !urls.isEmpty else { return [] }
        let normalizedQuery = DockTextMatch.normalized(q)
        let searchable = DockTextMatch.normalized("compress zip archive files folder")
        guard normalizedQuery.isEmpty || searchable.contains(normalizedQuery) else { return [] }
        var pill = DockPill(
            id: "selection-archive-zip",
            name: urls.count == 1 ? "Compress to ZIP" : "Compress Items to ZIP",
            icon: "archivebox",
            accentColorName: "yellow",
            badge: urls.count == 1 ? urls[0].lastPathComponent : "\(urls.count) items",
            execute: { [weak self] in self?.runSelectionZip(urls) }
        )
        pill.rankingKind = "selectionWorkflow"
        pill.rankingScore = 91_000
        pill.trackingIdentifier = "selection-archive:zip"
        pill.searchTerms = ["compress", "zip", "archive", "selection", "file", "folder"]
        return [pill]
    }

    func selectionScopeExecutableExists(_ name: String) -> Bool {
        let candidates = [
            "/opt/homebrew/bin/\(name)",
            "/usr/local/bin/\(name)",
            "/usr/bin/\(name)",
            "/bin/\(name)",
        ]
        return candidates.contains { FileManager.default.isExecutableFile(atPath: $0) }
    }

    func selectionScopeExecutableURL(_ name: String) -> URL? {
        let candidates = [
            "/opt/homebrew/bin/\(name)",
            "/usr/local/bin/\(name)",
            "/usr/bin/\(name)",
            "/bin/\(name)",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
            .map(URL.init(fileURLWithPath:))
    }

    func runSipsImageTransform(_ urls: [URL], format: String, suffix: String, quality: String?) {
        guard let sips = selectionScopeExecutableURL("sips") else {
            effectiveHost.showFeedback(title: "sips not available", icon: "exclamationmark.triangle", success: false)
            return
        }
        effectiveHost.showFeedback(title: "Processing images…", icon: "photo", success: true)
        Task.detached { [weak self] in
            var outputs: [URL] = []
            var failed = 0
            for url in urls {
                let base = url.deletingPathExtension()
                let output: URL
                if suffix.contains(".") {
                    output = base.deletingLastPathComponent()
                        .appendingPathComponent("\(base.lastPathComponent)-\(suffix)")
                } else {
                    output = base.deletingLastPathComponent()
                        .appendingPathComponent("\(base.lastPathComponent).\(suffix)")
                }
                let process = Process()
                process.executableURL = sips
                var args = ["-s", "format", format]
                if let quality {
                    args += ["-s", "formatOptions", quality]
                }
                args += [url.path, "--out", output.path]
                process.arguments = args
                process.standardInput = FileHandle.nullDevice
                process.standardOutput = FileHandle.nullDevice
                process.standardError = FileHandle.nullDevice
                do {
                    try process.run()
                    process.waitUntilExit()
                    if process.terminationStatus == 0 {
                        outputs.append(output)
                    } else {
                        failed += 1
                    }
                } catch {
                    failed += 1
                }
            }
            let completedOutputs = outputs
            let failedCount = failed
            await MainActor.run {
                if !completedOutputs.isEmpty {
                    NSWorkspace.shared.activateFileViewerSelecting(completedOutputs)
                    self?.effectiveHost.showFeedback(
                        title: completedOutputs.count == 1 ? "Created \(completedOutputs[0].lastPathComponent)" : "Created \(completedOutputs.count) images",
                        icon: "checkmark.circle",
                        success: true
                    )
                } else {
                    self?.effectiveHost.showFeedback(
                        title: failedCount > 0 ? "Image transform failed" : "No images transformed",
                        icon: "exclamationmark.triangle",
                        success: false
                    )
                }
            }
        }
    }

    func runSelectionZip(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        let parent = urls[0].deletingLastPathComponent()
        let baseName = urls.count == 1
            ? urls[0].deletingPathExtension().lastPathComponent
            : "Selection-\(Date().timeIntervalSince1970.rounded())"
        let output = parent.appendingPathComponent("\(baseName).zip")
        let toolName = urls.count == 1 ? "ditto" : "zip"
        guard let tool = selectionScopeExecutableURL(toolName) else {
            effectiveHost.showFeedback(title: "\(toolName) not available", icon: "exclamationmark.triangle", success: false)
            return
        }
        effectiveHost.showFeedback(title: "Creating ZIP…", icon: "archivebox", success: true)
        Task.detached { [weak self] in
            let process = Process()
            process.executableURL = tool
            process.currentDirectoryURL = parent
            process.arguments =
                urls.count == 1
                ? ["-c", "-k", "--sequesterRsrc", "--keepParent", urls[0].lastPathComponent, output.path]
                : ["-r", output.path] + urls.map(\.lastPathComponent)
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
                process.waitUntilExit()
                await MainActor.run {
                    if process.terminationStatus == 0 {
                        NSWorkspace.shared.activateFileViewerSelecting([output])
                        self?.effectiveHost.showFeedback(title: "Created \(output.lastPathComponent)", icon: "archivebox", success: true)
                    } else {
                        self?.effectiveHost.showFeedback(title: "ZIP failed", icon: "exclamationmark.triangle", success: false)
                    }
                }
            } catch {
                await MainActor.run {
                    self?.effectiveHost.showFeedback(title: error.localizedDescription, icon: "exclamationmark.triangle", success: false)
                }
            }
        }
    }

    func buildContextDockSelectionAIPills(for snapshot: SelectionSnapshot, query q: String) -> [DockPill] {
        let badge: String
        let isText: Bool
        if !snapshot.filePaths.isEmpty {
            badge = snapshot.filePaths.count == 1
                ? URL(fileURLWithPath: snapshot.filePaths[0]).lastPathComponent
                : "\(snapshot.filePaths.count) files"
            isText = false
        } else if !snapshot.text.isEmpty {
            badge = "Selection · \(snapshot.text.count) chars"
            isText = true
        } else {
            return []
        }

        let normalizedQuery = DockTextMatch.normalized(q)
        let textActions: [(name: String, icon: String, prompt: String)] = [
            ("Summarize", "text.alignleft", "Summarize this"),
            ("Explain", "text.magnifyingglass", "Explain this"),
            ("Key points", "list.bullet", "List the key points"),
            ("Translate", "character.book.closed", "Translate this"),
        ]
        let fileActions: [(name: String, icon: String, prompt: String)] = [
            ("Summarize", "doc.text.magnifyingglass", "Summarize this document"),
            ("Explain", "text.magnifyingglass", "Explain what this file is about"),
            ("Key points", "list.bullet", "List the key points of this document"),
        ]
        let nativeWritingTools = isText ? buildNativeSelectionWritingToolPills(for: snapshot, query: q) : []
        let actions = isText ? textActions : fileActions

        let chatPills = actions.compactMap { action -> DockPill? in
            let searchable = DockTextMatch.normalized("\(action.name) \(action.prompt)")
            guard normalizedQuery.isEmpty || searchable.contains(normalizedQuery) else { return nil }
            let prompt = action.prompt
            var pill = DockPill(
                id: "context-selection-ai-\(action.name.lowercased())",
                name: action.name,
                icon: action.icon,
                accentColorName: "purple",
                badge: badge,
                execute: { [weak self] in
                    self?.effectiveHost.enterSelectionChat(prompt: prompt, snapshot: snapshot)
                }
            )
            pill.selectionAIPrompt = prompt
            pill.rankingKind = "selectionAI"
            pill.sourceBundleId = snapshot.bundleID
            pill.sourceAppName = snapshot.appName
            pill.trackingIdentifier = "context-selection-ai:\(action.name.lowercased())"
            pill.searchTerms = [action.name, action.prompt, "selection", "ai"]
            return pill
        }
        return nativeWritingTools + chatPills
    }

    func buildNativeSelectionWritingToolPills(for snapshot: SelectionSnapshot, query q: String) -> [DockPill] {
        guard !snapshot.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        guard let targetApp = NSRunningApplication.runningApplications(withBundleIdentifier: snapshot.bundleID)
            .first(where: { !$0.isTerminated })
        else { return [] }
        let sourcePID = targetApp.processIdentifier

        let sourceBundleId = snapshot.bundleID
        let sourceAppName = snapshot.appName
        let normalizedQuery = DockTextMatch.normalized(q)
        let filteredActions = NativeWritingToolAction.allCases.filter { action in
            guard !normalizedQuery.isEmpty else { return true }
            let searchable = DockTextMatch.normalized(([action.title] + action.aliases).joined(separator: " "))
            return searchable.contains(normalizedQuery)
                || action.aliases.map(DockTextMatch.normalized).contains { alias in
                    alias.hasPrefix(normalizedQuery) || normalizedQuery.contains(alias)
                }
        }

        let writingContext = AXContext(
            appName: sourceAppName,
            bundleId: sourceBundleId,
            pid: sourcePID,
            selectedText: snapshot.text
        )

        return filteredActions.prefix(normalizedQuery.isEmpty ? 10 : 12).map { action in
            var pill = DockPill(
                id: "selection-writing-tool-\(sourcePID)-\(action.rawValue)",
                name: action.title,
                icon: action.icon,
                accentColorName: "purple",
                badge: "Selection",
                execute: {
                    DockEngine.shared.core.executeNativeWritingTool(
                        action,
                        context: writingContext,
                        sourcePID: sourcePID,
                        sourceBundleId: sourceBundleId,
                        sourceAppName: sourceAppName
                    )
                }
            )
            pill.menuContext = "Writing Tools"
            pill.rankingKind = "writingTool"
            pill.rankingScore = 100_000 - Double(NativeWritingToolAction.allCases.firstIndex(of: action) ?? 0)
            pill.trackingIdentifier = "writing-tool:\(action.rawValue)"
            pill.searchTerms = [action.title, "writing tools", "apple intelligence", "proofread", "rewrite"] + action.aliases
            pill.hasLiveAvailability = true
            return pill
        }
    }

    func buildGlobalSelectionSharePills(for snapshot: SelectionSnapshot, query q: String) -> [DockPill] {
        guard !snapshot.isEmpty else { return [] }
        let normalizedQuery = DockTextMatch.normalized(q)
        if !normalizedQuery.isEmpty {
            let shareTerms = ["share", "send", "airdrop", "export", "message", "mail"]
            guard
                shareTerms.contains(where: {
                    $0.hasPrefix(normalizedQuery) || normalizedQuery.contains($0)
                })
            else { return [] }
        }

        let badge: String
        if !snapshot.filePaths.isEmpty {
            badge = snapshot.filePaths.count == 1 ? "File" : "\(snapshot.filePaths.count) Items"
        } else {
            let trimmed = snapshot.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" {
                badge = "URL"
            } else {
                badge = "Text"
            }
        }

        let items = SelectionActions.items(for: snapshot)
        var pill = DockPill(
            id: "selection-share",
            name: "Share Selection",
            icon: "square.and.arrow.up",
            accentColorName: "blue",
            badge: badge,
            execute: { [weak self] in
                (self?.effectiveHost)?.presentShare(items: items, from: nil)
            }
        )
        pill.rankingKind = "payload"
        pill.trackingIdentifier = "selection-share"
        pill.searchTerms = [
            "share", "send", "airdrop", "export", "selection", "files", "text", "url",
        ]
        return [pill]
    }

    func buildShareQueryDestinationPills(for snapshot: SelectionSnapshot, query q: String) -> [DockPill] {
        let nq = DockTextMatch.normalized(q)
        guard nq.count >= 2 else { return [] }
        guard !snapshot.isEmpty else { return [] }
        let genericVerbs = ["share", "send", "export"]
        let destinationVerbs = ["airdrop", "mail", "message", "messages", "notes", "reminders"]
        let isGeneric = genericVerbs.contains { $0.hasPrefix(nq) }
        let isDestination = destinationVerbs.contains { $0.hasPrefix(nq) }
        guard isGeneric || isDestination else { return [] }

        let listingItems = SelectionActions.items(for: snapshot)
        guard !listingItems.isEmpty else { return [] }
        let filter = isGeneric ? "" : nq
        return shareDestinationPills(listingItems: listingItems, filter: filter)
    }

    func shareDestinationPills(listingItems: [Any], filter normalizedQuery: String) -> [DockPill] {
        let destinations = ShareActionCoordinator.shared.shareDestinations(items: listingItems)
        return destinations.enumerated().compactMap { index, dest in
            let normalizedTitle = DockTextMatch.normalized(dest.title)
            guard ShareActionCoordinator.destinationMatches(
                normalizedTitle: normalizedTitle, normalizedQuery: normalizedQuery)
            else { return nil }
            var pill = DockPill(
                id: ShareActionCoordinator.destinationRowID(normalizedTitle: normalizedTitle),
                name: dest.title,
                icon: "square.and.arrow.up",
                accentColorName: "blue",
                badge: "Share",
                execute: {
                    ShareActionCoordinator.recordUse(normalizedTitle: normalizedTitle)
                    dest.perform(withItems: listingItems)
                }
            )
            pill.menuItemImage = dest.image
            pill.isShareAction = true
            pill.menuItemName = dest.title
            pill.menuContext = "Share"
            pill.rankingKind = "submenuChild"
            pill.hasLiveAvailability = true
            pill.rankingScore = ShareActionCoordinator.rankingScore(
                normalizedTitle: normalizedTitle, systemIndex: index)
            pill.trackingIdentifier = "share-dest:\(normalizedTitle)"
            pill.searchTerms = [dest.title, "share", "send", "sharing"]
            return pill
        }
    }
}
