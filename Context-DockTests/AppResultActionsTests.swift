import Foundation
import Testing

@testable import Context_Dock

/// ⇧↩ on a closed app's card hands it the Finder selection — only a file it opens.
@Suite("App result actions")
struct AppResultActionsTests {
    @Test func picksTheFirstSelectedFileTheAppOpens() {
        let file = AppResultActions.openableFile(
            selection: ["/tmp/notes.txt", "/tmp/report.pdf", "/tmp/b.pdf"],
            canOpen: { $0.pathExtension == "pdf" })
        #expect(file?.lastPathComponent == "report.pdf")
    }

    @Test func nothingWhenNoSelectedFileOpensInTheApp() {
        #expect(
            AppResultActions.openableFile(selection: ["/tmp/a.txt"], canOpen: { _ in false })
                == nil)
        #expect(AppResultActions.openableFile(selection: [], canOpen: { _ in true }) == nil)
    }
}
