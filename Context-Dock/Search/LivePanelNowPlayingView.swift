// LivePanelNowPlayingView.swift
// Context-Dock
//
// The live panel's now-playing pane: album art, track information, transport.
//
// Extracted for #25 as a reachable leaf. Its two dependencies are shared controllers rather
// than launcher state, so they come across as the observable objects they already are and
// this view keeps watching them directly.
import SwiftUI

struct LivePanelNowPlayingView: View {
    @ObservedObject var miniPlayer: MiniPlayerController
    @ObservedObject var mediaDockEngine: MediaDockEngine

    var body: some View {
        VStack(spacing: 0) {
            // Album art placeholder + info
            VStack(spacing: 0) {
                // Large album art area
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color.accentColor.opacity(0.3), Color.purple.opacity(0.2),
                                ],
                                startPoint: .topLeading, endPoint: .bottomTrailing))
                    Image(systemName: "music.note")
                        .font(.system(size: 40, weight: .thin))
                        .foregroundStyle(.white.opacity(0.4))
                }
                .frame(maxWidth: .infinity)
                .frame(height: 120)
                .padding(.horizontal, 16)
                .padding(.top, 16)

                // Track info
                VStack(spacing: 4) {
                    Text(mediaDockEngine.title.isEmpty ? "Nothing Playing" : mediaDockEngine.title)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .center)
                    Text(mediaDockEngine.artist.isEmpty ? "—" : mediaDockEngine.artist)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if !mediaDockEngine.album.isEmpty {
                        Text(mediaDockEngine.album)
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 8)

                // Now playing source badge
                if let info = miniPlayer.playerInfo {
                    HStack(spacing: 4) {
                        Circle().fill(Color.green).frame(width: 5, height: 5)
                        Text("via \(info.toolName)")
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.bottom, 4)
                }

                Divider().padding(.horizontal, 16).padding(.vertical, 6)

                // Playback controls
                HStack(spacing: 0) {
                    Spacer()
                    Button {
                        mediaDockEngine.previous()
                    } label: {
                        Image(systemName: "backward.fill")
                            .font(.system(size: 18))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    Spacer()
                    Button {
                        mediaDockEngine.togglePlayPause()
                    } label: {
                        Image(
                            systemName: mediaDockEngine.isPlaying
                                ? "pause.circle.fill" : "play.circle.fill"
                        )
                        .font(.system(size: 36))
                        .foregroundStyle(Color.accentColor)
                    }
                    .buttonStyle(.plain)
                    Spacer()
                    Button {
                        mediaDockEngine.next()
                    } label: {
                        Image(systemName: "forward.fill")
                            .font(.system(size: 18))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)

                Button {
                    mediaDockEngine.stop()
                } label: {
                    Label("Stop Playback", systemImage: "stop.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .padding(.bottom, 12)
            }
            .frame(maxWidth: .infinity)

            Spacer()
        }
        .onAppear {
            mediaDockEngine.startAutoRefresh()
        }
        .onDisappear {
            mediaDockEngine.stopAutoRefresh()
        }
    }
}
