import Observation
import SwiftUI

/// The Dock's continuous magnification, as arithmetic: where the pointer is and where the
/// icons rest in, scales and shifts out. Pure so the curve is tested and the corner's drawing
/// and hit-testing read one number (`AppChatPromptMetrics` rule: nothing measured from a view
/// decides a size).
enum DockMagnification {
    /// The largest an icon grows, at the pointer.
    static let peak: CGFloat = 1.7
    /// Beyond this distance from the pointer an icon is at rest: 2.5 icon pitches.
    static let radius: CGFloat = 2.5 * (AppChatPromptMetrics.dockIconSize + AppChatPromptMetrics.dockIconGap)
    /// The icon artwork a scale multiplies — what neighbours must make room for.
    static let artwork: CGFloat = AppChatPromptMetrics.dockIconSize - 8
    /// How far above the dock's top edge a peak icon reaches, with the lift of the spring.
    static let headroom: CGFloat = 40

    /// Raised cosine: `peak` at the pointer, 1 from `radius` on, smooth at both ends.
    static func scale(distance: CGFloat) -> CGFloat {
        let d = abs(distance)
        guard d < radius else { return 1 }
        return 1 + (peak - 1) * 0.5 * (1 + cos(.pi * d / radius))
    }

    struct Item: Equatable {
        var scale: CGFloat = 1
        /// How far the icon's centre moves from rest.
        var shift: CGFloat = 0
    }

    struct Layout: Equatable {
        var items: [Item]
        /// How much wider the row gets; the glass grows by this, half on each side.
        var extra: CGFloat
    }

    /// The row with the pointer on it. Icons grow in place and push each other apart so the
    /// row stays in order; it widens by `extra` evenly about its middle, which is what the
    /// glass does, so the pointer is mapped back into rest space (a few passes of a fixed
    /// point) before the curve reads it — the icon under the pointer is the one that peaks.
    /// `centers` are rest centres, ascending. Nil pointer: everything at rest.
    static func layout(centers: [CGFloat], pointer: CGFloat?) -> Layout {
        let rest = Layout(items: Array(repeating: Item(), count: centers.count), extra: 0)
        guard let pointer, !centers.isEmpty else { return rest }
        var q = pointer
        var result = rest
        for _ in 0..<4 {
            let scales = centers.map { scale(distance: q - $0) }
            let widths = scales.map { ($0 - 1) * artwork }
            let extra = widths.reduce(0, +)
            var before: CGFloat = 0
            var items: [Item] = []
            for (i, s) in scales.enumerated() {
                items.append(Item(scale: s, shift: before + widths[i] / 2 - extra / 2))
                before += widths[i]
            }
            result = Layout(items: items, extra: extra)
            q = pointer - shift(at: q, centers: centers, items: items)
        }
        return result
    }

    /// The displacement of the rest point `x`, between the icons' own.
    private static func shift(at x: CGFloat, centers: [CGFloat], items: [Item]) -> CGFloat {
        if x <= centers[0] { return items[0].shift }
        for i in 1..<centers.count where x <= centers[i] {
            let t = (x - centers[i - 1]) / max(centers[i] - centers[i - 1], 1)
            return items[i - 1].shift + t * (items[i].shift - items[i - 1].shift)
        }
        return items[items.count - 1].shift
    }
}

/// What the strip's icons read: the pointer on the strip, the rest centres they report, and
/// the layout those make. An object of its own, read by each icon and by the glass, so a
/// pointer move redraws those and not the strip around them.
@MainActor @Observable
final class DockMagnifier {
    static let shared = DockMagnifier()

    private(set) var layout = DockMagnification.Layout(items: [], extra: 0)
    /// The pointer is on the strip, so the room above it is part of the dock.
    private(set) var isEngaged = false
    private var pointer: CGFloat?
    private var centers: [String: CGFloat] = [:]
    private var order: [String] = []

    func setPointer(_ x: CGFloat?) {
        pointer = x
        if (x != nil) != isEngaged { isEngaged = x != nil }
        recompute()
    }

    func setCenter(_ x: CGFloat, for id: String) {
        guard centers[id] != x else { return }
        centers[id] = x
        recompute()
    }

    func forget(_ id: String) {
        guard centers.removeValue(forKey: id) != nil else { return }
        recompute()
    }

    func item(for id: String) -> DockMagnification.Item {
        guard let i = order.firstIndex(of: id), layout.items.indices.contains(i) else {
            return DockMagnification.Item()
        }
        return layout.items[i]
    }

    private func recompute() {
        order = centers.sorted { $0.value < $1.value }.map(\.key)
        let next = DockMagnification.layout(
            centers: order.map { centers[$0] ?? 0 }, pointer: pointer)
        if next != layout { layout = next }
    }
}

/// One strip icon, magnified. The slot it takes in the row never changes size; the icon
/// inside draws at its scale and moves out of its neighbours' way. The slot reports its rest
/// centre, so nothing the icon does feeds back into where the pointer thinks it is.
struct DockMagnifiedSlot<Content: View>: View {
    let id: String
    @ViewBuilder let content: (CGFloat) -> Content
    private let magnifier = DockMagnifier.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let item = reduceMotion ? DockMagnification.Item() : magnifier.item(for: id)
        Color.clear
            .frame(
                width: AppChatPromptMetrics.dockIconSize,
                height: AppChatPromptMetrics.dockIconSize)
            .onGeometryChange(for: CGFloat.self) {
                $0.frame(in: .named(DockMagnifier.space)).midX
            } action: {
                magnifier.setCenter($0, for: id)
            }
            .onDisappear { magnifier.forget(id) }
            .overlay {
                content(item.scale).offset(x: item.shift)
            }
            .animation(DockMagnifier.spring, value: item)
    }
}

extension DockMagnifier {
    static let space = "dockStripMagnifier"
    /// Response ~0.25s, damping ~0.8 on a pointer-driven value (#232).
    static let spring = Animation.spring(response: 0.25, dampingFraction: 0.8)
}

/// The glass behind a magnified row: wider by what the row grew, with room above it for the
/// icons that stand taller than the capsule. Its own view so a pointer move redraws this and
/// not the shell around it.
struct DockMagnifiedGlass: ViewModifier {
    let active: Bool
    let radius: CGFloat
    private let magnifier = DockMagnifier.shared

    func body(content: Content) -> some View {
        let e = active ? magnifier.layout.extra / 2 : 0
        let room = active ? DockMagnification.headroom : 0
        content
            // Icons draw above the capsule, as the Dock's do: the clip opens upward and a little
            // sideways while the dock is at rest and closes the instant it is not.
            .mask {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .overlay(alignment: .top) {
                        Rectangle()
                            .frame(height: room)
                            .padding(.horizontal, -(e + 24))
                            .offset(y: -room)
                    }
            }
            .padding(.horizontal, e)
            .glassEffect(.regular.interactive(), in: .rect(cornerRadius: radius, style: .continuous))
            .padding(.horizontal, -e)
            .animation(DockMagnifier.spring, value: e)
    }
}
