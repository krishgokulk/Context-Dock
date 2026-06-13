//
//  ThumbnailGenerator.swift
//  ILauncher
//
//  Generate thumbnails for files
//

import Foundation
import AppKit
import QuickLookThumbnailing

class ThumbnailGenerator {
    static let shared = ThumbnailGenerator()

    private var thumbnailCache: [String: NSImage] = [:]
    private let cacheQueue = DispatchQueue(label: "com.ilauncher.thumbnailcache")

    private init() {}

    /// Get thumbnail for a file (cached or generated)
    func getThumbnail(for filePath: String, size: CGSize = CGSize(width: 128, height: 128), completion: @escaping (NSImage?) -> Void) {
        // Check cache first
        if let cached = getCachedThumbnail(for: filePath) {
            completion(cached)
            return
        }

        // Generate thumbnail
        generateThumbnail(for: filePath, size: size) { [weak self] thumbnail in
            if let thumbnail = thumbnail {
                self?.cacheThumbnail(thumbnail, for: filePath)
            }
            completion(thumbnail)
        }
    }

    /// Get thumbnail synchronously (returns cached or icon)
    func getThumbnailSync(for filePath: String) -> NSImage? {
        if let cached = getCachedThumbnail(for: filePath) {
            return cached
        }

        // Return file icon as fallback
        let icon = NSWorkspace.shared.icon(forFile: filePath)
        icon.size = NSSize(width: 32, height: 32)
        return icon
    }

    func cachedThumbnail(for filePath: String) -> NSImage? {
        getCachedThumbnail(for: filePath)
    }

    private func getCachedThumbnail(for filePath: String) -> NSImage? {
        return cacheQueue.sync {
            return thumbnailCache[filePath]
        }
    }

    private func cacheThumbnail(_ thumbnail: NSImage, for filePath: String) {
        cacheQueue.async { [weak self] in
            self?.thumbnailCache[filePath] = thumbnail

            // Limit cache size
            if let self = self, self.thumbnailCache.count > 200 {
                // Remove random entries
                let keysToRemove = Array(self.thumbnailCache.keys.prefix(50))
                for key in keysToRemove {
                    self.thumbnailCache.removeValue(forKey: key)
                }
            }
        }
    }

    private func generateThumbnail(for filePath: String, size: CGSize, completion: @escaping (NSImage?) -> Void) {
        let url = URL(fileURLWithPath: filePath)

        // Use QLThumbnailGenerator for modern thumbnail generation
        if #available(macOS 10.15, *) {
            let request = QLThumbnailGenerator.Request(
                fileAt: url,
                size: size,
                scale: NSScreen.main?.backingScaleFactor ?? 2.0,
                representationTypes: .thumbnail
            )

            QLThumbnailGenerator.shared.generateRepresentations(for: request) { thumbnail, type, error in
                if let error = error {
                    print("⚠️ Failed to generate thumbnail for \(filePath): \(error)")
                    completion(nil)
                    return
                }

                if let thumbnail = thumbnail {
                    let image = thumbnail.nsImage
                    DispatchQueue.main.async {
                        completion(image)
                    }
                } else {
                    DispatchQueue.main.async {
                        completion(nil)
                    }
                }
            }
        } else {
            // Fallback for older macOS
            completion(NSWorkspace.shared.icon(forFile: filePath))
        }
    }

    /// Clear thumbnail cache
    func clearCache() {
        cacheQueue.async { [weak self] in
            self?.thumbnailCache.removeAll()
            print("🗑️ Thumbnail cache cleared")
        }
    }
}
