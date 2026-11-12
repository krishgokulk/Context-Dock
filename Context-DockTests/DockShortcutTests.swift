import Testing

@testable import Context_Dock

/// Every pre-model keyword shortcut that claims a turn in `handleL2Query` names itself with one
/// step in the turn's trace, so the Corner panel and the Dock can say why something ran instead
/// of "Answered without running anything" (issue #198, plan §3). One test per family pins the
/// exact line the panel shows.
struct DockShortcutTests {

    // MARK: - One per shortcut family

    @Test func triggerRuleStep() {
        #expect(DockShortcut.triggerRule.step == "Shortcut: Trigger Rule — matched 'a saved trigger phrase'")
    }

    @Test func systemCommandStep() {
        #expect(DockShortcut.systemCommand.step == "Shortcut: System Command — matched 'a built-in system command'")
    }

    @Test func githubInstallStep() {
        #expect(DockShortcut.githubInstall.step == "Shortcut: GitHub Install — matched 'link a GitHub tool'")
    }

    @Test func appFindStep() {
        #expect(DockShortcut.appFind.step == "Shortcut: App Find — matched 'find … in this app'")
    }

    @Test func transformShareStep() {
        #expect(DockShortcut.transformShare.step == "Shortcut: Transform & Share — matched 'transform this and send it'")
    }

    @Test func finderStep() {
        #expect(DockShortcut.finder.step == "Shortcut: Finder — matched 'a Finder folder request'")
    }


    @Test func crossAppStep() {
        #expect(DockShortcut.crossApp.step == "Shortcut: Cross-App — matched 'send/open this in another app'")
    }

    @Test func appActionStep() {
        #expect(DockShortcut.appAction.step == "Shortcut: App Action — matched 'a global app action'")
    }

    @Test func appLaunchStep() {
        #expect(DockShortcut.appLaunch.step == "Shortcut: App Launch — matched 'open an app'")
    }

    @Test func safariCommandStep() {
        #expect(DockShortcut.safariCommand.step == "Shortcut: Safari Command — matched 'a Safari command'")
    }

    // MARK: - The whole set

    /// Every family starts its step with "Shortcut: " so `CornerLivePanel` can tell a shortcut
    /// claim from an ordinary trace line, and no two families share a line.
    @Test func everyFamilyHasADistinctShortcutLine() {
        let steps = DockShortcut.allCases.map(\.step)
        #expect(steps.allSatisfy { $0.hasPrefix("Shortcut: ") })
        #expect(Set(steps).count == DockShortcut.allCases.count)
    }
}
