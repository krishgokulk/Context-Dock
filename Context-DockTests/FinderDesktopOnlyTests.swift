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

    @Test func noFinderWindowOnScreenIsDesktopOnly() {
        let model = AppChatPromptModel()
        model.finderHasWindowOnScreen = { false }
        // Finder's own answer can name a window on another Space; the screen decides.
        model.finderFrontFolder = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Downloads", isDirectory: true)
        #expect(model.finderShowsDesktopOnly)
    }

    @Test func aFinderWindowOnScreenIsNot() {
        let model = AppChatPromptModel()
        model.finderHasWindowOnScreen = { true }
        model.finderFrontFolder = desktop
        #expect(!model.finderShowsDesktopOnly)
    }
}
