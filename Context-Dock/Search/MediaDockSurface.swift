import AppKit
import SwiftUI

struct MediaDockSurface: View {
    @ObservedObject var mediaObserver: MediaPlayerObserver

    private var progress: Double {
        mediaObserver.duration > 0
        ? min(max(mediaObserver.elapsed / max(mediaObserver.duration, 1), 0), 1)
        : 0
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
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                transportControls
                    .frame(minWidth: 184, alignment: .leading)

                artworkView
                    .frame(width: 38, height: 38)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                VStack(alignment: .leading, spacing: 2) {
                    Text(
                        mediaObserver.title.isEmpty
                            ? (mediaObserver.appName.isEmpty ? "Now Playing" : mediaObserver.appName)
                            : mediaObserver.title
                    )
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                    Text(mediaObserver.artist.isEmpty ? mediaObserver.appName : mediaObserver.artist)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: 12) {
                    iconButton(systemName: "ellipsis") {}
                    iconButton(systemName: "quote.bubble", disabled: true) {}
                    iconButton(systemName: "list.bullet", disabled: true) {}
                    iconButton(systemName: "speaker.wave.2.fill", disabled: true) {}
                }
                .frame(minWidth: 148, alignment: .trailing)
            }
            .padding(.horizontal, 18)
            .frame(height: 58)

            if mediaObserver.duration > 0 {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Color.white.opacity(0.16))
                        Capsule()
                            .fill(Color.white.opacity(0.72))
                            .frame(width: max(6, geo.size.width * CGFloat(progress)))
                    }
                }
                .frame(height: 3)
                .padding(.horizontal, 18)
                .padding(.bottom, 8)
                .animation(.linear(duration: 0.25), value: mediaObserver.elapsed)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: mediaObserver.duration > 0 ? 70 : 58)
        .background(glassBackground)
        .id("media-dock-surface")
    }

    private var transportControls: some View {
        HStack(spacing: 10) {
            iconButton(systemName: "shuffle", disabled: true) {}
            iconButton(systemName: "backward.fill") {
                mediaObserver.skipBack()
            }
            Button {
                mediaObserver.togglePlayPause()
            } label: {
                Image(systemName: mediaObserver.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(
                        Color.accentColor,
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                    )
                    .shadow(color: Color.accentColor.opacity(0.35), radius: 8, y: 2)
            }
            .buttonStyle(.plain)
            .help(mediaObserver.isPlaying ? "Pause" : "Play")
            iconButton(systemName: "forward.fill") {
                mediaObserver.skipForward()
            }
            iconButton(systemName: "repeat", disabled: true) {}
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
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.white.opacity(0.08))
                .overlay(
                    Image(systemName: "music.note")
                        .font(.system(size: 15, weight: .semibold))
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
                        colors: [Color.white.opacity(0.58), Color.white.opacity(0.06)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1.5
                )
            Capsule()
                .strokeBorder(Color.white.opacity(0.75), lineWidth: 1.5)
                .blur(radius: 3)
        }
    }

    private func iconButton(
        systemName: String,
        disabled: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(
                    disabled ? Color.secondary.opacity(0.45) : Color.primary.opacity(0.86)
                )
                .frame(width: 24, height: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
    }
}

extension LauncherView {
    @ViewBuilder
    var mediaDockSurface: some View {
        MediaDockSurface(mediaObserver: mediaObserver)
    }
}
