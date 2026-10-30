// DynamicIslandNotchShape.swift
// Context-Dock
//
// Smooth Dynamic Island notch container with concave top ears (flare)
// that transition seamlessly into the macOS top display bezel, as seen in
// NotchNook and Apple's Dynamic Island reference.

import SwiftUI

/// A shape that hugs the screen bezel at the top with concave flare ears,
/// drops down vertically, and rounds smoothly at the bottom corners.
struct DynamicIslandNotchShape: Shape {
    var cornerRadius: CGFloat = 20
    var earRadius: CGFloat = 10

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let r = min(cornerRadius, rect.height / 2)
        let e = min(earRadius, rect.width / 4)

        // Top-left outer ear (at the top bezel)
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))

        // Concave curve down from the top bezel into the island body
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + e, y: rect.minY + e),
            control: CGPoint(x: rect.minX + e, y: rect.minY)
        )

        // Left vertical edge down to bottom-left corner
        path.addLine(to: CGPoint(x: rect.minX + e, y: rect.maxY - r))

        // Convex bottom-left corner
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + e + r, y: rect.maxY),
            control: CGPoint(x: rect.minX + e, y: rect.maxY)
        )

        // Bottom edge
        path.addLine(to: CGPoint(x: rect.maxX - e - r, y: rect.maxY))

        // Convex bottom-right corner
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX - e, y: rect.maxY - r),
            control: CGPoint(x: rect.maxX - e, y: rect.maxY)
        )

        // Right vertical edge up to top-right ear
        path.addLine(to: CGPoint(x: rect.maxX - e, y: rect.minY + e))

        // Concave curve back out to the top bezel
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY),
            control: CGPoint(x: rect.maxX - e, y: rect.minY)
        )

        path.closeSubpath()
        return path
    }
}
