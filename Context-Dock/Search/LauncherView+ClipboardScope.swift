import AppKit
import Combine
import Foundation
import Quartz
import SwiftUI
import UniformTypeIdentifiers

extension LauncherView {
    // MARK: - Clipboard Pocket Pill

    @ViewBuilder
    var clipboardPocketPill: some View {
        let topEntry =
            clipboardHistory.first ?? ClipboardEntry(text: globalClipboardText, timestamp: Date())
        let count = clipboardHistory.count

        Button {
            withAnimation(.spring(response: 0.28, dampingFraction: 0.75)) {
                showClipboardHistory.toggle()
            }
        } label: {
            HStack(spacing: 5) {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: topEntry.icon)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.indigo.opacity(0.9))
                        .frame(width: 18, height: 18)
                }

                Text(topEntry.preview)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.primary.opacity(0.75))
                    .lineLimit(1)
                    .frame(maxWidth: 120)

                Image(systemName: showClipboardHistory ? "chevron.down" : "chevron.up")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Color.indigo.opacity(0.12), in: Capsule())
            .overlay(Capsule().strokeBorder(Color.indigo.opacity(0.3), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .popover(isPresented: showClipboardHistoryBinding, arrowEdge: .bottom) {
            clipboardHistorySheet
        }
        .transition(.scale(scale: 0.85).combined(with: .opacity))
    }

    // MARK: - Floating Selection Pill (always in dock when a selection is active)
    @ViewBuilder
    var selectionFloatingPill: some View {
        let axFiles = axContext.selectedFilePaths.map { URL(fileURLWithPath: $0) }
        let axText = axContext.selectedText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        let info: (icon: String, label: String)? = {
            if !axFiles.isEmpty {
                let lbl =
                    axFiles.count == 1 ? axFiles[0].lastPathComponent : "\(axFiles.count) files"
                let ico =
                    axFiles.count == 1
                    ? fileIcon(for: axFiles[0].pathExtension.lowercased()) : "doc.on.doc.fill"
                return (ico, lbl)
            } else if !axText.isEmpty {
                return ("text.cursor", String(axText.prefix(28)))
            } else {
                switch currentContext {
                case .filesSelected(let urls) where !urls.isEmpty:
                    let lbl = urls.count == 1 ? urls[0].lastPathComponent : "\(urls.count) files"
                    let ico =
                        urls.count == 1
                        ? fileIcon(for: urls[0].pathExtension.lowercased()) : "doc.on.doc.fill"
                    return (ico, lbl)
                case .textSelected(let t)
                where !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty:
                    return (
                        "text.cursor",
                        String(t.trimmingCharacters(in: .whitespacesAndNewlines).prefix(28))
                    )
                case .url(let s) where !s.isEmpty:
                    return ("link", URL(string: s)?.host ?? String(s.prefix(28)))
                default: return nil
                }
            }
        }()

        if let inf = info {
            HStack(spacing: 4) {
                Image(systemName: inf.icon)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.green.opacity(0.85))
                Text(inf.label)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Color.primary.opacity(0.72))
                    .lineLimit(1)
                    .frame(maxWidth: 90)
                Button(action: dismissContextAndReturnToDock) {
                    Image(systemName: "minus")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Clear selection")
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Color.green.opacity(0.10), in: Capsule())
            .overlay(Capsule().strokeBorder(Color.green.opacity(0.25), lineWidth: 0.5))
            .transition(.scale(scale: 0.85).combined(with: .opacity))
        }
    }

    // MARK: - Clipboard history sorted by frontmost app relevance
    func relevantClipboardHistory() -> [ClipboardEntry] {
        let isBrowser = [
            "com.apple.Safari", "com.google.Chrome", "org.mozilla.firefox",
            "com.microsoft.edgemac", "com.brave.Browser",
        ].contains(frontmost.bundleID)
        let isFinder = frontmost.bundleID == "com.apple.finder"

        if isBrowser {
            return clipboardHistory.sorted { a, b in
                if a.isURL && !b.isURL { return true }
                if !a.isURL && b.isURL { return false }
                return a.timestamp > b.timestamp
            }
        } else if isFinder {
            return clipboardHistory.sorted { a, b in
                if a.isFilePath && !b.isFilePath { return true }
                if !a.isFilePath && b.isFilePath { return false }
                return a.timestamp > b.timestamp
            }
        }
        return clipboardHistory
    }

    // MARK: - Floating Clipboard Icon Pill (always in dock, compact — scales with dockIconSize)
    @ViewBuilder
    var clipboardFloatingIconPill: some View {
        let hasContent = showGlobalClipboardPill && !globalClipboardText.isEmpty
        let showDropTarget = clipboardDropTargetVisible && !hasContent
        let count = clipboardHistory.count
        let sorted = relevantClipboardHistory()
        let limit = settings.clipboardHistoryLimit
        let pillH = CGFloat(settings.dockIconSize) * 0.909

        if hasContent && !isSearchBarExpanded && clipboardHistoryExpanded && !sorted.isEmpty {
            // Inline expanded: compact horizontal row of clipboard item chips
            HStack(spacing: 4) {
                ForEach(Array(sorted.prefix(min(limit, 10)).enumerated()), id: \.offset) {
                    _, entry in
                    Button {
                        copyClipboardEntryToPasteboard(entry)
                        withAnimation { clipboardHistoryExpanded = false }
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: entry.icon)
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(
                                    entry.isURL
                                        ? Color.blue.opacity(0.9) : Color.indigo.opacity(0.9))
                            Text(entry.preview)
                                .font(.system(size: 9, weight: .medium))
                                .foregroundStyle(Color.primary.opacity(0.75))
                                .lineLimit(1)
                                .frame(maxWidth: 64)
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 4)
                        .background(.ultraThinMaterial, in: Capsule())
                        .overlay(Capsule().strokeBorder(Color.indigo.opacity(0.20), lineWidth: 0.5))
                    }
                    .buttonStyle(.plain)
                    .help(entry.text)
                }

                // Collapse button
                Button {
                    withAnimation(.spring(response: 0.22, dampingFraction: 0.78)) {
                        clipboardHistoryExpanded = false
                    }
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Color.indigo.opacity(0.7))
                        .frame(width: 24, height: 28)
                        .background(.ultraThinMaterial, in: Capsule())
                }
                .buttonStyle(.plain)
                .help("Collapse clipboard")
            }
            .transition(.scale(scale: 0.9, anchor: .leading).combined(with: .opacity))
            .animation(
                .spring(response: 0.25, dampingFraction: 0.78), value: clipboardHistoryExpanded)
        } else if showDropTarget {
            Button {
                withAnimation(.spring(response: 0.22, dampingFraction: 0.78)) {
                    showClipboardHistory.toggle()
                }
            } label: {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: "tray.and.arrow.down")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.purple.opacity(0.90))
                }
                .frame(width: pillH * 1.1, height: pillH)
                .background {
                    ZStack {
                        Capsule().fill(.ultraThinMaterial)
                        Capsule().fill(
                            clipboardDropTargeted
                                ? Color.purple.opacity(0.18)
                                : Color.purple.opacity(0.08)
                        )
                        Capsule().strokeBorder(
                            clipboardDropTargeted
                                ? Color.purple.opacity(0.45)
                                : Color.purple.opacity(0.26),
                            lineWidth: 0.75)
                    }
                }
                .animation(.spring(response: 0.25, dampingFraction: 0.72), value: pillH)
            }
            .buttonStyle(.plain)
            .popover(isPresented: showClipboardHistoryBinding, arrowEdge: .bottom) {
                clipboardHistorySheet
            }
            .onDrop(
                of: [.fileURL, .text, .plainText, .url],
                isTargeted: clipboardDropTargetedBinding
            ) {
                providers in
                handleClipboardIconDrop(providers)
            }
            .help("Drop here to pin for later")
            .animation(.spring(response: 0.22, dampingFraction: 0.78), value: hasContent)
            .animation(.spring(response: 0.22, dampingFraction: 0.78), value: count)
            .animation(.spring(response: 0.22, dampingFraction: 0.78), value: clipboardDropTargeted)
        } else {
            EmptyView()
        }
    }

    var clipboardHistorySheet: some View {
        VStack(spacing: 0) {
            HStack {
                Label("Clipboard", systemImage: "doc.on.clipboard")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.primary)
                Spacer()
                Button {
                    withAnimation {
                        clipboardHistory.removeAll()
                        savePersistedClipboardHistory()
                        showGlobalClipboardPill = false
                        globalClipboardText = ""
                        showClipboardHistory = false
                        dismissContextAndReturnToDock()
                    }
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            Divider()

            ScrollView {
                LazyVStack(spacing: 0) {
                    let shown = relevantClipboardHistory().prefix(settings.clipboardHistoryLimit)
                    ForEach(Array(shown)) { entry in
                        clipboardHistoryRow(entry)
                        if entry.id != shown.last?.id {
                            Divider().padding(.leading, 38)
                        }
                    }
                }
            }
            .frame(maxHeight: 260)
        }
        .frame(width: 280)
        .background(.regularMaterial)
    }

    func clipboardHistoryRow(_ entry: ClipboardEntry) -> some View {
        clipboardHistoryRowContent(entry)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
            .modifier(
                OptionalDragProviderModifier(provider: {
                    clipboardDragProvider(for: entry)
                })
            )
            .onTapGesture {
                globalClipboardText = entry.text
                withAnimation { showClipboardHistory = false }
            }
            .background(Color.primary.opacity(0.001))
    }

    func clipboardHistoryRowContent(_ entry: ClipboardEntry) -> some View {
        HStack(spacing: 10) {
            ZStack(alignment: .bottomTrailing) {
                if let imageData = entry.imageData, let image = NSImage(data: imageData) {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 28, height: 28)
                        .clipShape(RoundedRectangle(cornerRadius: 7))
                } else if let sourceIcon = clipboardSourceIcon(for: entry) {
                    Image(nsImage: sourceIcon)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 28, height: 28)
                        .clipShape(RoundedRectangle(cornerRadius: 7))
                } else {
                    Image(systemName: entry.icon)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(entry.isURL ? Color.blue : Color.indigo)
                        .frame(width: 28, height: 28)
                        .background(
                            (entry.isURL ? Color.blue : Color.indigo).opacity(0.1),
                            in: RoundedRectangle(cornerRadius: 7))
                }
                if entry.fileCount > 1 {
                    Text("\(min(entry.fileCount, 99))")
                        .font(.system(size: 7, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 3)
                        .padding(.vertical, 1)
                        .background(Color.indigo, in: Capsule())
                        .offset(x: 4, y: 3)
                }
            }

            VStack(alignment: .leading, spacing: 1) {
                Text(entry.preview)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(clipboardEntrySubtitle(entry))
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }

            Spacer()

            Button {
                copyClipboardEntryToPasteboard(entry)
                withAnimation { showClipboardHistory = false }
            } label: {
                Image(systemName: "doc.on.doc")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Copy to clipboard")
        }
    }

    func clipboardSourceIcon(for entry: ClipboardEntry) -> NSImage? {
        if !entry.sourceBundleId.isEmpty,
            let url = NSWorkspace.shared.urlForApplication(
                withBundleIdentifier: entry.sourceBundleId)
        {
            return NSWorkspace.shared.icon(forFile: url.path)
        }
        let name = entry.sourceAppName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !name.isEmpty else { return nil }
        return NSWorkspace.shared.runningApplications.first(where: {
            ($0.localizedName ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                == name
        })?.icon
    }

    func sourceAppIcon(bundleId: String) -> NSImage? {
        guard !bundleId.isEmpty,
            let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId)
        else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path)
    }

    func clipboardEntrySubtitle(_ entry: ClipboardEntry) -> String {
        var parts: [String] = []
        if !entry.sourceAppName.isEmpty {
            parts.append("Copied from \(entry.sourceAppName)")
        }
        if entry.fileCount > 0 {
            parts.append(entry.fileCount == 1 ? "1 file" : "\(entry.fileCount) files")
        }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        let age = formatter.localizedString(for: entry.timestamp, relativeTo: Date())
        parts.append(age)
        return parts.joined(separator: " • ")
    }

    func copyClipboardEntryToPasteboard(_ entry: ClipboardEntry) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        if let imageData = entry.imageData,
            let image = NSImage(data: imageData)
        {
            pasteboard.writeObjects([image])
        } else if !entry.filePaths.isEmpty {
            let urls = entry.filePaths.map { URL(fileURLWithPath: $0) }
            pasteboard.writeObjects(urls as [NSURL])
            pasteboard.setString(entry.filePaths.joined(separator: "\n"), forType: .string)
        } else {
            pasteboard.setString(entry.text, forType: .string)
        }
    }

    func writeClipboardEntriesToPasteboard(_ entries: [ClipboardEntry]) {
        guard !entries.isEmpty else { return }
        if entries.count == 1, let entry = entries.first {
            copyClipboardEntryToPasteboard(entry)
            return
        }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()

        let fileURLs = entries.flatMap { entry in
            entry.filePaths.map { URL(fileURLWithPath: $0) }
        }
        if !fileURLs.isEmpty, fileURLs.count == entries.reduce(0, { $0 + $1.filePaths.count }) {
            pasteboard.writeObjects(fileURLs as [NSURL])
            pasteboard.setString(fileURLs.map(\.path).joined(separator: "\n"), forType: .string)
            return
        }

        let text = entries.map { entry -> String in
            if !entry.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return entry.text
            }
            if !entry.ocrText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return entry.ocrText
            }
            if !entry.filePaths.isEmpty {
                return entry.filePaths.joined(separator: "\n")
            }
            return entry.preview
        }
        .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        .joined(separator: "\n\n")

        if !text.isEmpty {
            pasteboard.setString(text, forType: .string)
        }
    }

    func selectedClipboardEntriesForPaste(fallback entry: ClipboardEntry? = nil) -> [ClipboardEntry] {
        let entries = filteredClipboardEntriesForScope()
        let selected = entries.filter { selectedClipboardEntryIDs.contains($0.id) }
        if !selected.isEmpty {
            return selected
        }
        if let entry {
            return [entry]
        }
        let index = focusedClipboardEntryIndex ?? searchState.selectedIndex ?? 0
        guard entries.indices.contains(index) else { return [] }
        return [entries[index]]
    }

    func selectedClipboardEntriesForContext() -> [ClipboardEntry] {
        let relevant = relevantClipboardHistory()
        let selected = relevant.filter { selectedClipboardEntryIDs.contains($0.id) }
        if !selected.isEmpty { return selected }
        let filtered = filteredClipboardEntriesForScope()
        let index = focusedClipboardEntryIndex ?? searchState.selectedIndex ?? 0
        guard filtered.indices.contains(index) else {
            return relevant.first.map { [$0] } ?? []
        }
        return [filtered[index]]
    }

    func clipboardContextText(from entries: [ClipboardEntry]) -> String {
        entries.map { entry -> String in
            if !entry.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return entry.text
            }
            if !entry.ocrText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return entry.ocrText
            }
            if !entry.filePaths.isEmpty {
                return entry.filePaths.joined(separator: "\n")
            }
            return entry.preview
        }
        .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        .joined(separator: "\n\n")
    }

    @discardableResult
    func submitClipboardScopeAIQuery(_ query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return false }
        let entries = selectedClipboardEntriesForContext()
        let contextText = clipboardContextText(from: entries)
        guard !contextText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }

        globalClipboardText = contextText
        showGlobalClipboardPill = true
        currentContext = .textSelected(contextText)
        axContext.selectedText = contextText
        l2.chatArmed = true
        l2.showChatPopover = true
        l2.chatDismissed = false
        handleL2Query(q, skipMenuRouter: true)
        return true
    }

    @discardableResult
    func pasteFocusedClipboardEntriesToFrontmost() -> Bool {
        let entries = selectedClipboardEntriesForPaste()
        guard !entries.isEmpty else { return false }
        pasteClipboardEntriesToFrontmost(entries)
        return true
    }

    func pasteClipboardEntryToFrontmost(_ entry: ClipboardEntry, index: Int) {
        focusedClipboardEntryIndex = index
        searchState.selectedIndex = index

        if NSEvent.modifierFlags.contains(.command) {
            toggleClipboardEntrySelection(entry, index: index)
            return
        }

        pasteClipboardEntriesToFrontmost(selectedClipboardEntriesForPaste(fallback: entry))
    }

    func pasteClipboardEntriesToFrontmost(_ entries: [ClipboardEntry]) {
        guard !entries.isEmpty else { return }
        writeClipboardEntriesToPasteboard(entries)

        let targetApp = AppDelegate.shared?.previousFrontmostApp
        let targetPID = targetApp?.processIdentifier ?? 0
        selectedClipboardEntryIDs.removeAll()
        hideLauncherAfterResultExecution()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.10) {
            if let targetApp, !targetApp.isTerminated {
                targetApp.activate(options: [.activateIgnoringOtherApps])
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                postPasteShortcut(to: targetPID)
            }
        }
    }

    func postPasteShortcut(to pid: pid_t) {
        guard let source = CGEventSource(stateID: .combinedSessionState) else { return }
        let keyCode: CGKeyCode = 9 // V
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true)
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        keyDown?.flags = .maskCommand
        keyUp?.flags = .maskCommand

        if pid > 0 {
            keyDown?.postToPid(pid)
            keyUp?.postToPid(pid)
        } else {
            keyDown?.post(tap: .cghidEventTap)
            keyUp?.post(tap: .cghidEventTap)
        }
    }

    func clipboardDragProvider(for entry: ClipboardEntry) -> NSItemProvider? {
        if let firstPath = entry.filePaths.first {
            let url = URL(fileURLWithPath: firstPath)
            if FileManager.default.fileExists(atPath: url.path),
                let provider = NSItemProvider(contentsOf: url)
            {
                return provider
            }
        }

        if let imageData = entry.imageData,
            let url = temporaryClipboardDragFile(data: imageData, fileExtension: "tiff"),
            let provider = NSItemProvider(contentsOf: url)
        {
            return provider
        }

        if entry.isURL, let url = URL(string: entry.text),
            let provider = NSItemProvider(contentsOf: url)
        {
            return provider
        }

        let text = entry.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        return NSItemProvider(object: text as NSString)
    }

    func temporaryClipboardDragFile(data: Data, fileExtension: String) -> URL? {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ContextDockClipboardDrag", isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent(UUID().uuidString).appendingPathExtension(
                fileExtension)
            try data.write(to: url, options: [.atomic])
            return url
        } catch {
            return nil
        }
    }

    func revealClipboardDropTarget() {
        withAnimation(.spring(response: 0.22, dampingFraction: 0.78)) {
            clipboardDropTargetVisible = true
        }
    }

    func hideClipboardDropTargetIfEmpty() {
        guard !showGlobalClipboardPill || globalClipboardText.isEmpty else { return }
        withAnimation(.spring(response: 0.22, dampingFraction: 0.82)) {
            clipboardDropTargetVisible = false
            clipboardDropTargeted = false
        }
    }

    func handleClipboardIconDrop(_ providers: [NSItemProvider]) -> Bool {
        clipboardDropTargetVisible = true
        let fileProviders = providers.filter {
            $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
        }
        let textProviders = providers.filter {
            $0.hasItemConformingToTypeIdentifier(UTType.utf8PlainText.identifier)
                || $0.hasItemConformingToTypeIdentifier(UTType.plainText.identifier)
                || $0.hasItemConformingToTypeIdentifier(UTType.text.identifier)
                || $0.canLoadObject(ofClass: NSString.self)
        }
        let urlProviders = providers.filter {
            $0.hasItemConformingToTypeIdentifier(UTType.url.identifier)
                || $0.canLoadObject(ofClass: NSURL.self)
        }
        guard !fileProviders.isEmpty || !textProviders.isEmpty || !urlProviders.isEmpty else {
            hideClipboardDropTargetIfEmpty()
            return false
        }

        let group = DispatchGroup()
        let lock = NSLock()
        var paths: [String] = []
        var texts: [String] = []

        for provider in fileProviders {
            group.enter()
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) {
                item, _ in
                defer { group.leave() }
                let url: URL? = {
                    if let data = item as? Data {
                        return URL(dataRepresentation: data, relativeTo: nil)
                    }
                    if let url = item as? URL {
                        return url
                    }
                    if let nsurl = item as? NSURL {
                        return nsurl as URL
                    }
                    return nil
                }()
                guard let url, url.isFileURL else { return }
                lock.lock()
                paths.append(url.path)
                lock.unlock()
            }
        }

        for provider in urlProviders
        where !provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            group.enter()
            provider.loadItem(forTypeIdentifier: UTType.url.identifier, options: nil) { item, _ in
                defer { group.leave() }
                let value: String? = {
                    if let data = item as? Data {
                        return String(data: data, encoding: .utf8)
                    }
                    if let url = item as? URL {
                        return url.absoluteString
                    }
                    if let nsurl = item as? NSURL {
                        return nsurl.absoluteString
                    }
                    if let string = item as? String {
                        return string
                    }
                    return nil
                }()
                guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                else { return }
                lock.lock()
                texts.append(value)
                lock.unlock()
            }
        }

        for provider in textProviders {
            group.enter()
            if provider.canLoadObject(ofClass: NSString.self) {
                provider.loadObject(ofClass: NSString.self) { object, _ in
                    defer { group.leave() }
                    let value =
                        (object as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    guard !value.isEmpty else { return }
                    lock.lock()
                    texts.append(value)
                    lock.unlock()
                }
            } else {
                provider.loadItem(forTypeIdentifier: UTType.plainText.identifier, options: nil) {
                    item, _ in
                    defer { group.leave() }
                    let value: String? = {
                        if let data = item as? Data { return String(data: data, encoding: .utf8) }
                        if let string = item as? String { return string }
                        if let nsString = item as? NSString { return nsString as String }
                        return nil
                    }()
                    let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    guard !trimmed.isEmpty else { return }
                    lock.lock()
                    texts.append(trimmed)
                    lock.unlock()
                }
            }
        }

        group.notify(queue: .main) {
            let uniquePaths = Array(NSOrderedSet(array: paths)) as? [String] ?? paths
            let uniqueTexts = Array(NSOrderedSet(array: texts)) as? [String] ?? texts
            if !uniquePaths.isEmpty {
                addClipboardEntry(text: uniquePaths.joined(separator: "\n"), filePaths: uniquePaths)
            } else if let text = uniqueTexts.first, !text.isEmpty {
                addClipboardEntry(text: text, filePaths: [])
            } else {
                hideClipboardDropTargetIfEmpty()
            }
        }

        return true
    }

    func handleDockContextDrop(_ providers: [NSItemProvider]) -> Bool {
        let fileProviders = providers.filter {
            $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
        }
        guard !fileProviders.isEmpty else {
            return handleClipboardIconDrop(providers)
        }

        let group = DispatchGroup()
        let lock = NSLock()
        var paths: [String] = []

        for provider in fileProviders {
            group.enter()
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) {
                item, _ in
                defer { group.leave() }
                let url: URL? = {
                    if let data = item as? Data {
                        return URL(dataRepresentation: data, relativeTo: nil)
                    }
                    if let url = item as? URL {
                        return url
                    }
                    if let nsurl = item as? NSURL {
                        return nsurl as URL
                    }
                    return nil
                }()
                guard let url, url.isFileURL,
                    FileManager.default.fileExists(atPath: url.path)
                else { return }
                lock.lock()
                paths.append(url.standardizedFileURL.path)
                lock.unlock()
            }
        }

        group.notify(queue: .main) {
            let uniquePaths = Array(NSOrderedSet(array: paths)) as? [String] ?? paths
            let urls = uniquePaths.map { URL(fileURLWithPath: $0) }
            guard !urls.isEmpty else {
                hideClipboardDropTargetIfEmpty()
                return
            }

            let label =
                urls.count == 1
                ? urls[0].lastPathComponent
                : "\(urls.count) items selected"
            let icon =
                urls.count == 1 && !urls[0].hasDirectoryPath
                ? fileIcon(for: urls[0].pathExtension.lowercased())
                : "folder.fill"

            currentContext = .filesSelected(urls)
            globalContextActivation = GlobalContextActivation(
                autoActivated: false,
                frozenText: label,
                frozenIcon: icon,
                sourceBundleId: frontmost.bundleID,
                frozenFilePaths: uniquePaths
            )
            showContextInDock = true
            showMediaLayer = false
            aiMode.isActive = false
            expandSearchBar()
            scheduleDockPillRebuild(query: lastPillQuery, delayNanoseconds: 0)
        }

        return true
    }

    func clipboardSearchResults() -> [SearchResult] {
        clipboardEntriesForScope(query: searchState.query).map { entry in
            let previewURL = quickLookURL(for: entry)
            return SearchResult(
                title: entry.preview,
                subtitle: clipboardEntrySubtitle(entry),
                icon: clipboardEntryImage(for: entry),
                action: {
                    copyClipboardEntryToPasteboard(entry)
                },
                score: 100,
                type: entry.fileCount > 0 ? .file : .document,
                filePath: previewURL?.path ?? entry.filePaths.first,
                contactData: nil,
                displayBadges: entry.ocrText.isEmpty ? [] : ["OCR"],
                showsTypeLabel: false,
                dismissesLauncher: false,
                dragProvider: {
                    clipboardDragProvider(for: entry)
                }
            )
        }
    }

    func refreshCompactScopeResults(resetSelection: Bool = true) {
        guard let key = searchState.activeSmartQueryKey,
            key == "clipboard" || key == "notifications"
        else { return }

        let results: [SearchResult] =
            key == "clipboard"
            ? clipboardSearchResults()
            : notificationSearchResults()
        searchState.results = results
        searchState.grouped = {
            var grouped = GroupedResults()
            grouped.pinnedResults = results
            grouped.pinnedSectionTitle = key == "clipboard" ? "Clipboard Items" : "Notifications"
            return grouped
        }()
        if resetSelection {
            searchState.selectedIndex = nil
            focusedClipboardEntryIndex = nil
            isKeyboardNavigation = false
        } else if let index = searchState.selectedIndex, index >= results.count {
            searchState.selectedIndex = results.isEmpty ? nil : max(results.count - 1, 0)
        }
        searchState.revision += 1
        refreshQuickLookPreviewForCurrentFocusIfVisible()
    }

    /// Provider usage rows as SearchResults so the notification scope has content
    /// (and a correctly-sized sheet) the moment it opens, before any notification.
    func aiUsageSearchResults() -> [SearchResult] {
        aiUsageScopeRows().map { row in
            SearchResult(
                title: row.title,
                subtitle: row.subtitle,
                icon: NSImage(
                    systemSymbolName: row.systemIcon, accessibilityDescription: row.title),
                action: {},
                type: .extensionCommand,
                filePath: nil,
                contactData: nil,
                displayBadges: ["Usage"],
                showsTypeLabel: false,
                dismissesLauncher: false
            )
        }
    }

    func notificationSearchResults() -> [SearchResult] {
        aiUsageSearchResults() + filteredNotificationsForScope().map { notification in
            SearchResult(
                title: notification.title,
                subtitle:
                    "\(notification.body) • \(notification.date.formatted(date: .abbreviated, time: .shortened))",
                icon: NSImage(
                    systemSymbolName: notification.icon,
                    accessibilityDescription: notification.title),
                action: {
                    notificationManager.tap(notification.id)
                    refreshCompactScopeResults(resetSelection: false)
                },
                type: .extensionCommand,
                filePath: nil,
                contactData: nil,
                displayBadges: notification.isRead ? [] : ["Unread"],
                showsTypeLabel: false,
                dismissesLauncher: false
            )
        }
    }

    @ViewBuilder
    func sharedResultSheet(
        sections: [SharedResultSectionModel],
        emptyIcon: String,
        emptyTitle: String,
        header: AnyView? = nil,
        settings: AnyView? = nil
    ) -> some View {
        let focusedRowID = sections.flatMap(\.rows).first(where: \.isFocused)?.id
        VStack(spacing: 0) {
            if let header {
                header
                Divider()
            }

            if sections.allSatisfy({ $0.rows.isEmpty }) {
                VStack(spacing: 8) {
                    Image(systemName: emptyIcon)
                        .font(.system(size: 28))
                        .foregroundStyle(.tertiary)
                    Text(emptyTitle)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(sections) { section in
                                if !section.rows.isEmpty {
                                    Text(section.title)
                                        .font(.system(size: 10, weight: .semibold))
                                        .foregroundStyle(.secondary)
                                        .textCase(.uppercase)
                                        .tracking(0.4)
                                        .padding(.horizontal, 12)
                                        .padding(.top, 12)
                                        .padding(.bottom, 6)
                                    ForEach(Array(section.rows.enumerated()), id: \.element.id) {
                                        _, row in
                                        sharedResultRow(row)
                                            .id(row.id)
                                    }
                                }
                            }
                            if let settings {
                                settings
                                    .padding(.top, 8)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .onChange(of: focusedRowID) { _, rowID in
                        guard let rowID else { return }
                        withAnimation(.spring(response: 0.24, dampingFraction: 0.84)) {
                            proxy.scrollTo(rowID, anchor: .center)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    func sharedResultRow(_ row: SharedResultRowModel) -> some View {
        Button {
            row.open()
        } label: {
            HStack(spacing: 12) {
                ZStack {
                    if let image = row.image {
                        Image(nsImage: image)
                            .resizable()
                            .interpolation(.high)
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 40, height: 40)
                    } else {
                        Image(systemName: row.systemIcon)
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundStyle(accentColor(for: row.accentColorName))
                    }
                }
                .frame(width: 58, height: 52)
                .opacity(row.isEnabled ? 1 : 0.38)

                VStack(alignment: .leading, spacing: 3) {
                    Text(row.title)
                        .font(.system(size: 14, weight: row.isUnread ? .semibold : .medium))
                        .foregroundStyle(row.isEnabled ? .primary : .secondary)
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        if !row.subtitle.isEmpty {
                            Text(row.subtitle)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        ForEach(row.badges, id: \.self) { badge in
                            Text(badge)
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(
                                    Color.primary.opacity(0.07),
                                    in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                        }
                    }
                }
                .opacity(row.isEnabled ? 1 : 0.46)

                Spacer(minLength: 12)

                if let sourceImage = row.sourceImage {
                    Image(nsImage: sourceImage)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 24, height: 24)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .padding(4)
                        .background(
                            .ultraThinMaterial,
                            in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .strokeBorder(Color.white.opacity(0.16), lineWidth: 0.6)
                        )
                }

                if let trailing = row.trailingText {
                    Text(trailing)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .fixedSize()
                }

                if let copy = row.copy {
                    Button {
                        copy()
                    } label: {
                        Image(systemName: "doc.on.clipboard")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.secondary.opacity(0.72))
                            .frame(width: 26, height: 26)
                            .background(Color.white.opacity(0.06), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .help("Copy")
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
            .background(
                ZStack {
                    if row.isFocused {
                        Capsule(style: .continuous)
                            .fill(.ultraThinMaterial)
                            .matchedGeometryEffect(
                                id: dockResultFocusEffectID,
                                in: compactScopeFocusNamespace,
                                properties: .frame,
                                isSource: false
                            )
                        Capsule(style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [
                                        Color.white.opacity(isEffectiveDark ? 0.18 : 0.24),
                                        Color.white.opacity(isEffectiveDark ? 0.055 : 0.10),
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                        Capsule(style: .continuous)
                            .strokeBorder(
                                LinearGradient(
                                    colors: [
                                        Color.white.opacity(0.34),
                                        Color.white.opacity(0.08),
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ),
                                lineWidth: 0.8
                            )
                        Capsule(style: .continuous)
                            .strokeBorder(Color.white.opacity(0.38), lineWidth: 1.0)
                            .blur(radius: 2.2)
                    } else if row.isUnread {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color.accentColor.opacity(0.07))
                    }
                }
            )
            .padding(.horizontal, 8)
            .padding(.vertical, 1)
        }
        .buttonStyle(.plain)
        .disabled(!row.isEnabled)
        .modifier(OptionalDragProviderModifier(provider: row.dragProvider))
        .onHover { hovering in
            guard hovering, acceptsMouseDrivenDockInteraction else { return }
            guard !isCompactSmartScope else { return }
            if isKeyboardNavigation {
                isKeyboardNavigation = false
            }
            row.focus()
            refreshQuickLookPreviewForCurrentFocusIfVisible()
        }
        .animation(.spring(response: 0.22, dampingFraction: 0.84), value: row.isFocused)
        .contextMenu {
            if let copy = row.copy {
                Button("Copy") { copy() }
            }
            if let markRead = row.markRead {
                Button("Mark as Read") { markRead() }
            }
            if let remove = row.remove {
                Button("Remove", role: .destructive) { remove() }
            }
        }
    }

    func notificationScopeSections() -> [SharedResultSectionModel] {
        let visible = filteredNotificationsForScope()
        let rows = visible.enumerated().map { index, notification in
            notificationSharedRow(notification, index: index)
        }
        return [
            SharedResultSectionModel(
                id: "usage", title: "AI Provider Usage", rows: aiUsageScopeRows()),
            SharedResultSectionModel(id: "notifications", title: "Notifications", rows: rows),
        ]
    }

    @ViewBuilder
    var notificationScopeView: some View {
        sharedResultSheet(
            sections: notificationScopeSections(),
            emptyIcon: "bell.slash",
            emptyTitle: searchState.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "No notifications"
                : "No matching notifications"
        )
        .onReceive(notificationManager.$notifications) { _ in
            if searchState.activeSmartQueryKey == "notifications" {
                refreshCompactScopeResults(resetSelection: false)
            }
        }
        .onReceive(usageStore.$usage) { _ in
            if searchState.activeSmartQueryKey == "notifications" {
                refreshCompactScopeResults(resetSelection: false)
            }
        }
    }

    /// Live per-provider rate-limit rows (from API response headers). Shows a hint
    /// row until the first API-key request populates real numbers.
    func aiUsageScopeRows() -> [SharedResultRowModel] {
        let usage = usageStore.usage
        guard !usage.isEmpty else {
            return [
                SharedResultRowModel(
                    id: "usage-empty",
                    title: "Usage appears after your next AI request",
                    subtitle: "API-key providers report remaining requests/tokens; "
                        + "subscription & bridge providers don't expose limits.",
                    systemIcon: "gauge.with.dots.needle.bottom.50percent"
                )
            ]
        }
        return usage.map { u in
            var parts: [String] = []
            if let remaining = u.remainingRequests {
                let limit = u.limitRequests.map { "/\($0)" } ?? ""
                parts.append("requests \(remaining)\(limit)")
            }
            if let remaining = u.remainingTokens {
                let limit = u.limitTokens.map { "/\($0)" } ?? ""
                parts.append("tokens \(remaining)\(limit)")
            }
            if let reset = u.resetText { parts.append(reset) }
            return SharedResultRowModel(
                id: "usage-\(u.id)",
                title: u.providerName,
                subtitle: parts.joined(separator: " • "),
                systemIcon: "gauge.with.dots.needle.67percent"
            )
        }
    }

    var notificationScopeHeader: some View {
        HStack(spacing: 8) {
            Label("Notifications", systemImage: "bell.badge")
                .font(.system(size: 13, weight: .semibold))
            Spacer()
            Text("\(notificationManager.notifications.count)")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            if notificationManager.unreadCount > 0 {
                Text("\(notificationManager.unreadCount) unread")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        Color.accentColor.opacity(0.12),
                        in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            }
            Button("Mark All Read") {
                notificationManager.markAllRead()
                searchState.appPanelAllItems = notificationSearchResults()
            }
            .buttonStyle(.bordered)
            .controlSize(.mini)
            .disabled(notificationManager.unreadCount == 0)
            Button("Clear") {
                notificationManager.clearAll()
                searchState.appPanelAllItems = notificationSearchResults()
            }
            .buttonStyle(.bordered)
            .controlSize(.mini)
            .disabled(notificationManager.notifications.isEmpty)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.accentColor.opacity(0.06))
    }

    var notificationInlineSettings: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Notification Settings")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .tracking(0.4)
                .padding(.horizontal, 12)
            HStack(spacing: 10) {
                notificationSettingToggle("Completed", isOn: $settings.notifyOnActionCompleted)
                notificationSettingToggle("Failed", isOn: $settings.notifyOnActionFailed)
                notificationSettingToggle("AI Response", isOn: $settings.notifyOnAIResponse)
                notificationSettingToggle("System Banners", isOn: $settings.notifySystemBanners)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 10)
        }
    }

    func notificationSettingToggle(_ title: String, isOn: Binding<Bool>) -> some View {
        Toggle(title, isOn: isOn)
            .toggleStyle(.switch)
            .controlSize(.mini)
            .font(.system(size: 11, weight: .medium))
            .fixedSize()
    }

    func filteredNotificationsForScope() -> [ILauncherNotification] {
        let q = searchState.query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return notificationManager.notifications }
        return notificationManager.notifications.filter { notification in
            notification.title.lowercased().contains(q)
                || notification.body.lowercased().contains(q)
        }
    }

    func notificationSharedRow(_ notification: ILauncherNotification, index: Int)
        -> SharedResultRowModel
    {
        SharedResultRowModel(
            id: notification.id.uuidString,
            title: notification.title,
            subtitle: notification.body,
            systemIcon: notification.icon,
            accentColorName: notification.accentColor,
            trailingText: notification.date.formatted(date: .omitted, time: .shortened),
            badges: notification.isRead ? [] : ["Unread"],
            isUnread: !notification.isRead,
            isFocused: searchState.selectedIndex == index,
            open: {
                notificationManager.tap(notification.id)
                refreshCompactScopeResults(resetSelection: false)
            },
            focus: {
                searchState.selectedIndex = index
            },
            markRead: notification.isRead
                ? nil
                : {
                    notificationManager.markRead(notification.id)
                    refreshCompactScopeResults(resetSelection: false)
                },
            remove: {
                notificationManager.remove(notification.id)
                refreshCompactScopeResults(resetSelection: false)
            }
        )
    }

    @ViewBuilder
    func notificationScopeRow(_ notification: ILauncherNotification) -> some View {
        Button {
            notificationManager.tap(notification.id)
            searchState.appPanelAllItems = notificationSearchResults()
        } label: {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(accentColor(for: notification.accentColor).opacity(0.16))
                    Image(systemName: notification.icon)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(accentColor(for: notification.accentColor))
                }
                .frame(width: 42, height: 42)

                VStack(alignment: .leading, spacing: 3) {
                    Text(notification.title)
                        .font(.system(size: 13, weight: notification.isRead ? .medium : .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(notification.body)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                Spacer()

                Text(notification.date, style: .relative)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.tertiary)
                    .fixedSize()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
            .background(notification.isRead ? Color.clear : Color.accentColor.opacity(0.08))
        }
        .buttonStyle(.plain)
        .contextMenu {
            if !notification.isRead {
                Button("Mark as Read") {
                    notificationManager.markRead(notification.id)
                    refreshCompactScopeResults(resetSelection: false)
                }
            }
            Button("Remove", role: .destructive) {
                notificationManager.remove(notification.id)
                refreshCompactScopeResults(resetSelection: false)
            }
        }
    }

    func clipboardEntryImage(for entry: ClipboardEntry) -> NSImage? {
        if let imageData = entry.imageData, let image = NSImage(data: imageData) {
            return image
        }
        if entry.filePaths.count == 1 {
            return NSWorkspace.shared.icon(forFile: entry.filePaths[0])
        }
        return NSImage(systemSymbolName: entry.icon, accessibilityDescription: entry.preview)
    }

    func clipboardEntriesForScope(query: String) -> [ClipboardEntry] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let entries = relevantClipboardHistory()
        guard !q.isEmpty, q != "clip", q != "clipboard" else { return entries }
        return entries.filter {
            $0.preview.lowercased().contains(q)
                || $0.text.lowercased().contains(q)
                || $0.ocrText.lowercased().contains(q)
                || $0.filePaths.joined(separator: " ").lowercased().contains(q)
                || $0.sourceAppName.lowercased().contains(q)
                || clipboardEntrySubtitle($0).lowercased().contains(q)
        }
    }

    func buildClipboardHistoryPills(query q: String) -> [DockPill] {
        let entries = clipboardEntriesForScope(query: q)
        return entries.prefix(maxListViewDockPills).enumerated().map { index, entry in
            var pill = DockPill(
                id: "clipboard-history-\(entry.id.uuidString)",
                name: entry.preview.isEmpty ? "Clipboard Item" : entry.preview,
                icon: entry.icon,
                accentColorName: entry.imageData != nil
                    ? "purple" : (entry.fileCount > 0 ? "green" : "blue"),
                badge: clipboardEntrySubtitle(entry),
                execute: {
                    copyClipboardEntryToPasteboard(entry)
                    searchState.query = ""
                    focusedClipboardEntryIndex = nil
                    l2.focusedPillIndex = nil
                }
            )
            pill.menuItemImage = clipboardEntryImage(for: entry)
            pill.sourceBundleId = entry.sourceBundleId
            pill.sourceAppName = entry.sourceAppName.isEmpty ? "Clipboard" : entry.sourceAppName
            pill.rankingKind = "clipboard"
            pill.trackingIdentifier = "clipboard:\(entry.id.uuidString)"
            pill.searchTerms = [
                entry.preview,
                entry.text,
                entry.ocrText,
                entry.filePaths.joined(separator: " "),
                entry.sourceAppName,
                clipboardEntrySubtitle(entry),
                "clipboard",
                "clip",
            ]
            pill.quickLookURL = quickLookURL(for: entry)
            pill.dragProvider = {
                clipboardDragProvider(for: entry)
            }
            pill.rankingScore = Double(maxListViewDockPills - index)
            return pill
        }
    }

    @ViewBuilder
    /// Split clipboard surface: a horizontally-scrolling "Recent" rail on top and
    /// per-source-app pills below. Selecting an app pill filters the list to that
    /// app's clips; the input filters across everything as usual.
    var clipboardScopeView: some View {
        let entries = filteredClipboardEntriesForScope()
        let scoped =
            clipboardSourceFilterBundleId.isEmpty
            ? entries
            : entries.filter { $0.sourceBundleId == clipboardSourceFilterBundleId }
        let rows = scoped.enumerated().map { index, entry in
            clipboardSharedRow(entry, index: index)
        }
        return VStack(spacing: 0) {
            clipboardRecentRail(Array(entries.prefix(10)))
            Divider().opacity(0.35)
            clipboardSourceAppPills(entries)
            Divider().opacity(0.35)
            sharedResultSheet(
                sections: [
                    SharedResultSectionModel(
                        id: "clipboard",
                        title: clipboardSourceFilterBundleId.isEmpty
                            ? "Clipboard Items"
                            : (clipboardSourceFilterName.isEmpty
                                ? "Clipboard Items" : "\(clipboardSourceFilterName) Clips"),
                        rows: rows)
                ],
                emptyIcon: "doc.on.clipboard",
                emptyTitle: "Clipboard is empty"
            )
        }
    }

    /// Top half — the 10 most recent clips as a horizontal scroller.
    @ViewBuilder
    func clipboardRecentRail(_ recent: [ClipboardEntry]) -> some View {
        if !recent.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("RECENT")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(.tertiary)
                    .tracking(0.7)
                    .padding(.horizontal, 12)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(recent) { entry in
                            Button {
                                copyClipboardEntryToPasteboard(entry)
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    // Real content preview: image clips render their
                                    // thumbnail, everything else shows its actual text.
                                    if let data = entry.imageData,
                                        let image = NSImage(data: data)
                                    {
                                        Image(nsImage: image)
                                            .resizable()
                                            .aspectRatio(contentMode: .fill)
                                            .frame(width: 112, height: 40)
                                            .clipShape(RoundedRectangle(cornerRadius: 5))
                                    } else {
                                        Text(clipboardEntryPreviewText(entry))
                                            .font(.system(size: 11))
                                            .foregroundStyle(.primary)
                                            .lineLimit(3)
                                            .multilineTextAlignment(.leading)
                                    }
                                    Spacer(minLength: 0)
                                    if !entry.sourceAppName.isEmpty {
                                        Text(entry.sourceAppName)
                                            .font(.system(size: 9, weight: .medium))
                                            .foregroundStyle(.tertiary)
                                            .lineLimit(1)
                                    }
                                }
                                .padding(8)
                                .frame(width: 128, height: 74, alignment: .topLeading)
                                .background(
                                    Color.primary.opacity(0.06),
                                    in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                                        .strokeBorder(Color.primary.opacity(0.08)))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 12)
                }
            }
            .padding(.vertical, 8)
        }
    }

    /// Bottom half — one floating pill per source app; tap to filter to its clips.
    @ViewBuilder
    func clipboardSourceAppPills(_ entries: [ClipboardEntry]) -> some View {
        let groups = clipboardSourceGroups(entries)
        if !groups.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    clipboardSourcePill(
                        name: "All", bundleId: "", count: entries.count,
                        isSelected: clipboardSourceFilterBundleId.isEmpty)
                    ForEach(groups, id: \.bundleId) { group in
                        clipboardSourcePill(
                            name: group.name, bundleId: group.bundleId, count: group.count,
                            isSelected: clipboardSourceFilterBundleId == group.bundleId)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
        }
    }

    func clipboardSourcePill(name: String, bundleId: String, count: Int, isSelected: Bool)
        -> some View
    {
        Button {
            clipboardSourceFilterBundleId = isSelected ? "" : bundleId
            clipboardSourceFilterName = isSelected ? "" : name
            refreshCompactScopeResults(resetSelection: true)
        } label: {
            HStack(spacing: 6) {
                if !bundleId.isEmpty, let icon = sourceAppIcon(bundleId: bundleId) {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 14, height: 14)
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                } else {
                    Image(systemName: "square.grid.2x2")
                        .font(.system(size: 10, weight: .semibold))
                }
                Text(name)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                Text("\(count)")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(
                isSelected ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.06),
                in: Capsule())
            .overlay(
                Capsule().strokeBorder(
                    isSelected ? Color.accentColor.opacity(0.45) : Color.primary.opacity(0.08)))
        }
        .buttonStyle(.plain)
    }

    func clipboardSourceGroups(_ entries: [ClipboardEntry])
        -> [(bundleId: String, name: String, count: Int)]
    {
        var order: [String] = []
        var names: [String: String] = [:]
        var counts: [String: Int] = [:]
        for entry in entries where !entry.sourceBundleId.isEmpty {
            if counts[entry.sourceBundleId] == nil {
                order.append(entry.sourceBundleId)
                names[entry.sourceBundleId] =
                    entry.sourceAppName.isEmpty ? entry.sourceBundleId : entry.sourceAppName
            }
            counts[entry.sourceBundleId, default: 0] += 1
        }
        return order.map {
            (bundleId: $0, name: names[$0] ?? $0, count: counts[$0] ?? 0)
        }
    }

    func clipboardEntryPreviewText(_ entry: ClipboardEntry) -> String {
        let text = entry.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty { return text }
        if !entry.filePaths.isEmpty {
            return entry.filePaths.map { ($0 as NSString).lastPathComponent }
                .joined(separator: ", ")
        }
        return entry.imageData != nil ? "Image" : "Empty"
    }


    var clipboardScopeHeader: some View {
        HStack(spacing: 8) {
            Label("Clipboard", systemImage: "doc.on.clipboard")
                .font(.system(size: 13, weight: .semibold))
            Spacer()
            Text("\(relevantClipboardHistory().count)")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            Button("Clear") {
                clipboardHistory.removeAll()
                selectedClipboardEntryIDs.removeAll()
                focusedClipboardEntryIndex = nil
                savePersistedClipboardHistory()
                syncVisibleClipboardStateAfterPrune()
                refreshCompactScopeResults(resetSelection: false)
            }
            .buttonStyle(.bordered)
            .controlSize(.mini)
            .disabled(clipboardHistory.isEmpty)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.accentColor.opacity(0.06))
    }

    func clipboardSharedRow(_ entry: ClipboardEntry, index: Int) -> SharedResultRowModel {
        SharedResultRowModel(
            id: entry.id.uuidString,
            title: entry.preview.isEmpty ? "Clipboard Item" : entry.preview,
            subtitle: clipboardEntrySubtitle(entry),
            systemIcon: entry.icon,
            image: clipboardEntryImage(for: entry),
            sourceImage: clipboardSourceIcon(for: entry),
            accentColorName: entry.imageData != nil
                ? "purple" : (entry.fileCount > 0 ? "green" : "blue"),
            badges: entry.ocrText.isEmpty ? [] : ["OCR"],
            isFocused: focusedClipboardEntryIndex == index || searchState.selectedIndex == index
                || selectedClipboardEntryIDs.contains(entry.id),
            quickLookURL: quickLookURL(for: entry),
            dragProvider: { clipboardDragProvider(for: entry) },
            open: {
                pasteClipboardEntryToFrontmost(entry, index: index)
            },
            focus: {
                focusedClipboardEntryIndex = index
                searchState.selectedIndex = index
            },
            remove: {
                clipboardHistory.removeAll { $0.id == entry.id }
                selectedClipboardEntryIDs.remove(entry.id)
                savePersistedClipboardHistory()
                syncVisibleClipboardStateAfterPrune()
                refreshCompactScopeResults(resetSelection: false)
            },
            copy: {
                copyClipboardEntryToPasteboard(entry)
            }
        )
    }

    func filteredClipboardEntriesForScope() -> [ClipboardEntry] {
        clipboardEntriesForScope(query: searchState.query)
    }

    func navigateClipboardScope(direction: Int) {
        let entries = filteredClipboardEntriesForScope()
        guard !entries.isEmpty else {
            focusedClipboardEntryIndex = nil
            return
        }

        if direction < 0, focusedClipboardEntryIndex == nil, searchState.selectedIndex == nil {
            return
        }

        let current = focusedClipboardEntryIndex ?? (direction < 0 ? entries.count : -1)
        if direction < 0, current <= 0 {
            withAnimation(.spring(response: 0.22, dampingFraction: 0.84)) {
                focusedClipboardEntryIndex = nil
                searchState.selectedIndex = nil
                isKeyboardNavigation = false
                isSearchFieldFocused = true
            }
            refreshQuickLookPreviewForCurrentFocusIfVisible()
            return
        }
        let next = min(max(current + direction, 0), entries.count - 1)
        isKeyboardNavigation = true
        beginMouseDrivenInteractionGrace(0.6)
        focusedClipboardEntryIndex = next
        searchState.selectedIndex = next
        refreshQuickLookPreviewForCurrentFocusIfVisible()
    }

    func toggleClipboardEntrySelection(_ entry: ClipboardEntry, index: Int) {
        focusedClipboardEntryIndex = index
        searchState.selectedIndex = index
        if selectedClipboardEntryIDs.contains(entry.id) {
            selectedClipboardEntryIDs.remove(entry.id)
        } else {
            selectedClipboardEntryIDs.insert(entry.id)
        }
    }

    func extendClipboardSelection(direction: Int) {
        let entries = filteredClipboardEntriesForScope()
        guard !entries.isEmpty else {
            focusedClipboardEntryIndex = nil
            selectedClipboardEntryIDs.removeAll()
            return
        }

        let current = focusedClipboardEntryIndex ?? searchState.selectedIndex ?? (direction < 0 ? entries.count : -1)
        let next = min(max(current + direction, 0), entries.count - 1)
        focusedClipboardEntryIndex = next
        searchState.selectedIndex = next
        selectedClipboardEntryIDs.insert(entries[next].id)
        isKeyboardNavigation = true
        beginMouseDrivenInteractionGrace(0.6)
        refreshQuickLookPreviewForCurrentFocusIfVisible()
    }

    func quickLookFocusedClipboardEntry() {
        let entries = filteredClipboardEntriesForScope()
        let index = focusedClipboardEntryIndex ?? searchState.selectedIndex ?? 0
        guard entries.indices.contains(index) else { return }
        focusedClipboardEntryIndex = index
        searchState.selectedIndex = index
        quickLookClipboardEntry(entries[index])
    }

    func quickLookClipboardEntry(_ entry: ClipboardEntry) {
        guard let url = quickLookURL(for: entry) else {
            openClipboardEntry(entry)
            return
        }

        _ = showQuickLookURL(url, toggleIfSame: true)
    }

    func quickLookURL(for entry: ClipboardEntry) -> URL? {
        if let path = entry.filePaths.first, FileManager.default.fileExists(atPath: path) {
            return URL(fileURLWithPath: path)
        }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ContextDockClipboardQuickLook", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        if let imageData = entry.imageData {
            let url = directory.appendingPathComponent("\(entry.id.uuidString).tiff")
            try? imageData.write(to: url, options: .atomic)
            return url
        }

        if let url = URL(string: entry.text), url.scheme != nil {
            let previewURL = directory.appendingPathComponent("\(entry.id.uuidString).webloc")
            let body = """
                <?xml version="1.0" encoding="UTF-8"?>
                <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
                <plist version="1.0"><dict><key>URL</key><string>\(url.absoluteString)</string></dict></plist>
                """
            try? body.write(to: previewURL, atomically: true, encoding: .utf8)
            return previewURL
        }

        let previewURL = directory.appendingPathComponent("\(entry.id.uuidString).txt")
        try? entry.text.write(to: previewURL, atomically: true, encoding: .utf8)
        return previewURL
    }

    func currentFocusedDockPillForQuickLook() -> DockPill? {
        guard isL2ContextActive, usesVerticalListDockLayout else { return nil }
        let q = searchState.query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let pillQuery = shouldUseFinderSearchPopover(for: q) ? "" : q
        let pills =
            pillQuery.isEmpty
            ? selectionScopedDockPills(cachedDockPills)
            : contextDockViewModel.visiblePills
        let index = l2.focusedPillIndex ?? listViewHoveredIndex
        guard let index, pills.indices.contains(index), !pills[index].isSeparator else {
            return nil
        }
        return pills[index]
    }

    func quickLookDockPill(_ pill: DockPill) -> Bool {
        // Web link rows (Safari history/bookmarks) peek the live page.
        if let webURL = pill.resolvedURL,
            webURL.scheme == "https" || webURL.scheme == "http"
        {
            WebQuickLookPanel.shared.toggle(url: webURL)
            return true
        }
        guard let url = pill.quickLookURL else { return false }
        return showQuickLookURL(url, toggleIfSame: true)
    }

    /// Focused pill in the global grouped list (app-scope sheet), for Space peeks.
    func focusedGlobalGroupedListPill() -> DockPill? {
        guard isGlobalContextActive else { return nil }
        let q = searchState.query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let state = globalGroupedListNavigationState(for: q)
        guard state.totalCount > 0,
            let index = currentGlobalGroupedFocusIndex(state: state)
        else { return nil }
        let menuIndex = index - state.appResults.count
        guard menuIndex >= 0, menuIndex < state.menuPills.count else { return nil }
        return state.menuPills[menuIndex]
    }

    func openClipboardEntry(_ entry: ClipboardEntry) {
        if !entry.filePaths.isEmpty {
            NSWorkspace.shared.activateFileViewerSelecting(
                entry.filePaths.map { URL(fileURLWithPath: $0) })
        } else if let url = URL(string: entry.text), url.scheme != nil {
            NSWorkspace.shared.open(url)
        } else {
            copyClipboardEntryToPasteboard(entry)
        }
    }

    @ViewBuilder
    func clipboardScopeListItem(_ entry: ClipboardEntry, index: Int) -> some View {
        let focused = focusedClipboardEntryIndex == index
        Button {
            copyClipboardEntryToPasteboard(entry)
        } label: {
            clipboardHistoryRowContent(entry)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
                .background(
                    focused
                        ? Color.accentColor.opacity(0.14)
                        : Color.clear
                )
        }
        .buttonStyle(.plain)
        .modifier(
            OptionalDragProviderModifier(provider: {
                clipboardDragProvider(for: entry)
            })
        )
        .contextMenu {
            Button("Copy") { copyClipboardEntryToPasteboard(entry) }
            Button("Open") { openClipboardEntry(entry) }
        }
        .onHover { hovering in
            if hovering {
                focusedClipboardEntryIndex = index
                refreshQuickLookPreviewForCurrentFocusIfVisible()
            }
        }
    }

    @ViewBuilder
    func clipboardScopeGridItem(_ entry: ClipboardEntry, index: Int) -> some View {
        let focused = focusedClipboardEntryIndex == index
        Button {
            copyClipboardEntryToPasteboard(entry)
        } label: {
            VStack(alignment: .leading, spacing: 7) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.primary.opacity(0.06))
                    if let imageData = entry.imageData, let image = NSImage(data: imageData) {
                        Image(nsImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    } else {
                        Image(systemName: entry.icon)
                            .font(.system(size: 24, weight: .medium))
                            .foregroundStyle(entry.isURL ? Color.blue : Color.indigo)
                    }
                }
                .frame(height: 74)
                Text(entry.preview)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(2)
                Text(clipboardEntrySubtitle(entry))
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                HStack {
                    Spacer()
                    Button {
                        copyClipboardEntryToPasteboard(entry)
                    } label: {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 22, height: 20)
                    }
                    .buttonStyle(.plain)
                    .help("Copy")
                }
            }
            .padding(8)
            .background(
                focused ? Color.accentColor.opacity(0.14) : Color.primary.opacity(0.035),
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(
                        focused ? Color.accentColor.opacity(0.45) : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .modifier(
            OptionalDragProviderModifier(provider: {
                clipboardDragProvider(for: entry)
            })
        )
        .contextMenu {
            Button("Copy") { copyClipboardEntryToPasteboard(entry) }
            Button("Open") { openClipboardEntry(entry) }
        }
        .onHover { hovering in
            if hovering {
                focusedClipboardEntryIndex = index
                refreshQuickLookPreviewForCurrentFocusIfVisible()
            }
        }
    }

    @ViewBuilder
    func pillScrollRowItem(pill: DockPill, index: Int) -> some View {
        let base = unifiedPillButton(pill: pill, index: index)
            .id("pill-\(index)")
            .transition(.scale(scale: 0.8).combined(with: .opacity))
        let scaled =
            base
            .scaleEffect(dockMagnificationScale(for: index), anchor: .bottom)
            .animation(.spring(response: 0.18, dampingFraction: 0.65), value: hoveredDockPillIndex)
        scaled.scrollTransition(.interactive, axis: .horizontal) { effect, phase in
            effect
                .rotation3DEffect(
                    .degrees(phase.value * 22),
                    axis: (x: 0, y: 1, z: 0),
                    perspective: 0.45
                )
                .scaleEffect(max(0.78, 1 - abs(phase.value) * 0.18))
                .opacity(max(0.45, 1 - abs(phase.value) * 0.38))
        }
    }

    @ViewBuilder
    func dockPillScrollRow(pills: [DockPill], appQuery: String = "") -> some View {
        // Filtered app icons: pinned + running apps whose name starts with or contains the query.
        // Suppressed in global context with an active selection — queries filter context pills there.
        let filteredApps:
            [(
                icon: NSImage?, label: String, bundleId: String?, isRunning: Bool,
                action: () -> Void
            )] = {
                guard !appQuery.isEmpty, !isExplicitAppScope, !isGlobalContextActive else {
                    return []
                }
                let q = appQuery.lowercased()
                var seen = Set<String>()
                var results:
                    [(
                        icon: NSImage?, label: String, bundleId: String?, isRunning: Bool,
                        action: () -> Void
                    )] = []
                // Pinned apps
                for app in settings.pinnedApps where app.type == .application {
                    let name = app.name.lowercased()
                    guard name.hasPrefix(q) || (q.count >= 2 && name.contains(q)) else { continue }
                    let key = app.bundleIdentifier ?? app.path
                    guard seen.insert(key).inserted else { continue }
                    let isRunning = runningApp(for: app) != nil
                    let icon = resolvedPinnedIcon(for: app)
                    let captured = app
                    results.append(
                        (
                            icon: icon, label: app.name, bundleId: app.bundleIdentifier,
                            isRunning: isRunning, action: { launchPinnedApp(captured) }
                        ))
                    if results.count >= 5 { break }
                }
                // Running apps not already in pinned
                for app in runningRegularApps where results.count < 5 {
                    guard let name = app.localizedName else { continue }
                    let lname = name.lowercased()
                    guard lname.hasPrefix(q) || (q.count >= 2 && lname.contains(q)) else {
                        continue
                    }
                    let key = app.bundleIdentifier ?? "\(app.processIdentifier)"
                    guard seen.insert(key).inserted else { continue }
                    let icon = resolvedRunningAppIcon(for: app)
                    let captured = app
                    results.append(
                        (
                            icon: icon, label: name, bundleId: app.bundleIdentifier,
                            isRunning: true, action: { activateRunningAppFromDock(captured) }
                        ))
                }
                return results
            }()

        Group {
            if let focIdx = l2.focusedPillIndex, !pills.isEmpty, focIdx < pills.count {
                // ── Cascade: at 820pt show prev2+prev+focused+next; at 640pt show prev+focused+next ──
                let leftSlots = visibleDockWidth >= 750 ? 2 : 1
                let prev2: Int? =
                    leftSlots >= 2
                    ? {
                        let i = focIdx - 2
                        guard i >= 0, !pills[i].isSeparator else { return nil }
                        return i
                    }() : nil
                let prev1: Int? = {
                    let i = focIdx - 1
                    guard i >= 0, !pills[i].isSeparator else { return nil }
                    return i
                }()
                let next1: Int? = {
                    let i = focIdx + 1
                    guard i < pills.count, !pills[i].isSeparator else { return nil }
                    return i
                }()
                HStack(spacing: 6) {
                    // Prev2 (only on wide dock)
                    if let p2 = prev2 {
                        unifiedPillButton(pill: pills[p2], index: p2)
                            .transition(
                                .asymmetric(
                                    insertion: .opacity.combined(with: .scale(scale: 0.9)),
                                    removal: .opacity.combined(with: .scale(scale: 0.9))))
                    }
                    // Prev
                    if let p1 = prev1 {
                        unifiedPillButton(pill: pills[p1], index: p1)
                            .transition(
                                .asymmetric(
                                    insertion: .opacity.combined(with: .scale(scale: 0.9)),
                                    removal: .opacity.combined(with: .scale(scale: 0.9))))
                    }
                    // Focused — expanded bright pill, fills remaining space
                    unifiedPillButton(pill: pills[focIdx], index: focIdx, isExpanded: true)
                        .frame(maxWidth: .infinity)
                        .transition(.opacity)
                    // Next
                    if let n1 = next1 {
                        unifiedPillButton(pill: pills[n1], index: n1)
                            .transition(
                                .asymmetric(
                                    insertion: .opacity.combined(with: .scale(scale: 0.9)),
                                    removal: .opacity.combined(with: .scale(scale: 0.9))))
                    }
                }
                .animation(.spring(response: 0.22, dampingFraction: 0.78), value: focIdx)
            } else {
                // ── Normal scrollable row ─────────────────────────────────────────────
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(spacing: 6) {
                            if !pills.isEmpty {
                                ForEach(Array(pills.enumerated()), id: \.element.id) { idx, pill in
                                    pillScrollRowItem(pill: pill, index: idx)
                                }
                            } else {
                                Spacer(minLength: 0)
                            }
                        }
                    }
                    .onChange(of: l2.focusedPillIndex) { newIndex in
                        guard l2.pillNavViaKeyboard, let idx = newIndex else { return }
                        withAnimation(.spring(response: 0.25, dampingFraction: 0.82)) {
                            proxy.scrollTo("pill-\(idx)", anchor: .center)
                        }
                        refreshQuickLookPreviewForCurrentFocusIfVisible()
                        if idx < pills.count, pills[idx].isShareAction {
                            showShareSheetForContext()
                        }
                    }
                }
            }  // end else
        }  // end Group
        .onHover { hovering in
            guard acceptsMouseDrivenDockInteraction else { return }
            isHoveringPillRow = hovering
            if !hovering { pillScrollAccumulator = 0 }
        }
    }

}
