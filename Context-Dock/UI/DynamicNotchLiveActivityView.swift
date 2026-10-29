// DynamicNotchLiveActivityView.swift
// Context-Dock
//
// Live Activity view for the MacBook notch Dynamic Island, referencing
// NotchNook's now-playing/file-tray and Pinterest's AI thinking/context indicators.

import AppKit
import SwiftUI

struct DynamicNotchLiveActivityView: View {
    @ObservedObject var prompt: AppChatPromptModel
    @ObservedObject private var actionFeedback = CornerActionFeedback.shared
    @ObservedObject private var mediaObserver = MediaPlayerObserver.shared
    @ObservedObject private var shelf = DropShelfController.shared.presentation

    var onExpand: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            if let running = actionFeedback.progressTitle ?? (actionFeedback.current?.phase == .progress ? actionFeedback.current?.title : nil) {
                // Pinterest AI Live Activity mode (e.g. "Read app-sidebar.tsx 219 lines" / "Thinking")
                aiThinkingContent(running: running)
            } else if mediaObserver.isPlaying && !mediaObserver.title.isEmpty {
                // NotchNook Music Live Activity mode (Lo-fi Nights / waveform equalizer)
                mediaContent(title: mediaObserver.title)
            } else if shelf.phase != .collapsed {
                // NotchNook Tray mode ("Drop files here")
                trayContent
            } else {
                // Default Dynamic Island Prompt mode ("Ask Antigravity...")
                defaultPromptContent
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .onTapGesture {
            onExpand()
        }
        .animation(.spring(response: 0.36, dampingFraction: 0.82), value: actionFeedback.progressTitle)
        .animation(.spring(response: 0.36, dampingFraction: 0.82), value: mediaObserver.isPlaying)
        .animation(.spring(response: 0.36, dampingFraction: 0.82), value: shelf.phase)
    }

    // MARK: - Pinterest AI Live Activity

    private func aiThinkingContent(running: String) -> some View {
        HStack(spacing: 9) {
            // Pulsing AI status indicator icon
            ZStack {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Color.orange.opacity(0.85))
                    .frame(width: 14, height: 14)
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .stroke(Color.white.opacity(0.4), lineWidth: 1)
                    .frame(width: 14, height: 14)
            }
            .shadow(color: .orange.opacity(0.6), radius: 4)

            VStack(alignment: .leading, spacing: 1) {
                if let subtitle = actionFeedback.current?.subject, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 11, weight: .regular))
                        .foregroundStyle(.white.opacity(0.65))
                        .lineLimit(1)
                }
                Text(running)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
            }
        }
    }

    // MARK: - NotchNook Media Live Activity

    private func mediaContent(title: String) -> some View {
        HStack(spacing: 8) {
            if let art = mediaObserver.artworkImage {
                Image(nsImage: art)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 22, height: 22)
                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            } else {
                Image(systemName: "music.note")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.pink)
                    .frame(width: 22, height: 22)
                    .background(Color.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 5))
            }

            VStack(alignment: .leading, spacing: 0) {
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                if !mediaObserver.artist.isEmpty {
                    Text(mediaObserver.artist)
                        .font(.system(size: 10, weight: .regular))
                        .foregroundStyle(.white.opacity(0.6))
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 4)

            // Equalizer waveform bars
            EqualizerBarsView(isPlaying: mediaObserver.isPlaying)
        }
    }

    // MARK: - NotchNook Tray / Drop Shelf

    private var trayContent: some View {
        HStack(spacing: 7) {
            Image(systemName: "tray.and.arrow.down.fill")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.cyan)
            Text("Drop files here")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.85))
        }
    }

    // MARK: - Default Spotlight Prompt

    private var defaultPromptContent: some View {
        HStack(spacing: 7) {
            Image(systemName: "sparkles")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.cyan)
            Text("Ask Antigravity…")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.7))
            Spacer(minLength: 0)
        }
    }
}

/// Animated equalizer waveform bars seen in NotchNook Pro.
struct EqualizerBarsView: View {
    var isPlaying: Bool
    @State private var wave = false

    var body: some View {
        HStack(spacing: 2) {
            bar(height: wave ? 14 : 6, delay: 0.0)
            bar(height: wave ? 8 : 14, delay: 0.15)
            bar(height: wave ? 16 : 8, delay: 0.3)
            bar(height: wave ? 10 : 16, delay: 0.1)
        }
        .frame(height: 16)
        .onAppear {
            if isPlaying {
                withAnimation(.easeInOut(duration: 0.45).repeatForever(autoreverses: true)) {
                    wave = true
                }
            }
        }
        .onChange(of: isPlaying) { playing in
            if playing {
                withAnimation(.easeInOut(duration: 0.45).repeatForever(autoreverses: true)) {
                    wave = true
                }
            } else {
                wave = false
            }
        }
    }

    private func bar(height: CGFloat, delay: Double) -> some View {
        RoundedRectangle(cornerRadius: 1)
            .fill(LinearGradient(colors: [.pink, .purple], startPoint: .top, endPoint: .bottom))
            .frame(width: 2.5, height: height)
    }
}
