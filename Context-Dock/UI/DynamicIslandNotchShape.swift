// DynamicIslandNotchShape.swift
// Context-Dock
//
// Pixel-perfect Dynamic Island notch container referencing Drooppy and DynamicBar.
// Provides smooth concave top ears (flare) transitioning seamlessly into the macOS
// display bezel, with Apple G2 continuous rounded bottom corners.
// Auto-adapts to displays with or without physical hardware notches.

import SwiftUI

struct DynamicIslandNotchShape: Shape {
    var cornerRadius: CGFloat = 22
    var earRadius: CGFloat = 12
    var hasNotch: Bool = true

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(cornerRadius, earRadius) }
        set {
            cornerRadius = newValue.first
            earRadius = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()

        // Fallback for displays without physical notch (external monitors, older Macs)
        guard hasNotch else {
            let r = min(cornerRadius, rect.height / 2)
            path.addRoundedRect(in: rect, cornerSize: CGSize(width: r, height: r), style: .continuous)
            return path
        }

        let r = min(cornerRadius, rect.height / 2)
        let e = min(earRadius, rect.width / 4)

        // Top-left outer ear (at the top bezel)
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))

        // Smooth concave curve down from the top bezel into the island body
        path.addCurve(
            to: CGPoint(x: rect.minX + e, y: rect.minY + e),
            control1: CGPoint(x: rect.minX + e * 0.45, y: rect.minY),
            control2: CGPoint(x: rect.minX + e, y: rect.minY + e * 0.45)
        )

        // Left vertical edge down to bottom-left corner
        path.addLine(to: CGPoint(x: rect.minX + e, y: rect.maxY - r))

        // Convex bottom-left corner
        path.addCurve(
            to: CGPoint(x: rect.minX + e + r, y: rect.maxY),
            control1: CGPoint(x: rect.minX + e, y: rect.maxY - r * 0.45),
            control2: CGPoint(x: rect.minX + e + r * 0.45, y: rect.maxY)
        )

        // Bottom edge
        path.addLine(to: CGPoint(x: rect.maxX - e - r, y: rect.maxY))

        // Convex bottom-right corner
        path.addCurve(
            to: CGPoint(x: rect.maxX - e, y: rect.maxY - r),
            control1: CGPoint(x: rect.maxX - e - r * 0.45, y: rect.maxY),
            control2: CGPoint(x: rect.maxX - e, y: rect.maxY - r * 0.45)
        )

        // Right vertical edge up to top-right ear
        path.addLine(to: CGPoint(x: rect.maxX - e, y: rect.minY + e))

        // Concave curve back out to the top bezel
        path.addCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY),
            control1: CGPoint(x: rect.maxX - e, y: rect.minY + e * 0.45),
            control2: CGPoint(x: rect.maxX - e * 0.45, y: rect.minY)
        )

        path.closeSubpath()
        return path
    }

    /// Stroke outline path that strokes only the ears, sides, and bottom,
    /// deliberately omitting the top edge so it blends seamlessly into the screen bezel.
    func outlinePath(in rect: CGRect) -> Path {
        var path = Path()

        guard hasNotch else {
            let r = min(cornerRadius, rect.height / 2)
            path.addRoundedRect(in: rect, cornerSize: CGSize(width: r, height: r), style: .continuous)
            return path
        }

        let r = min(cornerRadius, rect.height / 2)
        let e = min(earRadius, rect.width / 4)

        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addCurve(
            to: CGPoint(x: rect.minX + e, y: rect.minY + e),
            control1: CGPoint(x: rect.minX + e * 0.45, y: rect.minY),
            control2: CGPoint(x: rect.minX + e, y: rect.minY + e * 0.45)
        )
        path.addLine(to: CGPoint(x: rect.minX + e, y: rect.maxY - r))
        path.addCurve(
            to: CGPoint(x: rect.minX + e + r, y: rect.maxY),
            control1: CGPoint(x: rect.minX + e, y: rect.maxY - r * 0.45),
            control2: CGPoint(x: rect.minX + e + r * 0.45, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: rect.maxX - e - r, y: rect.maxY))
        path.addCurve(
            to: CGPoint(x: rect.maxX - e, y: rect.maxY - r),
            control1: CGPoint(x: rect.maxX - e - r * 0.45, y: rect.maxY),
            control2: CGPoint(x: rect.maxX - e, y: rect.maxY - r * 0.45)
        )
        path.addLine(to: CGPoint(x: rect.maxX - e, y: rect.minY + e))
        path.addCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY),
            control1: CGPoint(x: rect.maxX - e, y: rect.minY + e * 0.45),
            control2: CGPoint(x: rect.maxX - e * 0.45, y: rect.minY)
        )
        return path
    }
}
