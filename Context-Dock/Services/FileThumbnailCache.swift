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
import ImageIO
import PDFKit
import QuickLookThumbnailing
import SwiftUI

@MainActor
final class FileThumbnailCache {
    static let shared = FileThumbnailCache()
    private init() {}

    private var cache: [String: NSImage] = [:]
    private var inFlight: Set<String> = []
    private var waiters: [String: [() -> Void]] = [:]

    /// File types whose real content thumbnail is meaningfully richer than a generic type icon.
    private static let thumbnailExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "heic", "heif", "tiff", "bmp", "webp", "ico",
        "pdf", "rtf", "rtfd", "doc", "docx", "ppt", "pptx", "xls", "xlsx",
        "mov", "mp4", "m4v", "key", "pages", "numbers", "svg",
    ]

    static func benefitsFromThumbnail(_ path: String) -> Bool {
        let ext = (path as NSString).pathExtension.lowercased()
        return thumbnailExtensions.contains(ext)
    }

    func cachedThumbnail(for path: String) -> NSImage? {
        cache[path]
    }

    /// Cached thumbnail if present. Otherwise kicks off off-thread generation and returns nil
    /// so the caller can fall back to the Finder icon on the first frame, then swap smoothly.
    func thumbnail(for path: String, size: CGFloat = 28,
                   onReady: @escaping () -> Void) -> NSImage? {
        if let cached = cache[path] { return cached }
        guard Self.benefitsFromThumbnail(path) else { return nil }
        generate(path: path, size: max(size, 64), onReady: onReady)
        return nil
    }

    /// Synchronous helper for off-thread rendering, unit tests, and pre-warming.
    nonisolated static func renderDirectThumbnail(url: URL, maxPixelSize: CGFloat = 128) -> NSImage? {
        let ext = url.pathExtension.lowercased()
        if ext == "pdf",
            let doc = PDFDocument(url: url),
            let page = doc.page(at: 0)
        {
            let box = page.bounds(for: .mediaBox)
            let rotated = (page.rotation % 180) != 0
            let w = max(rotated ? box.height : box.width, 1)
            let h = max(rotated ? box.width : box.height, 1)
            let scale = min(maxPixelSize / w, maxPixelSize / h)
            let target = NSSize(width: max(round(w * scale), 16), height: max(round(h * scale), 16))
            return page.thumbnail(of: target, for: .mediaBox)
        }

        if let source = CGImageSourceCreateWithURL(url as CFURL, nil) {
            let opts: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            ]
            if let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, opts as CFDictionary) {
                return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
            }
        }
        return nil
    }

    private func generate(path: String, size: CGFloat, onReady: @escaping () -> Void) {
        waiters[path, default: []].append(onReady)
        guard !inFlight.contains(path) else { return }
        inFlight.insert(path)

        let url = URL(fileURLWithPath: path)
        let ext = url.pathExtension.lowercased()
        let scale = NSScreen.main?.backingScaleFactor ?? 2

        // Fast direct decode for PDFs and images so real document pages appear immediately
        // even before macOS quicklookd indexes freshly downloaded files.
        if ext == "pdf" || ["png", "jpg", "jpeg", "heic", "heif", "webp", "gif", "tiff", "bmp"].contains(ext) {
            let maxPx = size * scale
            Task.detached(priority: .userInitiated) {
                let direct = Self.renderDirectThumbnail(url: url, maxPixelSize: maxPx)
                await MainActor.run {
                    if let direct {
                        self.finish(path: path, image: direct)
                    } else {
                        self.generateViaQuickLook(url: url, path: path, size: size, scale: scale)
                    }
                }
            }
            return
        }

        generateViaQuickLook(url: url, path: path, size: size, scale: scale)
    }

    private func generateViaQuickLook(url: URL, path: String, size: CGFloat, scale: CGFloat) {
        let request = QLThumbnailGenerator.Request(
            fileAt: url,
            size: CGSize(width: size, height: size),
            scale: scale,
            representationTypes: .thumbnail
        )

        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { rep, _ in
            Task { @MainActor in
                let image = rep?.nsImage ?? Self.renderDirectThumbnail(url: url, maxPixelSize: size * scale)
                self.finish(path: path, image: image)
            }
        }
    }

    private func finish(path: String, image: NSImage?) {
        inFlight.remove(path)
        let callbacks = waiters.removeValue(forKey: path) ?? []
        guard let image else { return }
        if cache.count > 300, let oldest = cache.keys.first {
            cache.removeValue(forKey: oldest)
        }
        cache[path] = image
        for cb in callbacks { cb() }
    }
}

/// Renders a file or folder icon using its real Finder/Spotlight document page or image
/// thumbnail when available (with crisp paper edge framing), falling back to the system icon.
struct LiveFileIconView: View {
    let url: URL
    let size: CGFloat
    var fallback: NSImage? = nil
    @State private var thumbnail: NSImage?

    private var isFolderOrApp: Bool {
        let ext = url.pathExtension.lowercased()
        if ext == "app" { return true }
        return (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }

    var body: some View {
        let path = url.path
        let realThumb = isFolderOrApp ? nil : (thumbnail ?? FileThumbnailCache.shared.cachedThumbnail(for: path))
        Group {
            if let realThumb {
                let isDocPage = ["pdf", "rtf", "rtfd", "doc", "docx", "pages"].contains(url.pathExtension.lowercased())
                Image(nsImage: realThumb)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .background(isDocPage ? Color.white : Color.clear)
                    .clipShape(RoundedRectangle(cornerRadius: max(3, size * 0.13), style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: max(3, size * 0.13), style: .continuous)
                            .strokeBorder(Color.white.opacity(0.20), lineWidth: 0.5)
                    )
                    .shadow(color: .black.opacity(0.28), radius: 1.5, y: 0.5)
            } else {
                Image(nsImage: fallback ?? NSWorkspace.shared.icon(forFile: path))
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
            }
        }
        .frame(width: size, height: size)
        .task(id: path) {
            guard !isFolderOrApp else {
                thumbnail = nil
                return
            }
            if let ready = FileThumbnailCache.shared.thumbnail(for: path, size: max(size * 2, 56), onReady: {
                thumbnail = FileThumbnailCache.shared.cachedThumbnail(for: path)
            }) {
                thumbnail = ready
            }
        }
    }
}
