import AppKit
import SwiftUI

struct FileThumbnailImage: View {
    let filePath: String?
    let fallbackImage: NSImage?
    let systemName: String
    let tint: Color
    var size: CGFloat = 28
    var cornerRadius: CGFloat = 5
    var isApplication: Bool = false

    @State private var thumbnail: NSImage?
    @State private var loadedPath: String?

    var body: some View {
        Group {
            if let image = thumbnail ?? fallbackImage {
                Image(nsImage: image)
                    .resizable()
                    .renderingMode(.original)
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: size, height: size)
                    .clipShape(
                        RoundedRectangle(
                            cornerRadius: isApplication ? max(cornerRadius, 8) : cornerRadius,
                            style: .continuous
                        )
                    )
            } else {
                Image(systemName: systemName)
                    .font(.system(size: max(14, size * 0.62), weight: .semibold))
                    .symbolRenderingMode(.multicolor)
                    .foregroundStyle(tint)
                    .frame(width: size, height: size)
            }
        }
        .task(id: thumbnailTaskKey) {
            await loadThumbnailIfNeeded()
        }
    }

    private var thumbnailTaskKey: String {
        filePath ?? ""
    }

    private func loadThumbnailIfNeeded() async {
        guard let filePath, !filePath.isEmpty, !isApplication else { return }
        guard FileManager.default.fileExists(atPath: filePath) else { return }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: filePath, isDirectory: &isDirectory),
            !isDirectory.boolValue
        else { return }

        // Finder Desktop keeps thousands of indexed rows icon-free so search stays fast.
        // Resolve the real LaunchServices file icon only when a row becomes visible; this
        // replaces the semantic placeholder immediately while Quick Look works in the
        // background on a richer preview for image/document types that support one.
        if loadedPath != filePath {
            thumbnail = NSWorkspace.shared.icon(forFile: filePath)
            loadedPath = filePath
        }
        if let cached = ThumbnailGenerator.shared.cachedThumbnail(for: filePath) {
            thumbnail = cached
            loadedPath = filePath
            return
        }
        let thumbnailSize = max(CGFloat(96), size * 4)
        let image = await withCheckedContinuation { continuation in
            ThumbnailGenerator.shared.getThumbnail(
                for: filePath,
                size: CGSize(width: thumbnailSize, height: thumbnailSize)
            ) { thumb in
                continuation.resume(returning: thumb)
            }
        }
        if let image {
            thumbnail = image
            loadedPath = filePath
        }
    }
}
