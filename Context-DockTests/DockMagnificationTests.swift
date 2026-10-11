import Foundation
import Testing
@testable import Context_Dock

/// The Dock's magnification is a curve of pointer distance, not a step chosen by which icon
/// was entered (#232): continuous, peaked under the pointer, flat beyond its radius.
struct DockMagnificationTests {
    typealias D = DockMagnification

    @Test func peaksUnderThePointerAndRestsBeyondTheRadius() {
        #expect(D.scale(distance: 0) == D.peak)
        #expect(D.scale(distance: D.radius) == 1)
        #expect(D.scale(distance: D.radius * 3) == 1)
        #expect(D.scale(distance: -40) == D.scale(distance: 40))
    }

    @Test func fallsMonotonicallyAndWithoutSteps() {
        var last = D.peak
        for step in 0...280 {
            let s = D.scale(distance: CGFloat(step) * 0.5)
            #expect(s <= last + 1e-9)
            #expect(last - s < 0.02)  // half a point of travel never moves the scale in a step
            last = s
        }
    }

    @Test func noPointerLeavesTheRowAtRest() {
        let layout = D.layout(centers: [24, 80, 136], pointer: nil)
        #expect(layout.extra == 0)
        #expect(layout.items.allSatisfy { $0 == D.Item() })
    }

    @Test func neighboursMakeRoomAndStayInOrder() {
        let centers: [CGFloat] = (0..<8).map { 24 + CGFloat($0) * 56 }
        let layout = D.layout(centers: centers, pointer: centers[3])
        #expect(layout.items[3].scale > 1.6)
        #expect(layout.extra > 0)
        let shown = zip(centers, layout.items).map { $0 + $1.shift }
        for i in 1..<shown.count {
            // Centres end up at least a magnified artwork-half apart: nothing overlaps.
            let need = D.artwork * (layout.items[i - 1].scale + layout.items[i].scale) / 2
            #expect(shown[i] - shown[i - 1] >= need - 1e-6)
        }
        // The row widens evenly about its middle.
        #expect(abs(layout.items[0].shift + layout.items[7].shift) < layout.extra)
    }

    @Test func sweepingLeftToRightMovesTheLayoutContinuously() {
        let centers: [CGFloat] = (0..<6).map { 24 + CGFloat($0) * 56 }
        var last = D.layout(centers: centers, pointer: 0)
        for x in stride(from: CGFloat(1), through: 300, by: 1) {
            let next = D.layout(centers: centers, pointer: x)
            for (a, b) in zip(last.items, next.items) {
                #expect(abs(a.scale - b.scale) < 0.08)
                #expect(abs(a.shift - b.shift) < 6)
            }
            last = next
        }
    }
}
