import AppKit
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

    /// Every app's Context Dock rests as a dock, as Global does — its pins, or the running
    /// apps when it has none (owner 2026-10-08, replacing "a scoped chat never docks").
    @Test func aScopedChatDocksLikeGlobal() {
        let (model, _) = globalModel()
        model.scopeIntoApp(name: "TextEdit", bundleID: "com.apple.TextEdit")
        model.set(.prompt)
        model.standDown()
        #expect(model.phase == .dock)
    }

    @Test func typedTextKeepsThePromptFromDocking() {
        let (model, _) = globalModel()
        model.query = "saf"
        model.standDown()
        #expect(model.phase == .mini)
    }

    /// Resting the pointer on the apps folds a typed field too, and the draft waits for the
    /// field's return (owner 2026-10-08); the shell's own folds still refuse typed text.
    @Test func thePointerFoldsATypedFieldAndKeepsTheDraft() {
        let (model, _) = globalModel()
        model.query = "r"
        #expect(!model.restAsDockNow())
        #expect(model.phase == .prompt)
        #expect(model.restAsDockNow(keepsDraft: true))
        #expect(model.phase == .dock)
        #expect(model.query == "r")
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

    /// A key on a dock that kept the pointer's folded draft carries on from it.
    @Test func aKeyAfterAPointerFoldCarriesOnTheDraft() {
        let (model, _) = globalModel()
        model.query = "saf"
        #expect(model.restAsDockNow(keepsDraft: true))
        #expect(model.expandFromDock(seeding: "a"))
        #expect(model.query == "safa")
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

    @Test func pinningAnAppChangesWhereItIsDrawnNotWhatTheArrowsWalk() {
        // Two sessions fixed "a pinned app is drawn twice" on the same day, differently.
        // The shape that stayed is decision 26740ecd: one app region, pinned apps first,
        // composed by DockStripComposition. What the other fix got right is kept here —
        // `stripIcons` is the NAVIGATION list, what ← and → walk and a swipe moves
        // through, and a pinned app must stay in it. Filtering that list made a swipe
        // skip a pinned app. Membership, not counts: the running list fills in
        // asynchronously.
        let (model, _) = globalModel()
        guard let bundleID = model.stripIcons.compactMap(\.bundleID).first else { return }

        let pin = DockPin(
            id: UUID(), kind: .app(bundleID: bundleID), title: "Pinned", order: 0,
            documentID: nil)
        let composed = DockStripComposition.compose(
            running: model.stripIcons, pins: [pin], runningBundleIDs: [])

        // Drawn once, as the pin, with its running dot.
        #expect(composed.apps.filter { $0.bundleID == bundleID }.count == 1)
        #expect(composed.apps.first { $0.bundleID == bundleID }?.isPinned == true)
        // Still walked by the arrows.
        #expect(model.stripIcons.contains { $0.bundleID == bundleID })
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
        // An app's Context Dock can fold too now (owner 2026-10-08); the ← key folds only
        // Global's field (`CornerDockController`), since in a scope ← is the way back.
        let (scoped, _) = globalModel()
        scoped.scopeIntoApp(name: "TextEdit", bundleID: "com.apple.TextEdit")
        scoped.set(.prompt)
        #expect(scoped.foldToDock())
    }

    @Test func dockIsNotAnInputPhase() {
        #expect(!AppChatPromptPhase.dock.showsInput)
        #expect(AppChatPromptPhase.dock.isVisible)
    }

    /// An app stepped into from Global rests as its own Context Dock — no sheet of its
    /// actions — and Return on the empty field brings it forward (owner 2026-10-07). Finder
    /// is one of them (owner 2026-10-09).
    @Test func anAppSteppedIntoRestsAsItsOwnDock() {
        let (model, _) = globalModel()
        model.scopeIntoApp(name: "TextEdit", bundleID: "com.apple.TextEdit")
        #expect(model.isAppStepIn)
        #expect(model.phase != .suggesting)
        // Its field is a composer, as in the frontmost app's Context Dock: Return asks the app
        // rather than running its top menu row (owner 2026-10-09).
        #expect(!model.isSearchField)
        let (finder, _) = globalModel()
        finder.scopeIntoApp(name: "Finder", bundleID: "com.apple.finder")
        #expect(finder.isAppStepIn)
        #expect(!finder.isSearchField)
        #expect(finder.showsTabBar)
        // Its live menus are not read from Global — the read that once froze the field.
        #expect(finder.finderSkipsLiveMenus)
    }

    /// "/" in Global or an app's Context Dock jumps to an app by name — a space makes it a
    /// sentence — and the jump scopes in without launching anything (owner 2026-10-10).
    @Test func slashJumpsToAnAppWithoutLaunchingIt() {
        let (model, _) = globalModel()
        model.query = "/"
        #expect(model.slashAppFilter == "")
        model.query = "/Mes"
        #expect(model.slashAppFilter == "mes")
        model.query = "/mes what's new"
        #expect(model.slashAppFilter == nil)
        model.query = ""
        #expect(model.slashAppFilter == nil)

        let notes = ChatAppEntry(
            name: "Notes", bundleId: "com.example.not-running-notes", icon: nil, isRunning: false)
        model.run(.app(notes))
        #expect(model.appBundleID == "com.example.not-running-notes")
        #expect(model.returnsToGlobalScope)
        #expect(model.query.isEmpty)
        #expect(!NSWorkspace.shared.runningApplications.contains {
            $0.bundleIdentifier == "com.example.not-running-notes"
        })
        // From an app's Context Dock, "/" jumps sideways.
        model.query = "/s"
        #expect(model.slashAppFilter == "s")
        // Finder's Ask AI row stands aside for it.
        model.run(.app(ChatAppEntry(
            name: "Finder", bundleId: "com.apple.finder", icon: nil, isRunning: true)))
        model.query = "/sa"
        #expect(!model.showsAskAIRow)
    }

    @Test func slashListsRunningAppsBeforeInstalledOnes() {
        func entry(_ id: String, _ running: Bool) -> ChatAppEntry {
            ChatAppEntry(name: id, bundleId: id, icon: nil, isRunning: running)
        }
        let ordered = AppChatPromptModel.runningFirst([
            entry("maps", false), entry("messages", true), entry("mail", false),
            entry("music", true),
        ])
        #expect(ordered.map(\.bundleId) == ["messages", "music", "maps", "mail"])
    }

    /// Finder's typed list opens under an Ask AI row: nothing chosen is that row, so Return
    /// asks; ↓ chooses the first file or command (owner 2026-10-09).
    @Test func finderListsUnderAnAskAIRow() {
        let (finder, _) = globalModel()
        finder.scopeIntoApp(name: "Finder", bundleID: "com.apple.finder")
        #expect(!finder.showsAskAIRow)
        finder.query = "report"
        #expect(finder.showsAskAIRow)
        finder.rows = [
            .file(URL(fileURLWithPath: "/tmp/report.pdf")),
            .file(URL(fileURLWithPath: "/tmp/report-2.pdf")),
        ]
        #expect(finder.listRowCount == 3)
        #expect(!finder.runFocusedRow())
        #expect(finder.moveMenuFocus(by: 1))
        #expect(finder.focusedMenuIndex == 0)
        #expect(finder.moveMenuFocus(by: -1))
        #expect(finder.focusedMenuIndex == nil)
        // Another app keeps its own list: no Ask AI row.
        let (other, _) = globalModel()
        other.scopeIntoApp(name: "TextEdit", bundleID: "com.apple.TextEdit")
        other.query = "save"
        #expect(!other.showsAskAIRow)
    }
}
