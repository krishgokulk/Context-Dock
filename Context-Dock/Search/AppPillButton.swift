// AppPillButton.swift
// Context-Dock
//
// One app pill in the dock — running app, pinned app, or a search result standing in for one.
//
// Extracted for #25. It was already close to a standalone view: thirteen parameters, most of
// them values and optional closures. Only four things tied it to the launcher — the icon size
// from settings, the colour scheme, whether this pill is hovered, and the hover handler that
// writes back which pill the pointer is on. Those are now parameters like the rest, so the
// call site decides them and this draws.
//
// Worth extracting early despite its size: `pinnedAndRecentAppsRow` and
// `globalAppSearchPillRow` both call it, and neither can become a view of its own while it is
// still a member of LauncherView.
import AppKit
import SwiftUI

struct AppPillButton: View {
    let icon: NSImage?
    let label: String
    var subtitle: String? = nil
    let hoverKey: String
    var focused: Bool = false
    var index: Int? = nil
    /// Fills the vacated search-bar width.
    var isExpanded: Bool = false
    var destructiveAction: (() -> Void)? = nil
    var destructivePhase: DockInlineFeedback.Phase? = nil
    var removeAction: (() -> Void)? = nil
    var pinAction: (() -> Void)? = nil
    var previewApp: NSRunningApplication? = nil
    let action: () -> Void

    /// The pointer is on this pill. Resolved by the caller, which owns the hover key.
    let isHovered: Bool

    /// `AppSettings.dockIconSize`; every other dimension here is derived from it.
    let dockIconSize: Double

    let isDark: Bool

    let onHoverChanged: (Bool) -> Void

    var body: some View {
        let hovered = isHovered || focused
        let sz = CGFloat(dockIconSize)
        let iconSize: CGFloat = isExpanded ? sz * 0.78 : sz * 0.72
        let textSize: CGFloat = min(isExpanded ? 15 : 13, max(12, sz * (isExpanded ? 0.24 : 0.22)))
        let pillHeight: CGFloat = isExpanded ? sz + 8 : sz + 4
        let cornerRadius: CGFloat = max(5, iconSize / 4.2)
        let leadingPad: CGFloat = isExpanded ? max(10, sz * 0.20) : max(10, sz * 0.18)
        let separatorHeight: CGFloat = isExpanded ? max(24, sz * 0.50) : max(24, sz * 0.46)
        let trailingPad: CGFloat =
            isExpanded ? 12 : (destructiveAction != nil || removeAction != nil ? 8 : 12)

        ZStack(alignment: .topTrailing) {
            Button(action: action) {
                HStack(spacing: 0) {
                    if let icon {
                        Image(nsImage: icon)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: iconSize, height: iconSize)
                            .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
                            .padding(.leading, leadingPad)
                    } else {
                        Image(systemName: "app.fill")
                            .font(.system(size: iconSize * 0.72, weight: .medium))
                            .foregroundStyle(.secondary)
                            .frame(width: iconSize, height: iconSize)
                            .padding(.leading, leadingPad)
                    }
                    Rectangle()
                        .fill(Color.white.opacity(isExpanded ? 0.16 : 0.12))
                        .frame(width: 1, height: separatorHeight)
                        .padding(.horizontal, isExpanded ? 10 : 8)
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 4) {
                            Text(label)
                                .font(
                                    .system(
                                        size: textSize, weight: isExpanded ? .semibold : .medium)
                                )
                                .foregroundStyle(
                                    Color.primary.opacity(isExpanded ? 1.0 : (focused ? 1.0 : 0.9)))
                            if destructiveAction != nil {
                                Image(systemName: "chevron.right")
                                    .font(.system(size: max(9, textSize - 3), weight: .semibold))
                                    .foregroundStyle(.secondary.opacity(isExpanded ? 0.75 : 0.62))
                            }
                        }
                        .lineLimit(1)
                        if isExpanded, let sub = subtitle {
                            Text(sub)
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(
                                    sub == "Running"
                                        ? Color.green.opacity(0.85)
                                        : Color.secondary.opacity(0.65)
                                )
                                .lineLimit(1)
                        }
                    }
                    .padding(.trailing, isExpanded ? 4 : trailingPad)
                    .mask(alignment: .leading) {
                        // Smooth gradient fade on the trailing edge for expanded pills
                        if isExpanded {
                            LinearGradient(
                                stops: [
                                    .init(color: .black, location: 0),
                                    .init(color: .black, location: 0.75),
                                    .init(color: .clear, location: 1.0),
                                ],
                                startPoint: .leading, endPoint: .trailing)
                        } else {
                            Color.black
                        }
                    }
                    if isExpanded {
                        Spacer(minLength: 0)
                        Image(systemName: "return")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary.opacity(0.55))
                        .padding(.trailing, 12)
                    }
                }
                .frame(maxWidth: isExpanded ? .infinity : nil)
                .frame(height: pillHeight)
                .background {
                    ZStack {
                        Capsule().fill(.ultraThinMaterial)
                        Capsule().fill(
                            isDark
                                ? Color.black.opacity(isExpanded ? 0.10 : 0.06)
                                : Color.white.opacity(isExpanded ? 0.22 : 0.14)
                        )
                        Capsule().fill(
                            LinearGradient(
                                colors: [
                                    .white.opacity(
                                        isExpanded
                                            ? 0.18 : (focused ? 0.16 : (hovered ? 0.12 : 0.07))),
                                    .white.opacity(isExpanded ? 0.035 : (focused ? 0.04 : 0.015)),
                                ],
                                startPoint: .top, endPoint: .bottom)
                        )
                        Capsule().strokeBorder(
                            LinearGradient(
                                colors: [
                                    .white.opacity(isExpanded ? 0.34 : (hovered ? 0.28 : 0.16)),
                                    .white.opacity(0.035),
                                ],
                                startPoint: .topLeading, endPoint: .bottomTrailing),
                            lineWidth: isExpanded ? 1.0 : (focused ? 1.0 : 0.75))
                    }
                }
                .shadow(
                    color: .black.opacity(
                        isExpanded ? 0.20 : (focused ? 0.16 : (hovered ? 0.10 : 0.06))),
                    radius: isExpanded ? 10 : (focused ? 8 : 5),
                    y: isExpanded ? 5 : 3
                )
                .animation(.spring(response: 0.22, dampingFraction: 0.75), value: isExpanded)
                .animation(.spring(response: 0.18, dampingFraction: 0.75), value: focused)
            }
            .buttonStyle(.plain)
            .zIndex(isExpanded ? 20 : (focused ? 10 : (hovered ? 5 : 0)))

            if (hovered || destructivePhase != nil), !isExpanded, let quit = destructiveAction {
                Button(action: quit) {
                    Group {
                        if destructivePhase == .progress {
                            ProgressView()
                                .controlSize(.small)
                                .scaleEffect(0.56)
                                .frame(width: max(14, sz * 0.24), height: max(14, sz * 0.24))
                        } else if destructivePhase == .success {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: max(14, sz * 0.24), weight: .semibold))
                                .foregroundStyle(.white, Color.green.opacity(0.78))
                        } else {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: max(14, sz * 0.24), weight: .semibold))
                                .foregroundStyle(.white, Color.black.opacity(0.65))
                        }
                    }
                }
                .buttonStyle(.plain)
                .offset(x: max(4, sz * 0.08), y: -max(4, sz * 0.08))
                .transition(.scale(scale: 0.6).combined(with: .opacity))
            } else if hovered, !isExpanded, let remove = removeAction {
                Button(action: remove) {
                    Image(systemName: "minus.circle.fill")
                        .font(.system(size: max(14, sz * 0.24), weight: .semibold))
                        .foregroundStyle(.white, Color.black.opacity(0.65))
                }
                .buttonStyle(.plain)
                .offset(x: max(4, sz * 0.08), y: -max(4, sz * 0.08))
                .transition(.scale(scale: 0.6).combined(with: .opacity))
            }

        }
        .onHover(perform: onHoverChanged)
        .help(label)
    }
}
