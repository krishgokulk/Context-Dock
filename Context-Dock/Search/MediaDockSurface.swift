import AppKit
import SwiftUI

/// Now-Playing widget for the Media Dock. Mirrors the macOS Control Center
/// layout: artwork · title/artist + scrubber + time · transport. Fixed height
/// so switching into/out of the Media Dock animates smoothly with the unified
/// shell instead of jumping between sizes.
struct MediaDockSurface: View {
    @ObservedObject var mediaObserver: MediaPlayerObserver

    /// One constant height — drives both the surface and the dock-height resolver
    /// so the panel never resizes when a track gains/loses a duration. Kept close
    /// to the search-bar pill so the Media Dock matches the other dock surfaces.
    static let surfaceHeight: CGFloat = 60

    private var progress: Double {
        mediaObserver.duration > 0
            ? min(max(mediaObserver.elapsed / max(mediaObserver.duration, 1), 0), 1)
            : 0
    }

    private var displayTitle: String {
        if !mediaObserver.title.isEmpty { return mediaObserver.title }
        return mediaObserver.appName.isEmpty ? "Now Playing" : mediaObserver.appName
    }

    private var displaySubtitle: String {
        if !mediaObserver.artist.isEmpty { return mediaObserver.artist }
        return mediaObserver.appName
    }

    private var resolvedMediaIcon: NSImage? {
        mediaObserver.appIcon
            ?? {
                guard !mediaObserver.appName.isEmpty else { return nil }
                let name = mediaObserver.appName.lowercased()
                return NSWorkspace.shared.runningApplications
                    .first(where: { ($0.localizedName ?? "").lowercased() == name })?.icon
            }()
    }

    var body: some View {
        HStack(spacing: 12) {
            artworkView
                .frame(width: 46, height: 46)
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                Text(displayTitle)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Text(displaySubtitle)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                if mediaObserver.duration > 0 {
                    scrubber
                        .padding(.top, 2)
                        .animation(.linear(duration: 0.25), value: mediaObserver.elapsed)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            transportControls
        }
        .padding(.horizontal, 16)
        .frame(height: Self.surfaceHeight)
        .frame(maxWidth: .infinity)
        .background(glassBackground)
        .id("media-dock-surface")
    }

    private var scrubber: some View {
        VStack(spacing: 3) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.16))
                    Capsule()
                        .fill(Color.white.opacity(0.82))
                        .frame(width: max(4, geo.size.width * CGFloat(progress)))
                }
            }
            .frame(height: 3)

            HStack {
                Text(Self.timeString(mediaObserver.elapsed))
                Spacer()
                Text("-" + Self.timeString(max(0, mediaObserver.duration - mediaObserver.elapsed)))
            }
            .font(.system(size: 9, weight: .medium).monospacedDigit())
            .foregroundStyle(.secondary)
        }
    }

    private var transportControls: some View {
        HStack(spacing: 8) {
            iconButton(systemName: "backward.fill", size: 15) {
                mediaObserver.skipBack()
            }
            Button {
                mediaObserver.togglePlayPause()
            } label: {
                Image(systemName: mediaObserver.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 34)
                    .background(Color.accentColor, in: Circle())
                    .shadow(color: Color.accentColor.opacity(0.35), radius: 7, y: 2)
            }
            .buttonStyle(.plain)
            .help(mediaObserver.isPlaying ? "Pause" : "Play")
            iconButton(systemName: "forward.fill", size: 15) {
                mediaObserver.skipForward()
            }
        }
    }

    @ViewBuilder
    private var artworkView: some View {
        if let art = mediaObserver.artworkImage {
            Image(nsImage: art)
                .resizable()
                .aspectRatio(contentMode: .fill)
        } else if let icon = resolvedMediaIcon {
            Image(nsImage: icon)
                .resizable()
                .aspectRatio(contentMode: .fit)
        } else {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color.white.opacity(0.08))
                .overlay(
                    Image(systemName: "music.note")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.secondary)
                )
        }
    }

    private var glassBackground: some View {
        ZStack {
            Capsule().fill(.ultraThinMaterial)
            Capsule()
                .fill(
                    LinearGradient(
                        colors: [Color.white.opacity(0.18), Color.white.opacity(0.035)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
            Capsule()
                .strokeBorder(
                    LinearGradient(
                        colors: [Color.white.opacity(0.45), Color.white.opacity(0.06)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
        }
    }

    private func iconButton(
        systemName: String,
        size: CGFloat = 16,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(Color.primary.opacity(0.86))
                .frame(width: 26, height: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// mm:ss (or h:mm:ss for long media).
    static func timeString(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds.rounded())
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%d:%02d", m, s)
    }
}

extension LauncherView {
    @ViewBuilder
    var mediaDockSurface: some View {
        MediaDockSurface(mediaObserver: mediaObserver)
    }
}
