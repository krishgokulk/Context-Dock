// Context-Dock
//
// Pill row and picker sheet for Notch Page 2 quick actions (U7c).
//
// NotchActionPillRow: shows up to 4 pinned capabilities for the frontmost app;
//   falls back to the original nav chips when nothing is pinned.
// NotchActionPickerSheet: popover for toggling which capabilities are pinned.

import AppKit
import SwiftUI

// MARK: - Pill row

struct NotchActionPillRow: View {
    let bundleID: String?
    let onFallbackPick: (Int) -> Void
    @ObservedObject private var pinStore = NotchPinStore.shared

    private var pinnedCaps: [AICapability] {
        guard let bundleID else { return [] }
        return pinStore.pinnedIDs(for: bundleID)
            .compactMap { CapabilityRegistry.shared.capability(id: $0) }
    }

    var body: some View {
        HStack(spacing: 6) {
            if pinnedCaps.isEmpty {
                QuickChip(title: "Now Playing", icon: "music.note") { onFallbackPick(0) }
                QuickChip(title: "Drop Shelf",  icon: "tray.fill")  { onFallbackPick(1) }
                QuickChip(title: "Clipboard",   icon: "doc.on.clipboard") { onFallbackPick(2) }
            } else {
                ForEach(pinnedCaps, id: \.id) { cap in
                    ActionPill(cap: cap, bundleID: bundleID)
                }
                Spacer(minLength: 0)
            }
        }
    }
}

// MARK: - Single capability pill

private struct ActionPill: View {
    let cap: AICapability
    let bundleID: String?
    @State private var running = false
    @State private var failed = false

    var body: some View {
        Button {
            guard !running else { return }
            running = true
            failed = false
            let context: UserContext = bundleID.map {
                .appFocused(name: cap.title, bundleID: $0)
            } ?? .none
            let req = AICapabilityExecutionRequest(input: [:], context: context)
            Task { @MainActor in
                do { _ = try await cap.executor(req) }
                catch { failed = true }
                running = false
            }
        } label: {
            HStack(spacing: 4) {
                if running {
                    ProgressView().scaleEffect(0.5).frame(width: 10, height: 10)
                } else {
                    Image(systemName: notchIcon(for: cap.title))
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(failed ? .red : .cyan)
                }
                Text(cap.title)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white)
                    .lineLimit(1)
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(failed ? Color.red.opacity(0.2) : Color.cyan.opacity(0.15))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(
                                failed ? Color.red.opacity(0.4) : Color.white.opacity(0.1),
                                lineWidth: 0.5)
                    )
            )
        }
        .buttonStyle(.plain)
        .help(cap.title)
    }
}

// MARK: - Picker sheet (popover content)

struct NotchActionPickerSheet: View {
    let bundleID: String?
    let appName: String
    @ObservedObject private var pinStore = NotchPinStore.shared

    private var availableCaps: [AICapability] {
        CapabilityRegistry.shared.capabilities(for: bundleID)
            .sorted { $0.title < $1.title }
    }

    private var pinCount: Int {
        guard let bundleID else { return 0 }
        return pinStore.pinnedIDs(for: bundleID).count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Pin to Notch")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                Spacer()
                Text("\(pinCount)/\(NotchPinStore.maxPinsPerApp)")
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.5))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)

            Divider().background(Color.white.opacity(0.08))

            if availableCaps.isEmpty {
                Text("No capabilities for \(appName)")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.5))
                    .padding(10)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(availableCaps, id: \.id) { cap in
                            CapabilityPickerRow(
                                cap: cap,
                                bundleID: bundleID,
                                atMax: pinCount >= NotchPinStore.maxPinsPerApp)
                        }
                    }
                }
                .frame(maxHeight: 220)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.96))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .frame(width: 230)
    }
}

private struct CapabilityPickerRow: View {
    let cap: AICapability
    let bundleID: String?
    let atMax: Bool
    @ObservedObject private var pinStore = NotchPinStore.shared

    private var isPinned: Bool {
        guard let bundleID else { return false }
        return pinStore.isPinned(cap.id, for: bundleID)
    }

    var body: some View {
        Button {
            guard let bundleID else { return }
            pinStore.toggle(cap.id, for: bundleID)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: notchIcon(for: cap.title))
                    .font(.system(size: 11))
                    .foregroundStyle(.cyan)
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 1) {
                    Text(cap.title)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white)
                    Text(cap.riskLevel.rawValue)
                        .font(.system(size: 9))
                        .foregroundStyle(.white.opacity(0.4))
                }
                Spacer()
                Image(systemName: isPinned ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 12))
                    .foregroundStyle(isPinned ? Color.cyan : Color.white.opacity(0.3))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(isPinned ? Color.cyan.opacity(0.1) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isPinned && atMax)
        .opacity(!isPinned && atMax ? 0.4 : 1)
    }
}

// MARK: - Fallback chip (reusable)

struct QuickChip: View {
    let title: String
    let icon: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.6))
                Text(title)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.7))
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Icon helper

func notchIcon(for title: String) -> String {
    let t = title.lowercased()
    if t.contains("summarize") || t.contains("summary") { return "text.alignleft" }
    if t.contains("save") || t.contains("export")       { return "square.and.arrow.down" }
    if t.contains("send") || t.contains("mail")         { return "paperplane" }
    if t.contains("share")                              { return "square.and.arrow.up" }
    if t.contains("search") || t.contains("find")       { return "magnifyingglass" }
    if t.contains("open") || t.contains("launch")       { return "arrow.up.right.square" }
    if t.contains("close") || t.contains("quit")        { return "xmark.circle" }
    if t.contains("copy")                               { return "doc.on.doc" }
    if t.contains("translate")                          { return "character.book.closed" }
    if t.contains("read")                               { return "eye" }
    if t.contains("create") || t.contains("new") || t.contains("add") { return "plus.circle" }
    if t.contains("tab") || t.contains("browser")       { return "safari" }
    if t.contains("file")                               { return "doc" }
    return "bolt.fill"
}
