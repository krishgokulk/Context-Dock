// UnifiedFrontmostBar.swift
// Context-Dock
//
// Frontmost app chip (`[ ✳️ Safari ⌄ ]`) and its top 2–3 pinned satellite micro-pills
// in the Unified Global Launcher's resting bar.

import AppKit
import SwiftUI

struct UnifiedFrontmostBar: View {
    @ObservedObject var model: AppChatPromptModel

    private var frontmostApp: NSRunningApplication? {
        guard let app = AppDelegate.shared?.previousFrontmostApp,
            !app.isTerminated,
            let bundleID = app.bundleIdentifier,
            !bundleID.isEmpty,
            bundleID != Bundle.main.bundleIdentifier
        else { return nil }
        return app
    }

    var body: some View {
        if let app = frontmostApp,
            let bundleID = app.bundleIdentifier,
            model.query.count < 16
        {
            let appName = app.localizedName ?? "App"
            let microPills = model.frontmostPinnedMicroPills(limit: 3)
            HStack(spacing: 5) {
                Menu {
                    Button {
                        let target = CornerChatTarget(
                            name: appName,
                            bundleID: bundleID,
                            suggestions: AppChatSuggestionProvider.suggestions(for: app),
                            summary: AppChatSuggestionProvider.summary(for: app)
                        )
                        CornerDockController.shared.chatPresentation.showFrontmostApp(target: target)
                    } label: {
                        Label("Open \(appName) Pet", systemImage: "sparkles")
                    }

                    Button {
                        model.scopeIntoApp(name: appName, bundleID: bundleID)
                    } label: {
                        Label("Browse \(appName) Menus & Actions", systemImage: "list.bullet")
                    }

                    let allPins = model.dockPins.pins(forApp: bundleID)
                    if !allPins.isEmpty {
                        Divider()
                        Section("Pinned for \(appName)") {
                            ForEach(allPins, id: \.id) { pin in
                                Button {
                                    model.openAppPin(pin)
                                } label: {
                                    Label(pin.title, systemImage: model.appPinSymbol(pin) ?? pin.kind.fallbackSymbol)
                                }
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        if let icon = app.icon {
                            Image(nsImage: icon)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(width: 14, height: 14)
                        }
                        Text(appName)
                            .font(.system(size: 11.5, weight: .medium))
                            .lineLimit(1)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 8.5, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.primary.opacity(0.09), in: Capsule())
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("\(appName) context & pinned actions")

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
                    }
                    .buttonStyle(.plain)
                    .help("Run pinned \(item.pin.title)")
                }
            }
            .transition(.opacity.combined(with: .scale(scale: 0.94)))
        }
    }
}
