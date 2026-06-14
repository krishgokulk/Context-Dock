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
        if loadedPath == filePath, thumbnail != nil { return }
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
        guard loadedPath != filePath || thumbnail == nil else { return }
        if let image {
            thumbnail = image
            loadedPath = filePath
        }
    }
}
