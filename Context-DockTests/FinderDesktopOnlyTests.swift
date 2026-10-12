import Foundation
import Testing

@testable import Context_Dock

/// Finder showing the Desktop alone searches the user's files and folders, never Finder's
/// menu commands (owner 2026-10-12).
@MainActor
@Suite("Finder desktop only")
struct FinderDesktopOnlyTests {
    private let desktop = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Desktop", isDirectory: true)

    @Test func theDesktopAsFrontFolderIsDesktopOnly() {
        let model = AppChatPromptModel()
        model.finderFrontFolder = desktop
        #expect(model.finderShowsDesktopOnly)
    }

    @Test func aFinderWindowOnAnotherFolderIsNot() {
        let model = AppChatPromptModel()
        model.finderFrontFolder = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents", isDirectory: true)
        #expect(!model.finderShowsDesktopOnly)
        model.finderFrontFolder = nil
        #expect(!model.finderShowsDesktopOnly)
    }
}
