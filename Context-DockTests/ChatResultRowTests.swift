import Foundation
import Testing

@testable import Context_Dock

// Rows travelling from the capability that read them to the card a surface draws.
//
// The behaviour being protected: a Notes question answered in the dock, in General Chat and in
// the chat window produces the same cards, because all three read the same rows through the
// same mapper. Before this, note rows existed at two hardcoded sites inside the dock's Notes
// branch and every other surface showed prose.

@MainActor
struct ChatResultRowTests {

    private var collector: ChatResultRowCollector { .shared }

    private func note(_ id: String, title: String = "Note") -> ChatResultRow {
        ChatResultRow(
            kind: .note, id: id, title: title, subtitle: "Notes — iCloud",
            detail: "snippet", bundleID: "com.apple.Notes", date: Date(timeIntervalSince1970: 0))
    }

    @Test func rowsAreTakenOnceAndTheTurnIsThenEmpty() {
        let scope = GeneralChatScope.app(bundleId: "com.apple.Notes")
        collector.begin(scope: scope)
        collector.add([note("a"), note("b")], scope: scope)

        #expect(collector.take(scope: scope).count == 2)
        // Taken means gone: the same rows appearing under the next answer would read as a
        // fresh result when nothing had been read at all.
        #expect(collector.take(scope: scope).isEmpty)
    }

    @Test func beginDropsWhatTheLastTurnLeft() {
        let scope = GeneralChatScope.app(bundleId: "com.apple.Notes")
        collector.begin(scope: scope)
        collector.add([note("a")], scope: scope)
        collector.begin(scope: scope)
        #expect(collector.take(scope: scope).isEmpty)
    }

    @Test func oneConversationsRowsNeverAppearInAnother() {
        // The dock's Notes chat and the chat window can be answering at the same time.
        let notes = GeneralChatScope.app(bundleId: "com.apple.Notes")
        let general = GeneralChatScope.general
        collector.begin(scope: notes)
        collector.begin(scope: general)
        collector.add([note("a")], scope: notes)

        #expect(collector.take(scope: general).isEmpty)
        #expect(collector.take(scope: notes).count == 1)
    }

    @Test func theSameRecordTwiceIsOneRow() {
        // A capability called twice in one turn — search, then a narrower search — must not
        // draw the same note twice.
        let scope = GeneralChatScope.general
        collector.begin(scope: scope)
        collector.add([note("a")], scope: scope)
        collector.add([note("a"), note("b")], scope: scope)
        #expect(collector.take(scope: scope).count == 2)
    }

    @Test func aListingIsNotACardStack() {
        // Past a couple of dozen rows the answer text is the right medium; the cards become
        // the transcript.
        let scope = GeneralChatScope.general
        collector.begin(scope: scope)
        collector.add((0..<100).map { note("n\($0)") }, scope: scope)
        #expect(collector.take(scope: scope).count <= 24)
    }

    @Test func filesArriveAsRowsWithTheirFolder() {
        let scope = GeneralChatScope.general
        collector.begin(scope: scope)
        collector.addFiles(
            [URL(fileURLWithPath: "/Users/someone/Documents/report.pdf")], scope: scope)

        let rows = collector.take(scope: scope)
        #expect(rows.first?.kind == .file)
        #expect(rows.first?.title == "report.pdf")
        #expect(rows.first?.subtitle == "/Users/someone/Documents")
    }

    @Test func eachKindLandsOnTheFieldItsCardIsDrawnFrom() {
        let mapped = ChatResultRowMapper.map([
            note("note-1", title: "Project ideas"),
            ChatResultRow(
                kind: .file, id: "/tmp/a.pdf", title: "a.pdf", subtitle: "/tmp",
                url: URL(fileURLWithPath: "/tmp/a.pdf")),
            ChatResultRow(
                kind: .link, id: "https://example.com", title: "Example",
                subtitle: "Example page", url: URL(string: "https://example.com")),
            ChatResultRow(
                kind: .app, id: "com.apple.Notes", title: "Notes",
                bundleID: "com.apple.Notes"),
        ])

        #expect(mapped.notes.first?.title == "Project ideas")
        #expect(mapped.notes.first?.folder == "Notes — iCloud")
        #expect(mapped.files.first?.name == "a.pdf")
        #expect(mapped.links.first?.url == "https://example.com")
        #expect(mapped.apps.first?.bundleId == "com.apple.Notes")
    }

    @Test func aRowWithNowhereToPointIsDropped() {
        // A file or link row without a URL has no action behind it, and a card that does
        // nothing when clicked is worse than no card.
        let mapped = ChatResultRowMapper.map([
            ChatResultRow(kind: .file, id: "x", title: "x"),
            ChatResultRow(kind: .link, id: "y", title: "y"),
        ])
        #expect(mapped.isEmpty)
    }
}
