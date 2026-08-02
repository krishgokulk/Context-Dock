// FileThumbnailCache.swift
// Context-Dock
//
// Finder-quality thumbnails for list-extension rows that point at files.
//
// NSWorkspace.icon(forFile:) returns the generic type icon — every screenshot in a
// browser scope looks identical. QuickLook renders the actual image, but only
// asynchronously, and the dock's pill builder runs on the view-build path where a
// synchronous decode would stall (or re-enter) the view graph. So: serve whatever is
// cached immediately, generate the real thumbnail off-thread, and tell the caller to
// rebuild once it lands.

import AppKit
import QuickLookThumbnailing

@MainActor
final class FileThumbnailCache {
    static let shared = FileThumbnailCache()
    private init() {}

    private var cache: [String: NSImage] = [:]
    private var inFlight: Set<String> = []

    /// Types where a thumbnail says something the type icon doesn't. A PDF or image
    /// benefits; a .zip or binary just costs a QuickLook round-trip to look the same.
    private static let thumbnailExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "heic", "heif", "tiff", "bmp", "webp",
        "pdf", "mov", "mp4", "m4v", "key", "pages", "numbers", "svg",
    ]

    static func benefitsFromThumbnail(_ path: String) -> Bool {
        thumbnailExtensions.contains((path as NSString).pathExtension.lowercased())
    }

    /// Cached thumbnail if present. Otherwise kicks off generation and returns nil so
    /// the caller can fall back to the Finder icon this pass.
    func thumbnail(for path: String, size: CGFloat = 20,
                   onReady: @escaping () -> Void) -> NSImage? {
        if let cached = cache[path] { return cached }
        guard Self.benefitsFromThumbnail(path) else { return nil }
        generate(path: path, size: size, onReady: onReady)
        return nil
    }

    private func generate(path: String, size: CGFloat, onReady: @escaping () -> Void) {
        guard !inFlight.contains(path) else { return }
        inFlight.insert(path)

        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let request = QLThumbnailGenerator.Request(
            fileAt: URL(fileURLWithPath: path),
            size: CGSize(width: size, height: size),
            scale: scale,
            representationTypes: .thumbnail
        )

        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { rep, _ in
            Task { @MainActor in
                self.inFlight.remove(path)
                guard let rep else { return }
                let image = NSImage(cgImage: rep.cgImage,
                                    size: NSSize(width: size, height: size))
                self.cache[path] = image
                onReady()
            }
        }
    }
}
