// UnifiedPillButton.swift
// Context-Dock
//
// One pill in the dock strip — a menu command, an app, a file, a global action.
//
// Extracted for #25 as a true leaf. Where the earlier extractions carried launcher state
// across as bindings, this one takes plain values and closures and lets the call site resolve
// everything: the accent colour, whether this pill is the focused one, whether a badge should
// show. The view holds no opinion about the launcher at all — it draws a pill and reports
// three events — which is both a smaller interface and the easier thing to reason about.
//
// That is the shape the remaining leaf extractions should follow where the state allows it.
import SwiftUI

struct UnifiedPillButton: View {
    let pill: DockPill
    let index: Int
    let isExpanded: Bool
    let isCompact: Bool

    let accent: Color

    /// This pill currently has dock focus.
    let isFocused: Bool

    /// Nothing is focused, so a badge is not competing with a focus ring for the same corner.
    let showsBadge: Bool

    let onActivate: () -> Void
    let onHoverChanged: (Bool) -> Void
    let onToggleFavourite: () -> Void

    var body: some View {
        if pill.isSeparator {
            // Render as a thin vertical divider with optional app-name label
            HStack(spacing: 3) {
                Rectangle()
                    .fill(Color.secondary.opacity(0.25))
                    .frame(width: 1, height: 16)
                if !pill.name.isEmpty {
                    Text(pill.name)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 2)
        } else {
            let iconSize: CGFloat = isExpanded ? 24 : (isCompact ? 10 : 14)
            let textSize: CGFloat = isExpanded ? 14 : (isCompact ? 10 : 12)
            let hPad: CGFloat = isExpanded ? 12 : (isCompact ? 8 : 12)
            let vPad: CGFloat = isExpanded ? 0 : (isCompact ? 4 : 7)
            Button(action: onActivate) {
                HStack(spacing: isExpanded ? 0 : (isCompact ? 4 : 6)) {
                    if let img = pill.menuItemImage {
                        FileThumbnailImage(
                            filePath: pill.quickLookURL?.path ?? pill.resolvedURL?.path,
                            fallbackImage: img,
                            systemName: pill.icon,
                            tint: accent,
                            size: iconSize,
                            cornerRadius: isExpanded ? 5 : 3,
                            isApplication: false
                        )
                        .opacity(isFocused ? 1.0 : 0.88)
                    } else {
                        FileThumbnailImage(
                            filePath: pill.quickLookURL?.path ?? pill.resolvedURL?.path,
                            fallbackImage: nil,
                            systemName: pill.icon,
                            tint: isFocused ? accent : accent.opacity(0.88),
                            size: isExpanded ? iconSize : (isCompact ? 10 : 14),
                            cornerRadius: isExpanded ? 5 : 3,
                            isApplication: false
                        )
                    }
                    if isExpanded {
                        Rectangle()
                            .fill(Color.white.opacity(0.16))
                            .frame(width: 1, height: 28)
                            .padding(.horizontal, 10)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(pill.name)
                                .font(.system(size: textSize, weight: .semibold))
                                .foregroundStyle(Color.primary)
                                .lineLimit(1)
                            if let ctx = pill.menuContext {
                                Text(ctx)
                                    .font(.system(size: 9, weight: .medium))
                                    .foregroundStyle(.secondary.opacity(0.65))
                                    .lineLimit(1)
                            }
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "return")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary.opacity(0.55))
                    } else {
                        Text(pill.name)
                            .font(.system(size: textSize, weight: .medium))
                            .foregroundStyle(Color.primary.opacity(isFocused ? 1.0 : 0.88))
                            .lineLimit(1)
                        // Badge (shortcut): only in normal scroll row
                        if let badge = pill.badge, showsBadge {
                            Text(badge)
                                .font(.system(size: 9, weight: .medium))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .fixedSize(horizontal: true, vertical: false)
                                .padding(.horizontal, 4).padding(.vertical, 1)
                                .background(.white.opacity(0.08), in: Capsule())
                        }
                    }
                }
                .frame(maxWidth: isExpanded ? .infinity : nil)
                .frame(height: isExpanded ? 44 : nil)
                .padding(.horizontal, hPad).padding(.vertical, vPad)
                // Match context dock input field: ultraThinMaterial + white gradient border
                .background {
                    if isFocused {
                        ZStack {
                            Capsule().fill(.ultraThinMaterial)
                            Capsule().fill(
                                LinearGradient(
                                    colors: [.white.opacity(0.28), .white.opacity(0.06)],
                                    startPoint: .top, endPoint: .bottom)
                            )
                            Capsule().strokeBorder(
                                LinearGradient(
                                    colors: [.white.opacity(0.65), .white.opacity(0.06)],
                                    startPoint: .topLeading, endPoint: .bottomTrailing),
                                lineWidth: 1.5)
                            Capsule()
                                .strokeBorder(Color.white.opacity(0.75), lineWidth: 1.5)
                                .blur(radius: 3)
                        }
                    } else {
                        ZStack {
                            Capsule().fill(.ultraThinMaterial)
                            Capsule().fill(
                                LinearGradient(
                                    colors: [.white.opacity(0.14), .white.opacity(0.02)],
                                    startPoint: .top, endPoint: .bottom)
                            )
                            Capsule().strokeBorder(
                                LinearGradient(
                                    colors: [.white.opacity(0.32), .white.opacity(0.06)],
                                    startPoint: .topLeading, endPoint: .bottomTrailing),
                                lineWidth: 0.75)
                        }
                    }
                }
                .shadow(
                    color: isFocused ? .white.opacity(0.22) : .clear,
                    radius: isFocused ? 10 : 0, y: isFocused ? -1 : 0
                )
                .animation(.spring(response: 0.18, dampingFraction: 0.75), value: isFocused)
            }
            .buttonStyle(.plain)
            .help(pill.name)
            .onHover(perform: onHoverChanged)
            // Right-click context menu — shows Favourite / Unfavourite for menu item pills
            .contextMenu {
                if !pill.menuItemName.isEmpty, !pill.sourceBundleId.isEmpty {
                    Button(action: onToggleFavourite) {
                        Label(
                            pill.isFavourited ? "Remove from Favourites" : "Add to Favourites",
                            systemImage: pill.isFavourited ? "star.slash" : "star"
                        )
                    }
                }
            }
        }  // end else (non-separator)
    }
}
