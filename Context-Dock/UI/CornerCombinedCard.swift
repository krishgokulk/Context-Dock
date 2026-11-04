// CornerCombinedCard.swift
// Context-Dock
//
// Centred (⌥⌥), the field, the apps beside it and the result sheet are one card, the way
// Spotlight is one panel, rather than three pieces of glass (owner 2026-10-12: "result sheet
// combined, not separate"). The pieces read `sharesOneCard` and leave their own glass off;
// the card draws one behind all of them.

import AppKit
import SwiftUI

/// An AppKit background view that enables native Spotlight-style window dragging on empty space.
/// Buttons, TextFields, and list items in front handle their own mouse events, while
/// any drag on empty space smoothly updates the launcher's offset and double-click resets it.
struct LauncherDragBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> DragView {
        DragView()
    }
    func updateNSView(_ nsView: DragView, context: Context) {}

    final class DragView: NSView {
        private var initialMouse: NSPoint = .zero
        private var initialWindowOrigin: NSPoint = .zero
        private var initialOffsetX: Double = 0
        private var initialOffsetY: Double = 0
        private var isDragging = false

        override var mouseDownCanMoveWindow: Bool { false }

        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2 {
                AppSettings.shared.resetCentredLauncherPosition()
                CornerDockController.shared.repositionCentredLauncher()
                return
            }
            initialMouse = NSEvent.mouseLocation
            initialWindowOrigin = window?.frame.origin ?? .zero
            initialOffsetX = AppSettings.shared.centredLauncherOffsetX
            initialOffsetY = AppSettings.shared.centredLauncherOffsetY
            isDragging = false
        }

        override func mouseDragged(with event: NSEvent) {
            guard let window = self.window else { return }
            let current = NSEvent.mouseLocation
            let dx = current.x - initialMouse.x
            let dy = current.y - initialMouse.y
            if !isDragging && abs(dx) < 2 && abs(dy) < 2 { return }
            isDragging = true
            let isCentredMode = CornerDockController.shared.chatPresentation.isCentred
                || AppSettings.shared.launcherPresentationMode == .centerScreen
            guard isCentredMode else { return }

            let screen = window.screen ?? NSScreen.main
            let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
            let maxOffsetY = Double(max(0, visible.maxY - (visible.minY + visible.height * 0.62 + CornerDockLayout.pad) - 40))
            let minOffsetY = Double(-(visible.height * 0.45))
            let maxOffsetX = Double(visible.width * 0.4)

            let newOffsetX = min(max(-maxOffsetX, initialOffsetX + Double(dx)), maxOffsetX)
            let newOffsetY = min(max(minOffsetY, initialOffsetY + Double(dy)), maxOffsetY)
            AppSettings.shared.centredLauncherOffsetX = newOffsetX
            AppSettings.shared.centredLauncherOffsetY = newOffsetY

            let targetOrigin = NSPoint(
                x: initialWindowOrigin.x + CGFloat(newOffsetX - initialOffsetX),
                y: initialWindowOrigin.y + CGFloat(newOffsetY - initialOffsetY)
            )
            window.setFrameOrigin(targetOrigin)
            CornerDockController.shared.updateShownPanelOrigin(targetOrigin)
        }
    }
}

private struct SharesOneCardKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var sharesOneCard: Bool {
        get { self[SharesOneCardKey.self] }
        set { self[SharesOneCardKey.self] = newValue }
    }
}

struct CornerCombinedCard: ViewModifier {
    let active: Bool
    static let radius: CGFloat = 28
    static let inset: CGFloat = 6

    // One view structure whether or not the card is up — only values change. An if/else
    // here made SwiftUI build a new text field the moment the first letter brought the sheet
    // up, and a new field selects its text, so the next key replaced the first (owner
    // 2026-10-12).
    func body(content: Content) -> some View {
        content
            .environment(\.sharesOneCard, active)
            .padding(active ? Self.inset : 0)
            .background {
                ZStack {
                    LauncherDragBackground()
                    RoundedRectangle(cornerRadius: Self.radius, style: .continuous)
                        .fill(Color.clear)
                        .background(GlassBackground(cornerRadius: Self.radius, isDark: true))
                        .clipShape(RoundedRectangle(cornerRadius: Self.radius, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: Self.radius, style: .continuous)
                                .strokeBorder(Color.white.opacity(0.16), lineWidth: 1))
                        .shadow(color: .black.opacity(0.34), radius: 24, y: 12)
                        // An app opening or quitting glows the one card, as it glows the dock.
                        .modifier(AppLaunchGlow(
                            shape: RoundedRectangle(cornerRadius: Self.radius, style: .continuous)))
                        .opacity(active ? 1 : 0)
                }
            }
    }
}

/// A board's own glass — or nothing but a hairline when it already sits in the centred card,
/// where a second glass under the first is what made the clipboard and a command's panel
/// read far darker than the result sheet (owner 2026-10-12).
struct BoardGlass: ViewModifier {
    var radius: CGFloat = 22
    @Environment(\.sharesOneCard) private var sharesOneCard

    func body(content: Content) -> some View {
        content.background {
            if sharesOneCard {
                Rectangle().fill(Color.white.opacity(0.10)).frame(height: 1)
                    .frame(maxHeight: .infinity, alignment: .top)
            } else {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(Color.clear)
                    .background(GlassBackground(cornerRadius: radius, isDark: nil))
                    .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: radius, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.16), lineWidth: 1))
                    .shadow(color: .black.opacity(0.34), radius: 20, y: 10)
            }
        }
    }
}
