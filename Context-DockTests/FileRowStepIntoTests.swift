import AppKit
import Foundation
import PDFKit
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
            _ = controller.prompt.leaveFileSubmode()
            controller.selection.dismiss()
            controller.prompt.isSidePanelExpanded = false
        }

        #expect(controller.showSelection(forFile: file))
        #expect(controller.selection.phase.isVisible)
        #expect(controller.selection.isSheetSubmode)
        #expect(!controller.selection.coversChat)
        #expect(controller.prompt.isInFileSubmode)
        #expect(controller.prompt.fileSubmode?.kind == .selectionScope)
        #expect(controller.prompt.isSidePanelExpanded)

        // Filtering from the top input bar updates Selection Scope query without touching parent query
        controller.prompt.query = "untitled.rtf"
        controller.prompt.setFileSubmodeQuery("copy")
        #expect(controller.selection.query == "copy")
        #expect(controller.prompt.query == "untitled.rtf")

        // Leaving restores parent state cleanly
        #expect(controller.prompt.leaveFileSubmode())
        #expect(!controller.prompt.isInFileSubmode)
        #expect(controller.prompt.query == "untitled.rtf")
    }

    @Test func spaceKeyTogglesSidePanelFilePreviewWhenBrowsingFiles() throws {
        let fm = FileManager.default
        let file = fm.temporaryDirectory.appendingPathComponent("SpacePreview-\(UUID().uuidString).rtf")
        try Data("hello preview".utf8).write(to: file)
        defer { try? fm.removeItem(at: file) }

        let controller = CornerDockController.shared
        controller.selection.dismiss()
        defer {
            _ = controller.prompt.leaveFileSubmode()
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
        #expect(model.isInFileSubmode)
        #expect(model.fileSubmode?.kind == .preview)
        #expect(model.fileSubmode?.url.standardizedFileURL == file.standardizedFileURL)
        #expect(model.boardSize.width >= 680)

        // Switching modes in-place (dropdown / shortcuts) preserves the active file
        model.switchFileSubmode(.searchInFile)
        #expect(model.fileSubmode?.kind == .searchInFile)
        model.switchFileSubmode(.userActions)
        #expect(model.fileSubmode?.kind == .userActions)
        model.switchFileSubmode(.preview)
        #expect(model.fileSubmode?.kind == .preview)

        // Pressing Space again on empty submode query closes back to the file list
        #expect(model.toggleSidePanelPreview())
        #expect(!model.isInFileSubmode)
        #expect(!model.isSidePanelExpanded)
    }

    @Test func spaceKeyDoesNotHijackMidWordTypingUntilArrowedIntoList() throws {
        let fm = FileManager.default
        let file = fm.temporaryDirectory.appendingPathComponent("MidWord-\(UUID().uuidString).pdf")
        try Data("pdf".utf8).write(to: file)
        defer {
            CornerDockController.shared.selection.dismiss()
            try? fm.removeItem(at: file)
        }

        let model = AppChatPromptModel()
        model.summonGlobalContext()
        model.query = "authorization"
        model.queryChanged()
        model.set(.suggesting)
        model.rows = [.file(file)]
        model.focusedMenuIndex = 0

        // Typing mid-query without pressing ↑/↓: Space must NOT open the preview panel.
        #expect(!model.toggleSidePanelPreview())
        #expect(!model.isInFileSubmode)

        // Once the user presses ↓ to move focus into the list, Space opens full-sheet preview.
        #expect(model.moveMenuFocus(by: 1))
        #expect(model.toggleSidePanelPreview())
        #expect(model.isInFileSubmode)
        #expect(model.fileSubmode?.kind == .preview)
        #expect(model.leaveFileSubmode())

        // Typing again resets arrowed state so subsequent Space characters type into the query.
        model.query = "authorization letter"
        model.queryChanged()
        #expect(!model.toggleSidePanelPreview())
    }

    @Test func spaceInEmbeddedSelectionSwitchesToFilePreviewKeepingSidePanelOpen() throws {
        let fm = FileManager.default
        let file = fm.temporaryDirectory.appendingPathComponent("SwitchToPreview-\(UUID().uuidString).txt")
        try Data("alpha line\nbeta target match\ngamma line".utf8).write(to: file)
        defer { try? fm.removeItem(at: file) }

        let controller = CornerDockController.shared
        controller.prompt.isSidePanelExpanded = false
        defer {
            _ = controller.prompt.leaveFileSubmode()
            controller.selection.dismiss()
            controller.prompt.isSidePanelExpanded = false
        }

        #expect(controller.showSelection(forFile: file))
        #expect(controller.prompt.fileSubmode?.kind == .selectionScope)

        controller.switchSidePanelFromSelectionToPreview()
        #expect(controller.prompt.isInFileSubmode)
        #expect(controller.prompt.fileSubmode?.kind == .preview)

        // Verify in-document text search extracts and matches segments accurately
        let segments = FileInDocumentSearch.extractSearchableSegments(url: file)
        let matches = FileInDocumentSearch.matches(in: segments, query: "target")
        #expect(matches.count == 1)
        #expect(matches.first?.locationLabel == "Line 2")
    }

    @Test func fileURLRowResolvesFileIconInsteadOfGlobe() throws {
        let fm = FileManager.default
        let pdf = fm.temporaryDirectory.appendingPathComponent("EmployerDetails-\(UUID().uuidString).pdf")
        try Data("%PDF-1.4".utf8).write(to: pdf)
        defer { try? fm.removeItem(at: pdf) }

        let icon = CornerResultIcon.resolvedImage(url: pdf, fallback: nil)
        #expect(icon != nil)
        #expect(CornerResultIcon.fallbackSymbol(url: pdf, symbol: "doc") == "doc")
        #expect(CornerResultIcon.fallbackSymbol(url: URL(string: "https://example.com")!, symbol: "doc") == "globe")
    }

    @Test func fullFilePreviewLoaderLoadsMultiPagePDFAndTextInFull() throws {
        let fm = FileManager.default
        let pdfURL = fm.temporaryDirectory.appendingPathComponent("TwoPage-\(UUID().uuidString).pdf")
        let pdfDoc = PDFDocument()
        pdfDoc.insert(PDFPage(), at: 0)
        pdfDoc.insert(PDFPage(), at: 1)
        #expect(pdfDoc.write(to: pdfURL))
        defer { try? fm.removeItem(at: pdfURL) }

        let pdfLoaded = FullFilePreviewLoader.load(url: pdfURL)
        if case .pdf(_, let pages) = pdfLoaded {
            #expect(pages == 2)
        } else {
            Issue.record("Expected full PDF preview content")
        }
        #expect(pdfLoaded.detailRows.contains { $0.0 == "Pages" && $0.1 == "2" })

        let txtURL = fm.temporaryDirectory.appendingPathComponent("Notes-\(UUID().uuidString).txt")
        try Data("Line 1\nLine 2\nLine 3".utf8).write(to: txtURL)
        defer { try? fm.removeItem(at: txtURL) }

        let txtLoaded = FullFilePreviewLoader.load(url: txtURL)
        if case .plainText(let text, let isCode, let lines) = txtLoaded {
            #expect(text == "Line 1\nLine 2\nLine 3")
            #expect(!isCode)
            #expect(lines == 3)
        } else {
            Issue.record("Expected full plain-text preview content")
        }
    }

    @Test func directDocumentThumbnailRendersRealPDFPageImage() throws {
        let fm = FileManager.default
        let pdfURL = fm.temporaryDirectory.appendingPathComponent("RealDocIcon-\(UUID().uuidString).pdf")
        let pdfDoc = PDFDocument()
        pdfDoc.insert(PDFPage(), at: 0)
        #expect(pdfDoc.write(to: pdfURL))
        defer { try? fm.removeItem(at: pdfURL) }

        #expect(FileThumbnailCache.benefitsFromThumbnail(pdfURL.path))
        let thumb = FileThumbnailCache.renderDirectThumbnail(url: pdfURL, maxPixelSize: 128)
        #expect(thumb != nil)
        #expect((thumb?.size.width ?? 0) >= 16)
    }

    @Test func presentFullScreenOpensExpandedPreviewWindow() throws {
        let fm = FileManager.default
        let pdfURL = fm.temporaryDirectory.appendingPathComponent("FullScreenPreview-\(UUID().uuidString).pdf")
        let pdfDoc = PDFDocument()
        pdfDoc.insert(PDFPage(), at: 0)
        #expect(pdfDoc.write(to: pdfURL))
        defer {
            PreviewController.shared.close()
            try? fm.removeItem(at: pdfURL)
        }

        #expect(PreviewController.shared.presentFullScreen(url: pdfURL))
        #expect(PreviewController.shared.isOpen)
        #expect(PreviewController.shared.currentURL?.standardizedFileURL == pdfURL.standardizedFileURL)
    }
}
