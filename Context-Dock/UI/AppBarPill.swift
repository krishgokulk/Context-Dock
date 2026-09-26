// AppBarPill.swift
// Context-Dock
//
// An app's bar, as the pill beside "+" in its Context Dock (owner 2026-09-26): the app's
// pins first, a hairline, then its open tabs. The field keeps room for a few icons and the
// rest scroll sideways inside the capsule — the field stays compact, never widening with
// the tabs or folding into the big strip.

import AppKit
import SwiftUI

struct AppBarPill: View {
    @ObservedObject var model: AppChatPromptModel

    var body: some View {
        let icons = model.allRunningIcons
        let lastPin = icons.lastIndex { model.isAppPinIcon($0.id) }
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: AppChatPromptMetrics.appBarIconGap) {
                ForEach(Array(icons.enumerated()), id: \.element.id) { index, icon in
                    cell(icon)
                    if index == lastPin, index < icons.count - 1 {
                        Rectangle()
                            .fill(Color.primary.opacity(0.22))
                            .frame(width: 1, height: 20)
                    }
                }
            }
            .padding(.horizontal, 8)
        }
        // The room the field keeps for the pill: the same arithmetic the field's size uses,
        // so the capsule and the space for it are one number.
        .frame(
            width: AppChatPromptMetrics.appBarPillWidth(for: model),
            height: AppChatPromptMetrics.appBarPillHeight)
        .background(.regularMaterial, in: Capsule(style: .continuous))
        .overlay(
            Capsule(style: .continuous)
                .strokeBorder(Color.white.opacity(0.16), lineWidth: 0.7))
        .clipShape(Capsule(style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(model.appName) pins and tabs")
    }

    private func cell(_ icon: MatchDockIcon) -> some View {
        Button { model.openBarIcon(icon) } label: {
            Image(nsImage: icon.icon)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(
                    width: AppChatPromptMetrics.appBarIconSize,
                    height: AppChatPromptMetrics.appBarIconSize)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(icon.title)
        .accessibilityLabel(icon.title)
        .contextMenu { menu(for: icon) }
    }

    @ViewBuilder
    private func menu(for icon: MatchDockIcon) -> some View {
        if let pin = model.appPin(forIconID: icon.id) {
            Button("Unpin") {
                model.dockPins.unpin(pin.id)
                model.updateTabStrip()
            }
        } else if model.isTabIcon(icon.id) {
            Button(model.isTabPinned(iconID: icon.id) ? "Unpin Tab" : "Pin Tab") {
                model.toggleTabPin(iconID: icon.id)
            }
        }
    }
}
