// UnifiedFrontmostBar.swift
// Context-Dock
//
// Compact pinned action satellite micro-pills in the Unified Global Launcher's
// resting bar (without showing a frontmost app icon/chip in Global Context).

import SwiftUI

struct UnifiedFrontmostBar: View {
    @ObservedObject var model: AppChatPromptModel

    var body: some View {
        if model.query.count < 16 {
            let microPills = model.frontmostPinnedMicroPills(limit: 3)
            if !microPills.isEmpty {
                HStack(spacing: 4) {
                    ForEach(microPills, id: \.pin.id) { item in
                        Button {
                            model.openAppPin(item.pin)
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: item.symbol)
                                    .font(.system(size: 10, weight: .medium))
                                Text(item.pin.title)
                                    .font(.system(size: 11, weight: .medium))
                                    .lineLimit(1)
                            }
                            .padding(.horizontal, 7)
                            .padding(.vertical, 4)
                            .background(Color.primary.opacity(0.07), in: Capsule())
                            .fixedSize(horizontal: true, vertical: false)
                        }
                        .buttonStyle(.plain)
                        .help("Run pinned \(item.pin.title)")
                    }
                }
                .transition(.opacity.combined(with: .scale(scale: 0.94)))
            }
        }
    }
}
