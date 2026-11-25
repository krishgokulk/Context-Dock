// FileSheetSubmodeView.swift
// Context-Dock
//
// Unified Raycast-style in-sheet file experience:
// - `Space` (or clicking Expand on a split preview) opens the file in full-sheet Preview mode
//   inside the launcher's result sheet (never a separate window), updating the top input bar
//   with a `<` Back button on the left and a Mode/Scope dropdown on the right.
// - `→` (Right Arrow) on a file opens Selection Scope across the full result sheet, driven by
//   the same top input bar so there is never a duplicate bottom input field.
// - The right-end dropdown switches seamlessly between Preview File, Selection Scope,
//   Search Inside File, and User Actions & Extensions.

import AppKit
import PDFKit
import SwiftUI
import UniformTypeIdentifiers

enum FileSubmodeKind: String, CaseIterable, Equatable, Identifiable {
    case preview
    case selectionScope
    case searchInFile
    case userActions

    var id: String { rawValue }

    var menuTitle: String {
        switch self {
        case .preview: return "Preview File"
        case .selectionScope: return "Selection Scope"
        case .searchInFile: return "Search Inside File"
        case .userActions: return "User Actions & Extensions"
        }
    }

    var shortLabel: String {
        switch self {
        case .preview: return "Preview"
        case .selectionScope: return "Selection Scope"
        case .searchInFile: return "Search in File"
        case .userActions: return "User Actions"
        }
    }

    var symbol: String {
        switch self {
        case .preview: return "doc.text.magnifyingglass"
        case .selectionScope: return "sparkles"
        case .searchInFile: return "text.magnifyingglass"
        case .userActions: return "bolt.horizontal.circle"
        }
    }
}

struct FileSheetSubmodeState: Equatable {
    var url: URL
    var kind: FileSubmodeKind
    var query: String = ""
    var wasSidePanelExpanded: Bool = false
    var focusedRowIndex: Int = 0
    var previewScrollStep: Int = 0

    var fileName: String { url.lastPathComponent }

    var isFolder: Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            && url.pathExtension.lowercased() != "app"
    }

    func placeholder(isShowingAnswer: Bool) -> String {
        if isShowingAnswer && (kind == .selectionScope || kind == .userActions) {
            return "Ask a follow-up about \(fileName)…"
        }
        switch kind {
        case .preview:
            return isFolder
                ? "Filter items in \(fileName)…"
                : "Search inside \(fileName) or ask AI…"
        case .selectionScope:
            return "Search Selection Scope or ask about \(fileName)…"
        case .searchInFile:
            return "Search text inside \(fileName)…"
        case .userActions:
            return "Search user actions & extensions…"
        }
    }
}

// MARK: - In-File Search Engine

struct FileTextMatch: Identifiable, Equatable {
    let id: String
    let locationLabel: String   // e.g. "Page 2" or "Line 48"
    let snippet: String
    let pageOrLine: Int
}

enum FileInDocumentSearch {
    nonisolated static func extractSearchableSegments(url: URL) -> [(label: String, index: Int, text: String)] {
        let ext = url.pathExtension.lowercased()
        let utType = UTType(filenameExtension: ext)

        if ext == "pdf" || utType?.conforms(to: .pdf) == true,
            let doc = PDFDocument(url: url)
        {
            var segments: [(String, Int, String)] = []
            let count = min(doc.pageCount, 120)
            for idx in 0..<count {
                guard let raw = doc.page(at: idx)?.string else { continue }
                let lines = raw.components(separatedBy: .newlines)
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                for (lineOffset, line) in lines.enumerated() {
                    segments.append(("Page \(idx + 1)", idx * 10_000 + lineOffset, line))
                }
            }
            return segments
        }

        if ["rtf", "rtfd"].contains(ext) || utType?.conforms(to: .rtf) == true || utType?.conforms(to: .rtfd) == true,
            let attr = try? NSAttributedString(url: url, options: [:], documentAttributes: nil)
        {
            return attr.string.components(separatedBy: .newlines).enumerated().compactMap { idx, line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty else { return nil }
                return ("Line \(idx + 1)", idx + 1, trimmed)
            }
        }

        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 250_000),
            !data.prefix(512).contains(0),
            let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
        else { return [] }

        return text.components(separatedBy: .newlines).enumerated().compactMap { idx, line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return nil }
            return ("Line \(idx + 1)", idx + 1, trimmed)
        }
    }

    nonisolated static func matches(
        in segments: [(label: String, index: Int, text: String)],
        query: String,
        limit: Int = 80
    ) -> [FileTextMatch] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return segments.prefix(30).map { seg in
                FileTextMatch(
                    id: "\(seg.index)-\(seg.label)",
                    locationLabel: seg.label,
                    snippet: String(seg.text.prefix(180)),
                    pageOrLine: seg.index
                )
            }
        }

        var results: [FileTextMatch] = []
        for seg in segments {
            guard let range = seg.text.range(of: trimmed, options: [.caseInsensitive, .diacriticInsensitive]) else {
                continue
            }
            let snippet = excerpt(around: range, in: seg.text, radius: 75)
            results.append(
                FileTextMatch(
                    id: "\(seg.index)-\(seg.label)",
                    locationLabel: seg.label,
                    snippet: snippet,
                    pageOrLine: seg.index
                )
            )
            if results.count >= limit { break }
        }
        return results
    }

    private nonisolated static func excerpt(around range: Range<String.Index>, in text: String, radius: Int) -> String {
        let start = text.index(range.lowerBound, offsetBy: -radius, limitedBy: text.startIndex) ?? text.startIndex
        let end = text.index(range.upperBound, offsetBy: radius, limitedBy: text.endIndex) ?? text.endIndex
        let prefixDots = start > text.startIndex ? "…" : ""
        let suffixDots = end < text.endIndex ? "…" : ""
        return prefixDots + String(text[start..<end]) + suffixDots
    }
}

// MARK: - AppChatPromptModel Coordination

extension AppChatPromptModel {
    /// Resolves the target file/folder URL for the currently highlighted result row.
    func targetFileSubmodeURL() -> URL? {
        let targetRow = skipsTopRowOnBareReturn ? focusedRow : (focusedRow ?? rows.first)
        guard let preview = CornerBoardLayout.preview(
            for: targetRow, appName: appName, appBundleID: appBundleID,
            cliCommand: cliCommand, lookup: searchDocumentLookup)
        else { return nil }
        if case .file(let url) = preview { return url }
        return nil
    }

    /// Opens the unified in-sheet file submode (`Preview`, `Selection Scope`, `Search in File`,
    /// or `User Actions`) inside the launcher's result sheet and repurposes the top input bar.
    @discardableResult
    func enterFileSubmode(url: URL, kind: FileSubmodeKind, initialQuery: String = "") -> Bool {
        let controller = CornerDockController.shared
        let selection = controller.selection
        let wasExpanded = fileSubmode?.wasSidePanelExpanded ?? isSidePanelExpanded

        // Summon SelectionScopeModel in background sheet-submode so its actions, extensions,
        // share intents, and AI thread are ready without stealing focus from the main input bar.
        let context = AXContext(
            appName: "Finder",
            bundleId: "com.apple.finder",
            pid: 0,
            selectedFilePaths: [url.path]
        )
        selection.isSheetSubmode = true
        selection.isEmbeddedInSidePanel = false
        selection.coversChat = false
        _ = selection.summon(from: context)
        if !initialQuery.isEmpty, kind == .selectionScope || kind == .userActions {
            selection.query = initialQuery
            selection.queryChanged()
        }

        if phase != .suggesting {
            set(.suggesting)
        }
        cancelIdleTimer()

        withAnimation(FluidMotion.selectionGlide) {
            fileSubmode = FileSheetSubmodeState(
                url: url,
                kind: kind,
                query: initialQuery,
                wasSidePanelExpanded: wasExpanded,
                focusedRowIndex: 0,
                previewScrollStep: 0
            )
            isSidePanelExpanded = true
        }
        controller.publishKeyboardOwner()
        controller.refresh()
        controller.requestComposerFocus()
        touch()
        return true
    }

    /// Switches between Preview, Selection Scope, Search Inside File, and User Actions in-place.
    func switchFileSubmode(_ newKind: FileSubmodeKind) {
        guard var sub = fileSubmode else { return }
        let selection = CornerDockController.shared.selection
        sub.kind = newKind
        sub.focusedRowIndex = 0
        if newKind == .selectionScope || newKind == .userActions {
            if !selection.phase.isVisible || selection.files.first?.standardizedFileURL != sub.url.standardizedFileURL {
                let context = AXContext(
                    appName: "Finder",
                    bundleId: "com.apple.finder",
                    pid: 0,
                    selectedFilePaths: [sub.url.path]
                )
                selection.isSheetSubmode = true
                selection.isEmbeddedInSidePanel = false
                selection.coversChat = false
                _ = selection.summon(from: context)
            }
            selection.query = sub.query
            selection.queryChanged()
            selection.focusedIndex = 0
        }
        withAnimation(FluidMotion.selectionGlide) {
            fileSubmode = sub
        }
        CornerDockController.shared.requestComposerFocus()
        touch()
    }

    /// Updates the top input bar's text while inside a file submode without disturbing the
    /// parent file search query or result rows underneath.
    func setFileSubmodeQuery(_ text: String) {
        guard var sub = fileSubmode else { return }
        guard sub.query != text else { return }
        sub.query = text
        sub.focusedRowIndex = 0
        fileSubmode = sub
        if sub.kind == .selectionScope || sub.kind == .userActions {
            let selection = CornerDockController.shared.selection
            selection.query = text
            selection.queryChanged()
            if sub.kind == .selectionScope, text.isEmpty, !selection.rows.isEmpty {
                selection.focusedIndex = 0
            }
        }
        touch()
    }

    /// Steps back (`<`, `Esc`, or empty `⌫` / `←`) from the file submode to the parent file list.
    @discardableResult
    func leaveFileSubmode() -> Bool {
        guard let sub = fileSubmode else { return false }
        let controller = CornerDockController.shared
        let selection = controller.selection
        selection.isSheetSubmode = false
        selection.isEmbeddedInSidePanel = false
        selection.coversChat = false
        selection.dismiss()

        withAnimation(FluidMotion.selectionGlide) {
            fileSubmode = nil
            isSidePanelExpanded = sub.wasSidePanelExpanded
        }
        controller.publishKeyboardOwner()
        controller.refresh()
        controller.requestComposerFocus()
        touch()
        return true
    }

    /// Filtered User Actions & Extensions rows when `kind == .userActions`.
    func userActionRows(from rows: [SelectionActionRow]) -> [SelectionActionRow] {
        rows.filter { row in
            if case .ask = row.kind { return false }
            let badge = (row.badge ?? "").lowercased()
            return badge.contains("extension")
                || badge.contains("skill")
                || badge.contains("workflow")
                || badge.contains("user")
                || badge.contains("script")
                || badge.contains("command")
                || badge.contains("quick")
        }
    }

    /// Submits (`↩`) inside the active file submode.
    @discardableResult
    func submitFileSubmode() -> Bool {
        guard let sub = fileSubmode else { return false }
        let selection = CornerDockController.shared.selection
        let trimmed = sub.query.trimmingCharacters(in: .whitespacesAndNewlines)

        switch sub.kind {
        case .preview:
            if trimmed.isEmpty {
                if sub.isFolder {
                    let target = sub.url
                    _ = leaveFileSubmode()
                    return enterFolder(target)
                }
                NSWorkspace.shared.open(sub.url)
                dismiss()
                return true
            } else {
                // Ask AI about the previewed file directly inside Selection Scope
                switchFileSubmode(.selectionScope)
                selection.query = trimmed
                selection.focusedIndex = nil
                return selection.returnPressed()
            }

        case .selectionScope:
            if !selection.isShowingAnswer,
                let focused = selection.focusedRow,
                case .ask = focused.kind,
                trimmed.isEmpty
            {
                // Highlighted "Ask AI" with empty input: keep focus in top bar so user types prompt
                CornerDockController.shared.requestComposerFocus()
                return true
            }
            if !trimmed.isEmpty, selection.focusedRow == nil || ({
                if let r = selection.focusedRow, case .ask = r.kind { return true }
                return false
            }()) {
                selection.focusedIndex = nil
                let ok = selection.returnPressed()
                if ok {
                    fileSubmode?.query = ""
                }
                return ok
            }
            return selection.returnPressed()

        case .userActions:
            let filtered = userActionRows(from: selection.rows)
            if filtered.indices.contains(sub.focusedRowIndex) {
                selection.run(filtered[sub.focusedRowIndex])
                return true
            }
            if sub.focusedRowIndex == filtered.count {
                switchFileSubmode(.searchInFile)
                return true
            }
            return false

        case .searchInFile:
            switchFileSubmode(.preview)
            return true
        }
    }

    /// Handles special keys (`Esc`, `⌫`, `←`, `→`, `Space`, `↑`, `↓`, `↩`, `⌘F`) while inside
    /// `fileSubmode`. Returns `false` for normal text-editing keys so `TextField` receives them.
    func handleFileSubmodeKeyEvent(_ event: NSEvent) -> Bool {
        guard var sub = fileSubmode else { return false }
        let selection = CornerDockController.shared.selection
        let mods = event.modifierFlags.intersection([.command, .control, .option, .shift])
        let plainMods = event.modifierFlags.intersection([.command, .control, .option]).isEmpty

        // ⌘F switches straight into Search Inside File
        if mods == .command, event.charactersIgnoringModifiers?.lowercased() == "f" {
            switchFileSubmode(.searchInFile)
            return true
        }

        // ⌘1..⌘4 switches directly between the 4 dropdown modes
        if mods == .command, let ch = event.charactersIgnoringModifiers,
            let num = Int(ch), (1...4).contains(num)
        {
            let all = FileSubmodeKind.allCases
            switchFileSubmode(all[num - 1])
            return true
        }

        guard plainMods else { return false }

        switch event.keyCode {
        case 53: // Esc
            if sub.kind == .selectionScope,
                selection.isShowingAnswer || selection.isSharing
                    || selection.pendingSend != nil || selection.pendingApproval != nil
                    || selection.pendingConsent != nil
            {
                selection.escapePressed()
                return true
            }
            if !sub.query.isEmpty {
                setFileSubmodeQuery("")
                return true
            }
            return leaveFileSubmode()

        case 51: // Backspace on empty field -> step back like `<`
            guard sub.query.isEmpty else { return false }
            if sub.kind == .selectionScope, selection.isShowingAnswer {
                selection.escapePressed()
                return true
            }
            return leaveFileSubmode()

        case 123: // ← Left Arrow on empty field -> step back like `<`
            guard sub.query.isEmpty else { return false }
            if sub.kind == .selectionScope, selection.isShowingAnswer {
                selection.escapePressed()
                return true
            }
            return leaveFileSubmode()

        case 124: // → Right Arrow on empty field -> switch Preview to Selection Scope
            guard sub.query.isEmpty else { return false }
            if sub.kind == .preview, !sub.isFolder {
                switchFileSubmode(.selectionScope)
                return true
            }
            return false

        case 49: // Space on empty field -> toggle Preview (or switch from Selection Scope to Preview)
            guard sub.query.isEmpty else { return false }
            if sub.kind == .selectionScope && selection.isShowingAnswer {
                return false
            }
            if sub.kind == .preview {
                return leaveFileSubmode()
            } else {
                switchFileSubmode(.preview)
                return true
            }

        case 125: // ↓ Down Arrow
            moveFileSubmodeFocus(by: 1, state: &sub, selection: selection)
            return true

        case 126: // ↑ Up Arrow
            moveFileSubmodeFocus(by: -1, state: &sub, selection: selection)
            return true

        case 36, 76: // Return / Enter
            if event.modifierFlags.contains(.shift) { return false }
            return submitFileSubmode()

        default:
            return false
        }
    }

    private func moveFileSubmodeFocus(
        by delta: Int,
        state sub: inout FileSheetSubmodeState,
        selection: SelectionScopeModel
    ) {
        switch sub.kind {
        case .preview:
            sub.previewScrollStep = max(0, sub.previewScrollStep + delta)
            fileSubmode = sub
        case .selectionScope:
            if !selection.isShowingAnswer {
                _ = selection.moveFocus(by: delta)
            }
        case .userActions:
            let total = userActionRows(from: selection.rows).count + 1 // +1 for "Search Inside File"
            guard total > 0 else { return }
            sub.focusedRowIndex = max(0, min(total - 1, sub.focusedRowIndex + delta))
            fileSubmode = sub
        case .searchInFile:
            sub.focusedRowIndex = max(0, sub.focusedRowIndex + delta)
            fileSubmode = sub
        }
        touch()
    }
}

// MARK: - Top Input Bar Controls (Raycast `<` Back + File Badge + Right Mode Dropdown)

struct FileSubmodeLeadingBar: View {
    let submode: FileSheetSubmodeState
    let onBack: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onBack) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary.opacity(0.88))
                    .frame(width: 28, height: 28)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.primary.opacity(0.10))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.14), lineWidth: 1)
                    )
                    .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .buttonStyle(.plain)
            .help("Back to results (Esc)")
            .accessibilityLabel("Back")

            HStack(spacing: 6) {
                LiveFileIconView(url: submode.url, size: 18)
                Text(submode.fileName)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(.primary.opacity(0.9))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 136)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Color.primary.opacity(0.08), in: Capsule())
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.10), lineWidth: 0.5))
        }
        .layoutPriority(1)
    }
}

struct FileSubmodeDropdown: View {
    @ObservedObject var model: AppChatPromptModel
    let submode: FileSheetSubmodeState

    var body: some View {
        Menu {
            Section("View & Scope") {
                ForEach(FileSubmodeKind.allCases) { kind in
                    Button {
                        model.switchFileSubmode(kind)
                    } label: {
                        if submode.kind == kind {
                            Label("\(kind.menuTitle)  ✓", systemImage: kind.symbol)
                        } else {
                            Label(kind.menuTitle, systemImage: kind.symbol)
                        }
                    }
                }
            }
            Divider()
            Section("Quick File Actions") {
                Button {
                    NSWorkspace.shared.open(submode.url)
                    model.dismiss()
                } label: {
                    Label("Open File", systemImage: "arrow.up.forward.app")
                }
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([submode.url])
                } label: {
                    Label("Show in Finder", systemImage: "folder")
                }
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(submode.url.path, forType: .string)
                } label: {
                    Label("Copy File Path", systemImage: "doc.on.doc")
                }
            }
            Divider()
            Button {
                _ = model.leaveFileSubmode()
            } label: {
                Label("Back to Search Results", systemImage: "chevron.left")
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: submode.kind.symbol)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                Text("\(submode.kind.shortLabel) ▾")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.primary.opacity(0.92))
                    .lineLimit(1)
            }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.09))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.white.opacity(0.14), lineWidth: 1)
        )
        .fixedSize()
        .help("Switch between Preview, Selection Scope, Search Inside File, and User Actions")
    }
}

// MARK: - Full-Width Result Sheet Body

struct FileSheetSubmodeView: View {
    @ObservedObject var model: AppChatPromptModel
    @ObservedObject var selectionModel: SelectionScopeModel
    let submode: FileSheetSubmodeState
    let height: CGFloat

    @ObservedObject private var conversation = AppChatConversation.shared
    @State private var searchableSegments: [(label: String, index: Int, text: String)] = []
    @State private var loadedSegmentsURL: URL?
    @State private var mouseGate = MouseGate()
    @Namespace private var submodeSelectionSpace

    private var inFileMatches: [FileTextMatch] {
        FileInDocumentSearch.matches(in: searchableSegments, query: submode.query)
    }

    var body: some View {
        Group {
            switch submode.kind {
            case .preview:
                fullPreviewBody
            case .selectionScope:
                fullSelectionScopeBody(onlyUserActions: false)
            case .userActions:
                fullSelectionScopeBody(onlyUserActions: true)
            case .searchInFile:
                searchInsideFileBody
            }
        }
        .frame(maxWidth: .infinity, maxHeight: height, alignment: .topLeading)
        .task(id: submode.url) {
            let target = submode.url
            guard loadedSegmentsURL != target, !submode.isFolder else { return }
            let segments = await Task.detached(priority: .userInitiated) {
                FileInDocumentSearch.extractSearchableSegments(url: target)
            }.value
            if submode.url == target {
                searchableSegments = segments
                loadedSegmentsURL = target
            }
        }
    }

    // MARK: 1. Full-Width Scrollable File Preview (`Space` / Expand)

    private var fullPreviewBody: some View {
        let trimmedQuery = submode.query.trimmingCharacters(in: .whitespacesAndNewlines)
        return VStack(spacing: 0) {
            if !trimmedQuery.isEmpty, !submode.isFolder {
                HStack(spacing: 8) {
                    Image(systemName: "text.magnifyingglass")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                    let matchCount = inFileMatches.count
                    Text(matchCount == 0
                        ? "No exact text matches in file"
                        : "\(matchCount) match\(matchCount == 1 ? "" : "es") in \(submode.fileName)")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.primary.opacity(0.9))
                    Spacer(minLength: 8)
                    if matchCount > 0 {
                        Button {
                            model.switchFileSubmode(.searchInFile)
                        } label: {
                            Text("Show Matches")
                                .font(.system(size: 11, weight: .semibold))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(Color.primary.opacity(0.10), in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                    Button {
                        _ = model.submitFileSubmode()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "sparkles")
                                .font(.system(size: 10, weight: .semibold))
                            Text("Ask AI ↩")
                                .font(.system(size: 11, weight: .semibold))
                        }
                        .foregroundStyle(Color.accentColor)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.accentColor.opacity(0.15), in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 8)
                .background(Color.primary.opacity(0.05))
                Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1)
            }

            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: true) {
                    VStack(alignment: .leading, spacing: 0) {
                        Color.clear.frame(height: 0).id("preview-step-0")
                        FullSheetDocumentPreview(
                            url: submode.url,
                            highlightQuery: trimmedQuery,
                            onSelectFolderItem: { itemURL in
                                _ = model.enterFileSubmode(url: itemURL, kind: .preview)
                            }
                        )
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 12)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                .onChange(of: submode.previewScrollStep) { _, step in
                    withAnimation(.smooth(duration: 0.2)) {
                        if step == 0 {
                            proxy.scrollTo("preview-step-0", anchor: .top)
                        } else {
                            proxy.scrollTo("preview-details-end", anchor: .bottom)
                        }
                    }
                }
            }
        }
    }

    // MARK: 2. Split Selection Scope (`→`): Actions on Left Half + File Preview on Right Half

    private func fullSelectionScopeBody(onlyUserActions: Bool) -> some View {
        GeometryReader { geo in
            let boardWidth = max(geo.size.width, 680)
            let filePreview = CornerBoardPreview.file(submode.url)
            let leftWidth = CornerBoardLayout.listWidth(board: boardWidth, preview: filePreview)
            let rightWidth = CornerBoardLayout.panelWidth(board: boardWidth)

            HStack(alignment: .top, spacing: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(onlyUserActions
                        ? "User Actions & Extensions"
                        : (selectionModel.isShowingAnswer
                            ? "Answer · \(submode.fileName)"
                            : "Selection Scope · \(selectionModel.rows.count) action\(selectionModel.rows.count == 1 ? "" : "s")"))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary.opacity(0.75))
                        .lineLimit(1)
                        .padding(.horizontal, 16)
                        .frame(height: AppChatListMetrics.headerHeight, alignment: .leading)

                    if selectionModel.isShowingAnswer, !onlyUserActions {
                        CornerTranscript(
                            messages: selectionModel.answerMessages,
                            isAnswering: selectionModel.isAnswering,
                            liveSteps: conversation.liveSteps,
                            appName: selectionModel.appName,
                            appBundleID: selectionModel.appBundleID,
                            appIcon: NSWorkspace.shared.icon(forFile: "/System/Library/CoreServices/Finder.app")
                        )
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        answerActionsStrip
                    } else if onlyUserActions {
                        userActionsList
                    } else {
                        selectionRowsList
                    }

                    if selectionModel.pendingConsent != nil {
                        consentStrip
                    }
                    if let pendingRow = selectionModel.pendingApproval {
                        approvalStrip(pendingRow)
                    }
                    if let pendingSend = selectionModel.pendingSend {
                        sendConfirmStrip(pendingSend)
                    }
                    if let outcome = selectionModel.outcome, !outcome.isEmpty {
                        HStack(spacing: 6) {
                            Text(outcome)
                                .font(.system(size: 11.5, weight: .medium))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            Spacer()
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 6)
                    }
                }
                .frame(width: leftWidth, height: geo.size.height, alignment: .topLeading)

                Color.clear.frame(width: CornerBoardLayout.dividerWidth)

                CornerBoardPreviewPanel(preview: filePreview)
                    .frame(
                        width: rightWidth,
                        height: max(geo.size.height - 2 * AppChatListMetrics.verticalPadding, 120),
                        alignment: .topLeading
                    )
                    .padding(.vertical, AppChatListMetrics.verticalPadding)
            }
        }
    }

    private var selectionRowsList: some View {
        let rows = selectionModel.rows
        let activeFocus = selectionModel.focusedIndex ?? (rows.isEmpty ? nil : 0)
        return ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(spacing: 0) {
                    if rows.isEmpty, !submode.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        // Direct Ask AI fallback row when typed query narrows past static actions
                        Button {
                            _ = model.submitFileSubmode()
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "sparkles")
                                    .font(.system(size: 15, weight: .medium))
                                    .foregroundStyle(Color.accentColor)
                                    .frame(width: 28, height: 28)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Ask AI about \(submode.fileName)")
                                        .font(.system(size: 13.5, weight: .medium))
                                    Text(submode.query)
                                        .font(.system(size: 11.5))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                Spacer()
                                Image(systemName: "return")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 18)
                            .frame(height: AppChatListMetrics.rowHeight)
                            .fluidSelection(isSelected: true, namespace: submodeSelectionSpace, cornerRadius: 8, paddingHorizontal: 10)
                        }
                        .buttonStyle(.plain)
                    } else {
                        ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                            selectionActionRowView(row, isFocused: index == activeFocus)
                                .id(row.id)
                                .onHover { hovering in
                                    if hovering, mouseGate.moved() {
                                        withAnimation(FluidMotion.selectionGlide) {
                                            selectionModel.setFocusedIndex(index)
                                        }
                                    }
                                }
                        }
                    }
                }
                .padding(.vertical, 6)
                .animation(FluidMotion.selectionGlide, value: activeFocus)
            }
            .onChange(of: selectionModel.focusedIndex) { _, idx in
                guard let idx, rows.indices.contains(idx) else { return }
                withAnimation(FluidMotion.selectionGlide) {
                    proxy.scrollTo(rows[idx].id)
                }
            }
        }
    }

    private var userActionsList: some View {
        let userRows = model.userActionRows(from: selectionModel.rows)
        let focus = submode.focusedRowIndex
        return ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(spacing: 0) {
                ForEach(Array(userRows.enumerated()), id: \.element.id) { index, row in
                    selectionActionRowView(row, isFocused: index == focus)
                        .onHover { hovering in
                            if hovering, mouseGate.moved() {
                                model.fileSubmode?.focusedRowIndex = index
                            }
                        }
                }
                // Built-in Search Inside File action always available in User Actions
                Button {
                    model.switchFileSubmode(.searchInFile)
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "text.magnifyingglass")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(Color.accentColor)
                            .frame(width: 28, height: 28)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Search Inside File")
                                .font(.system(size: 13.5, weight: .medium))
                            Text("Find matching lines or pages inside \(submode.fileName)")
                                .font(.system(size: 11.5))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text("⌘F")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 18)
                    .frame(height: AppChatListMetrics.rowHeight)
                    .fluidSelection(
                        isSelected: focus == userRows.count,
                        namespace: submodeSelectionSpace,
                        cornerRadius: 8,
                        paddingHorizontal: 10
                    )
                }
                .buttonStyle(.plain)
            }
            .padding(.vertical, 6)
        }
    }

    private func selectionActionRowView(_ row: SelectionActionRow, isFocused: Bool) -> some View {
        let typed = submode.query.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayTitle: String = {
            if case .ask = row.kind, !typed.isEmpty, row.title.lowercased().hasPrefix("ask ai") {
                return "Ask AI: “\(typed)”"
            }
            return row.title
        }()
        return HStack(spacing: 12) {
            Group {
                if let image = row.image {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 22, height: 22)
                } else {
                    Image(systemName: row.icon)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(row.icon == "sparkles" ? Color.accentColor : .secondary)
                }
            }
            .frame(width: 28, height: 28)
            .fluidIconZoom(isFocused: isFocused)

            VStack(alignment: .leading, spacing: 1) {
                Text(displayTitle)
                    .font(.system(size: 13.5, weight: .medium))
                    .lineLimit(1)
                if case .needsConsent = selectionModel.screenGate(for: row) {
                    Text("Needs Computer Use · \(row.badge ?? "Finder")")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.orange.opacity(0.85))
                        .lineLimit(1)
                } else if let badge = row.badge, !badge.isEmpty {
                    Text(badge)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 6)
            if isFocused {
                Image(systemName: "return")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .frame(height: AppChatListMetrics.rowHeight)
        .fluidSelection(isSelected: isFocused, namespace: submodeSelectionSpace, cornerRadius: 8, paddingHorizontal: 8)
        .contentShape(Rectangle())
        .onTapGesture {
            if case .ask = row.kind, typed.isEmpty {
                CornerDockController.shared.requestComposerFocus()
            } else {
                selectionModel.run(row)
            }
        }
    }

    private var answerActionsStrip: some View {
        HStack(spacing: 8) {
            if selectionModel.latestAnswer != nil {
                Button { selectionModel.copyAnswer() } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                        .font(.system(size: 11.5, weight: .medium))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Color.primary.opacity(0.09), in: Capsule())
                }
                .buttonStyle(.plain)

                Button { selectionModel.saveAnswerToQuickNote() } label: {
                    Label("Quick Note", systemImage: "note.text.badge.plus")
                        .font(.system(size: 11.5, weight: .medium))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Color.primary.opacity(0.09), in: Capsule())
                }
                .buttonStyle(.plain)

                Button { selectionModel.shareAnswer() } label: {
                    Label("Share", systemImage: "square.and.arrow.up")
                        .font(.system(size: 11.5, weight: .medium))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Color.primary.opacity(0.09), in: Capsule())
                }
                .buttonStyle(.plain)
            }
            Spacer()
            Button { selectionModel.escapePressed() } label: {
                Text("Back to Actions (Esc)")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 8)
    }

    private var consentStrip: some View {
        HStack(spacing: 10) {
            Text("Allow Computer Use in \(selectionModel.pendingConsentAppName)?")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            Spacer()
            Button("Allow Once  ↩") { selectionModel.allowOnce() }
                .buttonStyle(.plain)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(Color.accentColor)
            Button("Always") { selectionModel.allowAlways() }
                .buttonStyle(.plain)
                .font(.system(size: 11.5, weight: .medium))
            Button("Cancel") { selectionModel.cancelConsent() }
                .buttonStyle(.plain)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 8)
        .background(Color.primary.opacity(0.06))
    }

    private func approvalStrip(_ row: SelectionActionRow) -> some View {
        HStack(spacing: 10) {
            Text("\(row.title) may \(row.approval ?? "modify data").")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer()
            Button("Run  ↩") { selectionModel.approveRun() }
                .buttonStyle(.plain)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(Color.accentColor)
            Button("Cancel") { selectionModel.cancelApproval() }
                .buttonStyle(.plain)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 8)
        .background(Color.primary.opacity(0.06))
    }

    private func sendConfirmStrip(_ pending: SelectionScopeModel.PendingSend) -> some View {
        HStack(spacing: 10) {
            Text("Send to \(pending.recipient) via \(pending.channel)?")
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
            Spacer()
            Button("Send  ↩") { selectionModel.confirmSend() }
                .buttonStyle(.plain)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(Color.accentColor)
            Button("Cancel") { selectionModel.cancelSend() }
                .buttonStyle(.plain)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 8)
        .background(Color.primary.opacity(0.06))
    }

    // MARK: 3. Search Inside File (`⌘F` / Dropdown)

    private var searchInsideFileBody: some View {
        let matches = inFileMatches
        let clampedFocus = matches.isEmpty ? 0 : min(submode.focusedRowIndex, matches.count - 1)
        let trimmed = submode.query.trimmingCharacters(in: .whitespacesAndNewlines)

        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(trimmed.isEmpty
                    ? "Document contents (\(searchableSegments.count) lines/segments) — type above to search"
                    : "\(matches.count) match\(matches.count == 1 ? "" : "es") for “\(trimmed)”")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    model.switchFileSubmode(.preview)
                } label: {
                    Text("Full Preview")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 18)
            .frame(height: 30)
            Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1)

            if searchableSegments.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.system(size: 22))
                        .foregroundStyle(.secondary.opacity(0.6))
                    Text("No extractable text in \(submode.fileName)")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                    Button("Switch to Preview") {
                        model.switchFileSubmode(.preview)
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if matches.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 20))
                        .foregroundStyle(.secondary.opacity(0.6))
                    Text("No matches for “\(trimmed)” in \(submode.fileName)")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                    Button {
                        model.switchFileSubmode(.selectionScope)
                        selectionModel.query = trimmed
                        selectionModel.focusedIndex = nil
                        _ = selectionModel.returnPressed()
                    } label: {
                        Label("Ask AI about “\(trimmed)” in this file", systemImage: "sparkles")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Color.accentColor)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(Color.accentColor.opacity(0.14), in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView(.vertical, showsIndicators: true) {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(matches.enumerated()), id: \.element.id) { index, match in
                            HStack(spacing: 12) {
                                Text(match.locationLabel)
                                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                    .foregroundStyle(Color.accentColor)
                                    .frame(width: 68, alignment: .leading)
                                Text(highlightedSnippet(match.snippet, query: trimmed))
                                    .font(.system(size: 12.5))
                                    .lineLimit(2)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                if index == clampedFocus {
                                    Image(systemName: "return")
                                        .font(.system(size: 10, weight: .medium))
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .padding(.horizontal, 18)
                            .padding(.vertical, 8)
                            .frame(minHeight: 44)
                            .fluidSelection(
                                isSelected: index == clampedFocus,
                                namespace: submodeSelectionSpace,
                                cornerRadius: 8,
                                paddingHorizontal: 10
                            )
                            .contentShape(Rectangle())
                            .onTapGesture {
                                model.switchFileSubmode(.preview)
                            }
                        }
                    }
                    .padding(.vertical, 6)
                }
            }
        }
    }

    private func highlightedSnippet(_ snippet: String, query: String) -> AttributedString {
        var attr = AttributedString(snippet)
        guard !query.isEmpty else { return attr }
        var searchStart = attr.startIndex
        while searchStart < attr.endIndex,
            let range = attr[searchStart..<attr.endIndex].range(
                of: query, options: [.caseInsensitive, .diacriticInsensitive])
        {
            attr[range].foregroundColor = .accentColor
            attr[range].inlinePresentationIntent = .stronglyEmphasized
            searchStart = range.upperBound
        }
        return attr
    }
}

// MARK: - Full-Width Document Content + End Details

struct FullSheetDocumentPreview: View {
    let url: URL
    let highlightQuery: String
    var onSelectFolderItem: ((URL) -> Void)? = nil

    @State private var loadedContent: FullFilePreviewContent = .loading
    @State private var fallbackThumbnail: NSImage?

    private var isFolder: Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            && url.pathExtension.lowercased() != "app"
    }

    var body: some View {
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        VStack(alignment: .leading, spacing: 0) {
            if isFolder {
                let items = FullFolderItemsLoader.items(in: url, filter: highlightQuery)
                PanelSection(title: items.isEmpty ? "No matching items" : "\(items.count) items in \(url.lastPathComponent)")
                ForEach(items.prefix(80), id: \.self) { item in
                    Button {
                        onSelectFolderItem?(item)
                    } label: {
                        HStack(spacing: 10) {
                            LiveFileIconView(url: item, size: 22)
                            Text(item.lastPathComponent)
                                .font(.system(size: 13, weight: .medium))
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer(minLength: 8)
                            Text(item.pathExtension.isEmpty ? "Folder" : item.pathExtension.uppercased())
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 5)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                PanelDivider()
                PanelSection(title: "Details")
                fileDetailsView(url: url, extraRows: []).id("preview-details-end")
            } else {
                documentBody(icon: icon)
                PanelDivider()
                PanelSection(title: "Details")
                fileDetailsView(url: url, extraRows: loadedContent.detailRows).id("preview-details-end")
            }
        }
        .task(id: url) {
            guard !isFolder else { return }
            loadedContent = FullFilePreviewLoader.load(url: url)
            if case .quickLook = loadedContent {
                let path = url.path
                ThumbnailGenerator.shared.getThumbnail(
                    for: path, size: CGSize(width: 960, height: 720)
                ) { img in
                    DispatchQueue.main.async {
                        if url.path == path { fallbackThumbnail = img }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func documentBody(icon: NSImage) -> some View {
        switch loadedContent {
        case .pdf(let doc, let pageCount):
            LazyVStack(spacing: 12) {
                ForEach(0..<min(pageCount, 80), id: \.self) { index in
                    PDFPageCardView(
                        document: doc,
                        pageIndex: index,
                        totalPages: pageCount,
                        renderPixelWidth: 1200
                    )
                }
                if pageCount > 80 {
                    Text("+\(pageCount - 80) more pages")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 4)
                }
            }
            .frame(maxWidth: .infinity)

        case .attributedText(let attributed):
            let displayAttr = highlightedAttributedText(attributed, query: highlightQuery)
            Text(displayAttr)
                .font(.system(size: 13))
                .lineSpacing(4)
                .textSelection(.enabled)
                .padding(16)
                .frame(maxWidth: .infinity, minHeight: 320, alignment: .topLeading)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.black.opacity(0.20))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.09), lineWidth: 1)
                )

        case .plainText(let text, let isCode, _):
            Group {
                if !highlightQuery.isEmpty, !text.isEmpty {
                    Text(highlightedPlainText(text, query: highlightQuery))
                } else {
                    Text(text.isEmpty ? "Empty file" : text)
                        .foregroundStyle(text.isEmpty ? Color.secondary : Color.primary.opacity(0.92))
                }
            }
            .font(.system(size: 12.5, design: isCode ? .monospaced : .default))
            .lineSpacing(3.5)
            .textSelection(.enabled)
            .padding(16)
            .frame(maxWidth: .infinity, minHeight: 320, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.black.opacity(0.20))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.09), lineWidth: 1)
            )

        case .image(let nsImage, _):
            Image(nsImage: nsImage)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: .infinity, minHeight: 300)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.09), lineWidth: 1)
                )

        case .quickLook, .loading:
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.black.opacity(0.18))
                Image(nsImage: fallbackThumbnail ?? icon)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .padding(fallbackThumbnail == nil ? 40 : 10)
                if case .quickLook = loadedContent,
                    !AppDelegate.isHostingTests,
                    FileManager.default.fileExists(atPath: url.path)
                {
                    EmbeddedQuickLookView(url: url)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 344)
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.09), lineWidth: 1)
            )
        }
    }

    private func fileDetailsView(url: URL, extraRows: [(String, String)]) -> some View {
        let values = try? url.resourceValues(forKeys: [
            .localizedTypeDescriptionKey, .fileSizeKey, .contentModificationDateKey,
        ])
        let parent = url.deletingLastPathComponent().path
            .replacingOccurrences(of: NSHomeDirectory(), with: "~")
        return VStack(alignment: .leading, spacing: 0) {
            if let kind = values?.localizedTypeDescription {
                PanelRow(
                    label: "Kind",
                    value: kind,
                    trailing: url.pathExtension.isEmpty ? "Folder" : url.pathExtension.uppercased()
                )
            }
            ForEach(Array(extraRows.enumerated()), id: \.offset) { _, pair in
                PanelRow(label: pair.0, value: pair.1)
            }
            if let size = values?.fileSize {
                PanelRow(
                    label: "Size",
                    value: ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
                )
            }
            if let date = values?.contentModificationDate {
                PanelRow(
                    label: "Modified",
                    value: date.formatted(date: .abbreviated, time: .shortened)
                )
            }
            PanelRow(label: "Where", value: parent)
        }
    }

    private func highlightedPlainText(_ text: String, query: String) -> AttributedString {
        var attr = AttributedString(text)
        guard !query.isEmpty else { return attr }
        var cursor = attr.startIndex
        while cursor < attr.endIndex,
            let range = attr[cursor..<attr.endIndex].range(
                of: query, options: [.caseInsensitive, .diacriticInsensitive])
        {
            attr[range].backgroundColor = Color.accentColor.opacity(0.32)
            attr[range].foregroundColor = .primary
            cursor = range.upperBound
        }
        return attr
    }

    private func highlightedAttributedText(_ base: AttributedString, query: String) -> AttributedString {
        guard !query.isEmpty else { return base }
        var attr = base
        var cursor = attr.startIndex
        while cursor < attr.endIndex,
            let range = attr[cursor..<attr.endIndex].range(
                of: query, options: [.caseInsensitive, .diacriticInsensitive])
        {
            attr[range].backgroundColor = Color.accentColor.opacity(0.32)
            cursor = range.upperBound
        }
        return attr
    }
}

private enum FullFolderItemsLoader {
    static func items(in url: URL, filter: String) -> [URL] {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles])) ?? []
        let trimmed = filter.trimmingCharacters(in: .whitespacesAndNewlines)
        let filtered = trimmed.isEmpty
            ? contents
            : contents.filter {
                $0.lastPathComponent.localizedCaseInsensitiveContains(trimmed)
            }
        return filtered.sorted { a, b in
            let aDir = (try? a.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            let bDir = (try? b.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            if aDir != bDir { return aDir }
            return a.lastPathComponent.localizedStandardCompare(b.lastPathComponent) == .orderedAscending
        }
    }
}
