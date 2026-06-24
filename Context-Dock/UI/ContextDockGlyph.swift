import SwiftUI

struct ContextDockNodeGlyph: View {
    var size: CGFloat = 20
    var animated: Bool = false
    var color: Color = .black

    private let outerNodes: [CGPoint] = [
        CGPoint(x: 0.50, y: 0.18),
        CGPoint(x: 0.68, y: 0.25),
        CGPoint(x: 0.80, y: 0.42),
        CGPoint(x: 0.78, y: 0.62),
        CGPoint(x: 0.64, y: 0.76),
        CGPoint(x: 0.44, y: 0.80),
        CGPoint(x: 0.27, y: 0.70),
        CGPoint(x: 0.20, y: 0.51),
        CGPoint(x: 0.25, y: 0.32),
        CGPoint(x: 0.38, y: 0.22),
    ]

    private let edges: [(Int, Int)] = [
        (0, 1), (1, 2), (2, 3), (3, 4), (4, 5),
        (5, 6), (6, 7), (7, 8), (8, 9), (9, 0),
        (0, 10), (2, 10), (4, 10), (6, 10), (8, 10),
    ]

    @ViewBuilder
    var body: some View {
        if animated {
            TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
                glyphCanvas(phase: timeline.date.timeIntervalSinceReferenceDate)
            }
        } else {
            glyphCanvas(phase: 0)
        }
    }

    private func glyphCanvas(phase: TimeInterval) -> some View {
        Canvas { context, canvasSize in
            let scale = min(canvasSize.width, canvasSize.height)
            let origin = CGPoint(
                x: (canvasSize.width - scale) * 0.5,
                y: (canvasSize.height - scale) * 0.5
            )
            let nodes = resolvedNodes(phase: phase)
            let lineWidth = max(1.0, scale * 0.055)
            let outerDot = max(1.7, scale * 0.088)
            let centerDot = max(2.3, scale * 0.125)

            var linePath = Path()
            for edge in edges {
                let a = point(nodes[edge.0], scale: scale, origin: origin)
                let b = point(nodes[edge.1], scale: scale, origin: origin)
                linePath.move(to: a)
                linePath.addLine(to: b)
            }
            context.stroke(
                linePath,
                with: .color(color.opacity(0.58)),
                style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round)
            )

            for index in nodes.indices {
                let radius = index == nodes.count - 1 ? centerDot : outerDot
                let center = point(nodes[index], scale: scale, origin: origin)
                let rect = CGRect(
                    x: center.x - radius,
                    y: center.y - radius,
                    width: radius * 2,
                    height: radius * 2
                )
                context.fill(Path(ellipseIn: rect), with: .color(color))
            }
        }
        .frame(width: size, height: size)
        .drawingGroup()
    }

    private func resolvedNodes(phase: TimeInterval) -> [CGPoint] {
        let center = CGPoint(x: 0.50, y: 0.50)
        guard animated else { return outerNodes + [center] }

        let drift: CGFloat = 0.024
        let moved = outerNodes.enumerated().map { index, node in
            let t = phase * (0.72 + Double(index % 3) * 0.12) + Double(index) * 0.83
            return CGPoint(
                x: node.x + CGFloat(sin(t)) * drift,
                y: node.y + CGFloat(cos(t * 0.91)) * drift
            )
        }
        let centerT = phase * 0.95
        return moved + [
            CGPoint(
                x: center.x + CGFloat(sin(centerT)) * drift * 0.75,
                y: center.y + CGFloat(cos(centerT * 1.17)) * drift * 0.75
            )
        ]
    }

    private func point(_ normalized: CGPoint, scale: CGFloat, origin: CGPoint) -> CGPoint {
        CGPoint(
            x: origin.x + normalized.x * scale,
            y: origin.y + normalized.y * scale
        )
    }
}

struct ContextDockGlyph: View {
    var size: CGFloat = 20
    var opacity: Double = 0.75

    var body: some View {
        ContextDockNodeGlyph(size: size, animated: false, color: .black)
            .opacity(opacity)
    }
}
