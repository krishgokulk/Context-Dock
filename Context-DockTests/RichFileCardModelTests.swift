import Testing
import Foundation
@testable import Context_Dock

@Suite struct RichFileCardModelTests {
    private func model(
        path: String = "/Users/me/Documents/report.pdf",
        app: String? = "Preview",
        bytes: Int64? = 1_500_000,
        modified: Date? = Date(timeIntervalSince1970: 1_794_000_000),
        exists: Bool = true
    ) -> RichFileCardModel {
        RichFileCardModel(url: URL(fileURLWithPath: path), defaultAppName: app, byteCount: bytes,
                          modified: modified, homeDirectory: "/Users/me", exists: exists)
    }

    @Test func labelNamesDefaultApp() {
        #expect(model().openLabel == "Open in Preview")
    }

    @Test func labelFallsBackToOpenWithoutDefaultApp() {
        #expect(model(app: nil).openLabel == "Open")
        #expect(model(app: "").openLabel == "Open")
    }

    @Test func folderShortensHomeToTilde() {
        #expect(model().folderDisplay == "~/Documents")
        #expect(model(path: "/Users/me/a.txt").folderDisplay == "~")
        #expect(model(path: "/Users/mentor/a.txt").folderDisplay == "/Users/mentor")
        #expect(model(path: "/tmp/a.txt").folderDisplay == "/tmp")
    }

    @Test func sizeAndDateFormatting() {
        let m = model()
        #expect(m.sizeDisplay == ByteCountFormatter.string(fromByteCount: 1_500_000, countStyle: .file))
        #expect(m.dateDisplay?.contains("2026") == true)
        #expect(model(bytes: nil, modified: nil).metadataLine == "~/Documents")
    }

    @Test func missingFileSaysSo() {
        #expect(model(exists: false).metadataLine == "~/Documents · File not found")
    }
}
