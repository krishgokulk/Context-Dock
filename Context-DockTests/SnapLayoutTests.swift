import CoreGraphics
import Foundation
import Testing
@testable import Context_Dock

/// The snap catalogue is arithmetic on a screen; these hold the arithmetic, and the rule
/// that snapping one window adjusts the others into what it left.
struct SnapLayoutTests {
    private let screen = CGRect(x: 0, y: 25, width: 1800, height: 1100)
    private let window = CGRect(x: 300, y: 200, width: 900, height: 700)

    @Test func everyLayoutStaysOnTheScreen() {
        for layout in SnapLayout.allCases {
            let frame = layout.frame(on: screen, window: window)
            #expect(screen.insetBy(dx: -1, dy: -1).contains(frame), "\(layout) left the screen")
            #expect(frame.width > 0 && frame.height > 0)
        }
    }

    @Test func halvesThirdsAndFourthsDivideTheWidth() {
        #expect(SnapLayout.leftHalf.frame(on: screen, window: window).width == 900)
        #expect(SnapLayout.rightHalf.frame(on: screen, window: window).minX == 900)
        #expect(SnapLayout.centerThird.frame(on: screen, window: window).minX == 600)
        #expect(SnapLayout.lastFourth.frame(on: screen, window: window).minX == 1350)
        #expect(SnapLayout.bottomRightSixth.frame(on: screen, window: window).minY == 575)
    }

    @Test func centerAndMaximizeHeightKeepTheWindowsOwnSize() {
        let centered = SnapLayout.center.frame(on: screen, window: window)
        #expect(centered.size == window.size)
        #expect(abs(centered.midX - screen.midX) <= 1)
        let tall = SnapLayout.maximizeHeight.frame(on: screen, window: window)
        #expect(tall.width == window.width)
        #expect(tall.height == screen.height)
        #expect(tall.minX == window.minX)
    }

    @Test func anExistingWindowIsReadAsItsLayout() {
        let left = SnapLayout.leftHalf.frame(on: screen, window: window)
        #expect(SnapLayout.matching(left.offsetBy(dx: 3, dy: -2), on: screen) == .leftHalf)
        #expect(SnapLayout.matching(window, on: screen) == nil)
    }

    @Test func droppingLeftHalfSendsTheOtherWindowRight() {
        let moves = SnapArrangement.adjustments(
            after: .leftHalf, others: [.init(id: 7, frame: window)], screen: screen)
        #expect(moves == [.init(id: 7, layout: .rightHalf)])
    }

    @Test func aWindowAlreadyInTheComplementIsLeftAlone() {
        let right = SnapLayout.rightHalf.frame(on: screen, window: window)
        let moves = SnapArrangement.adjustments(
            after: .leftHalf, others: [.init(id: 7, frame: right), .init(id: 8, frame: window)],
            screen: screen)
        #expect(moves.isEmpty)
    }

    @Test func aQuarterHandsOutTheOtherThreeInOrder() {
        let moves = SnapArrangement.adjustments(
            after: .topLeft,
            others: [.init(id: 1, frame: window), .init(id: 2, frame: window), .init(id: 3, frame: window), .init(id: 4, frame: window)],
            screen: screen)
        #expect(moves.map(\.layout) == [.topRight, .bottomLeft, .bottomRight])
        #expect(moves.map(\.id) == [1, 2, 3])
    }

    // MARK: Pointer zones
    //
    // There is no palette to aim at any more: where the pointer is *is* the choice, the way
    // Rectangle and Windows Snap do it. Edge means half, corner means quarter, top means
    // maximize, and the middle of the screen means "leave it where I drop it".

    @Test func anEdgeMeansThatHalf() {
        #expect(SnapLayout.zone(at: CGPoint(x: 20, y: 600), on: screen) == .leftHalf)
        #expect(SnapLayout.zone(at: CGPoint(x: 1780, y: 600), on: screen) == .rightHalf)
    }

    @Test func theTopMeansMaximize() {
        #expect(SnapLayout.zone(at: CGPoint(x: 900, y: 40), on: screen) == .maximize)
    }

    @Test func aCornerMeansThatQuarterAndBeatsTheEdgeItSharesAnEdgeWith() {
        #expect(SnapLayout.zone(at: CGPoint(x: 20, y: 40), on: screen) == .topLeft)
        #expect(SnapLayout.zone(at: CGPoint(x: 1780, y: 40), on: screen) == .topRight)
        #expect(SnapLayout.zone(at: CGPoint(x: 20, y: 1100), on: screen) == .bottomLeft)
        #expect(SnapLayout.zone(at: CGPoint(x: 1780, y: 1100), on: screen) == .bottomRight)
    }

    @Test func theMiddleAndTheBottomEdgeSnapToNothing() {
        #expect(SnapLayout.zone(at: CGPoint(x: 900, y: 600), on: screen) == nil)
        // The bottom edge is where this app's own corner lives — snapping there would fight it.
        #expect(SnapLayout.zone(at: CGPoint(x: 900, y: 1115), on: screen) == nil)
    }

    @Test func aPointOffTheScreenSnapsToNothing() {
        #expect(SnapLayout.zone(at: CGPoint(x: -40, y: 600), on: screen) == nil)
        #expect(SnapLayout.zone(at: CGPoint(x: 900, y: 4000), on: screen) == nil)
    }

    @Test func everyZoneAZoneReturnsHasAFrame() {
        let corners = [
            CGPoint(x: 20, y: 40), CGPoint(x: 1780, y: 40),
            CGPoint(x: 20, y: 1100), CGPoint(x: 1780, y: 1100),
            CGPoint(x: 20, y: 600), CGPoint(x: 1780, y: 600), CGPoint(x: 900, y: 40),
        ]
        for point in corners {
            let layout = SnapLayout.zone(at: point, on: screen)
            #expect(layout != nil)
            let frame = layout!.frame(on: screen, window: window)
            #expect(screen.insetBy(dx: -1, dy: -1).contains(frame))
        }
    }

    @Test func layoutsWithoutACleanRemainderAdjustNothing() {
        let moves = SnapArrangement.adjustments(
            after: .maximize, others: [.init(id: 7, frame: window)], screen: screen)
        #expect(moves.isEmpty)
        #expect(SnapArrangement.adjustments(after: .center, others: [.init(id: 7, frame: window)], screen: screen).isEmpty)
    }
}
