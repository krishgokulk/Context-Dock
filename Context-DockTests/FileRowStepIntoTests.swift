import Foundation
import Testing

@testable import Context_Dock

/// → on a file row opens that file's Selection card (owner 2026-10-11); the list underneath
/// keeps its query and highlight for when the card closes.
@MainActor
@Suite("File row step-into")
struct FileRowStepIntoTests {
    @Test func rightArrowOnAFileAsksForItsSelectionCard() {
        let model = AppChatPromptModel()
        let file = URL(fileURLWithPath: "/tmp/Statement_2026_3.pdf")
        var opened: URL?
        model.onStepIntoFile = { opened = $0; return true }
        model.rows = [.file(file)]
        model.focusedMenuIndex = 0
        model.query = ".pdf"

        #expect(model.stepIntoFocusedRow())
        #expect(opened == file)
        #expect(model.query == ".pdf")
        #expect(model.focusedMenuIndex == 0)
    }

    @Test func nothingSpentWhenTheCornerCannotOpenTheCard() {
        let model = AppChatPromptModel()
        model.onStepIntoFile = { _ in false }
        model.rows = [.file(URL(fileURLWithPath: "/tmp/a.txt"))]
        model.focusedMenuIndex = 0

        #expect(!model.stepIntoFocusedRow())
    }

    @Test func showSelectionForFileExpandsSidePanelWithoutCoveringChat() throws {
        let fm = FileManager.default
        let file = fm.temporaryDirectory.appendingPathComponent("SidePanelTest-\(UUID().uuidString).pdf")
        try Data("pdf".utf8).write(to: file)
        defer { try? fm.removeItem(at: file) }

        let controller = CornerDockController.shared
        controller.prompt.isSidePanelExpanded = false
        defer {
            controller.selection.dismiss()
            controller.prompt.isSidePanelExpanded = false
        }

        #expect(controller.showSelection(forFile: file))
        #expect(controller.selection.phase.isVisible)
        #expect(controller.selection.isEmbeddedInSidePanel)
        #expect(!controller.selection.coversChat)
        #expect(controller.prompt.isSidePanelExpanded)
    }

    @Test func spaceKeyTogglesSidePanelFilePreviewWhenBrowsingFiles() throws {
        let fm = FileManager.default
        let file = fm.temporaryDirectory.appendingPathComponent("SpacePreview-\(UUID().uuidString).rtf")
        try Data("hello preview".utf8).write(to: file)
        defer { try? fm.removeItem(at: file) }

        let controller = CornerDockController.shared
        controller.selection.dismiss()
        defer {
            controller.selection.dismiss()
            controller.prompt.isSidePanelExpanded = false
        }

        let model = AppChatPromptModel()
        model.summonGlobalContext()
        model.set(.suggesting)
        model.rows = [.file(file)]
        model.focusedMenuIndex = 0
        model.query = ""
        model.isSidePanelExpanded = false

        #expect(model.toggleSidePanelPreview())
        #expect(model.isSidePanelExpanded)
        #expect(model.boardPreview == .file(file))

        #expect(model.toggleSidePanelPreview())
        #expect(!model.isSidePanelExpanded)
        #expect(model.boardPreview == nil)
    }

    @Test func spaceKeyDoesNotHijackMidWordTypingUntilArrowedIntoList() throws {
        let fm = FileManager.default
        let file = fm.temporaryDirectory.appendingPathComponent("MidWord-\(UUID().uuidString).pdf")
        try Data("pdf".utf8).write(to: file)
        defer { try? fm.removeItem(at: file) }

        let model = AppChatPromptModel()
        model.summonGlobalContext()
        model.query = "authorization"
        model.queryChanged()
        model.set(.suggesting)
        model.rows = [.file(file)]
        model.focusedMenuIndex = 0

        // Typing mid-query without pressing ↑/↓: Space must NOT open the preview panel.
        #expect(!model.toggleSidePanelPreview())
        #expect(!model.isSidePanelExpanded)

        // Once the user presses ↓ to move focus into the list, Space toggles the preview panel.
        #expect(model.moveMenuFocus(by: 1))
        #expect(model.toggleSidePanelPreview())
        #expect(model.isSidePanelExpanded)

        // Typing again resets arrowed state so subsequent Space characters type into the query.
        model.query = "authorization letter"
        model.queryChanged()
        #expect(!model.toggleSidePanelPreview())
    }

    @Test func spaceInEmbeddedSelectionSwitchesToFilePreviewKeepingSidePanelOpen() throws {
        let fm = FileManager.default
        let file = fm.temporaryDirectory.appendingPathComponent("SwitchToPreview-\(UUID().uuidString).pdf")
        try Data("pdf".utf8).write(to: file)
        defer { try? fm.removeItem(at: file) }

        let controller = CornerDockController.shared
        controller.prompt.isSidePanelExpanded = false
        defer {
            controller.selection.dismiss()
            controller.prompt.isSidePanelExpanded = false
        }

        #expect(controller.showSelection(forFile: file))
        #expect(controller.selection.isEmbeddedInSidePanel)
        #expect(controller.selection.phase.isVisible)
        #expect(controller.prompt.isSidePanelExpanded)

        controller.switchSidePanelFromSelectionToPreview()
        #expect(!controller.selection.phase.isVisible)
        #expect(!controller.selection.isEmbeddedInSidePanel)
        #expect(controller.prompt.isSidePanelExpanded)
    }
}
