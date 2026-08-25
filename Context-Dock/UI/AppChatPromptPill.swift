// AppChatPromptPill.swift
// Context-Dock
//
// The corner input: a search field for asking the frontmost app something, in the same
// shell and the same shape as the clipboard pill. It is deliberately the same object the
// user already knows — only the content differs.

import AppKit
import SwiftUI

enum AppChatPromptMetrics {
    static let promptSize = CGSize(width: 372, height: 56)
    static let miniSize = CGSize(width: 112, height: 44)

    static func size(for phase: AppChatPromptPhase) -> CGSize {
        phase == .mini ? miniSize : promptSize
    }
}

struct AppChatPromptPill: View {
    @ObservedObject var model: AppChatPromptModel
    @FocusState private var fieldFocused: Bool

    private var size: CGSize { AppChatPromptMetrics.size(for: model.phase) }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            miniContent.opacity(model.phase == .mini ? 1 : 0)
            promptContent.opacity(model.phase == .prompt ? 1 : 0)
        }
        .frame(width: size.width, height: size.height, alignment: .bottomLeading)
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
        .onChange(of: model.phase) { _, phase in
            fieldFocused = phase == .prompt
        }
    }

    private var promptContent: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 22)

            ZStack(alignment: .leading) {
                if model.query.isEmpty {
                    Text(placeholder)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.secondary.opacity(0.6))
                        .lineLimit(1)
                }
                TextField("", text: $model.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14, weight: .medium))
                    .focused($fieldFocused)
                    .onChange(of: model.query) { _, _ in
                        model.queryChanged()
                    }
                    .onSubmit {
                        // Not wired to a route yet; the field keeps the question rather
                        // than clearing it as though something had been sent.
                        model.submit()
                    }
                    .onKeyPress(.escape) {
                        model.dismiss()
                        return .handled
                    }
            }

            if !model.appBundleID.isEmpty, let icon = appIcon {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 18, height: 18)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            }
        }
        .padding(.horizontal, 16)
        .frame(
            width: AppChatPromptMetrics.promptSize.width,
            height: AppChatPromptMetrics.promptSize.height)
    }

    private var placeholder: String {
        model.appName.isEmpty ? "Ask this app…" : "Ask \(model.appName)…"
    }

    /// Holds a half-written question until the user comes back for it.
    private var miniContent: some View {
        HStack(spacing: 7) {
            Image(systemName: "bubble.left.and.bubble.right.fill")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            Text("Draft")
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .frame(
            width: AppChatPromptMetrics.miniSize.width,
            height: AppChatPromptMetrics.miniSize.height)
    }

    private var appIcon: NSImage? {
        guard
            let url = NSWorkspace.shared.urlForApplication(
                withBundleIdentifier: model.appBundleID)
        else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path)
    }
}
