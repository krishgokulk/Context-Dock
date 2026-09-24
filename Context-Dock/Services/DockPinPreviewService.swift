// DockPinPreviewService.swift
// Context-Dock
//
// The filesystem half of the pin preview: what is actually on disk behind a pinned file or
// folder, and the QuickLook thumbnail for it. The rules live in `DockPinPreview`; this reads.
//
// Shaped like `AppWindowSnapshotService` on purpose — the app half of the same hover — so
// there is one pattern for "the card above the strip asks something slow for a picture":
// published cache keyed by what is being shown, one read in flight, a short freshness so
// walking the strip does not hammer the disk, and an absent answer that draws as itself
// rather than as an empty frame.

import AppKit
import Combine
import Foundation

@MainActor
final class DockPinPreviewService: ObservableObject {
    static let shared = DockPinPreviewService()

    @Published private(set) var previews: [UUID: DockPinPreview] = [:]
    @Published private(set) var thumbnails: [String: NSImage] = [:]

    private var inFlight: Set<UUID> = []
    private var lastRead: [UUID: Date] = [:]
    /// Long enough that hovering along the pins does not re-read every folder, short enough
    /// that a file saved a moment ago shows its new size.
    private static let freshness: TimeInterval = 3

    private init() {}

    func preview(for pin: DockPin) -> DockPinPreview? { previews[pin.id] }
    func thumbnail(for path: String) -> NSImage? { thumbnails[path] }

    func refresh(pin: DockPin, document: GlobalSearchService.SearchDocument?) {
        switch pin.kind {
        case .globalCommand, .cliTool:
            // Nothing to read: what a command is, the search document already says.
            previews[pin.id] = Self.documentPreview(pin: pin, document: document)
            return
        case .app:
            return  // apps answer with their windows, not with a card
        case .file, .folder:
            break
        }
        guard !inFlight.contains(pin.id) else { return }
        if let last = lastRead[pin.id], Date().timeIntervalSince(last) < Self.freshness { return }
        inFlight.insert(pin.id)

        let kind = pin.kind
        let id = pin.id
        Task { [weak self] in
            let preview = await Self.read(kind)
            guard let self else { return }
            self.inFlight.remove(id)
            self.lastRead[id] = Date()
            self.previews[id] = preview
            if case .file(let detail) = preview { self.loadThumbnail(path: detail.path) }
        }
    }

    private func loadThumbnail(path: String) {
        guard thumbnails[path] == nil else { return }
        ThumbnailGenerator.shared.getThumbnail(
            for: path, size: DockPinPreviewMetrics.thumb
        ) { [weak self] image in
            guard let image else { return }
            Task { @MainActor in self?.thumbnails[path] = image }
        }
    }

    private static func documentPreview(
        pin: DockPin, document: GlobalSearchService.SearchDocument?
    ) -> DockPinPreview {
        guard let document else {
            return .missing(name: pin.title, reason: "Not available in this build")
        }
        let subtitle = document.subtitle.isEmpty ? nil : document.subtitle
        switch pin.kind {
        case .cliTool:
            return .document(
                DockPinPreview.DocumentDetail(
                    title: document.title, subtitle: subtitle ?? "Command-line tool",
                    symbol: "terminal"))
        default:
            return .document(
                DockPinPreview.DocumentDetail(
                    title: document.title, subtitle: subtitle ?? "Global command",
                    symbol: "command"))
        }
    }

    /// Off the main actor: `contentsOfDirectory` on a large folder is not instant, and this
    /// runs while the pointer is moving.
    private static func read(_ kind: DockPinKind) async -> DockPinPreview {
        await Task.detached(priority: .userInitiated) { () -> DockPinPreview in
            let manager = FileManager.default
            switch kind {
            case .file(let path):
                let url = URL(fileURLWithPath: path)
                guard manager.fileExists(atPath: path) else {
                    return .missing(name: url.lastPathComponent, reason: "Moved or deleted")
                }
                let values = try? url.resourceValues(forKeys: [
                    .localizedTypeDescriptionKey, .fileSizeKey, .contentModificationDateKey,
                ])
                return .file(
                    DockPinPreview.FileDetail(
                        path: path, name: url.lastPathComponent,
                        kindName: values?.localizedTypeDescription ?? "File",
                        byteCount: values?.fileSize.map(Int64.init),
                        modified: values?.contentModificationDate))
            case .folder(let path):
                let url = URL(fileURLWithPath: path)
                var isDirectory: ObjCBool = false
                guard manager.fileExists(atPath: path, isDirectory: &isDirectory),
                    isDirectory.boolValue
                else {
                    return .missing(name: url.lastPathComponent, reason: "Moved or deleted")
                }
                // Only that it is there. The browser reads what is in it.
                return .folder(
                    DockPinPreview.FolderDetail(path: path, name: url.lastPathComponent))
            case .app, .globalCommand, .cliTool:
                return .missing(name: "", reason: "")
            }
        }.value
    }
}
