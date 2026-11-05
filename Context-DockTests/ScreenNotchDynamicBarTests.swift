// ScreenNotchDynamicBarTests.swift
// Context-DockTests
//
// Tests for DynamicBar Notch geometry, safe area computations,
// resting dual-wing metrics, and MacBook Air 2024 / MacBook Pro compatibility.

import AppKit
import Foundation
import Testing

@testable import Context_Dock

@MainActor
struct ScreenNotchDynamicBarTests {

    @Test func dynamicBarDimensionsMatchReference() {
        #expect(ScreenNotchMetrics.openIslandDefaultWidth == 378)
        #expect(ScreenNotchMetrics.openIslandDefaultHeight == 172)
        #expect(ScreenNotchMetrics.openIslandMaxWidth == 600)
        #expect(ScreenNotchMetrics.openIslandMaxHeight == 320)
        #expect(ScreenNotchMetrics.safeAreaSideInset == 32)
        #expect(ScreenNotchMetrics.safeAreaTopInset == 36)
        #expect(ScreenNotchMetrics.safeAreaBottomInset == 26)
        #expect(ScreenNotchMetrics.wingWidth == 52)
        #expect(ScreenNotchMetrics.hoverSwellAmount == 4.0)
    }

    @Test func safeAreaBudgetCalculatesCorrectClearance() {
        let islandSize = CGSize(width: 378, height: 172)
        let safeArea = ScreenNotchMetrics.safeArea(for: islandSize)

        // Safe area width should be 378 - (32 * 2) = 314
        #expect(safeArea.width == 314)
        #expect(safeArea.origin.x == 32)
        #expect(safeArea.origin.y == 26)

        // Height should leave clearance for top notch (>= 36) and bottom (26)
        #expect(safeArea.height <= (172 - 36 - 26))
        #expect(safeArea.height > 0)
    }

    @Test func restingIslandWidthIncludesFlankingWings() {
        let activeScreen = ScreenNotchMetrics.activeScreen
        let notchW = ScreenNotchMetrics.notchRect(on: activeScreen).width
        let restingW = ScreenNotchMetrics.restingIslandWidth(on: activeScreen)

        #expect(restingW == notchW + (ScreenNotchMetrics.wingWidth * 2))
        #expect(restingW >= ScreenNotchMetrics.islandRestingWidth)
    }
}
