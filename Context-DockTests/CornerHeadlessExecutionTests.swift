//
//  CornerHeadlessExecutionTests.swift
//  Context-DockTests
//
//  Verifies that Corner presentation, phase transitions, and layout
//  execute deterministically, quickly (<100ms), and headlessly without
//  WindowServer or live AX dependencies.
//

import AppKit
import CoreGraphics
import Foundation
import Testing

@testable import Context_Dock

@MainActor
struct CornerHeadlessExecutionTests {
    private var codeTarget: CornerChatTarget {
        CornerChatTarget(
            name: "Code",
            bundleID: "com.microsoft.VSCode",
            suggestions: [.init(icon: "bolt.fill", title: "New Window", kind: .action)],
            summary: "5 actions"
        )
    }

    @Test func defaultRunningAppsSourceUsesTestFixture() {
        let model = AppChatPromptModel(conversation: AppChatConversation())
        let pills = model.orderedAppPills()
        #expect(!pills.isEmpty)
        #expect(pills.contains { $0.bundleID == "com.apple.finder" })
    }

    @Test func modeSwitchArrowRouteExecutesSubMillisecond() {
        let start = CFAbsoluteTimeGetCurrent()
        let subject = CornerChatPresentation(
            appChat: AppChatPromptModel(conversation: AppChatConversation()),
            generalChat: GeneralChatWindowModel()
        )
        subject.frontmostTargetProvider = { nil }
        subject.showFrontmostApp(target: codeTarget)

        #expect(subject.handleLeftArrow(draft: "") == true)
        #expect(subject.mode == .general)
        #expect(subject.handleLeftArrow(draft: "") == false)
        #expect(subject.handleRightArrow(draft: "") == true)
        #expect(subject.mode == .frontmostApp)

        subject.showGlobalContext()
        #expect(subject.handleLeftArrow(draft: "") == true)
        #expect(subject.mode == .general)
        #expect(subject.handleRightArrow(draft: "") == true)
        #expect(subject.mode == .globalContext)

        let duration = CFAbsoluteTimeGetCurrent() - start
        #expect(duration < 0.1, "Mode switching must run headlessly in <100ms, took \(duration)s")
    }

    @Test func restingDockScopeStepExecutesSubMillisecond() {
        let start = CFAbsoluteTimeGetCurrent()
        let conversation = AppChatConversation()
        let model = AppChatPromptModel(
            conversation: conversation,
            globalResultSource: GlobalContextResultSource()
        )
        model.autoShrinkEnabled = { true }
        model.summonGlobalContext()
        model.standDown()
        #expect(model.phase == .dock)

        let scoped = model.arrowRightFromDock()
        #expect(scoped == true)
        #expect(model.phase != .dock)

        let duration = CFAbsoluteTimeGetCurrent() - start
        #expect(duration < 0.1, "Dock scoping must run headlessly in <100ms, took \(duration)s")
    }

    @Test func calculatePanelOriginComputesDeterministicRectsWithoutScreen() {
        let visible = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let full = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let size = CGSize(width: 400, height: 200)

        let rightOrigin = CornerDockController.calculatePanelOrigin(
            visibleScreenFrame: visible,
            fullScreenFrame: full,
            panelSize: size,
            anchor: .right,
            isCentred: false
        )
        #expect(rightOrigin.x > 0)
        #expect(rightOrigin.y == visible.minY + 20 - CornerDockLayout.pad)

        let centerOrigin = CornerDockController.calculatePanelOrigin(
            visibleScreenFrame: visible,
            fullScreenFrame: full,
            panelSize: size,
            anchor: .center,
            isCentred: true,
            centredOffsetX: 0,
            centredOffsetY: 0
        )
        let expectedX = (full.width - size.width) / 2
        #expect(abs(centerOrigin.x - expectedX) < 1.0)
    }

    @Test func panelSizeComputesValidCGSizeForHeadlessWidth() {
        let size = CornerDockLayout.panelSize(for: .center, panelWidth: 1512)
        #expect(size.width > 0)
        #expect(size.height > 0)
    }
}
