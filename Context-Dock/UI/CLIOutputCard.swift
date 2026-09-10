// CLIOutputCard.swift
// Context-Dock
//
// What a command printed, above the field that ran it.
//
// Deliberately a transcript of one command rather than a terminal: a terminal is phase 4 of
// the corner scope plan, and most CLI use in this app is one command and one answer. Shipping
// the common case first means the scope is usable while the harder thing is designed, instead
// of the other way round.

import AppKit
import SwiftUI

enum CLIOutputMetrics {
    static let width = CornerDockLayout.cardWidth
    static let headerHeight: CGFloat = 30
    static let bodyHeight: CGFloat = 190
    static let verticalPadding: CGFloat = 10

    /// Pure, like every other corner surface: the shell reserves exactly this.
    static var size: CGSize {
        CGSize(width: width, height: headerHeight + bodyHeight + verticalPadding * 2)
    }
}

struct CLIOutputCard: View {
    @ObservedObject var model: AppChatPromptModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            body_
        }
        .padding(.vertical, CLIOutputMetrics.verticalPadding)
        .frame(
            width: CLIOutputMetrics.size.width, height: CLIOutputMetrics.size.height,
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
    }

    /// The command that produced this, said back exactly — including the arguments, so the
    /// user can see what was actually run rather than what they meant to type.
    private var header: some View {
        HStack(spacing: 6) {
            if model.isRunningCommand {
                ProgressView().controlSize(.small).scaleEffect(0.7)
            } else if let output = model.cliOutput {
                Image(systemName: output.failed ? "xmark.circle.fill" : "checkmark.circle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(output.failed ? Color.orange : Color.green.opacity(0.8))
            }
            Text(model.cliOutput?.command ?? "\(model.cliCommand)…")
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 4)
            if model.cliOutput != nil {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(model.cliOutput?.text ?? "", forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Copy output")
            }
        }
        .padding(.horizontal, 16)
        .frame(height: CLIOutputMetrics.headerHeight)
    }

    private var body_: some View {
        ScrollView {
            Text(model.isRunningCommand ? "Running…" : (model.cliOutput?.text ?? ""))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.primary.opacity(0.85))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
        }
        .frame(height: CLIOutputMetrics.bodyHeight)
    }
}
