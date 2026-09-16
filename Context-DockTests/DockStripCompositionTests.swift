import AppKit
import Foundation
import Testing

@testable import Context_Dock

/// One dock row out of two lists. The strip drew the running apps and the pins as separate
/// sections, so an app that was both — Safari pinned while Safari is open — appeared twice.
@MainActor
struct DockStripCompositionTests {
    private func icon(_ bundleID: String, _ title: String) -> MatchDockIcon {
        MatchDockIcon(
            id: "app:\(bundleID)", bundleID: bundleID, title: title, icon: NSImage(),
            isRunning: true, isExpandable: true, score: 1, isExactAppPrefix: false)
    }

    private func pin(_ kind: DockPinKind, _ title: String, order: Int) -> DockPin {
        DockPin(id: UUID(), kind: kind, title: title, order: order, documentID: nil)
    }

    @Test func anAppThatIsPinnedAndRunningIsOneIcon() {
        let pins = [pin(.app(bundleID: "com.apple.Safari"), "Safari", order: 0)]
        let composed = DockStripComposition.compose(
            running: [icon("com.apple.finder", "Finder"), icon("com.apple.Safari", "Safari")],
            pins: pins, runningBundleIDs: [])

        #expect(composed.apps.count == 2)
        let safari = composed.apps.filter { $0.bundleID == "com.apple.Safari" }
        #expect(safari.count == 1)
        #expect(safari.first?.isPinned == true)
        #expect(safari.first?.isRunning == true)
    }

    @Test func pinnedAppsComeFirstInPinOrderThenTheRunningOnes() {
        let pins = [
            pin(.app(bundleID: "com.microsoft.VSCode"), "Code", order: 0),
            pin(.app(bundleID: "com.apple.Safari"), "Safari", order: 1),
        ]
        let composed = DockStripComposition.compose(
            running: [icon("com.apple.finder", "Finder"), icon("com.apple.Safari", "Safari")],
            pins: pins, runningBundleIDs: [])

        #expect(composed.apps.map(\.bundleID) == [
            "com.microsoft.VSCode", "com.apple.Safari", "com.apple.finder",
        ])
        // A pinned app that is not running still draws, without a dot.
        #expect(composed.apps.first?.isRunning == false)
    }

    @Test func pinsThatAreNotAppsKeepTheirOwnRegion() {
        let pins = [
            pin(.app(bundleID: "com.apple.Safari"), "Safari", order: 0),
            pin(.folder(path: "/tmp"), "tmp", order: 1),
            pin(.cliTool(name: "rg"), "rg", order: 2),
        ]
        let composed = DockStripComposition.compose(running: [], pins: pins, runningBundleIDs: [])

        #expect(composed.apps.map(\.bundleID) == ["com.apple.Safari"])
        #expect(composed.otherPins.map(\.title) == ["tmp", "rg"])
    }

    @Test func overflowDropsRunningAppsAndNeverPinnedOnes() {
        let pins = [
            pin(.app(bundleID: "com.microsoft.VSCode"), "Code", order: 0),
            pin(.app(bundleID: "com.apple.Safari"), "Safari", order: 1),
        ]
        let running = (1...5).map { icon("com.other.app\($0)", "App \($0)") }
        let composed = DockStripComposition.compose(
            running: running, pins: pins, runningBundleIDs: [], capacity: 2)

        #expect(composed.apps.count == 4)  // both pins, two of the five
        #expect(composed.apps.prefix(2).filter(\.isPinned).count == 2)
        #expect(composed.overflow == 3)
    }

    @Test func aPinnedAppKeepsItsDotWhenItsIconIsNotInTheRunningList() {
        // "Remove from Strip" takes an app out of `stripIcons` while it is still up; the
        // pin has to tell the truth about that, which is why the running set is passed in.
        let pins = [pin(.app(bundleID: "com.apple.Safari"), "Safari", order: 0)]
        let composed = DockStripComposition.compose(
            running: [], pins: pins, runningBundleIDs: ["com.apple.Safari"])

        #expect(composed.apps.first?.isRunning == true)
        #expect(composed.apps.first?.isPinned == true)
    }

    @Test func aPinWhoseDocumentThisBuildCannotFindIsNotDrawn() {
        // A plugin pinned on a build that has the plugin, opened on a build that does not:
        // the row drew an empty dashed square that said nothing and did nothing. The pin
        // stays in the store — it comes back with the thing it points at.
        var sleep = pin(.globalCommand(id: "plugin:sleep"), "Sleep", order: 0)
        sleep = DockPin(
            id: sleep.id, kind: sleep.kind, title: sleep.title, order: sleep.order,
            documentID: "plugin://sleep")
        let composed = DockStripComposition.compose(
            running: [], pins: [sleep, pin(.folder(path: "/tmp"), "tmp", order: 1)],
            runningBundleIDs: [], unresolvedDocumentIDs: ["plugin://sleep"])

        #expect(composed.otherPins.map(\.title) == ["tmp"])
    }

    @Test func theCountsTheStripIsSizedFromMatchWhatItDraws() {
        let pins = [
            pin(.app(bundleID: "com.apple.Safari"), "Safari", order: 0),
            pin(.folder(path: "/tmp"), "tmp", order: 1),
        ]
        let composed = DockStripComposition.compose(
            running: [icon("com.apple.finder", "Finder"), icon("com.apple.Safari", "Safari")],
            pins: pins, runningBundleIDs: [])

        #expect(composed.pinnedAppCount == 1)
        #expect(composed.unpinnedRunningCount == 1)
        #expect(composed.pinnedAppCount + composed.unpinnedRunningCount == composed.apps.count)
        #expect(composed.otherPins.count == 1)
    }
}
