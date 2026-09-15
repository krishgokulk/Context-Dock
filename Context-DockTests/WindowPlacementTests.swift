import CoreGraphics
import Foundation
import Testing
@testable import Context_Dock

/// Where a window lands when its thumbnail is dropped on the screen. Screen coordinates here
/// are top-left origin, as AX reports them.
struct WindowPlacementTests {
    private let screen = CGRect(x: 0, y: 0, width: 2000, height: 1000)
    private let size = CGSize(width: 800, height: 600)

    @Test func theLeftEdgeTilesLeft() {
        let frame = WindowPlacement.frame(drop: CGPoint(x: 100, y: 500), screen: screen, size: size)
        #expect(frame == CGRect(x: 0, y: 0, width: 1000, height: 1000))
    }

    @Test func theRightEdgeTilesRight() {
        let frame = WindowPlacement.frame(drop: CGPoint(x: 1900, y: 500), screen: screen, size: size)
        #expect(frame == CGRect(x: 1000, y: 0, width: 1000, height: 1000))
    }

    @Test func theTopBandMaximises() {
        let frame = WindowPlacement.frame(drop: CGPoint(x: 1000, y: 50), screen: screen, size: size)
        #expect(frame == screen)
    }

    @Test func anywhereElseMovesTheWindowToThePointer() {
        let frame = WindowPlacement.frame(drop: CGPoint(x: 900, y: 300), screen: screen, size: size)
        #expect(frame.origin == CGPoint(x: 900, y: 300))
        #expect(frame.size == size)
    }

    @Test func aMoveIsKeptOnTheScreen() {
        let frame = WindowPlacement.frame(drop: CGPoint(x: 1400, y: 800), screen: screen, size: size)
        #expect(frame.maxX <= screen.maxX)
        #expect(frame.maxY <= screen.maxY)
        #expect(frame.size == size)
    }

    @Test func aScreenWithAnOriginTilesInItsOwnSpace() {
        let second = CGRect(x: 2000, y: 0, width: 1000, height: 800)
        let frame = WindowPlacement.frame(drop: CGPoint(x: 2100, y: 400), screen: second, size: size)
        #expect(frame == CGRect(x: 2000, y: 0, width: 500, height: 800))
    }
}
