// ClipboardImageStore.swift
// Context-Dock
//
// Sidecar blob store for clipboard image clips.
//
// Image clips used to live inside clipboard-history.json as base64 TIFF: a 50-entry
// history re-encoded and rewrote tens of megabytes on *every* clipboard change, and
// held all of it in RAM. Now the JSON keeps a file name only, the bytes live as PNG
// in clipboard-images/, and a clip loads its full data on demand (paste, OCR,
// Quick Look) while the scope list renders from the downscaled thumbnail cache.

import AppKit
import Foundation

enum ClipboardImageStore {

    static var directory: URL {
        let base =
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(
                "Library/Application Support")
        return
            base
            .appendingPathComponent("Context-Dock", isDirectory: true)
            .appendingPathComponent("clipboard-images", isDirectory: true)
    }

    static func url(for fileName: String) -> URL {
        directory.appendingPathComponent(fileName)
    }

    /// PNG is 3–10× smaller than the TIFF the pasteboard hands us, and every consumer
    /// (NSImage, Vision, CGImageSource) reads it just as happily.
    static func pngData(from raw: Data) -> Data? {
        guard let rep = NSBitmapImageRep(data: raw) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    @discardableResult
    static func write(_ data: Data, fileName: String) -> Bool {
        let target = url(for: fileName)
        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
            try data.write(to: target, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    static func read(fileName: String) -> Data? {
        try? Data(contentsOf: url(for: fileName))
    }

    static func delete(fileNames: [String]) {
        for name in fileNames where !name.isEmpty {
            try? FileManager.default.removeItem(at: url(for: name))
        }
    }

    /// Drops blobs whose entry is gone (trimmed by the history limit or the retention
    /// window). Blobs written in the last minute are spared: a clip's file lands on disk
    /// slightly before its entry records the file name, and a sweep in that window would
    /// delete the image out from under a live clip.
    static func pruneOrphans(keeping fileNames: Set<String>) {
        guard
            let contents = try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: [.contentModificationDateKey])
        else { return }
        let graceCutoff = Date().addingTimeInterval(-60)
        for url in contents where !fileNames.contains(url.lastPathComponent) {
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate
            if let modified, modified > graceCutoff { continue }
            try? FileManager.default.removeItem(at: url)
        }
    }
}

/// Serialises Vision text recognition for clipboard images. Copying a run of
/// screenshots used to launch one full-resolution `.accurate` request per clip at
/// once, which saturates the CPU while the user is still typing in the launcher.
actor ClipboardOCRQueue {
    static let shared = ClipboardOCRQueue()

    private var pending: Task<Void, Never>?

    func run(_ work: @escaping @Sendable () async -> Void) async {
        let previous = pending
        let task = Task {
            await previous?.value
            await work()
        }
        pending = task
        await task.value
    }
}
