// DropShelfStore.swift
// Context-Dock
//
// The Drop Shelf's storage. Owns the folder, decides what a dropped thing is, copies it
// in, and hands it back. No UI, and no knowledge of the clipboard: a copy is not a drop.
//
// Everything dropped is *copied* into the shelf and the shelf owns the copy, so an item
// outlives the original being renamed, moved, or deleted. The files on disk are the
// truth; `index.json` only carries what the filesystem cannot (source app, drop time),
// and is rebuilt by walking the folders if it is ever lost.

import AppKit
import Combine
import Foundation
import UniformTypeIdentifiers

@MainActor
final class DropShelfStore: ObservableObject {
    static let shared = DropShelfStore()

    let root: URL
    @Published private(set) var items: [DropShelfItem] = []

    /// Long enough to stay recognisable, short enough to stay a filename.
    private static let maxTextNameLength = 40

    init(root: URL? = nil) {
        self.root = root ?? Self.defaultRoot
        reload()
    }

    static var defaultRoot: URL {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(
            "Library/Application Support")
        return base.appendingPathComponent("Context-Dock/Shelf")
    }

    var indexURL: URL { root.appendingPathComponent("index.json") }

    func url(for item: DropShelfItem) -> URL {
        root.appendingPathComponent(item.relativePath)
    }

    // MARK: - Classification

    /// Ordered, first match wins. The broad conformances overlap the narrow ones — an
    /// image also conforms to `.content` — so an unordered rule set files a PNG as a
    /// document.
    static func kind(for url: URL) -> DropShelfItem.Kind {
        if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
            return .other
        }
        guard
            let type = (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType
                ?? UTType(filenameExtension: url.pathExtension)
        else { return .other }

        if type.conforms(to: .image) { return .images }
        if type.conforms(to: .archive) { return .archives }
        for documentType: UTType in [.pdf, .text, .spreadsheet, .presentation, .content]
        where type.conforms(to: documentType) {
            return .documents
        }
        return .other
    }

    // MARK: - Destinations

    /// `Shelf/<Kind>/<yyyy-MM-dd>/<name>`, with a numeric suffix when the name is taken.
    /// Never returns a URL that already exists: two dropped files sharing a name are two
    /// different items, and silently overwriting one would lose work the user believes
    /// is on the shelf.
    func destinationURL(
        forName name: String, kind: DropShelfItem.Kind, date: Date = Date()
    ) -> URL {
        let folder = root
            .appendingPathComponent(kind.folderName)
            .appendingPathComponent(Self.dayFormatter.string(from: date))
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension

        var candidate = folder.appendingPathComponent(name)
        var counter = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            let suffixed = ext.isEmpty ? "\(base) \(counter)" : "\(base) \(counter).\(ext)"
            candidate = folder.appendingPathComponent(suffixed)
            counter += 1
        }
        return candidate
    }

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    // MARK: - Ingest

    @discardableResult
    func ingestFile(
        at source: URL, source app: (name: String, bundleId: String)
    ) throws -> DropShelfItem {
        let kind = Self.kind(for: source)
        let destination = destinationURL(forName: source.lastPathComponent, kind: kind)
        try copy(source, to: destination)
        return try record(
            at: destination, kind: kind, originalName: source.lastPathComponent, app: app)
    }

    /// Dropped text has no file of its own. Without one it could be shown but never
    /// dragged back out, which would make it a second-class item in the one operation the
    /// shelf exists for.
    @discardableResult
    func ingestText(
        _ text: String, source app: (name: String, bundleId: String)
    ) throws -> DropShelfItem {
        let name = Self.fileName(forText: text) + ".txt"
        let destination = destinationURL(forName: name, kind: .text)
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: destination, atomically: true, encoding: .utf8)
        return try record(at: destination, kind: .text, originalName: name, app: app)
    }

    @discardableResult
    func ingestURL(
        _ url: URL, source app: (name: String, bundleId: String)
    ) throws -> DropShelfItem {
        let stem = url.host ?? url.lastPathComponent
        let name = (stem.isEmpty ? "link" : stem) + ".webloc"
        let destination = destinationURL(forName: name, kind: .links)
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try PropertyListSerialization.data(
            fromPropertyList: ["URL": url.absoluteString], format: .xml, options: 0)
        try data.write(to: destination, options: .atomic)
        return try record(at: destination, kind: .links, originalName: name, app: app)
    }

    /// First line of the text, trimmed of anything a filename cannot carry. Falls back to
    /// the clock when the text opens with blank lines.
    static func fileName(forText text: String) -> String {
        let firstLine =
            text
            .split(whereSeparator: \.isNewline)
            .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .map(String.init) ?? ""
        let illegal = CharacterSet(charactersIn: "/:\\?%*|\"<>")
        let cleaned = firstLine
            .components(separatedBy: illegal).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else {
            let f = DateFormatter()
            f.dateFormat = "HHmmss"
            return "note-\(f.string(from: Date()))"
        }
        return String(cleaned.prefix(maxTextNameLength))
            .trimmingCharacters(in: .whitespaces)
    }

    /// Copies land at a temporary name and are moved into place only once complete, so an
    /// interrupted copy leaves nothing half-written on the shelf.
    private func copy(_ source: URL, to destination: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let staging = destination.deletingLastPathComponent()
            .appendingPathComponent(".incoming-\(UUID().uuidString)")
        try fm.copyItem(at: source, to: staging)
        do {
            try fm.moveItem(at: staging, to: destination)
        } catch {
            try? fm.removeItem(at: staging)
            throw error
        }
    }

    private func record(
        at destination: URL,
        kind: DropShelfItem.Kind,
        originalName: String,
        app: (name: String, bundleId: String)
    ) throws -> DropShelfItem {
        let item = DropShelfItem(
            relativePath: relativePath(for: destination),
            kind: kind,
            originalName: originalName,
            sourceAppName: app.name,
            sourceBundleId: app.bundleId
        )
        items.insert(item, at: 0)
        saveIndex()
        return item
    }

    private func relativePath(for url: URL) -> String {
        let rootPath = root.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(rootPath) else { return url.lastPathComponent }
        return String(path.dropFirst(rootPath.count).drop(while: { $0 == "/" }))
    }

    // MARK: - Removal

    /// Deletes the shelf's copy. The original the user dropped is never touched, because
    /// the shelf only ever held a copy of it.
    func remove(_ item: DropShelfItem) {
        try? FileManager.default.removeItem(at: url(for: item))
        items.removeAll { $0.id == item.id }
        saveIndex()
    }

    // MARK: - Index

    func reload() {
        guard let data = try? Data(contentsOf: indexURL),
            let stored = try? JSONDecoder().decode([DropShelfItem].self, from: data)
        else {
            // The files are the truth: a lost or corrupt index must not lose the shelf.
            items = rebuiltFromDisk()
            if !items.isEmpty { saveIndex() }
            return
        }
        // Drop entries whose file went missing underneath us, then take on anything on
        // disk the index never knew about.
        let known = stored.filter {
            FileManager.default.fileExists(atPath: url(for: $0).path)
        }
        let knownPaths = Set(known.map(\.relativePath))
        let strays = rebuiltFromDisk().filter { !knownPaths.contains($0.relativePath) }
        items = (known + strays).sorted { $0.droppedAt > $1.droppedAt }
        if known.count != stored.count || !strays.isEmpty { saveIndex() }
    }

    /// Walks the kind folders. Metadata the filesystem cannot carry — source app — is
    /// simply lost; the item itself is not.
    private func rebuiltFromDisk() -> [DropShelfItem] {
        let fm = FileManager.default
        var rebuilt: [DropShelfItem] = []
        for kind in DropShelfItem.Kind.allCases {
            let kindFolder = root.appendingPathComponent(kind.folderName)
            guard let days = try? fm.contentsOfDirectory(
                at: kindFolder, includingPropertiesForKeys: nil)
            else { continue }
            for day in days {
                guard let files = try? fm.contentsOfDirectory(
                    at: day, includingPropertiesForKeys: [.creationDateKey])
                else { continue }
                for file in files where !file.lastPathComponent.hasPrefix(".") {
                    let dropped =
                        (try? file.resourceValues(forKeys: [.creationDateKey]))?.creationDate
                        ?? Date.distantPast
                    rebuilt.append(
                        DropShelfItem(
                            relativePath: relativePath(for: file),
                            kind: kind,
                            originalName: file.lastPathComponent,
                            droppedAt: dropped
                        ))
                }
            }
        }
        return rebuilt.sorted { $0.droppedAt > $1.droppedAt }
    }

    private func saveIndex() {
        let snapshot = items
        let url = indexURL
        try? FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
