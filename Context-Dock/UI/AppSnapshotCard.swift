// AppSnapshotCard.swift
// Context-Dock
//
// What the scoped app is showing right now, as a card above the field — the corner's app
// switcher.
//
// Scoping into an app from Global asks "what is this app doing?". A list of its menu
// commands answers a different question, so this shows the window instead: the same thing
// ⌘-Tab shows, except it stays put while the user decides, and Return switches to it.

import AppKit
import SwiftUI

enum AppSnapshotMetrics {
    static let width = CornerDockLayout.cardWidth
    static let headerHeight: CGFloat = 30
    /// A 16:10 window, which is close enough to most, at the shell's card width.
    static let imageHeight: CGFloat = 208
    static let verticalPadding: CGFloat = 10

    /// Pure, like every other corner surface: the shell reserves exactly this.
    static var size: CGSize {
        CGSize(width: width, height: headerHeight + imageHeight + verticalPadding * 2)
    }
}

struct AppSnapshotCard: View {
    @ObservedObject var model: AppChatPromptModel
    @ObservedObject private var snapshots = AppWindowSnapshotService.shared

    private var image: NSImage? { snapshots.snapshot(for: model.appBundleID) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            content
        }
        .padding(.vertical, AppSnapshotMetrics.verticalPadding)
        .frame(
            width: AppSnapshotMetrics.size.width, height: AppSnapshotMetrics.size.height,
            alignment: .topLeading)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .background {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Color.clear)
                .background(GlassBackground(cornerRadius: 22, isDark: true))
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.16), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.34), radius: 20, y: 10)
        }
        .onHover { _ in model.touch() }
        .contentShape(Rectangle())
        .onTapGesture { activate() }
        .onAppear { retryIfEmpty() }
        .task(id: model.appBundleID) { retryIfEmpty() }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text(model.appName)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            Spacer(minLength: 4)
            Text("Return to switch")
                .font(.system(size: 10))
                .foregroundStyle(.secondary.opacity(0.55))
        }
        .padding(.horizontal, 16)
        .frame(height: AppSnapshotMetrics.headerHeight)
    }

    @ViewBuilder
    private var content: some View {
        if let image {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(
                    maxWidth: .infinity, maxHeight: AppSnapshotMetrics.imageHeight,
                    alignment: .center)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .padding(.horizontal, 12)
        } else {
            // Absent for one of two reasons, and they need different answers: the capture is
            // still running, or macOS refused it. Saying "no window" for a permission
            // problem would send the user looking in the wrong place.
            VStack(spacing: 6) {
                Image(systemName: snapshots.isDenied ? "lock.display" : "macwindow")
                    .font(.system(size: 20, weight: .light))
                    .foregroundStyle(.secondary.opacity(0.6))
                Text(
                    snapshots.isDenied
                        ? "Allow Screen Recording to preview windows"
                        : "No window to show")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary.opacity(0.7))
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, maxHeight: AppSnapshotMetrics.imageHeight)
        }
    }

    /// A window that was not ready when the scope opened — an app still drawing, or one
    /// coming forward from another Space — gets asked again rather than being left blank.
    private func retryIfEmpty() {
        guard image == nil, !snapshots.isDenied else { return }
        snapshots.refresh(bundleID: model.appBundleID)
    }

    /// Switch to the app, which is what a switcher is for.
    private func activate() {
        guard let app = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == model.appBundleID && !$0.isTerminated
        }) else { return }
        app.activate()
        model.hasActed = true
    }
}
