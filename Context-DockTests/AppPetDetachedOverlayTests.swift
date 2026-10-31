// AppPetDetachedOverlayTests.swift
// Context-DockTests
//
// Tests for Stage 5 (#342) detached Pet presentation overlay:
// - 3-tier lifecycle (floating mascot with pinned bubbles, compact launcher, expanded window)
// - Direct jump to Tier 3 on mascot click
// - Persistent action bubbles retention until explicit dismissal
// - Drag-to-detach creation and reattach without history deletion
// - Multiple detached Pets coexistence over shared harness

import Foundation
import Testing
@testable import Context_Dock

@Suite("AppPetDetachedOverlayTests")
struct AppPetDetachedOverlayTests {

    @Test("3-tier lifecycle transitions follow the approved progressive disclosure rules")
    func threeTierTransitions() {
        // Mascot click jumps directly to Tier 3 (Expanded Window)
        #expect(DetachedPetStore.transitionOnMascotClick(from: .tier1Mascot) == .tier3Expanded)
        #expect(DetachedPetStore.transitionOnMascotClick(from: .tier2Launcher) == .tier3Expanded)
        #expect(DetachedPetStore.transitionOnMascotClick(from: .tier3Expanded) == .tier3Expanded)

        // Chevron '^' transitions to Tier 2 (Compact Launcher)
        #expect(DetachedPetStore.transitionOnLauncherChevron(from: .tier1Mascot) == .tier2Launcher)
        #expect(DetachedPetStore.transitionOnLauncherChevron(from: .tier3Expanded) == .tier2Launcher)

        // Micro-bar ✏️ expands into inline input and collapses back
        #expect(DetachedPetStore.transitionOnMicroBarEdit(from: .micro) == .inlineInput)
        #expect(DetachedPetStore.transitionOnMicroBarEdit(from: .inlineInput) == .micro)
    }

    @Test("Action bubbles stay pinned until explicitly closed with ✕")
    @MainActor
    func pinnedActionBubblesRetention() {
        let petID = AppPetID.app(bundleID: "com.apple.Safari")
        let vm = DetachedPetViewModel(
            petID: petID,
            appName: "Safari",
            bundleID: "com.apple.Safari"
        )

        // Add a thinking bubble
        let thinking = AppPetActionBubble(kind: .thinking(detail: "Researching WWDC sessions…"))
        vm.addBubble(thinking)
        #expect(vm.pinnedBubbles.count == 1)
        #expect(vm.pinnedBubbles[0].isThinking)
        #expect(vm.pinnedBubbles[0].isPinned)

        // Add a success receipt bubble
        let receipt = AppPetActionBubble(
            kind: .receipt(title: "Safari: Found 5 sessions", detail: "Downloaded PDF schedule")
        )
        vm.addBubble(receipt)
        #expect(vm.pinnedBubbles.count == 2)
        #expect(vm.pinnedBubbles[1].isReceipt)
        #expect(vm.pinnedBubbles[1].displayTitle == "Safari: Found 5 sessions")
        #expect(vm.pinnedBubbles[1].displayDetail == "Downloaded PDF schedule")

        // Bubbles stay pinned permanently until explicit dismissal
        vm.dismissBubble(id: thinking.id)
        #expect(vm.pinnedBubbles.count == 1)
        #expect(vm.pinnedBubbles[0].id == receipt.id)

        vm.dismissBubble(id: receipt.id)
        #expect(vm.pinnedBubbles.isEmpty)
    }

    @Test("DetachedPetStore round-trips records cleanly through defaults")
    func detachedPetStoreRoundTrip() {
        let suiteName = "test.dorax.detachedpets.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let petID = AppPetID.app(bundleID: "com.apple.mail")
        let record = DetachedPetRecord(
            petID: petID,
            appName: "Mail",
            bundleID: "com.apple.mail",
            position: CGPoint(x: 450, y: 320),
            mascotState: .idle,
            microBarState: .micro,
            pinnedBubbles: [
                AppPetActionBubble(kind: .receipt(title: "Mail checked", detail: "2 new messages"))
            ]
        )

        DetachedPetStore.upsertRecord(record, defaults: defaults)

        let loaded = DetachedPetStore.record(for: petID, defaults: defaults)
        #expect(loaded != nil)
        #expect(loaded?.appName == "Mail")
        #expect(loaded?.bundleID == "com.apple.mail")
        #expect(loaded?.position.x == 450)
        #expect(loaded?.position.y == 320)
        #expect(loaded?.pinnedBubbles.count == 1)
        #expect(loaded?.pinnedBubbles[0].displayTitle == "Mail checked")

        DetachedPetStore.removeRecord(for: petID, defaults: defaults)
        #expect(DetachedPetStore.record(for: petID, defaults: defaults) == nil)
    }

    @Test("DetachedPetManager coordinates multiple detached pets without state collision")
    @MainActor
    func multipleDetachedPetsCoexistence() {
        let manager = DetachedPetManager.shared
        defer { manager.closeAll() }

        let safariID = AppPetID.app(bundleID: "com.apple.Safari")
        let mailID = AppPetID.app(bundleID: "com.apple.mail")

        let safariController = manager.detachPet(
            petID: safariID,
            appName: "Safari",
            at: CGPoint(x: 100, y: 150)
        )
        let mailController = manager.detachPet(
            petID: mailID,
            appName: "Mail",
            at: CGPoint(x: 800, y: 150)
        )

        #expect(manager.isDetached(petID: safariID))
        #expect(manager.isDetached(petID: mailID))
        #expect(safariController.appName == "Safari")
        #expect(mailController.appName == "Mail")
        #expect(safariController.panel.frame.origin.x == 100)
        #expect(mailController.panel.frame.origin.x == 800)

        // Reattaching Safari does not affect Mail
        manager.reattachPet(petID: safariID)
        #expect(!manager.isDetached(petID: safariID))
        #expect(manager.isDetached(petID: mailID))

        manager.reattachPet(petID: mailID)
        #expect(!manager.isDetached(petID: mailID))
    }

    @Test("DetachedPetViewModel callbacks wire to Tier 2, Tier 3, and reattach")
    @MainActor
    func viewModelCallbacksTriggerExpectedTransitions() {
        let petID = AppPetID.app(bundleID: "com.apple.Terminal")
        let vm = DetachedPetViewModel(
            petID: petID,
            appName: "Terminal",
            bundleID: "com.apple.Terminal"
        )

        var jumpedToExpanded = false
        var jumpedToLauncher = false
        var reattached = false

        vm.onJumpToExpandedWindow = { jumpedToExpanded = true }
        vm.onJumpToLauncher = { jumpedToLauncher = true }
        vm.onReattachToDock = { reattached = true }

        vm.jumpToExpandedWindow()
        #expect(jumpedToExpanded)

        vm.jumpToLauncher()
        #expect(jumpedToLauncher)

        vm.reattachToDock()
        #expect(reattached)
    }

    @Test("Pupil offset tracks cursor position and updates dynamically")
    @MainActor
    func pupilOffsetTracking() {
        let petID = AppPetID.app(bundleID: "com.apple.Safari")
        let vm = DetachedPetViewModel(
            petID: petID,
            appName: "Safari",
            bundleID: "com.apple.Safari"
        )

        #expect(vm.pupilOffset == .zero)
        vm.pupilOffset = CGSize(width: 1.8, height: -1.2)
        #expect(vm.pupilOffset.width == 1.8)
        #expect(vm.pupilOffset.height == -1.2)
    }

    @Test("Dynamic bubble updates reflect live reasoning steps")
    @MainActor
    func dynamicReasoningBubbleUpdates() {
        let petID = AppPetID.app(bundleID: "com.apple.Safari")
        let vm = DetachedPetViewModel(
            petID: petID,
            appName: "Safari",
            bundleID: "com.apple.Safari"
        )

        let thinking = AppPetActionBubble(kind: .thinking(detail: "Safari: Thinking…"))
        vm.addBubble(thinking)
        #expect(vm.pinnedBubbles.first?.displayTitle == "Safari: Thinking…")

        vm.updateBubbleDetail(id: thinking.id, detail: "Safari: Reading tabs…")
        #expect(vm.pinnedBubbles.first?.displayTitle == "Safari: Reading tabs…")

        vm.updateBubbleDetail(id: thinking.id, detail: "Safari: Executing query…")
        #expect(vm.pinnedBubbles.first?.displayTitle == "Safari: Executing query…")
    }
}
