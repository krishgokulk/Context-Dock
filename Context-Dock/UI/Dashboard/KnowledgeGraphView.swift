//
//  KnowledgeGraphView.swift
//  Context-Dock
//
//  The shape of what DoraX knows: every conversation the user actually held, drawn
//  against the apps, folders and tools it reached into. Edges are real scope links —
//  a thread scoped to an app, or widened to one in a combined chat — not similarity
//  or inference, so a line here means the user did that, not that we guessed it.
//
//  Layout is a small force simulation run once per size and cached. It is seeded
//  from the node ids rather than randomly, so the same graph draws the same way on
//  every open — a graph that reshuffles itself is one the user cannot learn.
//

import SwiftUI

struct KnowledgeGraphView: View {
    let graph: KnowledgeGraph
    /// Tapping a conversation node should take you to it; anything else is inert.
    var onSelectThread: ((String) -> Void)?

    @Environment(\.colorScheme) private var colorScheme
    private var dark: Bool { colorScheme == .dark }

    @State private var positions: [String: CGPoint] = [:]
    @State private var laidOutFor: CGSize = .zero
    @State private var hovered: String?

    /// Past this the picture stops being a graph and starts being a texture.
    private let nodeLimit = 40

    private var nodes: [KnowledgeNode] { Array(graph.nodes.prefix(nodeLimit)) }

    private var edges: [KnowledgeEdge] {
        let visible = Set(nodes.map(\.id))
        return graph.edges.filter { visible.contains($0.from) && visible.contains($0.to) }
    }

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            Canvas { context, _ in
                draw(in: &context, size: size)
            }
            .onAppear { layoutIfNeeded(size) }
            .onChange(of: size) { _, new in layoutIfNeeded(new) }
            .onChange(of: graph.nodes.count) { _, _ in
                laidOutFor = .zero
                layoutIfNeeded(size)
            }
            .onContinuousHover { phase in
                switch phase {
                case .active(let point): hovered = node(near: point)?.id
                case .ended: hovered = nil
                }
            }
            .onTapGesture { point in
                guard let hit = node(near: point), hit.kind == .thread else { return }
                onSelectThread?(hit.id)
            }
        }
    }

    // MARK: - Drawing

    private func draw(in context: inout GraphicsContext, size: CGSize) {
        guard !positions.isEmpty else { return }
        let neighbours = hovered.map(neighbourhood) ?? []
        let dimming = hovered != nil

        for edge in edges {
            guard let a = positions[edge.from], let b = positions[edge.to] else { continue }
            let touched = hovered == edge.from || hovered == edge.to
            var path = Path()
            path.move(to: a)
            // A slight arc keeps parallel links between the same clusters from stacking
            // into one thick line.
            path.addQuadCurve(to: b, control: control(a, b))
            context.stroke(
                path,
                with: .color(DashboardPalette.grid(dark).opacity(dimming && !touched ? 0.35 : 1)),
                lineWidth: touched ? 2 : 1)
        }

        for node in nodes {
            guard let point = positions[node.id] else { continue }
            let isHovered = hovered == node.id
            let inFocus = !dimming || isHovered || neighbours.contains(node.id)
            let color = DashboardPalette.color(for: node.kind, dark: dark)
                .opacity(inFocus ? 1 : 0.28)
            let radius = self.radius(for: node)

            // A 2px surface ring so overlapping nodes keep a clean edge instead of merging
            // into one blob.
            context.fill(
                shape(node.kind, at: point, radius: radius + 2).path,
                with: .color(DashboardPalette.gap(dark).opacity(inFocus ? 1 : 0.4)))
            context.fill(shape(node.kind, at: point, radius: radius).path, with: .color(color))

            if isHovered {
                context.stroke(
                    shape(node.kind, at: point, radius: radius + 3).path,
                    with: .color(color), lineWidth: 1.5)
            }

            guard shouldLabel(node), inFocus else { continue }
            let label = Text(node.label)
                .font(.system(size: 10, weight: isHovered ? .semibold : .regular))
                .foregroundStyle(isHovered ? .primary : .secondary)
            context.draw(
                context.resolve(label),
                at: CGPoint(x: point.x, y: point.y + radius + 8),
                anchor: .top)
        }
    }

    /// Aqua fails 3:1 on the light surface, so tools are always labelled — that is the
    /// relief the contrast check requires. Everything else is labelled while the graph is
    /// small enough for the text to fit, plus whatever the pointer is on.
    private func shouldLabel(_ node: KnowledgeNode) -> Bool {
        if node.kind == .tool || node.kind == .note { return true }
        if hovered == node.id { return true }
        return nodes.count <= 22
    }

    private func radius(for node: KnowledgeNode) -> CGFloat {
        // Area, not diameter, tracks weight — a radius scaled linearly overstates the big
        // nodes by the square.
        let maxWeight = max(1, nodes.map(\.weight).max() ?? 1)
        let share = Double(node.weight) / Double(maxWeight)
        return 4 + 8 * CGFloat(share.squareRoot())
    }

    /// Shape is the secondary encoding that lets the graph survive without colour.
    private func shape(_ kind: KnowledgeNode.Kind, at point: CGPoint, radius: CGFloat) -> AnyShapeAtPoint {
        AnyShapeAtPoint(kind: kind, center: point, radius: radius)
    }

    private func control(_ a: CGPoint, _ b: CGPoint) -> CGPoint {
        let mid = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
        let dx = b.x - a.x, dy = b.y - a.y
        let length = max(1, (dx * dx + dy * dy).squareRoot())
        return CGPoint(x: mid.x - dy / length * 12, y: mid.y + dx / length * 12)
    }

    // MARK: - Hit testing

    private func node(near point: CGPoint) -> KnowledgeNode? {
        var best: (node: KnowledgeNode, distance: CGFloat)?
        for node in nodes {
            guard let position = positions[node.id] else { continue }
            let dx = position.x - point.x, dy = position.y - point.y
            let distance = (dx * dx + dy * dy).squareRoot()
            // Hit target is bigger than the mark, so small nodes stay reachable.
            guard distance <= max(14, radius(for: node) + 8) else { continue }
            if best == nil || distance < best!.distance { best = (node, distance) }
        }
        return best?.node
    }

    private func neighbourhood(_ id: String) -> Set<String> {
        var found: Set<String> = [id]
        for edge in edges {
            if edge.from == id { found.insert(edge.to) }
            if edge.to == id { found.insert(edge.from) }
        }
        return found
    }

    // MARK: - Layout

    private func layoutIfNeeded(_ size: CGSize) {
        guard size.width > 40, size.height > 40 else { return }
        guard size != laidOutFor || positions.isEmpty else { return }
        laidOutFor = size
        positions = KnowledgeGraphLayout.solve(nodes: nodes, edges: edges, in: size)
    }
}

// MARK: - Node shapes

/// One shape per node kind — circle for a conversation, rounded square for an app,
/// folder-ish for a folder, diamond for a tool.
private struct AnyShapeAtPoint {
    let kind: KnowledgeNode.Kind
    let center: CGPoint
    let radius: CGFloat

    var path: Path {
        let rect = CGRect(
            x: center.x - radius, y: center.y - radius,
            width: radius * 2, height: radius * 2)
        switch kind {
        case .thread:
            return Path(ellipseIn: rect)
        case .note:
            // A page: taller than wide, so it reads as a written thing next to the round
            // conversations it shares an ink with.
            return Path(roundedRect: rect.insetBy(dx: radius * 0.28, dy: 0), cornerRadius: radius * 0.25)
        case .app:
            return Path(roundedRect: rect, cornerRadius: radius * 0.42)
        case .folder:
            return Path(roundedRect: rect.insetBy(dx: 0, dy: radius * 0.22), cornerRadius: radius * 0.3)
        case .tool:
            var path = Path()
            path.move(to: CGPoint(x: center.x, y: center.y - radius))
            path.addLine(to: CGPoint(x: center.x + radius, y: center.y))
            path.addLine(to: CGPoint(x: center.x, y: center.y + radius))
            path.addLine(to: CGPoint(x: center.x - radius, y: center.y))
            path.closeSubpath()
            return path
        }
    }
}

// MARK: - Force layout

/// A trimmed Fruchterman-Reingold: repulsion between every pair, attraction along edges,
/// cooling over a fixed iteration count. Deterministic — the seed comes from the node id's
/// hash, so reopening the window redraws the same picture.
enum KnowledgeGraphLayout {
    static func solve(nodes: [KnowledgeNode], edges: [KnowledgeEdge], in size: CGSize) -> [String: CGPoint] {
        guard !nodes.isEmpty else { return [:] }
        let inset: CGFloat = 26
        let usableHeight = size.height - inset * 2
        // Ideal spacing, then clamped by the short side.
        //
        // `sqrt(area / n)` assumes a roughly square canvas. This card is wide and short —
        // about 1700×320 — where that formula asks for 156pt of space per node against
        // 268pt of usable height. Two rows fit, so the simulation did the only thing it
        // could and pressed every node against the top and bottom edges, which is what the
        // graph looked like: dots in lines. Capping at a quarter of the height guarantees
        // room for four rows, and the drawing gets its vertical structure back.
        let area = (size.width - inset * 2) * usableHeight
        let k = min((area / CGFloat(nodes.count)).squareRoot(), usableHeight / 4)
        let index = Dictionary(uniqueKeysWithValues: nodes.enumerated().map { ($1.id, $0) })

        var points: [CGPoint] = nodes.enumerated().map { position, node in
            // Golden-angle spiral seeded by id — spread out, stable, no RNG.
            let jitter = Double(abs(node.id.hashValue % 1000)) / 1000
            let angle = (Double(position) + jitter) * 2.399963
            let spread = (Double(position) + 0.5) / Double(nodes.count)
            let r = spread.squareRoot() * Double(min(size.width, size.height) / 2 - inset)
            return CGPoint(
                x: size.width / 2 + CGFloat(cos(angle) * r),
                y: size.height / 2 + CGFloat(sin(angle) * r))
        }

        let iterations = 260
        let initialTemperature = min(size.width, size.height) / 6
        var temperature = initialTemperature

        for step in 0..<iterations {
            var forces = [CGPoint](repeating: .zero, count: points.count)

            for i in 0..<points.count {
                for j in (i + 1)..<points.count {
                    var dx = points[i].x - points[j].x
                    var dy = points[i].y - points[j].y
                    var distance = (dx * dx + dy * dy).squareRoot()
                    if distance < 0.01 {
                        // Perfectly coincident nodes have no direction to push apart in.
                        dx = CGFloat((i % 7) - 3) * 0.1
                        dy = CGFloat((j % 7) - 3) * 0.1
                        distance = 0.01
                    }
                    // Repulsion falls off with distance, and past a couple of k it is
                    // noise. Left unbounded, every node pushed every other node across the
                    // whole canvas at once, which no amount of attraction could balance —
                    // so nodes ran to the edges and the clamp lined them up in rows there.
                    guard distance < k * 2.5 else { continue }
                    let magnitude = k * k / distance
                    let fx = dx / distance * magnitude
                    let fy = dy / distance * magnitude
                    forces[i].x += fx; forces[i].y += fy
                    forces[j].x -= fx; forces[j].y -= fy
                }
            }

            for edge in edges {
                guard let a = index[edge.from], let b = index[edge.to] else { continue }
                let dx = points[a].x - points[b].x
                let dy = points[a].y - points[b].y
                let distance = max(0.01, (dx * dx + dy * dy).squareRoot())
                let magnitude = distance * distance / k
                let fx = dx / distance * magnitude
                let fy = dy / distance * magnitude
                forces[a].x -= fx; forces[a].y -= fy
                forces[b].x += fx; forces[b].y += fy
            }

            // Gravity, strong enough to actually hold the drawing together. At 0.012 it
            // was a rounding error next to repulsion, and "keeps disconnected nodes from
            // drifting to the edges" is exactly what it failed to do.
            let centre = CGPoint(x: size.width / 2, y: size.height / 2)
            for i in 0..<points.count {
                forces[i].x += (centre.x - points[i].x) * 0.09
                forces[i].y += (centre.y - points[i].y) * 0.14
            }

            for i in 0..<points.count {
                let length = max(0.01, (forces[i].x * forces[i].x + forces[i].y * forces[i].y).squareRoot())
                let limited = min(length, temperature)
                points[i].x = min(max(points[i].x + forces[i].x / length * limited, inset), size.width - inset)
                points[i].y = min(max(points[i].y + forces[i].y / length * limited, inset), size.height - inset - 10)
            }

            // Cool to nothing, linearly. The old schedule multiplied by 0.98 of a fraction
            // that started at 1, so temperature ended within 2% of where it began: every
            // step could still move a node the width of the card, and the layout never
            // settled into the arrangement the forces were describing.
            temperature = initialTemperature * (1 - CGFloat(step) / CGFloat(iterations))
            temperature = max(temperature, 0.25)
        }

        return Dictionary(uniqueKeysWithValues: zip(nodes.map(\.id), points))
    }
}
