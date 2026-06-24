// ShortcutsCatalog.swift
// Context-Dock
//
// Enumerates the user's macOS Shortcuts (via the `shortcuts` CLI) so they can be
// linked to an App Adapter. Linked shortcuts become `.shortcut` adapter actions,
// which already surface in the dock when that app is frontmost and run through the
// existing adapter execution path.
//
// macOS does not expose the user's exact Shortcuts glyph/color through the public
// `shortcuts` CLI. Use a deterministic name-based SF Symbol/color so shortcuts
// are scannable instead of every row using the same Shortcuts.app icon.

import AppKit
import Combine
import Foundation
import SwiftUI

struct MacShortcut: Identifiable, Hashable {
    let name: String
    let iconName: String
    let accentColor: String

    var id: String { name }

    init(name: String) {
        self.name = name
        self.iconName = ShortcutsCatalog.iconName(for: name)
        self.accentColor = ShortcutsCatalog.accentColorName(for: name)
    }
}

@MainActor
final class ShortcutsCatalog: ObservableObject {
    static let shared = ShortcutsCatalog()

    @Published private(set) var shortcuts: [MacShortcut] = []
    @Published private(set) var isLoading = false

    private var loadedOnce = false

    private init() {}

    /// The real Shortcuts.app icon, kept only as a fallback when a bitmap is required.
    /// `nonisolated` so it can be read from any pill-building context.
    nonisolated static let appIcon: NSImage? = {
        let ws = NSWorkspace.shared
        let url =
            ws.urlForApplication(withBundleIdentifier: "com.apple.shortcuts")
            ?? [
                "/System/Applications/Shortcuts.app",
                "/Applications/Shortcuts.app",
            ].map { URL(fileURLWithPath: $0) }.first { FileManager.default.fileExists(atPath: $0.path) }
        guard let url else { return nil }
        let icon = ws.icon(forFile: url.path)
        icon.size = NSSize(width: 64, height: 64)
        return icon
    }()

    /// Load once on first use; subsequent calls are no-ops unless `refresh()` is used.
    func loadIfNeeded() {
        guard !loadedOnce, !isLoading else { return }
        refresh()
    }

    func refresh() {
        guard !isLoading else { return }
        isLoading = true
        Task.detached(priority: .userInitiated) {
            let names = Self.enumerate()
            await MainActor.run {
                self.shortcuts = names.map { MacShortcut(name: $0) }
                self.isLoading = false
                self.loadedOnce = true
            }
        }
    }

    nonisolated static func iconName(for shortcutName: String) -> String {
        let q = shortcutName
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()

        let rules: [(tokens: [String], icon: String)] = [
            (["combine", "merge", "join"], "square.stack.3d.down.right.fill"),
            (["clipboard", "copy", "paste"], "clipboard.fill"),
            (["bookmark", "bookmarks"], "bookmark.fill"),
            (["search", "find"], "magnifyingglass"),
            (["back", "previous"], "arrow.left.circle.fill"),
            (["forward", "next"], "arrow.right.circle.fill"),
            (["action button", "tap", "button"], "hand.tap.fill"),
            (["claude", "chatgpt", "ai", "prompt"], "brain.head.profile"),
            (["bristol", "map", "place", "location"], "map.fill"),
            (["document", "pdf", "file", "make"], "doc.fill"),
            (["image", "photo", "remove"], "photo.fill"),
            (["message", "sms", "whatsapp"], "message.fill"),
            (["mail", "email"], "envelope.fill"),
            (["calendar", "event"], "calendar"),
            (["reminder", "task", "todo"], "checklist"),
            (["music", "audio", "song"], "music.note"),
            (["video", "movie"], "play.rectangle.fill"),
            (["download"], "arrow.down.circle.fill"),
            (["upload", "share"], "square.and.arrow.up.fill"),
            (["home", "house"], "house.fill"),
            (["folder"], "folder.fill"),
            (["terminal", "shell", "script"], "terminal.fill"),
            (["settings", "preferences"], "gearshape.fill"),
            (["lock", "password"], "lock.fill"),
            (["weather"], "cloud.sun.fill"),
            (["web", "url", "link", "safari"], "globe"),
        ]

        if let match = rules.first(where: { rule in
            rule.tokens.contains { q.contains($0) }
        }) {
            return match.icon
        }

        let fallbacks = [
            "sparkles", "bolt.fill", "wand.and.stars", "command", "flowchart.fill",
            "square.stack.3d.up.fill", "circle.grid.2x2.fill", "play.fill",
        ]
        return fallbacks[stableIndex(for: q, modulo: fallbacks.count)]
    }

    nonisolated static func accentColorName(for shortcutName: String) -> String {
        let q = shortcutName
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()

        if q.contains("delete") || q.contains("remove") || q.contains("trash") { return "red" }
        if q.contains("mail") || q.contains("message") || q.contains("chat") { return "blue" }
        if q.contains("calendar") || q.contains("weather") { return "orange" }
        if q.contains("reminder") || q.contains("task") || q.contains("todo") { return "green" }
        if q.contains("photo") || q.contains("image") || q.contains("video") { return "pink" }
        if q.contains("terminal") || q.contains("script") || q.contains("code") { return "gray" }
        if q.contains("ai") || q.contains("claude") || q.contains("prompt") { return "purple" }

        let colors = ["pink", "orange", "yellow", "green", "teal", "blue", "indigo", "purple"]
        return colors[stableIndex(for: q, modulo: colors.count)]
    }

    nonisolated private static func stableIndex(for text: String, modulo: Int) -> Int {
        guard modulo > 0 else { return 0 }
        var hash = 5381
        for scalar in text.unicodeScalars {
            hash = ((hash << 5) &+ hash) &+ Int(scalar.value)
        }
        return Int(UInt(bitPattern: hash) % UInt(modulo))
    }

    /// Run `shortcuts list` and return the user's shortcut names, sorted.
    nonisolated private static func enumerate() -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
        process.arguments = ["list"]
        let outPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = Pipe()

        do { try process.run() } catch { return [] }

        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0,
            let text = String(data: data, encoding: .utf8)
        else { return [] }

        var seen = Set<String>()
        return text
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }
}

// MARK: - Reusable tile

/// Renders a stable, per-shortcut symbol tile.
struct ShortcutTileIcon: View {
    var shortcut: MacShortcut?
    var name: String?
    var size: CGFloat = 28
    var corner: CGFloat = 7

    private var iconName: String {
        shortcut?.iconName ?? name.map(ShortcutsCatalog.iconName(for:)) ?? "square.stack.3d.up.fill"
    }

    private var accent: Color {
        let colorName = shortcut?.accentColor ?? name.map(ShortcutsCatalog.accentColorName(for:)) ?? "purple"
        switch colorName {
        case "red": return .red
        case "orange": return .orange
        case "yellow": return .yellow
        case "green": return .green
        case "teal": return .teal
        case "blue": return .blue
        case "indigo": return .indigo
        case "pink": return .pink
        case "gray", "grey": return .secondary
        default: return .purple
        }
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: corner)
                .fill(
                    LinearGradient(
                        colors: [accent.opacity(0.90), accent.opacity(0.45)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: size, height: size)
            Image(systemName: iconName)
                .font(.system(size: size * 0.48, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.white)
        }
        .overlay(
            RoundedRectangle(cornerRadius: corner)
                .strokeBorder(.white.opacity(0.28), lineWidth: 0.7)
        )
        .shadow(color: accent.opacity(0.22), radius: 4, y: 1)
    }
}
