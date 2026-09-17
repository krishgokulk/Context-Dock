// Context-Dock
//
// Which host is asking the renderer to draw. One renderer, many hosts: a host never forks a
// component, it passes different traits. Spec §5.

import CoreGraphics
import Foundation

enum PluginWidthClass: String, Equatable { case regular, compact }

/// How much animation a host can afford right now. The strip drops to `.low` while it is
/// shrunk; a hidden host is `.none` and live components freeze rather than tick unseen.
enum PluginLiveBudget: String, Equatable { case full, low, none }

struct HostTraits: Equatable {
    var presentation: PluginPresentation
    var widthClass: PluginWidthClass
    var keyboardOwner: Bool
    var liveBudget: PluginLiveBudget
    var width: CGFloat
    var maxHeight: CGFloat

    static let dockSheet = HostTraits(
        presentation: .panel, widthClass: .regular, keyboardOwner: true,
        liveBudget: .full, width: 560, maxHeight: 420)

    static let cornerPanel = HostTraits(
        presentation: .panel, widthClass: .compact, keyboardOwner: true,
        liveBudget: .low, width: 380, maxHeight: 360)

    /// A strip icon is one slot; a `bar` widget is `slots` of them with the strip's own gap
    /// between, so the tile lines up with the icons on either side of it.
    static let stripSlot: CGFloat = 48
    static let stripGap: CGFloat = 8

    static func barWidth(slots: Int) -> CGFloat {
        let n = CGFloat(max(1, slots))
        return n * stripSlot + (n - 1) * stripGap
    }

    static func strip(
        _ presentation: PluginPresentation, family: PluginWidgetFamily = .small,
        slots: Int = PluginWidgetView.defaultSlots
    ) -> HostTraits {
        let size: CGSize
        switch (presentation, family) {
        case (.icon, _): size = CGSize(width: stripSlot, height: stripSlot)
        case (_, .bar): size = CGSize(width: barWidth(slots: slots), height: stripSlot)
        case (_, .small): size = CGSize(width: 156, height: 156)
        case (_, .medium): size = CGSize(width: 328, height: 156)
        case (_, .large): size = CGSize(width: 328, height: 328)
        }
        return HostTraits(
            presentation: presentation, widthClass: .compact, keyboardOwner: false,
            liveBudget: .low, width: size.width, maxHeight: size.height)
    }

    /// The strip's bar tile: everything inside has to fit in one icon's height.
    var isBar: Bool { presentation == .widget && maxHeight <= HostTraits.stripSlot }

    /// Spec §5: 360 / 480 / 640 wide, content height up to 70 % of the screen.
    static func window(_ width: PluginWindowWidth, screenHeight: CGFloat) -> HostTraits {
        let points: CGFloat
        switch width {
        case .narrow: points = 360
        case .regular: points = 480
        case .wide: points = 640
        }
        return HostTraits(
            presentation: .window, widthClass: width == .narrow ? .compact : .regular,
            keyboardOwner: true, liveBudget: .full,
            width: points, maxHeight: (screenHeight * 0.7).rounded(.down))
    }

    /// The Creator previews any presentation at the size its real host would give it.
    static func creatorPreview(_ presentation: PluginPresentation) -> HostTraits {
        switch presentation {
        case .icon, .widget: return .strip(presentation)
        case .panel: return .dockSheet
        case .window: return .window(.regular, screenHeight: 900)
        }
    }
}
