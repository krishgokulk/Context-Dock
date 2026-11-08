//
//  TestHostQuarantineTests.swift
//  Context-DockTests
//
//  Verifies that when running in the test host, all GUI window creation,
//  AX monitoring, and background loops are quarantined and inactive.
//

import Foundation
import Testing

@testable import Context_Dock

@MainActor
struct TestHostQuarantineTests {
    @Test func testHostRecognizesHostingEnvironment() {
        #expect(AppDelegate.isHostingTests)
    }

    @Test func cornerDockControllerIsHeadlessAndHasNoLiveWindow() {
        #expect(CornerDockController.shared.isHeadless == true)
        #expect(CornerDockController.shared.window == nil)
    }

    @Test func menuWarmingIsInactiveInTestHost() {
        #expect(MenuWarmCacheService.shared.isWarmingActive == false)
    }

    @Test func axObserverManagerPoolIsEmptyInTestHost() {
        #expect(AXObserverManager.shared.activeObserverCount == 0)
    }

    @Test func watchdogReportsNoStallAtBaseline() {
        #expect(TestHostMainActorWatchdog.shared.isMainActorStalled == false)
    }
}
