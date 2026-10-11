// SharedResultRow.swift
// Context-Dock
//
// One row in a shared result list — clipboard, notifications, and the other compact scopes.
//
// Extracted for #25, as a true leaf: it draws from its model and calls no other view member,
// which is what makes a nominal boundary here actually terminate the opaque-type chain rather
// than re-enter it through a @ViewBuilder parameter.
//
// Everything about the row itself already lived in `SharedResultRowModel`. What had to come
// across is the surrounding state the row consults to decide how to look and whether to react
// to a hover: the theme, the two scope predicates, the focus namespace it matches geometry
// into, and the keyboard-navigation flag it turns off when the mouse takes over.
import SwiftUI

struct SharedResultRow: View {
    let row: SharedResultRowModel

    let isEffectiveDark: Bool

    /// A hover only takes focus when the dock is accepting mouse-driven interaction and the
    /// scope is not a compact one. Both are the launcher's judgement, not this row's.
    let acceptsMouseDrivenDockInteraction: Bool
    let isCompactSmartScope: Bool

    /// Written, not just read: the mouse taking over focus is what turns keyboard navigation
    /// off, so this needs to reach back to the launcher.
    @Binding var isKeyboardNavigation: Bool

    let focusEffectID: String
    let focusNamespace: Namespace.ID

    let accentColor: (String?) -> SwiftUI.Color

    /// The row took focus because the pointer moved onto it.
    let onFocusedByHover: () -> Void

    var body: some View {
        Button {
            row.open()
        } label: {
            HStack(spacing: 12) {
                ZStack {
                    if let image = row.image {
                        Image(nsImage: image)
                            .resizable()
                            .interpolation(.high)
                            .aspectRatio(contentMode: .fill)
                            .frame(width: 30, height: 30)
                            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    } else {
                        Image(systemName: row.systemIcon)
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(accentColor(row.accentColorName))
                    }
                }
                .frame(width: 34, height: 34)
                .opacity(row.isEnabled ? 1 : 0.38)

                VStack(alignment: .leading, spacing: 2) {
                    Text(row.title)
                        .font(.system(size: 13, weight: row.isUnread ? .semibold : .medium))
                        .foregroundStyle(row.isEnabled ? .primary : .secondary)
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        if !row.subtitle.isEmpty {
                            Text(row.subtitle)
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        ForEach(row.badges, id: \.self) { badge in
                            Text(badge)
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(
                                    Color.primary.opacity(0.07),
                                    in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                        }
                    }
                }
                .opacity(row.isEnabled ? 1 : 0.46)

                Spacer(minLength: 12)

                if let sourceImage = row.sourceImage {
                    Image(nsImage: sourceImage)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 18, height: 18)
                        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                        .padding(3)
                        .background(
                            .ultraThinMaterial,
                            in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .strokeBorder(Color.white.opacity(0.16), lineWidth: 0.6)
                        )
                }

                if let trailing = row.trailingText {
                    Text(trailing)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .fixedSize()
                }

                if row.isExpandable, let toggle = row.toggleExpand {
                    Button {
                        toggle()
                    } label: {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.secondary.opacity(0.8))
                            .rotationEffect(.degrees(row.isExpanded ? 0 : -90))
                            .frame(width: 22, height: 22)
                            .background(Color.white.opacity(0.06), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .help(row.isExpanded ? "Collapse files" : "Expand files")
                }

                if let copy = row.copy {
                    Button {
                        copy()
                    } label: {
                        Image(systemName: "doc.on.clipboard")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary.opacity(0.72))
                            .frame(width: 22, height: 22)
                            .background(Color.white.opacity(0.06), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .help("Copy")
                }
            }
            .padding(.leading, row.isChild ? 34 : 12)
            .padding(.trailing, 12)
            .padding(.vertical, row.isChild ? 4 : 6)
            .contentShape(Rectangle())
            .background(
                ZStack {
                    if row.isFocused {
                        Capsule(style: .continuous)
                            .fill(.ultraThinMaterial)
                            .matchedGeometryEffect(
                                id: focusEffectID,
                                in: focusNamespace,
                                properties: .frame,
                                isSource: false
                            )
                        Capsule(style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [
                                        Color.white.opacity(isEffectiveDark ? 0.18 : 0.24),
                                        Color.white.opacity(isEffectiveDark ? 0.055 : 0.10),
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                        Capsule(style: .continuous)
                            .strokeBorder(
                                LinearGradient(
                                    colors: [
                                        Color.white.opacity(0.34),
                                        Color.white.opacity(0.08),
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ),
                                lineWidth: 0.8
                            )
                        Capsule(style: .continuous)
                            .strokeBorder(Color.white.opacity(0.38), lineWidth: 1.0)
                            .blur(radius: 2.2)
                    } else if row.isUnread {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color.accentColor.opacity(0.07))
                    }
                }
            )
            .padding(.horizontal, 8)
            .padding(.vertical, 1)
        }
        .buttonStyle(.plain)
        .disabled(!row.isEnabled)
        .modifier(OptionalDragProviderModifier(provider: row.dragProvider))
        .onHover { hovering in
            guard hovering, acceptsMouseDrivenDockInteraction else { return }
            guard !isCompactSmartScope else { return }
            if isKeyboardNavigation {
                isKeyboardNavigation = false
            }
            row.focus()
            onFocusedByHover()
        }
        .animation(.dockStandard, value: row.isFocused)
        .contextMenu {
            if let copy = row.copy {
                Button("Copy") { copy() }
            }
            if let markRead = row.markRead {
                Button("Mark as Read") { markRead() }
            }
            if let remove = row.remove {
                Button("Remove", role: .destructive) { remove() }
            }
        }
    }
}
