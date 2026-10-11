import Foundation
import Testing

@testable import Context_Dock

/// Finder in front lists the folder its front window shows — the Desktop when no window is
/// open, Finder's desktop-only mode included (owner 2026-10-08).
struct FinderFrontFolderTests {
    @Test func aWindowsFolderIsItsPath() {
        #expect(FinderFrontFolder.folder(fromScriptOutput: "/Users/me/Documents/\n")?.path
            == "/Users/me/Documents")
    }

    @Test func noWindowIsTheDesktop() {
        #expect(FinderFrontFolder.folder(fromScriptOutput: "  \n") == FinderFrontFolder.desktop)
    }
}
