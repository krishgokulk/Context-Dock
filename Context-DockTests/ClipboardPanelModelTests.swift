import Foundation
import Testing
@testable import Context_Dock

@MainActor
struct ClipboardPanelModelTests {
    private func entry(_ text: String, app: String, bundleID: String) -> LauncherView.ClipboardEntry {
        LauncherView.ClipboardEntry(
            text: text,
            timestamp: Date(),
            sourceAppName: app,
            sourceBundleId: bundleID
        )
    }

    @Test func allIsTheDefaultAndSourceOrderFollowsRecentHistory() {
        let model = ClipboardPanelModel()
        model.entries = [
            entry("finder", app: "Finder", bundleID: "com.apple.finder"),
            entry("code", app: "Code", bundleID: "com.microsoft.VSCode"),
            entry("finder two", app: "Finder", bundleID: "com.apple.finder"),
        ]

        #expect(model.selectedSource.name == "All")
        #expect(model.sources.map(\.name) == ["All", "Finder", "Code"])
        #expect(model.sources.map(\.count) == [3, 2, 1])
    }

    @Test func rightArrowCyclingWrapsThroughAllAndApps() {
        let model = ClipboardPanelModel()
        model.entries = [
            entry("finder", app: "Finder", bundleID: "com.apple.finder"),
            entry("code", app: "Code", bundleID: "com.microsoft.VSCode"),
        ]

        model.cycleSource(1)
        #expect(model.selectedSource.name == "Finder")
        model.cycleSource(1)
        #expect(model.selectedSource.name == "Code")
        model.cycleSource(1)
        #expect(model.selectedSource.name == "All")
    }

    @Test func sourceAndTextFiltersComposeWithoutChangingOtherState() {
        let model = ClipboardPanelModel()
        model.entries = [
            entry("project alpha", app: "Finder", bundleID: "com.apple.finder"),
            entry("project beta", app: "Code", bundleID: "com.microsoft.VSCode"),
            entry("notes", app: "Code", bundleID: "com.microsoft.VSCode"),
        ]
        model.selectSource(bundleID: "com.microsoft.VSCode")
        model.query = "project"

        #expect(model.visibleEntries.map(\.text) == ["project beta"])
    }
}

// MARK: - Pill phase machine

@MainActor
struct ClipboardPillPhaseTests {
    private func entry(_ text: String) -> LauncherView.ClipboardEntry {
        LauncherView.ClipboardEntry(
            text: text,
            timestamp: Date(),
            sourceAppName: "Code",
            sourceBundleId: "com.microsoft.VSCode"
        )
    }

    private func loaded(_ texts: String...) -> ClipboardPanelModel {
        let model = ClipboardPanelModel()
        model.entries = texts.map(entry)
        return model
    }

    @Test func aCopyShowsTheCollapsedPillAndArmsTheAutoHide() {
        let model = loaded("one")

        model.didCopy()

        #expect(model.phase == .collapsed)
        #expect(model.isHideArmed)
    }

    @Test func hoverExpandsThePillAndCancelsTheAutoHide() {
        let model = loaded("one")
        model.didCopy()

        model.hoverBegan()

        #expect(model.phase == .expanded)
        #expect(!model.isHideArmed)
    }

    @Test func leavingTheCardCollapsesItAndRearmsTheAutoHide() {
        let model = loaded("one")
        model.didCopy()
        model.hoverBegan()

        model.hoverEnded()

        #expect(model.phase == .collapsed)
        #expect(model.isHideArmed)
    }

    /// The hotkey is a deliberate ask — it must not evaporate four seconds later.
    @Test func theHotkeySummonsTheExpandedCardWithNoAutoHide() {
        let model = loaded("one")

        model.summon()

        #expect(model.phase == .expanded)
        #expect(!model.isHideArmed)
    }

    @Test func dismissHidesThePillAndClearsRowFocus() {
        let model = loaded("one", "two")
        model.summon()
        model.moveEntry(1)

        model.dismiss()

        #expect(model.phase == .hidden)
        #expect(!model.isHideArmed)
        #expect(model.focusedEntryIndex == nil)
    }

    /// Copying while reading the history must not yank the card out from under the pointer.
    @Test func aCopyWhileTheCardIsOpenLeavesItOpen() {
        let model = loaded("one")
        model.summon()

        model.didCopy()

        #expect(model.phase == .expanded)
        #expect(!model.isHideArmed)
    }

    @Test func theHotkeyTogglesTheCardShut() {
        let model = loaded("one")
        model.summon()

        model.toggleSummon()

        #expect(model.phase == .hidden)
    }

    @Test func downArrowFromTheCardFocusesTheNewestClip() {
        let model = loaded("newest", "older")
        model.summon()

        model.moveEntry(1)

        #expect(model.focusedEntryIndex == 0)
        #expect(model.focusedEntry?.text == "newest")
    }

    @Test func summoningResetsAFilterLeftOverFromTheLastVisit() {
        let model = loaded("one")
        model.selectSource(bundleID: "com.microsoft.VSCode")
        model.dismiss()

        model.summon()

        #expect(model.selectedSource.name == "All")
    }
}

// MARK: - Fresh clips vs the debounced disk write

@MainActor
struct ClipboardIngestTests {
    private func model() -> ClipboardPanelModel {
        // A path with no file on it: stands in for "the debounced write has not landed".
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("clipboard-\(UUID().uuidString).json")
        return ClipboardPanelModel(storeURL: url)
    }

    private func entry(_ text: String, hash: String) -> LauncherView.ClipboardEntry {
        LauncherView.ClipboardEntry(
            text: text,
            timestamp: Date(),
            sourceAppName: "Code",
            sourceBundleId: "com.microsoft.VSCode",
            contentHash: hash
        )
    }

    /// History is written to disk on a 600ms debounce, so the clip that raised the pill is
    /// not on disk yet. Handed the entry directly, the pill still shows the right thing.
    @Test func anIngestedClipIsVisibleBeforeTheDiskWriteLands() {
        let model = model()
        model.ingest(entry("newest", hash: "a"))

        #expect(model.visibleEntries.first?.text == "newest")
    }

    @Test func aReloadFromStaleDiskDoesNotDropAFreshlyIngestedClip() {
        let model = model()
        model.ingest(entry("newest", hash: "a"))

        model.reload()

        #expect(model.visibleEntries.first?.text == "newest")
    }

    @Test func reIngestingTheSameContentMovesItUpInsteadOfDuplicating() {
        let model = model()
        model.ingest(entry("one", hash: "a"))
        model.ingest(entry("two", hash: "b"))

        model.ingest(entry("one", hash: "a"))

        #expect(model.visibleEntries.map(\.text) == ["one", "two"])
    }
}

// MARK: - Keyboard arming and preview targets

@MainActor
struct ClipboardKeyboardTests {
    private func entry(
        _ text: String, files: [String] = [], imageFileName: String? = nil
    ) -> LauncherView.ClipboardEntry {
        LauncherView.ClipboardEntry(
            text: text,
            timestamp: Date(),
            filePaths: files,
            imageFileName: imageFileName,
            sourceAppName: "Code",
            sourceBundleId: "com.microsoft.VSCode",
            contentHash: text + files.joined()
        )
    }

    private func loaded(_ entries: LauncherView.ClipboardEntry...) -> ClipboardPanelModel {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("clipboard-\(UUID().uuidString).json")
        let model = ClipboardPanelModel(storeURL: url)
        model.entries = entries
        return model
    }

    /// Hovering is mouse-only; a click is the deliberate act that hands the card the
    /// keyboard. Once armed it must stop behaving like an ambient pill.
    @Test func armingTheKeyboardKeepsTheCardOpenAfterThePointerLeaves() {
        let model = loaded(entry("one"))
        model.didCopy()
        model.hoverBegan()

        model.armKeyboard()
        model.hoverEnded()

        #expect(model.phase == .expanded)
        #expect(!model.isHideArmed)
    }

    @Test func dismissDisarmsTheKeyboard() {
        let model = loaded(entry("one"))
        model.summon()
        model.armKeyboard()

        model.dismiss()

        #expect(!model.isKeyboardArmed)
    }

    @Test func aCopyDoesNotDisturbAnArmedCard() {
        let model = loaded(entry("one"))
        model.summon()
        model.armKeyboard()

        model.didCopy()

        #expect(model.phase == .expanded)
        #expect(model.isKeyboardArmed)
    }

    @Test func previewingAFileClipTargetsTheFileItself() {
        let model = loaded(entry("", files: ["/tmp/report.pdf"]))
        model.moveEntry(1)

        #expect(model.previewTarget == .file(URL(fileURLWithPath: "/tmp/report.pdf")))
    }

    @Test func previewingAnImageClipTargetsItsStoredBlob() {
        let model = loaded(entry("", imageFileName: "clip-7.png"))
        model.moveEntry(1)

        #expect(model.previewTarget == .file(ClipboardImageStore.url(for: "clip-7.png")))
    }

    @Test func previewingATextClipTargetsTheTextItself() {
        let model = loaded(entry("some copied prose"))
        model.moveEntry(1)

        #expect(model.previewTarget == .text("some copied prose"))
    }

    /// Space with nothing arrowed to yet should still preview something sensible.
    @Test func previewFallsBackToTheNewestClipWhenNoRowIsFocused() {
        let model = loaded(entry("newest"), entry("older"))

        #expect(model.previewTarget == .text("newest"))
    }
}

// MARK: - Bursts and shrinking

@MainActor
struct ClipboardBurstTests {
    private func entry(_ text: String) -> LauncherView.ClipboardEntry {
        LauncherView.ClipboardEntry(
            text: text, timestamp: Date(),
            sourceAppName: "Finder", sourceBundleId: "com.apple.finder",
            contentHash: text)
    }

    private func model() -> ClipboardPanelModel {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("clipboard-\(UUID().uuidString).json")
        return ClipboardPanelModel(storeURL: url)
    }

    @Test func theFirstCopyIsNotABurst() {
        let model = model()
        model.ingest(entry("one"))
        model.didCopy()

        #expect(model.burstCount == 0)
    }

    /// Copying faster than the pill can stand down should say how much was caught, not
    /// silently replace one clip with the next.
    @Test func copiesLandingWhileThePillIsUpAreCounted() {
        let model = model()
        model.ingest(entry("one"))
        model.didCopy()

        model.ingest(entry("two"))
        model.didCopy()
        model.ingest(entry("three"))
        model.didCopy()

        #expect(model.burstCount == 2)
    }

    @Test func openingTheCardClearsTheBurstBecauseTheClipsHaveBeenSeen() {
        let model = model()
        model.ingest(entry("one"))
        model.didCopy()
        model.ingest(entry("two"))
        model.didCopy()

        model.hoverBegan()

        #expect(model.burstCount == 0)
    }

    @Test func aBurstDoesNotCarryIntoTheNextTimeThePillAppears() {
        let model = model()
        model.ingest(entry("one"))
        model.didCopy()
        model.ingest(entry("two"))
        model.didCopy()
        model.dismiss()

        model.ingest(entry("three"))
        model.didCopy()

        #expect(model.burstCount == 0)
    }

    @Test func thePillShrinksToABadgeBeforeItGoesAway() {
        let model = model()
        model.ingest(entry("one"))
        model.didCopy()

        model.autoShrink()

        #expect(model.phase == .mini)
        #expect(model.isHideArmed)
    }

    @Test func theBadgeIsStillTheClipboardSoHoveringItOpensTheCard() {
        let model = model()
        model.ingest(entry("one"))
        model.didCopy()
        model.autoShrink()

        model.hoverBegan()

        #expect(model.phase == .expanded)
    }

    @Test func theBadgeGoesAwayOnItsOwn() {
        let model = model()
        model.ingest(entry("one"))
        model.didCopy()
        model.autoShrink()

        model.autoHide()

        #expect(model.phase == .hidden)
    }

    /// A card being read belongs to the pointer; it must not shrink underneath it.
    @Test func anOpenCardNeverShrinks() {
        let model = model()
        model.ingest(entry("one"))
        model.summon()

        model.autoShrink()

        #expect(model.phase == .expanded)
    }

    @Test func aCopyDuringTheBadgeStageBringsTheFullPillBack() {
        let model = model()
        model.ingest(entry("one"))
        model.didCopy()
        model.autoShrink()

        model.ingest(entry("two"))
        model.didCopy()

        #expect(model.phase == .collapsed)
        #expect(model.burstCount == 1)
    }
}
