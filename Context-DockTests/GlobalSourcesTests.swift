import Foundation
import Testing

@testable import Context_Dock

/// The clipboard, quick notes and DoraX's notifications answer in Global Context (S4).
@Suite("Global sources")
struct GlobalSourcesTests {
    private let now = Date()
    private var clips: [DockCore.ClipboardEntry] {
        [
            .init(text: "https://github.com/fmhy/FMHY", timestamp: now, sourceAppName: "Safari"),
            .init(text: "", timestamp: now, filePaths: ["/Users/me/Desktop/report.pdf"]),
            .init(text: "lunch at noon", timestamp: now),
        ]
    }
    private var notes: [QuickNote] { [QuickNote(text: "Ideas for github README\nsecond line")] }
    private var sent: [ILauncherNotification] {
        [ILauncherNotification(title: "Build finished", body: "github actions passed")]
    }

    private func rows(_ query: String) -> [AppChatRow] {
        GlobalSources.rows(
            query: query, clips: clips, notes: notes, notifications: sent, now: now,
            copy: { _ in }, openNote: { _ in }, openNotification: { _ in })
    }

    @Test func everySourceAnswersItsWords() {
        let titles = rows("github").map(\.title)
        #expect(titles == ["https://github.com/fmhy/FMHY", "Ideas for github README", "Build finished"])
        #expect(rows("report").map(\.title) == ["report.pdf"])
    }

    @Test func aSourceNameAloneListsItsNewest() {
        #expect(rows("clipboard").count == 3)
        #expect(rows("notes").map(\.title) == ["Ideas for github README"])
        #expect(rows("zz").isEmpty)
        #expect(rows("g").isEmpty)
    }

    @Test func eachSourceHasItsSectionAndFoot() {
        let found = rows("github")
        #expect(found.map(GlobalResultSection.title(for:)) == [GlobalSources.clipboard, GlobalSources.notes, GlobalSources.notifications])
        let feet = found.map {
            BoardFoot.foot(for: $0, scopeName: "Global", scopeBundleID: "", isGlobal: true)
        }
        #expect(feet.map(\.verb) == ["Copy", "Open", "Open"])
        #expect(feet.map(\.kind) == ["Clipboard", "Quick note", "Notification"])
    }

    @Test func aSourceNameKeepsItsRowsThroughTheQueryReading() {
        let (safe, _) = GlobalQuery.split(rows("clipboard"), query: "clipboard")
        #expect(safe.count == 3)
    }
}
