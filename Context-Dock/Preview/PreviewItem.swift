// PreviewItem.swift
// Context-Dock
//
// One thing the preview surface can show. Kind is resolved once, on construction,
// because every renderer branch and the AI context both need it and re-deriving it
// per redraw put UTType lookups on the render path.

import AppKit
import Foundation
import UniformTypeIdentifiers

struct PreviewItem: Identifiable, Hashable {
    enum Kind: String {
        case document
        case image
        case text
        case folder
        case web
    }

    let url: URL
    let kind: Kind

    var id: String { url.absoluteString }
    var title: String { kind == .web ? (url.host ?? url.absoluteString) : url.lastPathComponent }

    /// Nil when the path no longer exists — a preview of a deleted file is a blank
    /// window the user has to close, which is worse than the key doing nothing.
    static func file(_ url: URL) -> PreviewItem? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            return nil
        }
        return PreviewItem(url: url, kind: isDirectory.boolValue ? .folder : fileKind(url))
    }

    static func file(path: String) -> PreviewItem? {
        file(URL(fileURLWithPath: (path as NSString).expandingTildeInPath))
    }

    static func web(_ url: URL) -> PreviewItem {
        PreviewItem(url: url, kind: .web)
    }

    /// Route by URL scheme first: a caller holding a plain URL shouldn't have to know
    /// which factory to reach for.
    static func any(_ url: URL) -> PreviewItem? {
        if url.isFileURL { return file(url) }
        if url.scheme == "http" || url.scheme == "https" { return web(url) }
        return nil
    }

    private static func fileKind(_ url: URL) -> Kind {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return .document }
        if type.conforms(to: .image) { return .image }
        if type.conforms(to: .text) || type.conforms(to: .sourceCode) { return .text }
        return .document
    }

    /// Contents for the assistant come from PreviewTextExtractor, which handles PDFs and
    /// OCR off the main actor. This type stays a value: what the file IS, not what it says.
    var metadataForAI: String {
        guard url.isFileURL else { return "Web page: \(url.absoluteString)" }
        let attributes = (try? FileManager.default.attributesOfItem(atPath: url.path)) ?? [:]
        let size = attributes[.size] as? Int ?? 0
        let modified = attributes[.modificationDate] as? Date
        var lines = [
            "Name: \(url.lastPathComponent)",
            "Path: \(url.path)",
            "Kind: \(kind.rawValue)",
        ]
        if kind != .folder {
            lines.append("Size: \(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))")
        }
        if let modified {
            lines.append("Modified: \(modified.formatted(date: .abbreviated, time: .shortened))")
        }
        return lines.joined(separator: "\n")
    }
}
