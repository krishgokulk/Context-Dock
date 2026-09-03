import SwiftUI

@MainActor
enum ChatSlashAppPicker {
    static func openInline(text: inout String) {
        guard !text.hasPrefix("/") else { return }
        text = "/"
    }

    static func matches(for text: String) -> [ChatAppEntry] {
        guard text.hasPrefix("/") else { return [] }
        let filter = String(text.dropFirst())
        guard !filter.contains(" ") else { return [] }
        return ChatAppDirectory.matching(filter.lowercased())
    }

    /// Where ↑/↓ lands, or nil when there is no list and the key belongs to the field.
    ///
    /// Clamped rather than wrapped: arrowing off the end of a short list and reappearing at
    /// the top reads as the selection having been lost, and this list is usually two rows.
    static func movedSelection(from current: Int, by delta: Int, count: Int) -> Int? {
        guard count > 0 else { return nil }
        return min(max(current + delta, 0), count - 1)
    }

    @discardableResult
    static func pickLeadingMatch(
        text: inout String,
        onPick: (ChatAppEntry) -> Void
    ) -> Bool {
        guard let match = matches(for: text).first else { return false }
        onPick(match)
        text = ""
        return true
    }
}

/// The `/` matches as a list above the composer, the way the clipboard's own panel stacks
/// its rows over its field.
///
/// A horizontal strip of capsules was the wrong shape for the corner: at 372 points it fits
/// three apps, so the fourth match was reachable only by scrolling sideways in a control the
/// user had no reason to think scrolled. A list reads top to bottom, shows the same rows the
/// rest of this app shows, and grows the card by a number the corner can compute.
struct ChatSlashAppList: View {
    let matches: [ChatAppEntry]
    /// Which row ↑/↓ has landed on, and the one Return takes. The list draws the selection;
    /// the surface owning the keyboard moves it.
    var selection: Int = 0
    let onPick: (ChatAppEntry) -> Void

    /// Enough to choose from without the list becoming the surface. Past this it scrolls.
    static let maxVisibleRows = 5
    static let rowHeight: CGFloat = 34
    /// Room above the first row and below the last. Without it the top row's highlight
    /// runs into the card's rounded top edge, and a selected first row reads as clipped
    /// rather than selected.
    static let verticalInset: CGFloat = 6

    static func height(for matchCount: Int) -> CGFloat {
        guard matchCount > 0 else { return 0 }
        return CGFloat(min(matchCount, maxVisibleRows)) * rowHeight + verticalInset * 2
    }

    @State private var hovered: String?

    /// Clamped, because the filter narrows under the cursor: typing another letter can
    /// leave the selection pointing past the end of a shorter list.
    private var selectedIndex: Int {
        guard !matches.isEmpty else { return 0 }
        return min(max(selection, 0), matches.count - 1)
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(Array(matches.enumerated()), id: \.element.id) { index, app in
                    Button { onPick(app) } label: {
                        HStack(spacing: 10) {
                            Group {
                                if let icon = app.icon {
                                    Image(nsImage: icon)
                                        .resizable()
                                        .aspectRatio(contentMode: .fit)
                                } else {
                                    Image(systemName: "app.dashed")
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .frame(width: 18, height: 18)
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                            .overlay(alignment: .bottomTrailing) {
                                if app.isRunning {
                                    Circle()
                                        .fill(.green)
                                        .frame(width: 6, height: 6)
                                        .overlay(
                                            Circle().stroke(.black.opacity(0.4), lineWidth: 1))
                                }
                            }

                            Text(app.name)
                                .font(.system(size: 13, weight: .medium))
                                .lineLimit(1)

                            Spacer(minLength: 4)

                            // Return takes the selected row, so the selected row says so.
                            if index == selectedIndex {
                                Text("↩")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.horizontal, 14)
                        .frame(height: Self.rowHeight)
                        .background(
                            rowTint(index: index, app: app),
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                        )
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .id(index)
                    .onHover { hovered = $0 ? app.id : (hovered == app.id ? nil : hovered) }
                    .help(app.isRunning ? "\(app.name) — running" : app.name)
                    }
                }
                .padding(.horizontal, 6)
                .padding(.vertical, Self.verticalInset)
            }
            .frame(height: Self.height(for: matches.count))
            // Arrowing past the fifth row has to bring it into view, or the selection is
            // somewhere the user cannot see.
            .onChange(of: selectedIndex) { _, index in
                withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(index) }
            }
        }
    }

    private func rowTint(index: Int, app: ChatAppEntry) -> Color {
        if index == selectedIndex { return Color.accentColor.opacity(0.22) }
        if hovered == app.id { return Color.primary.opacity(0.1) }
        return .clear
    }
}

struct ChatSlashAppChipStrip: View {
    let matches: [ChatAppEntry]
    let onPick: (ChatAppEntry) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(matches) { app in
                    Button { onPick(app) } label: {
                        HStack(spacing: 7) {
                            Group {
                                if let icon = app.icon {
                                    Image(nsImage: icon)
                                        .resizable()
                                        .aspectRatio(contentMode: .fit)
                                } else {
                                    Image(systemName: "app.dashed")
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .frame(width: 18, height: 18)
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                            .overlay(alignment: .bottomTrailing) {
                                if app.isRunning {
                                    Circle()
                                        .fill(.green)
                                        .frame(width: 6, height: 6)
                                        .overlay(Circle().stroke(.black.opacity(0.4), lineWidth: 1))
                                }
                            }

                            Text(app.name)
                                .font(.system(size: 12.5, weight: .semibold))
                                .lineLimit(1)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(.ultraThinMaterial, in: Capsule())
                        .background(
                            app.id == matches.first?.id
                                ? Color.accentColor.opacity(0.16) : Color.clear,
                            in: Capsule())
                        .overlay {
                            Capsule().strokeBorder(
                                app.id == matches.first?.id
                                    ? Color.accentColor.opacity(0.75)
                                    : Color.white.opacity(0.16),
                                lineWidth: 1)
                        }
                    }
                    .buttonStyle(.plain)
                    .help(app.isRunning ? "\(app.name) — running" : app.name)
                }
            }
            .padding(.horizontal, 2)
        }
    }
}
