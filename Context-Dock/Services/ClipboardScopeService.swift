// ClipboardScopeService.swift
// Context-Dock
//
// What a clipboard surface can *do* with clips, held apart from either surface that shows
// them.
//
// The dock's clipboard scope grew all of this — ordered multi-selection, the pasteboard
// payload rules, drag providers, the text an AI turn should be given — and the corner panel
// was written beside it as a viewer, so the corner could show a clip and paste one, and
// nothing else. Copying those rules into the panel would have made two implementations of
// "what does pasting three mixed clips mean", which is exactly how the two answers start
// disagreeing.
//
// Everything here is a function of its arguments. The surfaces keep their own state — which
// rows are selected, what is focused — and hand it in.

import AppKit
import Foundation

@MainActor
enum ClipboardScopeService {
    typealias Entry = LauncherView.ClipboardEntry

    // MARK: - Selection

    /// Selected clips in the order the user picked them, falling back to list order for
    /// anything selected before the order was being tracked.
    ///
    /// Order is the whole point: pasting three clips into a document should produce them in
    /// the order they were chosen, not the order the history happens to hold them.
    static func orderedSelection<Item: Identifiable>(
        from items: [Item], selectedIDs: Set<Item.ID>, pickOrder: [Item.ID]
    ) -> [Item] {
        let selected = items.filter { selectedIDs.contains($0.id) }
        guard selected.count > 1 else { return selected }
        let rank = Dictionary(
            pickOrder.enumerated().map { ($0.element, $0.offset) },
            uniquingKeysWith: { first, _ in first })
        let listRank = Dictionary(
            selected.enumerated().map { ($0.element.id, $0.offset) },
            uniquingKeysWith: { first, _ in first })
        return selected.sorted { a, b in
            let ra = rank[a.id] ?? (pickOrder.count + (listRank[a.id] ?? 0))
            let rb = rank[b.id] ?? (pickOrder.count + (listRank[b.id] ?? 0))
            return ra < rb
        }
    }

    /// What a range selection covers, given the row last clicked and the row shift-clicked.
    ///
    /// Generic because the Drop Shelf selects the same way over different items: one rule
    /// for "what does shift-click mean", not one per list.
    static func rangeSelection<Item: Identifiable>(
        in items: [Item], from anchorID: Item.ID?, to targetID: Item.ID
    ) -> Set<Item.ID> {
        guard let anchorID,
            let anchor = items.firstIndex(where: { $0.id == anchorID }),
            let target = items.firstIndex(where: { $0.id == targetID })
        else { return [targetID] }
        let range = anchor <= target ? anchor...target : target...anchor
        return Set(items[range].map(\.id))
    }

    // MARK: - Content

    /// The text an AI turn should be handed for these clips: the readable content, in order,
    /// falling back through OCR text and file paths to the preview.
    static func contextText(from entries: [Entry]) -> String {
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

    static func imageData(for entry: Entry) -> Data? {
        if let data = entry.imageData { return data }
        guard let fileName = entry.imageFileName else { return nil }
        return ClipboardImageStore.read(fileName: fileName)
    }

    // MARK: - Pasteboard

    /// What kind of paste a selection means. Named because the rule is not obvious and both
    /// surfaces have to agree on it.
    enum Payload: Equatable {
        /// Every clip is a file. Finder, Mail and upload fields all want fileURL items, and
        /// handing them the paths as text is never what was meant.
        case files([URL])
        /// Every clip is an image. The picture itself, never the "Image" placeholder or the
        /// OCR text — pasting an image used to hand the target a string.
        case images(count: Int)
        /// Anything mixed: the text a document would want, with file URLs appended as extra
        /// items for targets that understand them.
        case textWithFiles(text: String, files: [URL])
        case empty
    }

    static func payload(for entries: [Entry]) -> Payload {
        guard !entries.isEmpty else { return .empty }
        let fileURLs = entries.flatMap { entry in
            entry.filePaths.map { URL(fileURLWithPath: $0) }
        }
        let imageCount = entries.filter { imageData(for: $0) != nil }.count
        let text = contextText(from: entries)

        // "Every clip is a file", not "any clip is a file". The dock's own copy of this
        // reads `!fileURLs.isEmpty` while its comment says every — so selecting a sentence
        // and a file there pastes the file and drops the sentence. The comment is the
        // intent: a selection containing text must still paste as text somewhere.
        let allAreFiles = entries.allSatisfy { !$0.filePaths.isEmpty }
        if allAreFiles, imageCount == 0 { return .files(fileURLs) }
        if imageCount > 0, imageCount == entries.count { return .images(count: imageCount) }
        if text.isEmpty, fileURLs.isEmpty, imageCount > 0 { return .images(count: imageCount) }
        if text.isEmpty && fileURLs.isEmpty { return .empty }
        return .textWithFiles(text: text, files: fileURLs)
    }

    /// Writes the selection, and reports the change count it left behind so the always-on
    /// monitor can decline to re-import what we just wrote — a clip re-entering its own
    /// history churns the list, and the image blob behind it, for nothing.
    @discardableResult
    static func writeToPasteboard(_ entries: [Entry]) -> Int {
        let pasteboard = NSPasteboard.general
        guard !entries.isEmpty else { return pasteboard.changeCount }
        pasteboard.clearContents()

        switch payload(for: entries) {
        case .empty:
            break

        case .files(let urls):
            var items: [NSPasteboardItem] = []
            for (index, url) in urls.enumerated() {
                let item = NSPasteboardItem()
                item.setString(url.absoluteString, forType: .fileURL)
                if index == 0 {
                    item.setString(urls.map(\.path).joined(separator: "\n"), forType: .string)
                }
                items.append(item)
            }
            pasteboard.writeObjects(items)

        case .images:
            let images = entries.compactMap { imageData(for: $0).flatMap(NSImage.init(data:)) }
            if !images.isEmpty { pasteboard.writeObjects(images) }

        case .textWithFiles(let text, let files):
            var items: [NSPasteboardItem] = []
            if !text.isEmpty {
                let item = NSPasteboardItem()
                item.setString(text, forType: .string)
                items.append(item)
            }
            for url in files {
                let item = NSPasteboardItem()
                item.setString(url.absoluteString, forType: .fileURL)
                items.append(item)
            }
            if !items.isEmpty { pasteboard.writeObjects(items) }
        }

        return pasteboard.changeCount
    }

    // MARK: - Dragging

    /// A real file wherever one can be produced, so a drop into Finder writes a file rather
    /// than a path someone has to paste somewhere.
    static func dragProvider(for entry: Entry) -> NSItemProvider? {
        if let firstPath = entry.filePaths.first {
            let url = URL(fileURLWithPath: firstPath)
            if FileManager.default.fileExists(atPath: url.path),
                let provider = NSItemProvider(contentsOf: url)
            {
                return provider
            }
        }

        if let data = imageData(for: entry),
            let url = temporaryDragFile(data: data, fileExtension: "png"),
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

    static func dragProviders(for entries: [Entry]) -> [NSItemProvider] {
        entries.compactMap { dragProvider(for: $0) }
    }

    static func temporaryDragFile(data: Data, fileExtension: String) -> URL? {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ContextDockClipboardDrag", isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
            let url = directory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension(fileExtension)
            try data.write(to: url, options: [.atomic])
            return url
        } catch {
            return nil
        }
    }

    // MARK: - Pasting into the app in front

    /// Writes the selection and sends ⌘V to the given process.
    ///
    /// The corner never activates Context-Dock, so whatever was frontmost still is — which
    /// is the only reason this can paste into it at all.
    static func pasteToFrontmost(_ entries: [Entry], target pid: pid_t?) {
        guard !entries.isEmpty else { return }
        writeToPasteboard(entries)
        guard let pid else { return }
        postPasteShortcut(to: pid)
    }

    static func postPasteShortcut(to pid: pid_t) {
        guard let source = CGEventSource(stateID: .combinedSessionState) else { return }
        let vKey: CGKeyCode = 9
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: true),
            let up = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: false)
        else { return }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.postToPid(pid)
        up.postToPid(pid)
    }
}
