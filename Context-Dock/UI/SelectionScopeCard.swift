// SelectionScopeCard.swift
// Context-Dock
//
// The selection card in the corner shell: what is selected, and a field to act on it.
//
// Same card shape as its siblings — the clipboard preview, the App Chat list — because it
// is one of them now rather than the launcher wearing a smaller coat.

import AppKit
import SwiftUI

enum SelectionScopeMetrics {
    static let width = CornerDockLayout.cardWidth
    static let headerHeight: CGFloat = 30
    static let inputHeight: CGFloat = 44
    /// Three lines of the selection, which is enough to recognise it without becoming a
    /// reader. The card is for choosing a subject, not for reading the document.
    static let previewHeight: CGFloat = 62
    static let verticalPadding: CGFloat = 10

    /// A pure function of state, like every other corner surface: the shell hit-tests this
    /// exact number.
    static var size: CGSize {
        CGSize(
            width: width,
            height: headerHeight + previewHeight + inputHeight + verticalPadding * 2)
    }
}

struct SelectionScopeCard: View {
    @ObservedObject var model: SelectionScopeModel
    @ObservedObject private var keyboardState = CornerDockController.shared.keyboardState
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            preview
            field
        }
        .padding(.vertical, SelectionScopeMetrics.verticalPadding)
        .frame(
            width: SelectionScopeMetrics.size.width,
            height: SelectionScopeMetrics.size.height,
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
        .onAppear { fieldFocused = keyboardState.owner == .selection }
        .onChange(of: keyboardState.owner) { _, owner in fieldFocused = owner == .selection }
        .onChange(of: keyboardState.focusRequestToken) { _, _ in
            fieldFocused = keyboardState.owner == .selection
        }
    }

    /// What was selected and where it came from — said plainly, because acting on the wrong
    /// selection is the failure this surface exists to prevent.
    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: model.scope?.icon ?? "text.cursor")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.accentColor)
            Text(model.scope?.label ?? "Selection")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.accentColor)
            if !model.appName.isEmpty {
                Text("· \(model.appName)")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary.opacity(0.7))
            }
            Spacer(minLength: 4)
            Button { model.togglePin() } label: {
                Image(systemName: model.isPinned ? "pin.fill" : "pin")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(model.isPinned ? Color.accentColor : .secondary)
            }
            .buttonStyle(.plain)
            .help(model.isPinned ? "Unpin" : "Keep this open")
        }
        .padding(.horizontal, 16)
        .frame(height: SelectionScopeMetrics.headerHeight)
    }

    private var preview: some View {
        Text(model.preview)
            .font(.system(size: 12))
            .foregroundStyle(.primary.opacity(0.82))
            .lineLimit(3)
            .multilineTextAlignment(.leading)
            .frame(
                maxWidth: .infinity, minHeight: SelectionScopeMetrics.previewHeight,
                maxHeight: SelectionScopeMetrics.previewHeight, alignment: .topLeading)
            .padding(.horizontal, 16)
    }

    private var field: some View {
        HStack(spacing: 8) {
            ZStack(alignment: .leading) {
                if model.query.isEmpty {
                    Text("Ask about this selection…")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary.opacity(0.6))
                }
                TextField("", text: $model.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, weight: .medium))
                    .focused($fieldFocused)
                    .onChange(of: model.query) { _, _ in model.touch() }
                    .onSubmit { model.submit() }
                    .onKeyPress(.escape) {
                        model.dismiss()
                        return .handled
                    }
            }
            Button { model.submit() } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(
                        model.query.isEmpty ? Color.secondary.opacity(0.5) : Color.accentColor)
            }
            .buttonStyle(.plain)
            .disabled(model.query.isEmpty)
        }
        .padding(.horizontal, 16)
        .frame(height: SelectionScopeMetrics.inputHeight)
    }
}
