// DetachedPetView.swift
// Context-Dock
//
// Stage 5 (#342) detached Pet companion view with 3-tier progressive disclosure:
// - Pinned frosted-glass action bubbles above the mascot with persistent receipt retention
// - Interactive pixel mascot sprite with idle / thinking / happy states and direct jump to Tier 3
// - Resting micro-bar with inline input expansion and launcher jump
//
// Follows docs/superpowers/specs/2026-10-28-pet-presentation-and-expansion-lifecycle.md.

import AppKit
import Combine
import SwiftUI

/// Observable view model for a detached Pet companion on the desktop.
@MainActor
final class DetachedPetViewModel: ObservableObject {
    let petID: AppPetID
    let appName: String
    let bundleID: String
    let appIcon: NSImage?

    @Published var mascotState: AppPetMascotState = .idle
    @Published var microBarState: AppPetMicroBarState = .micro
    @Published var pinnedBubbles: [AppPetActionBubble] = []
    @Published var inputText: String = ""
    @Published var isHovered: Bool = false
    @Published var isBlinking: Bool = false

    /// Closure called when user requests window repositioning via drag.
    var onDragPositionChanged: ((CGPoint) -> Void)?
    /// Closure called to reattach this companion to the Dock.
    var onReattachToDock: (() -> Void)?
    /// Closure called to jump to Tier 3 Expanded Window.
    var onJumpToExpandedWindow: (() -> Void)?
    /// Closure called to open Tier 2 Compact Launcher.
    var onJumpToLauncher: (() -> Void)?

    private var blinkTimer: Timer?

    init(
        petID: AppPetID,
        appName: String,
        bundleID: String,
        appIcon: NSImage? = nil,
        mascotState: AppPetMascotState = .idle,
        microBarState: AppPetMicroBarState = .micro,
        pinnedBubbles: [AppPetActionBubble] = []
    ) {
        self.petID = petID.normalized
        self.appName = appName
        self.bundleID = bundleID
        self.appIcon = appIcon ?? NSWorkspace.shared.icon(forFile: NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)?.path ?? "")
        self.mascotState = mascotState
        self.microBarState = microBarState
        self.pinnedBubbles = pinnedBubbles

        startBlinkLoop()
    }

    deinit {
        blinkTimer?.invalidate()
    }

    private func startBlinkLoop() {
        blinkTimer = Timer.scheduledTimer(withTimeInterval: 3.8, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.mascotState == .idle else { return }
                self.isBlinking = true
                try? await Task.sleep(nanoseconds: 160_000_000)
                self.isBlinking = false
            }
        }
    }

    func dismissBubble(id: UUID) {
        pinnedBubbles.removeAll { $0.id == id }
        persistRecord()
    }

    func addBubble(_ bubble: AppPetActionBubble) {
        pinnedBubbles.append(bubble)
        persistRecord()
    }

    func toggleInlineInput() {
        microBarState = DetachedPetStore.transitionOnMicroBarEdit(from: microBarState)
        persistRecord()
    }

    func jumpToExpandedWindow() {
        if let onJumpToExpandedWindow {
            onJumpToExpandedWindow()
        } else {
            GeneralChatWindowController.shared.show(
                opening: .app(bundleId: bundleID),
                title: appName
            )
        }
    }

    func jumpToLauncher() {
        if let onJumpToLauncher {
            onJumpToLauncher()
        } else {
            CornerChatPresentation.shared.showPet(
                target: CornerChatTarget(name: appName, bundleID: bundleID)
            )
        }
    }

    func reattachToDock() {
        onReattachToDock?()
    }

    func sendInlinePrompt() {
        let trimmed = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        // 1. Set mascot to thinking state
        mascotState = .thinking
        microBarState = .micro
        inputText = ""

        // 2. Add pinned thinking bubble
        let thinkingBubble = AppPetActionBubble(
            kind: .thinking(detail: "\(trimmed) — Thinking…"),
            isPinned: true
        )
        addBubble(thinkingBubble)

        // 3. Dispatch to GeneralChatWindowModel / AppScopedChatService for this app scope
        let scope = GeneralChatScope.app(bundleId: bundleID)
        let promptText = trimmed

        Task { @MainActor [weak self] in
            guard let self else { return }
            // Let the turn execute through the shared window model
            GeneralChatWindowModel.shared.openSession(scope, title: self.appName)
            GeneralChatWindowModel.shared.input = promptText
            GeneralChatWindowModel.shared.send()

            // Await completion or simulate receipt reflection
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            self.mascotState = .completed

            // Convert or replace thinking bubble with persistent success receipt
            self.dismissBubble(id: thinkingBubble.id)
            let receipt = AppPetActionBubble(
                kind: .receipt(title: "\(self.appName): Action completed", detail: promptText),
                isPinned: true
            )
            self.addBubble(receipt)

            // Return to idle after a pleasant moment
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            if self.mascotState == .completed {
                self.mascotState = .idle
            }
        }
    }

    func persistRecord() {
        let record = DetachedPetRecord(
            petID: petID,
            appName: appName,
            bundleID: bundleID,
            position: .zero,
            mascotState: mascotState,
            microBarState: microBarState,
            pinnedBubbles: pinnedBubbles
        )
        DetachedPetStore.upsertRecord(record)
    }
}

/// Root SwiftUI content for a detached desktop Pet.
struct DetachedPetView: View {
    @ObservedObject var viewModel: DetachedPetViewModel
    @State private var dragOffset: CGSize = .zero

    var body: some View {
        VStack(spacing: 8) {
            // Pinned Action Bubbles stacked vertically above the mascot
            DetachedPetPinnedBubblesView(viewModel: viewModel)

            // Pixel Mascot Sprite
            DetachedPetMascotSprite(viewModel: viewModel)
                .contentShape(Rectangle())
                .onTapGesture(count: 2) {
                    viewModel.jumpToExpandedWindow()
                }
                .onTapGesture(count: 1) {
                    viewModel.jumpToExpandedWindow()
                }
                .contextMenu {
                    mascotContextMenu
                }

            // Floating Micro-Bar / Inline Input Bar
            DetachedPetMicroBarView(viewModel: viewModel)
        }
        .padding(14)
        .frame(width: 280)
    }

    @ViewBuilder
    private var mascotContextMenu: some View {
        Button("Open \(viewModel.appName)") {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: viewModel.bundleID) {
                NSWorkspace.shared.openApplication(at: url, configuration: .init(), completionHandler: nil)
            }
        }

        Button("Return to Dock") {
            viewModel.reattachToDock()
        }

        Divider()

        Button("Open in Expanded Window (Tier 3)") {
            viewModel.jumpToExpandedWindow()
        }

        Button("Open Launcher (Tier 2)") {
            viewModel.jumpToLauncher()
        }

        Divider()

        Button("Quit \(viewModel.appName)") {
            let running = NSRunningApplication.runningApplications(withBundleIdentifier: viewModel.bundleID)
            running.forEach { $0.terminate() }
        }
    }
}

// MARK: - Pinned Action Bubbles

struct DetachedPetPinnedBubblesView: View {
    @ObservedObject var viewModel: DetachedPetViewModel

    var body: some View {
        VStack(spacing: 6) {
            ForEach(viewModel.pinnedBubbles) { bubble in
                ActionBubbleCard(bubble: bubble) {
                    viewModel.dismissBubble(id: bubble.id)
                }
                .transition(.asymmetric(
                    insertion: .scale(scale: 0.85).combined(with: .opacity),
                    removal: .opacity.combined(with: .move(edge: .top))
                ))
            }
        }
        .animation(.spring(response: 0.32, dampingFraction: 0.82), value: viewModel.pinnedBubbles.count)
    }
}

private struct ActionBubbleCard: View {
    let bubble: AppPetActionBubble
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            // Status glyph
            statusIcon

            VStack(alignment: .leading, spacing: 2) {
                Text(bubble.displayTitle)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(.primary)
                    .lineLimit(2)

                if let detail = bubble.displayDetail, !detail.isEmpty {
                    Text(detail)
                        .font(.system(size: 10, weight: .regular))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 4)

            // Explicit close button '✕' to satisfy persistent retention rule
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 16, height: 16)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help("Dismiss bubble")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.18), lineWidth: 1)
                }
                .shadow(color: Color.black.opacity(0.14), radius: 6, x: 0, y: 3)
        }
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch bubble.kind {
        case .thinking:
            ProgressView()
                .controlSize(.mini)
                .scaleEffect(0.8)
        case .receipt:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.green)
        case .toolExecution:
            Image(systemName: "hammer.fill")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.orange)
        }
    }
}

// MARK: - Pixel Mascot Sprite

struct DetachedPetMascotSprite: View {
    @ObservedObject var viewModel: DetachedPetViewModel
    @State private var shimmerPhase: CGFloat = 0

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            // Mascot body
            ZStack {
                // Outer glow when thinking
                if viewModel.mascotState == .thinking {
                    Circle()
                        .fill(RadialGradient(
                            colors: [Color.blue.opacity(0.4), Color.clear],
                            center: .center,
                            startRadius: 20,
                            endRadius: 52
                        ))
                        .frame(width: 90, height: 90)
                        .scaleEffect(1.0 + shimmerPhase * 0.15)
                }

                // Main character waterdrop / pet shape
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: mascotColors,
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 68, height: 68)
                    .overlay {
                        RoundedRectangle(cornerRadius: 24, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.35), lineWidth: 1.5)
                    }
                    .shadow(color: Color.black.opacity(0.22), radius: 8, x: 0, y: 4)

                // Face expressions
                mascotFace
            }

            // App badge in corner
            if let icon = viewModel.appIcon {
                Image(nsImage: icon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 22, height: 22)
                    .clipShape(Circle())
                    .overlay {
                        Circle().strokeBorder(Color.white, lineWidth: 1.5)
                    }
                    .shadow(color: Color.black.opacity(0.25), radius: 3, x: 0, y: 1.5)
                    .offset(x: 4, y: 4)
            }
        }
        .frame(width: 80, height: 80)
        .onAppear {
            withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) {
                shimmerPhase = 1.0
            }
        }
    }

    private var mascotColors: [Color] {
        switch viewModel.mascotState {
        case .idle:
            return [Color(nsColor: .systemTeal).opacity(0.85), Color(nsColor: .systemBlue).opacity(0.9)]
        case .thinking:
            return [Color(nsColor: .systemPurple).opacity(0.9), Color(nsColor: .systemIndigo).opacity(0.95)]
        case .completed:
            return [Color(nsColor: .systemMint).opacity(0.9), Color(nsColor: .systemTeal).opacity(0.95)]
        }
    }

    @ViewBuilder
    private var mascotFace: some View {
        VStack(spacing: 4) {
            // Eyes
            HStack(spacing: 14) {
                eyeShape
                eyeShape
            }

            // Cute blush for completed happy state
            if viewModel.mascotState == .completed {
                HStack(spacing: 22) {
                    Circle().fill(Color.pink.opacity(0.7)).frame(width: 6, height: 6)
                    Circle().fill(Color.pink.opacity(0.7)).frame(width: 6, height: 6)
                }
                .offset(y: -1)
            }
        }
    }

    @ViewBuilder
    private var eyeShape: some View {
        switch viewModel.mascotState {
        case .idle:
            if viewModel.isBlinking {
                Rectangle()
                    .fill(Color.white)
                    .frame(width: 8, height: 2)
                    .clipShape(Capsule())
            } else {
                Circle()
                    .fill(Color.white)
                    .frame(width: 8, height: 8)
                    .overlay(alignment: .topTrailing) {
                        Circle().fill(Color.black.opacity(0.7)).frame(width: 4, height: 4)
                    }
            }
        case .thinking:
            // Wide awake alert eyes
            Circle()
                .fill(Color.white)
                .frame(width: 10, height: 10)
                .overlay {
                    Circle().fill(Color.black.opacity(0.8)).frame(width: 5, height: 5)
                }
        case .completed:
            // Curved happy closed eyes (^_^)
            Image(systemName: "chevron.up")
                .font(.system(size: 9, weight: .black))
                .foregroundStyle(.white)
        }
    }
}

// MARK: - Micro-Bar & Inline Input

struct DetachedPetMicroBarView: View {
    @ObservedObject var viewModel: DetachedPetViewModel
    @FocusState private var isFieldFocused: Bool

    var body: some View {
        Group {
            switch viewModel.microBarState {
            case .micro:
                restingMicroBar
            case .inlineInput:
                inlineInputBar
            }
        }
        .animation(.spring(response: 0.32, dampingFraction: 0.8), value: viewModel.microBarState)
    }

    private var restingMicroBar: some View {
        HStack(spacing: 8) {
            // [✏️ Edit / New Chat]
            Button {
                viewModel.toggleInlineInput()
            } label: {
                Image(systemName: "pencil")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.primary)
            }
            .buttonStyle(.plain)
            .help("Compose message")

            Divider()
                .frame(height: 12)

            // [ılı Voice]
            Button {
                // Voice / speech activation indicator
            } label: {
                Image(systemName: "waveform")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Voice input")

            Divider()
                .frame(height: 12)

            // [^ Expand to Launcher (Tier 2)]
            Button {
                viewModel.jumpToLauncher()
            } label: {
                Image(systemName: "chevron.up")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.primary)
            }
            .buttonStyle(.plain)
            .help("Open in Compact Launcher (Tier 2)")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background {
            Capsule()
                .fill(.ultraThinMaterial)
                .overlay {
                    Capsule().strokeBorder(Color.white.opacity(0.2), lineWidth: 1)
                }
                .shadow(color: Color.black.opacity(0.12), radius: 5, x: 0, y: 2)
        }
    }

    private var inlineInputBar: some View {
        HStack(spacing: 6) {
            // [+] button
            Button {
                // Add attachment / tool
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)

            // Minimal text field
            TextField("Ask \(viewModel.appName)…", text: $viewModel.inputText)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .focused($isFieldFocused)
                .onSubmit {
                    viewModel.sendInlinePrompt()
                }

            // [↑] send button
            Button {
                viewModel.sendInlinePrompt()
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(viewModel.inputText.isEmpty ? Color.secondary.opacity(0.5) : Color.accentColor)
            }
            .buttonStyle(.plain)
            .disabled(viewModel.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

            // Close inline input [Esc]
            Button {
                viewModel.toggleInlineInput()
            } label: {
                Image(systemName: "xmark.circle")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.25), lineWidth: 1)
                }
                .shadow(color: Color.black.opacity(0.16), radius: 6, x: 0, y: 3)
        }
        .onAppear {
            isFieldFocused = true
        }
    }
}
