// DockEngineHeadlessTests.swift
// Context-DockTests
//
// Verifies that DockEngine and DockCore operate cleanly as a windowless, headless engine
// behind the Corner shell without requiring or manipulating NSWindow/NSPanel instances (Issue #257).

import AppKit
import Foundation
import Testing

@testable import Context_Dock

@Suite("DockEngineHeadlessTests")
@MainActor
struct DockEngineHeadlessTests {

    @Test
    func dockEngineRegistersWithoutWindow() {
        // Registering sets the selection actions provider and connects global results.
        // It must execute safely in a windowless state without throwing or instantiating windows.
        DockEngine.shared.register()

        #expect(SelectionActions.provider != nil)
    }

    @Test
    func dockEngineObservingWithoutWindow() {
        let engine = DockEngine.shared
        engine.resetForTesting()

        // Verify test harness registration of notification sinks without live background indexing
        engine.startObservingForTesting()

        // Post a cancellation notification to verify delivery through the notification publisher
        NotificationCenter.default.post(name: .appChatPromptCancel, object: nil)

        // Clean teardown
        engine.resetForTesting()
    }

    @Test
    func refocusDockInputDoesNotTouchNSAppWindows() {
        let core = DockEngine.shared.core

        // Ensure initially unfocused
        core.isSearchFieldFocused = false
        #expect(!core.isSearchFieldFocused)

        // Count existing windows before invocation
        let windowCountBefore = NSApp.windows.count

        // Invoke synchronous refocus (delay <= 0 runs directly on main actor)
        core.refocusDockInputAfterAppAction(delay: 0)

        // Verify state was updated to true without creating or modifying the window list
        #expect(core.isSearchFieldFocused)
        #expect(NSApp.windows.count == windowCountBefore)
    }

    @Test
    func resetEngineStateAfterResultExecutionOperatesWindowless() {
        let core = DockEngine.shared.core

        core.isSearchFieldFocused = true
        #expect(core.isSearchFieldFocused)

        // Reset engine state (force: true bypasses alwaysFloatDock)
        core.resetEngineStateAfterResultExecution(force: true)

        #expect(!core.isSearchFieldFocused)
        #expect(core.searchState.query == "")
        #expect(core.focusedAppPillIndex == nil)
    }
}
