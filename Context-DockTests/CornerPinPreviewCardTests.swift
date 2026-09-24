// Context-DockTests/CornerPinPreviewCardTests.swift
import Foundation
import Testing

@testable import Context_Dock

/// The folder card above a pinned folder: it fills its slot, grows when expanded, and stays
/// up when pinned.
struct CornerPinPreviewCardTests {
    private let folder = DockPinPreview.folder(
        .init(path: "/tmp", name: "Downloads"))

    @Test func theFolderCardIsItsSlotAndGrowsOnlyWhenExpanded() {
        let small = DockPinPreviewMetrics.size(for: folder)
        let big = DockPinPreviewMetrics.size(for: folder, expanded: true)
        #expect(small == DockPinPreviewMetrics.folder)
        #expect(big.width > small.width && big.height > small.height)
        // A file has nothing more to show; expanding never changes it.
        let file = DockPinPreview.missing(name: "x", reason: "")
        #expect(DockPinPreviewMetrics.size(for: file, expanded: true)
            == DockPinPreviewMetrics.size(for: file))
    }

    @Test func aPinnedCardWinsOverWhateverThePointerIsOn() {
        let pinned = UUID()
        #expect(AppChatPromptModel.previewTarget(hovered: .app(bundleID: "a"), pinnedPin: pinned)
            == .pin(id: pinned))
        #expect(AppChatPromptModel.previewTarget(hovered: nil, pinnedPin: pinned)
            == .pin(id: pinned))
        #expect(AppChatPromptModel.previewTarget(hovered: .app(bundleID: "a"), pinnedPin: nil)
            == .app(bundleID: "a"))
    }
}
