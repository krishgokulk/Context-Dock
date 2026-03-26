import SwiftUI
import AppKit
import Foundation

// MARK: - YouTube Search Result model

struct YouTubeSearchResult: Identifiable, Equatable {
    let id: String        // YouTube video ID
    let title: String
    let url: String       // full watch URL
    let duration: Int?    // seconds
    let channel: String?
    let thumbnail: String?
    let viewCount: Int?

    var durationString: String {
        guard let d = duration else { return "" }
        let h = d / 3600; let m = (d % 3600) / 60; let s = d % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    var viewCountString: String {
        guard let v = viewCount else { return "" }
        if v >= 1_000_000 { return String(format: "%.1fM views", Double(v) / 1_000_000) }
        if v >= 1_000    { return String(format: "%.0fK views", Double(v) / 1_000) }
        return "\(v) views"
    }
}

// MARK: - YouTube Results right-panel view

struct YouTubePanelResultsView: View {
    let results: [YouTubeSearchResult]
    @Binding var selected: YouTubeSearchResult?
    let onDownloadMP3: (YouTubeSearchResult) -> Void
    let onDownloadMP4: (YouTubeSearchResult) -> Void
    let onOpenBrowser: (YouTubeSearchResult) -> Void

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(results) { result in
                    YouTubeResultRow(
                        result: result,
                        isSelected: selected?.id == result.id,
                        onTap: { selected = result },
                        onDownloadMP3: { onDownloadMP3(result) },
                        onDownloadMP4: { onDownloadMP4(result) },
                        onOpenBrowser: { onOpenBrowser(result) }
                    )
                    Divider().opacity(0.4)
                }
            }
        }
        .scrollIndicators(.hidden)
    }
}

private struct YouTubeResultRow: View {
    let result: YouTubeSearchResult
    let isSelected: Bool
    let onTap: () -> Void
    let onDownloadMP3: () -> Void
    let onDownloadMP4: () -> Void
    let onOpenBrowser: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(alignment: .top, spacing: 8) {
                // Thumbnail
                Group {
                    if let thumbURL = result.thumbnail, let url = URL(string: thumbURL) {
                        AsyncImage(url: url) { phase in
                            switch phase {
                            case .success(let img):
                                img.resizable().aspectRatio(contentMode: .fill)
                            default:
                                thumbnailPlaceholder
                            }
                        }
                    } else {
                        thumbnailPlaceholder
                    }
                }
                .frame(width: 80, height: 45)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .overlay(alignment: .bottomTrailing) {
                    if !result.durationString.isEmpty {
                        Text(result.durationString)
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 3).padding(.vertical, 1)
                            .background(Color.black.opacity(0.75))
                            .clipShape(RoundedRectangle(cornerRadius: 2))
                            .padding(2)
                    }
                }

                // Info
                VStack(alignment: .leading, spacing: 2) {
                    Text(result.title)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)

                    HStack(spacing: 4) {
                        if let channel = result.channel {
                            Text(channel)
                                .font(.system(size: 9))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        if !result.viewCountString.isEmpty {
                            Text("·")
                                .font(.system(size: 9))
                                .foregroundStyle(.tertiary)
                            Text(result.viewCountString)
                                .font(.system(size: 9))
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(isSelected
                ? Color.accentColor.opacity(0.12)
                : Color.clear
            )
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Download as MP3") { onDownloadMP3() }
            Button("Download as MP4") { onDownloadMP4() }
            Divider()
            Button("Open in Browser") { onOpenBrowser() }
        }
    }

    private var thumbnailPlaceholder: some View {
        RoundedRectangle(cornerRadius: 4)
            .fill(Color.secondary.opacity(0.15))
            .overlay {
                Image(systemName: "play.rectangle")
                    .foregroundStyle(.secondary.opacity(0.4))
                    .font(.system(size: 18))
            }
    }
}
