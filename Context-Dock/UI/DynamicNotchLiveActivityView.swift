// DynamicNotchLiveActivityView.swift
// Context-Dock
//
// Pixel-perfect Dynamic Island notch experience referencing Drooppy and DynamicBar.
// Auto-adjusts to MacBooks with hardware notch (M2/M3/M4) or notchless external displays:
// - Jet-black Apple hardware finish merging with the camera bezel
// - Seamless top concave ear flares (zero stroke line at the top bezel)
// - Page 0: Now Playing / Music playback controls & scrubber (Drooppy parity)
// - Page 1: Drop Shelf staged items grid with thumbnails & "Clear" button (Drooppy parity)
// - Page 2: Ask Antigravity AI Prompt & Search
// - Interactive page indicator dots (• • •)
// - Smooth hover swell and spring-driven expansion

import AppKit
import Combine
import SwiftUI

@MainActor
final class DynamicNotchState: ObservableObject {
    static let shared = DynamicNotchState()

    @Published var isExpanded: Bool = false
    @Published var selectedPage: Int = 0
    @Published var dragOffset: CGFloat = 0

    private var accumulatedScroll: CGFloat = 0
    private var isTrackingScroll = false

    func toggleExpand() {
        withAnimation(.spring(response: 0.38, dampingFraction: 0.82)) {
            isExpanded.toggle()
        }
    }

    func expand(page: Int? = nil) {
        withAnimation(.spring(response: 0.38, dampingFraction: 0.82)) {
            isExpanded = true
            if let page { selectedPage = page }
        }
    }

    func collapse() {
        withAnimation(.spring(response: 0.38, dampingFraction: 0.82)) {
            isExpanded = false
            dragOffset = 0
        }
    }

    /// Handles two-finger trackpad horizontal swipe gestures with real-time feedback and spring snapping
    func handleTrackpadScroll(dx: CGFloat, phase: NSEvent.Phase) {
        if phase.contains(.began) {
            accumulatedScroll = 0
            isTrackingScroll = true
        }

        if phase.contains(.changed) || (phase == [] && isTrackingScroll) {
            accumulatedScroll += dx
            let translation = accumulatedScroll
            // Resistance / rubber-band at outer edges
            if (selectedPage == 0 && translation > 0) || (selectedPage == 2 && translation < 0) {
                dragOffset = translation * 0.25
            } else {
                dragOffset = translation
            }
        }

        if phase.contains(.ended) || phase.contains(.cancelled) {
            isTrackingScroll = false
            let threshold: CGFloat = 35
            withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) {
                if accumulatedScroll < -threshold && selectedPage < 2 {
                    selectedPage += 1
                } else if accumulatedScroll > threshold && selectedPage > 0 {
                    selectedPage -= 1
                }
                dragOffset = 0
            }
            accumulatedScroll = 0
        }
    }
}

struct DynamicNotchLiveActivityView: View {
    @ObservedObject var prompt: AppChatPromptModel
    @ObservedObject private var actionFeedback = CornerActionFeedback.shared
    @ObservedObject private var mediaObserver = MediaPlayerObserver.shared
    @ObservedObject private var shelf = DropShelfController.shared.presentation
    @ObservedObject private var shelfStore = DropShelfStore.shared
    @ObservedObject private var notchState = DynamicNotchState.shared
    @ObservedObject private var approvalCenter = ApprovalCenter.shared

    var onExpand: () -> Void

    @State private var isHovered = false
    @State private var hoverExpandWorkItem: DispatchWorkItem?
    @State private var hoverCollapseWorkItem: DispatchWorkItem?

    private var isExpanded: Bool {
        notchState.isExpanded
    }

    private var selectedPage: Int {
        get { notchState.selectedPage }
        nonmutating set { notchState.selectedPage = newValue }
    }

    private var activeScreen: NSScreen {
        ScreenNotchMetrics.activeScreen
    }

    private var hasNotch: Bool {
        ScreenNotchMetrics.hasHardwareNotch(on: activeScreen)
    }

    private var notchRect: CGRect {
        ScreenNotchMetrics.notchRect(on: activeScreen)
    }

    private var notchH: CGFloat {
        max(ScreenNotchMetrics.notchHeight(on: activeScreen), 32)
    }

    private var hasActiveStatus: Bool {
        mediaObserver.isPlaying || shelfStore.items.count > 0 || actionFeedback.progressTitle != nil
    }

    private var islandWidth: CGFloat {
        if isExpanded {
            return 384
        }
        if !hasNotch {
            return isHovered ? 180 : 160
        }
        // At rest with physical notch:
        let showWings = hasActiveStatus || isHovered || !AppSettings.shared.notchCompactIslandAtRest
        if showWings {
            let baseW = notchRect.width + 104 // 52pt per wing outside camera cutout
            return baseW + (isHovered ? 6 : 0)
        } else {
            // Flush with camera notch cutout + small bezel transition
            return notchRect.width + 24
        }
    }

    private var currentCornerRadius: CGFloat {
        isExpanded ? 22 : (hasNotch ? 12 : 18)
    }

    private var currentEarRadius: CGFloat {
        isExpanded ? 14 : 10
    }

    private var islandHeight: CGFloat {
        if isExpanded {
            return 182
        }
        return notchH + (isHovered ? 3.0 : 0.0)
    }

    /// Resolves the actual macOS application icon for the source media player (Spotify, Apple Music, Safari, etc.)
    private var resolvedAppIcon: NSImage? {
        if let icon = mediaObserver.appIcon {
            return icon
        }
        let running = NSWorkspace.shared.runningApplications
        if mediaObserver.appName.localizedCaseInsensitiveContains("Spotify") ||
           running.contains(where: { $0.bundleIdentifier == "com.spotify.client" }) {
            return running.first(where: { $0.bundleIdentifier == "com.spotify.client" })?.icon
                ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.spotify.client").map { NSWorkspace.shared.icon(forFile: $0.path) }
        }
        if mediaObserver.appName.localizedCaseInsensitiveContains("Music") ||
           running.contains(where: { $0.bundleIdentifier == "com.apple.Music" }) {
            return running.first(where: { $0.bundleIdentifier == "com.apple.Music" })?.icon
                ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Music").map { NSWorkspace.shared.icon(forFile: $0.path) }
        }
        return nil
    }

    var body: some View {
        ZStack(alignment: .top) {
            islandBackground

            Group {
                if isExpanded {
                    expandedContent
                        .transition(
                            .asymmetric(
                                insertion: .opacity.combined(with: .scale(scale: 0.94, anchor: .top)),
                                removal: .opacity.animation(.easeIn(duration: 0.12))
                            )
                        )
                } else {
                    restingContent
                        .contentShape(Rectangle())
                        .onTapGesture {
                            withAnimation(.spring(response: 0.38, dampingFraction: 0.82)) {
                                notchState.expand()
                                if shelfStore.items.count > 0 {
                                    notchState.selectedPage = 1
                                } else if mediaObserver.isPlaying {
                                    notchState.selectedPage = 0
                                }
                            }
                        }
                        .transition(.opacity)
                }
            }
            .clipShape(DynamicIslandNotchShape(cornerRadius: currentCornerRadius, earRadius: currentEarRadius, hasNotch: hasNotch))
        }
        .frame(width: islandWidth, height: islandHeight, alignment: .top)
        .contentShape(DynamicIslandNotchShape(cornerRadius: currentCornerRadius, earRadius: currentEarRadius, hasNotch: hasNotch))
        .onHover { hovering in
            withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) {
                isHovered = hovering
            }
        }
        .dropShelfTarget(shelf)
        .onChange(of: shelfStore.items.count) { _, newCount in
            if newCount > 0 && !notchState.isExpanded {
                withAnimation(.spring(response: 0.38, dampingFraction: 0.82)) {
                    notchState.expand(page: 1)
                }
            }
        }
        .animation(.spring(response: 0.36, dampingFraction: 0.82), value: isExpanded)
        .animation(.spring(response: 0.36, dampingFraction: 0.82), value: isHovered)
        .animation(.spring(response: 0.36, dampingFraction: 0.82), value: selectedPage)
    }

    // MARK: - Island Background (Liquid Glass + Apple Pitch Black + Bezel Flare)

    @ViewBuilder
    private var islandBackground: some View {
        let shape = DynamicIslandNotchShape(
            cornerRadius: currentCornerRadius,
            earRadius: currentEarRadius,
            hasNotch: hasNotch
        )
        let rect = CGRect(origin: .zero, size: CGSize(width: islandWidth, height: islandHeight))
        let darkness = AppSettings.shared.glassDarkness

        ZStack {
            // Apple hardware jet-black core — identical to physical camera notch bezel
            shape
                .fill(Color.black.opacity(isExpanded ? (0.85 + darkness * 0.13) : 0.995))

            // Specular perimeter outline along ears, sides, and bottom (never at top bezel)
            shape.outlinePath(in: rect)
                .stroke(
                    shelf.isDragOverIcon
                        ? Color.accentColor.opacity(0.9)
                        : Color.white.opacity(isHovered ? 0.22 : 0.12),
                    lineWidth: shelf.isDragOverIcon ? 1.5 : 0.75
                )
        }
        .shadow(
            color: .black.opacity(isExpanded ? 0.45 : 0.20),
            radius: isExpanded ? 14 : 4,
            y: isExpanded ? 6 : 1
        )
    }

    // MARK: - Resting Content (Closed Island)

    @ViewBuilder
    private var restingContent: some View {
        let wingW: CGFloat = 44
        let showWings = hasActiveStatus || isHovered || !AppSettings.shared.notchCompactIslandAtRest

        HStack(spacing: 0) {
            // Left wing
            HStack(spacing: 4) {
                if showWings {
                    if shelfStore.items.count > 0 {
                        Image(systemName: "tray.fill")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.cyan)
                        Text("\(shelfStore.items.count)")
                            .font(.system(size: 11, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                    } else if mediaObserver.isPlaying || !mediaObserver.title.isEmpty {
                        // Show source app icon on the left side while media is playing
                        if let icon = resolvedAppIcon {
                            Image(nsImage: icon)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(width: 15, height: 15)
                                .clipShape(RoundedRectangle(cornerRadius: 3.5, style: .continuous))
                        } else {
                            Image(systemName: "music.note")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(.pink)
                        }
                    } else if let running = actionFeedback.progressTitle {
                        Circle().fill(Color.orange).frame(width: 6, height: 6)
                        Text(running).font(.system(size: 10, weight: .medium)).lineLimit(1).foregroundStyle(.white)
                    } else {
                        Image(systemName: "sparkles")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(isHovered ? .cyan : .white.opacity(0.6))
                    }
                }
            }
            .frame(width: wingW, height: notchH, alignment: .center)
            .padding(.leading, 8)

            Spacer(minLength: 0)

            // Right wing
            HStack(spacing: 4) {
                if showWings {
                    if mediaObserver.isPlaying {
                        EqualizerBarsView(isPlaying: true)
                    } else if shelfStore.items.count > 0 {
                        Image(systemName: "arrow.down.to.line")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.cyan)
                    } else {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(isHovered ? .white : .white.opacity(0.4))
                    }
                }
            }
            .frame(width: wingW, height: notchH, alignment: .center)
            .padding(.trailing, 8)
        }
        .frame(width: islandWidth, height: notchH)
    }

    // MARK: - Expanded Content (DynamicBar & Drooppy Parity)

    @ViewBuilder
    private var expandedContent: some View {
        let pageWidth: CGFloat = islandWidth - 44

        VStack(spacing: 0) {
            // 1. Safe area clearance strictly matching the physical camera notch depth
            Color.clear
                .frame(height: max(notchH, 32) + 4)

            // 2. Interactive Sliding Page Carousel (Smooth Drag & Swipe Switching)
            GeometryReader { geo in
                HStack(alignment: .top, spacing: 0) {
                    mediaPage
                        .frame(width: pageWidth)
                    dropShelfPage
                        .frame(width: pageWidth)
                    launcherPage
                        .frame(width: pageWidth)
                }
                .frame(width: pageWidth * 3, alignment: .leading)
                .offset(x: -CGFloat(selectedPage) * pageWidth + notchState.dragOffset)
                .animation(.spring(response: 0.35, dampingFraction: 0.82), value: selectedPage)
            }
            .frame(width: pageWidth, height: 96)
            .clipped()
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 10)
                    .onChanged { value in
                        let translation = value.translation.width
                        if (selectedPage == 0 && translation > 0) || (selectedPage == 2 && translation < 0) {
                            notchState.dragOffset = translation * 0.25
                        } else {
                            notchState.dragOffset = translation
                        }
                    }
                    .onEnded { value in
                        let translation = value.translation.width
                        let velocity = value.predictedEndTranslation.width - value.translation.width
                        let totalMove = translation + velocity * 0.25
                        let threshold: CGFloat = 35

                        withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) {
                            if totalMove < -threshold && selectedPage < 2 {
                                selectedPage += 1
                            } else if totalMove > threshold && selectedPage > 0 {
                                selectedPage -= 1
                            }
                            notchState.dragOffset = 0
                        }
                    }
            )

            Spacer(minLength: 4)

            // 3. Page Indicator Dots (DynamicBar / Drooppy Parity)
            HStack(spacing: 6) {
                ForEach(0..<3) { index in
                    pageDot(index: index)
                }
            }
            .frame(height: 12)
            .padding(.bottom, 6)
        }
        .frame(width: islandWidth, height: islandHeight, alignment: .top)
    }

    private func pageDot(index: Int) -> some View {
        Capsule()
            .fill(selectedPage == index ? Color.white : Color.white.opacity(0.3))
            .frame(width: selectedPage == index ? 14 : 5, height: 5)
            .animation(.spring(response: 0.3, dampingFraction: 0.8), value: selectedPage)
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
                    notchState.selectedPage = index
                }
            }
    }

    // MARK: - Page 0: Media Player (Drooppy & DynamicBar Parity)

    private var mediaPage: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                // 34x34 Album art with source app badge at bottom-right
                ZStack(alignment: .bottomTrailing) {
                    if let art = mediaObserver.artworkImage {
                        Image(nsImage: art)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: 34, height: 34)
                            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))

                        if let icon = resolvedAppIcon {
                            Image(nsImage: icon)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(width: 13, height: 13)
                                .clipShape(Circle())
                                .overlay(Circle().stroke(Color.black, lineWidth: 1.5))
                                .offset(x: 2, y: 2)
                        }
                    } else if let icon = resolvedAppIcon {
                        Image(nsImage: icon)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 34, height: 34)
                            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                    } else {
                        ZStack {
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(LinearGradient(colors: [.pink.opacity(0.85), .purple.opacity(0.85)], startPoint: .topLeading, endPoint: .bottomTrailing))
                                .frame(width: 34, height: 34)
                            Image(systemName: "music.note")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(.white)
                        }
                    }
                }

                // Title and Artist with Source App Icon
                VStack(alignment: .leading, spacing: 2) {
                    Text(mediaObserver.title.isEmpty ? "Not Playing" : mediaObserver.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)

                    HStack(spacing: 4) {
                        if let icon = resolvedAppIcon {
                            Image(nsImage: icon)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(width: 11, height: 11)
                                .clipShape(RoundedRectangle(cornerRadius: 2.5, style: .continuous))
                        }
                        Text(mediaObserver.artist.isEmpty ? (mediaObserver.appName.isEmpty ? "Open Music or Spotify" : mediaObserver.appName) : "\(mediaObserver.artist)\(mediaObserver.appName.isEmpty ? "" : " • " + mediaObserver.appName)")
                            .font(.system(size: 11, weight: .regular))
                            .foregroundStyle(.white.opacity(0.65))
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 0)

                Button {
                    let target = (mediaObserver.appName.localizedCaseInsensitiveContains("Spotify") || NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == "com.spotify.client" }) ? "com.spotify.client" : "com.apple.Music"
                    if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: target) {
                        NSWorkspace.shared.openApplication(at: url, configuration: .init(), completionHandler: nil)
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.white.opacity(0.7))
                        .frame(width: 24, height: 24)
                        .background(Color.white.opacity(0.08), in: Circle())
                }
                .buttonStyle(.plain)
            }

            // Progress Scrubber
            HStack(spacing: 6) {
                Text(formatTime(mediaObserver.elapsed))
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.5))

                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Color.white.opacity(0.18))
                            .frame(height: 3)
                        Capsule()
                            .fill(Color.white)
                            .frame(width: max(0, min(geo.size.width, geo.size.width * CGFloat(mediaObserver.duration > 0 ? (mediaObserver.elapsed / mediaObserver.duration) : 0))), height: 3)
                    }
                    .frame(height: 3)
                    .frame(maxHeight: .infinity, alignment: .center)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { gesture in
                                let fraction = max(0, min(1, gesture.location.x / geo.size.width))
                                if mediaObserver.duration > 0 {
                                    mediaObserver.seek(to: Double(fraction) * mediaObserver.duration)
                                }
                            }
                    )
                }
                .frame(height: 10)

                Text(mediaObserver.duration > 0 ? "-\(formatTime(mediaObserver.duration - mediaObserver.elapsed))" : "-0:00")
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.5))
            }
            .frame(height: 10)

            // Playback controls row (Heart, Prev, Play/Pause, Next, AirPlay)
            HStack(spacing: 22) {
                Button {
                    // Favorite action
                } label: {
                    Image(systemName: "heart")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white.opacity(0.75))
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)

                Button {
                    mediaObserver.previousTrack()
                } label: {
                    Image(systemName: "backward.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 26, height: 26)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Button {
                    mediaObserver.togglePlayPause()
                } label: {
                    Image(systemName: mediaObserver.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 32, height: 32)
                        .background(Color.white.opacity(0.18), in: Circle())
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)

                Button {
                    mediaObserver.nextTrack()
                } label: {
                    Image(systemName: "forward.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 26, height: 26)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Button {
                    // AirPlay / outputs
                } label: {
                    Image(systemName: "airplayaudio")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white.opacity(0.75))
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
            }
            .frame(height: 32)
        }
    }

    // MARK: - Page 1: Drop Shelf (Drooppy Parity, Image 4)

    private var dropShelfPage: some View {
        VStack(spacing: 6) {
            // Header
            HStack {
                Text("\(shelfStore.items.count) \(shelfStore.items.count == 1 ? "item" : "items")")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)

                Spacer()

                if shelfStore.items.count > 0 {
                    Button {
                        for item in shelfStore.items {
                            DropShelfController.shared.remove(item)
                        }
                    } label: {
                        Text("Clear")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.cyan)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 4)

            // Dropped items list / Drop zone
            if shelfStore.items.isEmpty {
                VStack(spacing: 4) {
                    Image(systemName: "tray.and.arrow.down")
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(.cyan)
                    Text("Drop files here to hold or share")
                        .font(.system(size: 11, weight: .regular))
                        .foregroundStyle(.white.opacity(0.6))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(shelfStore.items) { item in
                            VStack(spacing: 4) {
                                ZStack(alignment: .topTrailing) {
                                    shelfItemIcon(for: item)

                                    Button {
                                        DropShelfController.shared.remove(item)
                                    } label: {
                                        Image(systemName: "xmark.circle.fill")
                                            .font(.system(size: 13))
                                            .foregroundStyle(.white.opacity(0.7))
                                    }
                                    .buttonStyle(.plain)
                                    .offset(x: 4, y: -4)
                                }

                                Text(item.originalName)
                                    .font(.system(size: 9.5, weight: .medium))
                                    .foregroundStyle(.white.opacity(0.85))
                                    .frame(width: 52)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                        }
                    }
                    .padding(.horizontal, 4)
                }
                .frame(maxHeight: .infinity)
            }
        }
    }

    // MARK: - Page 2: Frontmost App Extensions, Live Approvals & Window Management

    @ViewBuilder
    private var launcherPage: some View {
        if let pending = approvalCenter.pending {
            // Live AI Approval Request Card (e.g. Claude, Antigravity, Codex command approvals)
            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.shield.fill")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(.orange)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(pending.title)
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                        if let claim = pending.requesterClaim ?? pending.body {
                            Text(claim)
                                .font(.system(size: 10, weight: .regular, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.75))
                                .lineLimit(1)
                        }
                    }

                    Spacer()
                }

                HStack(spacing: 12) {
                    Button {
                        approvalCenter.deny(pending)
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "xmark")
                            Text("Deny")
                        }
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 5)
                        .background(Color.red.opacity(0.85), in: Capsule())
                    }
                    .buttonStyle(.plain)

                    Button {
                        approvalCenter.approve(pending)
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "checkmark")
                            Text("Approve")
                        }
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 5)
                        .background(Color.green.opacity(0.85), in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
        } else {
            // Frontmost App Actions & Live Controls
            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    if let app = NSWorkspace.shared.frontmostApplication {
                        Image(nsImage: app.icon ?? NSImage())
                            .resizable()
                            .frame(width: 20, height: 20)
                            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                        Text(app.localizedName ?? "Frontmost App")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                    } else {
                        Image(systemName: "macwindow")
                            .font(.system(size: 14))
                            .foregroundStyle(.cyan)
                        Text("Window Actions")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.white)
                    }

                    Spacer()

                    // Frontmost App Window Tiling Controls
                    HStack(spacing: 6) {
                        Button {
                            FrontmostAppActions.tileLeft()
                        } label: {
                            Image(systemName: "rectangle.leadinghalf.filled")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.white.opacity(0.85))
                                .frame(width: 24, height: 22)
                                .background(Color.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 5))
                        }
                        .buttonStyle(.plain)
                        .help("Tile frontmost window to left half")

                        Button {
                            FrontmostAppActions.maximize()
                        } label: {
                            Image(systemName: "rectangle.fill")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.white.opacity(0.85))
                                .frame(width: 24, height: 22)
                                .background(Color.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 5))
                        }
                        .buttonStyle(.plain)
                        .help("Maximize frontmost window")

                        Button {
                            FrontmostAppActions.tileRight()
                        } label: {
                            Image(systemName: "rectangle.trailinghalf.filled")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.white.opacity(0.85))
                                .frame(width: 24, height: 22)
                                .background(Color.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 5))
                        }
                        .buttonStyle(.plain)
                        .help("Tile frontmost window to right half")
                    }
                }

                HStack(spacing: 8) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.cyan)

                    TextField("Ask frontmost app or search…", text: $prompt.query)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white)
                        .onSubmit {
                            if !prompt.query.isEmpty {
                                _ = prompt.submit()
                            }
                        }

                    if !prompt.query.isEmpty {
                        Button {
                            prompt.query = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 11))
                                .foregroundStyle(.white.opacity(0.6))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 8)
                .frame(height: 28)
                .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))

                HStack(spacing: 8) {
                    quickChip(title: "Now Playing", icon: "music.note") { notchState.selectedPage = 0 }
                    quickChip(title: "Drop Shelf", icon: "tray.fill") { notchState.selectedPage = 1 }
                    quickChip(title: "Clipboard", icon: "doc.on.clipboard") {
                        CornerDockController.shared.showClipboardBoard()
                    }
                }
            }
        }
    }

    private func quickChip(title: String, icon: String, action: (() -> Void)? = nil) -> some View {
        Button {
            action?()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 9))
                Text(title)
                    .font(.system(size: 10, weight: .medium))
            }
            .foregroundStyle(.white.opacity(0.75))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.white.opacity(0.06), in: Capsule())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func shelfItemIcon(for item: DropShelfItem) -> some View {
        let url = shelfStore.url(for: item)
        if item.kind == .images, let image = NSImage(contentsOf: url) {
            Image(nsImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        } else {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                .resizable()
                .frame(width: 28, height: 28)
                .frame(width: 44, height: 44)
                .background(Color.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }

    private func formatTime(_ seconds: Double) -> String {
        guard !seconds.isNaN, seconds > 0 else { return "0:00" }
        let total = Int(seconds)
        let m = total / 60
        let s = total % 60
        return String(format: "%d:%02d", m, s)
    }
}

/// Animated equalizer waveform bars seen in Drooppy, DynamicBar, and Apple Music Live Activities.
struct EqualizerBarsView: View {
    var isPlaying: Bool
    @State private var wave = false

    var body: some View {
        HStack(spacing: 2) {
            bar(height: wave ? 12 : 5)
            bar(height: wave ? 6 : 12)
            bar(height: wave ? 14 : 7)
        }
        .frame(height: 14)
        .onAppear {
            if isPlaying {
                withAnimation(.easeInOut(duration: 0.45).repeatForever(autoreverses: true)) {
                    wave = true
                }
            }
        }
        .onChange(of: isPlaying) { _, playing in
            if playing {
                withAnimation(.easeInOut(duration: 0.45).repeatForever(autoreverses: true)) {
                    wave = true
                }
            } else {
                wave = false
            }
        }
    }

    private func bar(height: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 1)
            .fill(LinearGradient(colors: [.pink, .purple], startPoint: .top, endPoint: .bottom))
            .frame(width: 2, height: height)
    }
}

// MARK: - Frontmost App Actions (Window Tiling & System Extensions)

enum FrontmostAppActions {
    static var frontmostApp: NSRunningApplication? {
        NSWorkspace.shared.frontmostApplication
    }

    static func tileLeft() {
        guard let app = frontmostApp, let screen = NSScreen.main else { return }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        var focusedWindow: CFTypeRef?
        if AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &focusedWindow) == .success,
           let win = focusedWindow {
            let vis = screen.visibleFrame
            let primH = NSScreen.screens.first?.frame.height ?? vis.height
            let targetFrame = CGRect(x: vis.minX, y: primH - vis.maxY, width: vis.width / 2, height: vis.height)
            _ = AXWindowControl.write(element: win as! AXUIElement, frame: targetFrame, label: "tileLeft")
        }
    }

    static func tileRight() {
        guard let app = frontmostApp, let screen = NSScreen.main else { return }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        var focusedWindow: CFTypeRef?
        if AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &focusedWindow) == .success,
           let win = focusedWindow {
            let vis = screen.visibleFrame
            let primH = NSScreen.screens.first?.frame.height ?? vis.height
            let targetFrame = CGRect(x: vis.midX, y: primH - vis.maxY, width: vis.width / 2, height: vis.height)
            _ = AXWindowControl.write(element: win as! AXUIElement, frame: targetFrame, label: "tileRight")
        }
    }

    static func maximize() {
        guard let app = frontmostApp, let screen = NSScreen.main else { return }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        var focusedWindow: CFTypeRef?
        if AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &focusedWindow) == .success,
           let win = focusedWindow {
            let vis = screen.visibleFrame
            let primH = NSScreen.screens.first?.frame.height ?? vis.height
            let targetFrame = CGRect(x: vis.minX, y: primH - vis.maxY, width: vis.width, height: vis.height)
            _ = AXWindowControl.write(element: win as! AXUIElement, frame: targetFrame, label: "maximize")
        }
    }
}
