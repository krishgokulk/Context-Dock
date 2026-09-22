// PanelWelcomeView.swift
// Context-Dock
//
// What the app panel shows before anything has been asked of it.
//
// Extracted for #25 as a reachable leaf. It needs no launcher state — only the title and
// subtitle for the scope it is standing in, which the caller works out.
import AppKit
import SwiftUI

struct PanelWelcomeView: View {
    let greeting: String
    let subtext: String

    /// The scope's own icon when it has one; `fallbackIcon` is the SF Symbol used when it
    /// does not.
    let contextIcon: NSImage?
    let fallbackIcon: String

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                // ── Greeting card ──────────────────────────────────────
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        // Context icon
                        ZStack {
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(Color.accentColor.opacity(0.12))
                                .frame(width: 36, height: 36)
                            if let icon = contextIcon {
                                Image(nsImage: icon)
                                    .resizable().aspectRatio(contentMode: .fit)
                                    .frame(width: 22, height: 22)
                            } else {
                                Image(systemName: fallbackIcon)
                                    .font(.system(size: 16, weight: .semibold))
                                    .foregroundStyle(Color.accentColor)
                            }
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(greeting)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(.primary)
                            Text(subtext)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.top, 16)
                .padding(.bottom, 12)

                Spacer()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
