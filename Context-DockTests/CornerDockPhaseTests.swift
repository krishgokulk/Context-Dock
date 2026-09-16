import Foundation
import Testing
@testable import Context_Dock

/// The corner's Global Context rests as a dock: an empty field folds after a second, the
/// dock never folds further, and only a typed character brings the field back.
@MainActor
struct CornerDockPhaseTests {
    private func globalModel(autoShrink: Bool = true)
        -> (AppChatPromptModel, AppChatConversation)
    {
        let conversation = AppChatConversation()
        let model = AppChatPromptModel(
            conversation: conversation, globalResultSource: GlobalContextResultSource())
        model.autoShrinkEnabled = { autoShrink }
        model.summonGlobalContext()
        return (model, conversation)
    }

    @Test func idleGlobalPromptRestsAsDock() {
        let (model, _) = globalModel()
        #expect(model.phase == .prompt)
        model.standDown()
        #expect(model.phase == .dock)
    }

    @Test func dockNeverStandsDownFurther() {
        let (model, _) = globalModel()
        model.standDown()
        #expect(model.phase == .dock)
        model.standDown()
        model.standDown()
        #expect(model.phase == .dock)
    }

    @Test func settingOffKeepsTheMiniPath() {
        let (model, _) = globalModel(autoShrink: false)
        model.standDown()
        #expect(model.phase == .mini)
        model.standDown()
        #expect(model.phase == .hidden)
    }

    @Test func aScopedChatNeverDocks() {
        let (model, _) = globalModel()
        model.scopeIntoApp(name: "Safari", bundleID: "com.apple.Safari")
        model.set(.prompt)
        model.standDown()
        #expect(model.phase == .mini)
    }

    @Test func typedTextKeepsThePromptFromDocking() {
        let (model, _) = globalModel()
        model.query = "saf"
        model.standDown()
        #expect(model.phase == .mini)
    }

    /// The pin's own block is the shared `standDown` guard, held by `AppChatPromptTests`;
    /// toggling it here would write UserDefaults under a suite running in parallel.
    @Test func answeringBlocksTheDock() {
        let (model, conversation) = globalModel()
        conversation.isLoading = true
        model.standDown()
        #expect(model.phase == .prompt)
        #expect(!model.foldToDock())
    }

    @Test func aPrintableCharacterExpandsAndSeeds() {
        let (model, _) = globalModel()
        model.standDown()
        #expect(model.expandFromDock(seeding: "s"))
        #expect(model.phase == .prompt)
        #expect(model.query == "s")
    }

    @Test func expandFromDockIsANoOpElsewhere() {
        let (model, _) = globalModel()
        #expect(!model.expandFromDock(seeding: "s"))
        #expect(model.query.isEmpty)
    }

    @Test func hoverDoesNotExpandTheDock() {
        let (model, _) = globalModel()
        model.standDown()
        model.hoverBegan()
        #expect(model.phase == .dock)
        model.hoverEnded()
        #expect(model.phase == .dock)
    }

    @Test func rightArrowFromDockScopesLikeAnEmptyPromptDoes() {
        let (model, _) = globalModel()
        model.standDown()
        // Whatever an empty Global prompt does on →, the dock does — and never seeds a
        // character.
        let (reference, _) = globalModel()
        let expected = reference.scopeIntoFirstRunningApp()
        let result = model.arrowRightFromDock()
        #expect(result == expected)
        #expect(model.query.isEmpty)
        #expect(model.phase != .dock)
    }

    @Test func removedRunningAppsLeaveTheStrip() {
        let (model, _) = globalModel()
        model.hideRunningApp("com.apple.Safari")
        #expect(model.stripIcons.allSatisfy { $0.bundleID != "com.apple.Safari" })
        #expect(model.hiddenRunningBundleIDs == ["com.apple.Safari"])
    }

    @Test func aPinnedAppIsNotAlsoARunningIcon() {
        // Pinning a running app showed it twice, once on each side of the divider. The pin is
        // its home: pinning is what says "keep this here", and the running dot goes with it.
        // Membership, not counts: the running list fills in asynchronously, so any count
        // captured now can be stale by the next line — which is what made the first version
        // of this test fail for a reason that had nothing to do with pinning.
        let (model, _) = globalModel()
        model.pinnedAppBundleIDs = { [] }
        guard let bundleID = model.dockStripIcons.compactMap(\.bundleID).first else { return }
        #expect(model.dockStripIcons.contains { $0.bundleID == bundleID })

        model.pinnedAppBundleIDs = { [bundleID] }
        #expect(model.dockStripIcons.allSatisfy { $0.bundleID != bundleID })
        // Still one of the running apps: pinning changes where it is drawn, not what ← and →
        // walk through. Filtering the navigation list made a swipe skip a pinned app.
        #expect(model.stripIcons.contains { $0.bundleID == bundleID })

        // Unpinned, it comes straight back — the strip is a view of two lists, not a move.
        model.pinnedAppBundleIDs = { [] }
        #expect(model.dockStripIcons.contains { $0.bundleID == bundleID })
    }

    @Test func leftArrowFoldsAnEmptyGlobalFieldAtOnce() {
        let (model, _) = globalModel()
        #expect(model.foldToDock())
        #expect(model.phase == .dock)
        // Not with text in it, not with the setting off, not in a scope.
        let (typed, _) = globalModel()
        typed.query = "s"
        #expect(!typed.foldToDock())
        let (off, _) = globalModel(autoShrink: false)
        #expect(!off.foldToDock())
        let (scoped, _) = globalModel()
        scoped.scopeIntoApp(name: "Safari", bundleID: "com.apple.Safari")
        scoped.set(.prompt)
        #expect(!scoped.foldToDock())
    }

    @Test func dockIsNotAnInputPhase() {
        #expect(!AppChatPromptPhase.dock.showsInput)
        #expect(AppChatPromptPhase.dock.isVisible)
    }
}
