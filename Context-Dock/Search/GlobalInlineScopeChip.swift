// GlobalInlineScopeChip.swift
// Context-Dock
//
// One scope chip in the search field — the app, folder or CLI tool a query is scoped to.
//
// Extracted for #25 as a true leaf. Its whole relationship with the launcher was four things:
// the colour scheme, whether the pointer is on it, and the two things a click can mean.
//
// A click means different things depending on hover, and that stays here because it is about
// this chip: hovered, the chip is showing its remove affordance and a click removes the scope;
// not hovered, a click is really a click on the field behind it and the field should take
// focus back. The launcher supplies what each of those does, not when.
import AppKit
import SwiftUI

struct GlobalInlineScopeChip: View {
    let scope: LauncherView.GlobalInlineAppScope

    let isHovered: Bool
    let isDark: Bool

    /// This scope's chip is a CLI tool rather than an app — drawn differently.
    let isCLIToolScope: (LauncherView.GlobalInlineAppScope) -> Bool

    /// Clicked while hovered: drop this scope and put focus back in the field.
    let onRemove: () -> Void

    /// Clicked while not hovered: the field behind should take focus.
    let onTapWhileNotHovered: () -> Void

    let onHoverChanged: (Bool) -> Void

    var body: some View {
        let icon: NSImage = {
            if scope.bundleId.hasPrefix("syscmd://") {
                let id = String(scope.bundleId.dropFirst("syscmd://".count))
                if let uuid = UUID(uuidString: id),
                    let command = SystemCommandsRegistry.shared.commands.first(where: { $0.id == uuid }),
                    let image = NSImage(systemSymbolName: command.icon, accessibilityDescription: command.name)
                {
                    return image
                }
            }
            if isCLIToolScope(scope),
                let image = NSImage(systemSymbolName: "terminal.fill", accessibilityDescription: scope.appName)
            {
                return image
            }
            return FileManager.default.fileExists(atPath: scope.appPath)
                ? NSWorkspace.shared.icon(forFile: scope.appPath)
                : NSWorkspace.shared.icon(
                    forFile: NSWorkspace.shared.urlForApplication(
                        withBundleIdentifier: scope.bundleId)?.path ?? "")
        }()
        let accent = icon.dominantSwiftUIColor
        let hoverAccent = SwiftUI.Color.red
        let activeAccent = isHovered ? hoverAccent : accent
        let labelColor: SwiftUI.Color =
            isDark
            ? .white.opacity(0.96)
            : .black.opacity(0.88)

        return HStack(spacing: 5) {
            Image(nsImage: icon)
                .resizable()
                .renderingMode(.original)
                .aspectRatio(contentMode: .fit)
                .frame(width: 16, height: 16)
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            Text(scope.matchedAlias.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? scope.appName
                : scope.matchedAlias)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(labelColor)
                .shadow(color: .black.opacity(isDark ? 0.35 : 0.08), radius: 1, y: 0.5)
        }
            .padding(.leading, 7)
            .padding(.trailing, 8)
            .padding(.vertical, 3)
            .background(.ultraThinMaterial, in: Capsule(style: .continuous))
            .background(
                activeAccent.opacity(
                    isHovered
                    ? (isDark ? 0.34 : 0.24)
                    : (isDark ? 0.26 : 0.16)
                ),
                in: Capsule(style: .continuous)
            )
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(isHovered ? 0.58 : 0.50),
                                activeAccent.opacity(
                                    isHovered
                                    ? (isDark ? 0.72 : 0.48)
                                    : (isDark ? 0.38 : 0.24)
                                ),
                                Color.white.opacity(0.10),
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 0.9
                            )
            )
            .shadow(
                color: activeAccent.opacity(
                    isHovered
                    ? (isDark ? 0.42 : 0.28)
                    : 0.0
                ),
                radius: isHovered ? 9 : 0,
                x: 0,
                y: 0
            )
            .shadow(color: .black.opacity(isHovered ? 0.18 : 0.20), radius: 6, x: 0, y: 2)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .onTapGesture { isHovered ? onRemove() : onTapWhileNotHovered() }
            .zIndex(isHovered ? 10 : 0)
            // Small margin so the chip stays separated from adjacent query text at the
            // tighter inline spacing (without leaving a stray gap before the caret).
            .padding(.horizontal, 3)
            .transition(
                .asymmetric(
                    insertion: .scale(scale: 0.82, anchor: .leading).combined(with: .opacity),
                    removal: .opacity
                )
            )
            .focusable(false)
            .focusEffectDisabled()
            .help(isHovered ? "Click to remove \(scope.appName) scope" : "\(scope.appName) scope")
            .contentShape(Rectangle())
            .onHover(perform: onHoverChanged)
    }
}
