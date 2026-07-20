// FinderCoworkerCapabilities.swift
// Context-Dock
//
// The default "coworker" tool for Finder-scoped chat: a robust, privacy-first
// file toolkit so the assistant can actually complete file requests instead of
// saying "I can't access your files." Everything runs LOCALLY through FileManager
// and the app's built-in MarkItDown converter — no shell-outs, no network, no
// third-party service. Reads are low-risk (run freely); anything that changes the
// disk (trash) is high-risk and follows the normal approval path.

import AppKit
import Foundation

@MainActor
enum FinderCoworkerCapabilities {
    static let finderBundleID = "com.apple.finder"

    static func register(in registry: CapabilityRegistry) {
        registerSearch(in: registry)
        registerList(in: registry)
        registerRead(in: registry)
        registerInfo(in: registry)
        registerReveal(in: registry)
        registerTrash(in: registry)
    }

    // MARK: - Roots the tool may touch

    /// Common user roots searched when no explicit path is given. Kept to the
    /// user's own directories — never the whole disk — as a privacy default.
    private static var defaultRoots: [URL] {
        let fm = FileManager.default
        return [
            .desktopDirectory, .documentDirectory, .downloadsDirectory,
        ].compactMap { try? fm.url(for: $0, in: .userDomainMask, appropriateFor: nil, create: false) }
    }

    /// Resolve a user-supplied path (tilde/relative allowed), constrained to the
    /// user's home tree so the tool never wanders outside it.
    private static func resolveRoot(_ raw: String?) -> URL? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty
        else { return nil }
        let expanded = (raw as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: expanded).standardizedFileURL
        let home = URL(fileURLWithPath: NSHomeDirectory()).standardizedFileURL.path
        guard url.path == home || url.path.hasPrefix(home + "/") else { return nil }
        return url
    }

    // MARK: - Search

    private static func registerSearch(in registry: CapabilityRegistry) {
        registry.register(
            AICapability(
                id: "finder.searchFiles",
                title: "Search files by name under the user's folders (Desktop/Documents/Downloads or a given path)",
                appBundleID: finderBundleID,
                inputSchema: .init(fields: [
                    .init(name: "query", description: "Substring or *.ext glob to match file names", required: true),
                    .init(name: "path", description: "Optional folder to search under (defaults to user roots)", required: false),
                ]),
                riskLevel: .low
            ) { request in
                let query = (request.input["query"] ?? "").lowercased()
                guard !query.isEmpty else { throw AICapabilityError.missingInput("query") }
                let roots = resolveRoot(request.input["path"]).map { [$0] } ?? defaultRoots
                let ext = query.hasPrefix("*.") ? String(query.dropFirst(2)) : nil

                var hits: [URL] = []
                let fm = FileManager.default
                for root in roots {
                    guard
                        let e = fm.enumerator(
                            at: root,
                            includingPropertiesForKeys: [.isRegularFileKey],
                            options: [.skipsHiddenFiles, .skipsPackageDescendants])
                    else { continue }
                    for case let url as URL in e {
                        let name = url.lastPathComponent.lowercased()
                        let match =
                            ext != nil ? name.hasSuffix("." + ext!) : name.contains(query)
                        if match { hits.append(url) }
                        if hits.count >= 60 { break }
                    }
                    if hits.count >= 60 { break }
                }
                guard !hits.isEmpty else {
                    return .init(success: true, output: "No files matched \"\(query)\".")
                }
                let list = hits.prefix(60).map { "- \($0.path)" }.joined(separator: "\n")
                return .init(success: true, output: "Found \(hits.count) file(s):\n\(list)")
            }
        )
    }

    // MARK: - List

    private static func registerList(in registry: CapabilityRegistry) {
        registry.register(
            AICapability(
                id: "finder.listFolder",
                title: "List the contents of a folder",
                appBundleID: finderBundleID,
                inputSchema: .init(fields: [
                    .init(name: "path", description: "Folder to list (defaults to the selected folder or Desktop)", required: false)
                ]),
                riskLevel: .low
            ) { request in
                let root =
                    resolveRoot(request.input["path"])
                    ?? selectedURLs(from: request).first(where: { $0.hasDirectoryPath })
                    ?? defaultRoots.first
                guard let root else { return .init(success: false, output: "No folder to list.") }
                let fm = FileManager.default
                let items =
                    (try? fm.contentsOfDirectory(
                        at: root, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
                        options: [.skipsHiddenFiles])) ?? []
                guard !items.isEmpty else {
                    return .init(success: true, output: "\(root.path) is empty.")
                }
                let lines = items.prefix(100).map { url -> String in
                    let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
                    return "\(isDir ? "📁" : "📄") \(url.lastPathComponent)"
                }
                return .init(
                    success: true,
                    output: "\(root.path) — \(items.count) item(s):\n" + lines.joined(separator: "\n"))
            }
        )
    }

    // MARK: - Read (token-reduced via MarkItDown)

    private static func registerRead(in registry: CapabilityRegistry) {
        registry.register(
            AICapability(
                id: "finder.readFile",
                title: "Read a file's contents (PDF/Office/text converted to Markdown to save tokens)",
                appBundleID: finderBundleID,
                inputSchema: .init(fields: [
                    .init(name: "path", description: "File to read (defaults to the selected file)", required: false)
                ]),
                riskLevel: .low
            ) { request in
                let url =
                    resolveRoot(request.input["path"])
                    ?? selectedURLs(from: request).first
                guard let url, FileManager.default.fileExists(atPath: url.path) else {
                    return .init(success: false, output: "File not found.")
                }
                if MarkItDownService.supports(url),
                    let converted = MarkItDownService.convert(url, characterBudget: 8_000),
                    !converted.markdown.isEmpty
                {
                    return .init(
                        success: true,
                        output: converted.markdown
                            + (converted.wasTruncated ? "\n\n…(truncated)" : ""))
                }
                if let text = try? String(contentsOf: url, encoding: .utf8) {
                    return .init(success: true, output: String(text.prefix(8_000)))
                }
                return .init(success: false, output: "Couldn't read \(url.lastPathComponent) as text.")
            }
        )
    }

    // MARK: - Info

    private static func registerInfo(in registry: CapabilityRegistry) {
        registry.register(
            AICapability(
                id: "finder.fileInfo",
                title: "Get size, kind and dates for a file or folder",
                appBundleID: finderBundleID,
                inputSchema: .init(fields: [
                    .init(name: "path", description: "File/folder (defaults to the selected item)", required: false)
                ]),
                riskLevel: .low
            ) { request in
                let url = resolveRoot(request.input["path"]) ?? selectedURLs(from: request).first
                guard let url else { return .init(success: false, output: "No item to inspect.") }
                let keys: [URLResourceKey] = [
                    .isDirectoryKey, .fileSizeKey, .contentModificationDateKey,
                    .creationDateKey, .localizedTypeDescriptionKey,
                ]
                guard let v = try? url.resourceValues(forKeys: Set(keys)) else {
                    return .init(success: false, output: "Couldn't read \(url.lastPathComponent).")
                }
                var lines = ["Name: \(url.lastPathComponent)", "Path: \(url.path)"]
                if let kind = v.localizedTypeDescription { lines.append("Kind: \(kind)") }
                if let size = v.fileSize {
                    lines.append(
                        "Size: \(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))")
                }
                if let modified = v.contentModificationDate {
                    lines.append("Modified: \(modified.formatted())")
                }
                if let created = v.creationDate { lines.append("Created: \(created.formatted())") }
                return .init(success: true, output: lines.joined(separator: "\n"))
            }
        )
    }

    // MARK: - Reveal

    private static func registerReveal(in registry: CapabilityRegistry) {
        registry.register(
            AICapability(
                id: "finder.reveal",
                title: "Reveal a file or folder in Finder",
                appBundleID: finderBundleID,
                inputSchema: .init(fields: [
                    .init(name: "path", description: "Item to reveal (defaults to the selected item)", required: false)
                ]),
                riskLevel: .low
            ) { request in
                let url = resolveRoot(request.input["path"]) ?? selectedURLs(from: request).first
                guard let url else { return .init(success: false, output: "Nothing to reveal.") }
                NSWorkspace.shared.activateFileViewerSelecting([url])
                return .init(success: true, output: "Revealed \(url.lastPathComponent) in Finder.")
            }
        )
    }

    // MARK: - Trash (destructive → approval)

    private static func registerTrash(in registry: CapabilityRegistry) {
        registry.register(
            AICapability(
                id: "finder.trash",
                title: "Move files to the Trash (recoverable)",
                appBundleID: finderBundleID,
                inputSchema: .init(fields: [
                    .init(name: "path", description: "File/folder to trash; defaults to the selection", required: false)
                ]),
                riskLevel: .high
            ) { request in
                let urls =
                    resolveRoot(request.input["path"]).map { [$0] } ?? selectedURLs(from: request)
                guard !urls.isEmpty else { return .init(success: false, output: "Nothing to trash.") }
                var trashed: [String] = []
                for url in urls {
                    try FileManager.default.trashItem(at: url, resultingItemURL: nil)
                    trashed.append(url.lastPathComponent)
                }
                return .init(
                    success: true,
                    output: "Moved to Trash: \(trashed.joined(separator: ", "))")
            }
        )
    }

    // MARK: - Shared

    static func selectedURLs(from request: AICapabilityExecutionRequest) -> [URL] {
        if case .filesSelected(let urls) = request.context { return urls }
        return AXContextReader.shared.current.selectedFilePaths.map(URL.init(fileURLWithPath:))
    }
}
