import SwiftUI

/// Shared visual architecture for all floating DoraX surfaces.
/// Keep shell/material/spacing stable; swap mode-specific content inside.
struct UnifiedDockSurface<Content: View>: View {
    enum Size {
        case standard
        case compact
        case sheet

        var cornerRadius: CGFloat {
            switch self {
            case .standard: return 28
            case .compact: return 24
            case .sheet: return 22
            }
        }

        var shadowRadius: CGFloat {
            switch self {
            case .standard: return 24
            case .compact: return 18
            case .sheet: return 22
            }
        }
    }

    var size: Size = .standard
    var width: CGFloat? = nil
    var isDark: Bool
    @ViewBuilder var content: Content

    var body: some View {
        content
            .frame(width: width, alignment: .leading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: size.cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: size.cornerRadius, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [
                                .white.opacity(isDark ? 0.16 : 0.42),
                                .white.opacity(isDark ? 0.035 : 0.08),
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
            }
    }
}

struct UnifiedDockInputBar<Leading: View, Trailing: View>: View {
    var isFocused: Bool
    var isDark: Bool
    var height: CGFloat = 38
    @ViewBuilder var leading: Leading
    @ViewBuilder var trailing: Trailing

    init(
        isFocused: Bool,
        isDark: Bool,
        height: CGFloat = 38,
        @ViewBuilder leading: () -> Leading,
        @ViewBuilder trailing: () -> Trailing = { EmptyView() }
    ) {
        self.isFocused = isFocused
        self.isDark = isDark
        self.height = height
        self.leading = leading()
        self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: 8) {
            leading
            Spacer(minLength: 8)
            trailing
        }
        .frame(height: height)
        .padding(.horizontal, 10)
        .background {
            Capsule(style: .continuous)
                .fill(.ultraThinMaterial)
            Capsule(style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(isFocused ? (isDark ? 0.22 : 0.32) : (isDark ? 0.13 : 0.22)),
                            Color.white.opacity(isFocused ? (isDark ? 0.06 : 0.10) : (isDark ? 0.03 : 0.06)),
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
            Capsule(style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(isFocused ? (isDark ? 0.65 : 0.78) : (isDark ? 0.32 : 0.48)),
                            Color.white.opacity(isDark ? 0.06 : 0.14),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: isFocused ? 1.35 : 0.8
                )
            if isFocused {
                Capsule(style: .continuous)
                    .strokeBorder(Color.white.opacity(isDark ? 0.58 : 0.40), lineWidth: 1.1)
                    .blur(radius: 2.2)
            }
        }
    }
}

struct UnifiedDockRowBackground: View {
    var isFocused: Bool
    var isHovered: Bool
    var isEnabled: Bool = true
    var isDark: Bool
    var selectionNamespace: Namespace.ID? = nil
    var selectionEffectID: String = "unified-dock-row-focus"
    var usesMatchedGeometry: Bool = false

    var body: some View {
        rowBody
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
    }

    @ViewBuilder
    private var rowBody: some View {
        if isFocused, usesMatchedGeometry, let selectionNamespace {
            baseRowBody
                .matchedGeometryEffect(
                    id: selectionEffectID,
                    in: selectionNamespace,
                    properties: .frame,
                    isSource: false
                )
        } else {
            baseRowBody
        }
    }

    @ViewBuilder
    private var baseRowBody: some View {
        ZStack {
            if isFocused {
                Capsule(style: .continuous)
                    .fill(isDark ? AnyShapeStyle(.ultraThinMaterial) : AnyShapeStyle(Color.accentColor))
                Capsule(style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                Theme.selectionGlassTop(isDark),
                                Theme.selectionGlassBottom(isDark),
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                Capsule(style: .continuous)
                    .strokeBorder(Theme.selectionGlassRim(isDark), lineWidth: 0.9)
                if isDark {
                    Capsule(style: .continuous)
                        .strokeBorder(Color.white.opacity(0.34), lineWidth: 1.0)
                        .blur(radius: 2.0)
                }
            } else if isHovered && isEnabled {
                Capsule(style: .continuous)
                    .fill(isDark ? Color.white.opacity(0.08) : Color.accentColor.opacity(0.12))
            }
        }
    }
}

struct UnifiedDockSectionHeader: View {
    var title: String

    var body: some View {
        Text(title)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
            .tracking(0.5)
            .padding(.horizontal, 14)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.thinMaterial)
    }
}

struct UnifiedDockContextChip: View {
    var icon: String
    var title: String
    var tint: Color = .accentColor

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .lineLimit(1)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(.regularMaterial, in: Capsule(style: .continuous))
        .overlay(Capsule(style: .continuous).strokeBorder(tint.opacity(0.20), lineWidth: 0.8))
    }
}
