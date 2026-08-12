// LauncherView+GeneralChatAppSlash.swift
// Context-Dock
//
// "/" at the start of the General Chat field filters apps by name, the way Global
// Context filters app icons into its capsule. Picking one puts the app in the
// chat's focus, so the next question is answered about that app.
//
// This replaces guessing the app from the sentence. Name-alias matching read
// "reminder" as no app at all (the alias is "reminders") and read an app name
// mentioned in passing as a target — a typed "/" says which app the user means,
// with no inference in the middle.

import AppKit
import SwiftUI

struct GeneralChatSlashApp: Identifiable, Equatable {
    let name: String
    let bundleId: String
    let icon: NSImage?
    let isRunning: Bool

    var id: String { bundleId.lowercased() }

    static func == (lhs: GeneralChatSlashApp, rhs: GeneralChatSlashApp) -> Bool {
        lhs.id == rhs.id
    }
}

extension LauncherView {

    /// The text after "/", or nil when this isn't an app filter.
    ///
    /// A space ends it: "/rem" filters, "/rem what is due today" is a sentence the
    /// user kept typing, and yanking the field out from under them mid-question
    /// would be worse than showing nothing.
    var generalChatSlashFilter: String? {
        guard currentDockSurfaceMode == .generalChat else { return nil }
        let query = searchState.query
        guard query.hasPrefix("/") else { return nil }
        let rest = String(query.dropFirst())
        guard !rest.contains(" ") else { return nil }
        return rest.lowercased()
    }

    /// Apps matching the filter: running and adapter-configured apps first (those are
    /// the ones with live data), then everything installed, so "/rem" still finds
    /// Reminders when Reminders isn't open.
    ///
    /// The ranking lives in ChatAppDirectory, which the chat window's composer filters
    /// too — "/finder" must mean the same thing in both places, and it did not while each
    /// surface merged its own sources.
    var generalChatSlashApps: [GeneralChatSlashApp] {
        guard let filter = generalChatSlashFilter else { return [] }
        return ChatAppDirectory.matching(filter).map {
            GeneralChatSlashApp(
                name: $0.name, bundleId: $0.bundleId, icon: $0.icon, isRunning: $0.isRunning)
        }
    }

    /// Put the app in this chat's focus and clear the "/…" text — the field goes back
    /// to being a question box, now scoped to that app.
    func pickGeneralChatSlashApp(_ app: GeneralChatSlashApp) {
        if !chatFocusApps.contains(where: {
            $0.bundleId.caseInsensitiveCompare(app.bundleId) == .orderedSame
        }) {
            chatFocusApps.append(.init(name: app.name, bundleId: app.bundleId))
        }
        searchState.query = ""
        ensureSearchInputFocusReady()
    }

    /// Return while filtering picks the first match instead of sending "/rem" to the
    /// model. Returns true when it handled the key.
    @discardableResult
    func handleGeneralChatSlashPickIfNeeded() -> Bool {
        guard generalChatSlashFilter != nil, let first = generalChatSlashApps.first else {
            return false
        }
        pickGeneralChatSlashApp(first)
        return true
    }

    /// Filtered app icons, inline in the composer — the same read as Global Context's
    /// capsule: icons narrow as you type, the leftmost is what Return will take.
    @ViewBuilder
    var generalChatSlashAppCapsule: some View {
        let apps = generalChatSlashApps
        if !apps.isEmpty {
            HStack(spacing: 5) {
                ForEach(apps) { app in
                    Button {
                        pickGeneralChatSlashApp(app)
                    } label: {
                        Group {
                            if let icon = app.icon {
                                Image(nsImage: icon)
                                    .resizable()
                                    .aspectRatio(contentMode: .fit)
                            } else {
                                Image(systemName: "app.dashed")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .frame(width: 18, height: 18)
                        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                        .padding(2)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(
                                    app.id == apps.first?.id
                                        ? Color.accentColor.opacity(0.28) : Color.clear
                                )
                        )
                        .overlay(alignment: .bottomTrailing) {
                            if app.isRunning {
                                Circle()
                                    .fill(Color.green)
                                    .frame(width: 5, height: 5)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(app.isRunning ? "\(app.name) — running" : app.name)
                }
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(Color.accentColor.opacity(0.12), in: Capsule())
            .transition(.scale(scale: 0.9).combined(with: .opacity))
        }
    }
}
