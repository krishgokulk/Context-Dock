import Foundation
import Testing

@testable import Context_Dock

/// The row the same words were answered with before leads (S5).
@MainActor
@Suite("Global pick memory")
struct GlobalPickMemoryTests {
    private func menu(_ title: String, app: String) -> AppChatRow {
        var pill = DockPill(id: "\(app)-\(title)", name: title, icon: "app", badge: nil, execute: {})
        pill.rankingKind = "menu"
        pill.sourceAppName = app
        return .dock(pill)
    }

    private let now = Date()

    @Test func aPickLeadsTheSameWordsAndTheirStart() {
        let memory = GlobalPickMemory(file: nil)
        let rows = [menu("Show Personal History", app: "Safari"), menu("History", app: "Chrome")]
        #expect(memory.favourite(in: rows, query: "history", now: now) == nil)
        memory.record(query: "History", row: rows[1], now: now)
        #expect(memory.favourite(in: rows, query: "history", now: now)?.id == rows[1].id)
        #expect(memory.favourite(in: rows, query: "his", now: now)?.id == rows[1].id)
        #expect(memory.favourite(in: rows, query: "hi", now: now) == nil)
        #expect(GlobalPickMemory.queryKeys("hi") == ["hi"] && GlobalPickMemory.queryKeys("h").isEmpty)
        #expect(memory.favourite(in: rows, query: "safari", now: now) == nil)
    }

    @Test func theMostTakenAndRecentWins() {
        let memory = GlobalPickMemory(file: nil)
        let a = menu("New Window", app: "Safari"), b = menu("New Window", app: "Chrome")
        let old = now.addingTimeInterval(-60 * 86_400)
        for _ in 0..<3 { memory.record(query: "new window", row: a, now: old) }
        memory.record(query: "new window", row: b, now: now)
        // Three picks two months ago weigh less than one today.
        #expect(memory.favourite(in: [a, b], query: "new window", now: now)?.id == b.id)
    }

    @Test func aDestructiveRowLeadsOnlyWhenItsVerbIsTyped() {
        let memory = GlobalPickMemory(file: nil)
        let clear = menu("Clear History…", app: "Safari")
        memory.record(query: "history", row: clear, now: now)
        #expect(memory.favourite(in: [clear], query: "history", now: now) == nil)
        memory.record(query: "clear history", row: clear, now: now)
        #expect(memory.favourite(in: [clear], query: "clear history", now: now)?.id == clear.id)
    }

    @Test func controlsAreNeverLearned() {
        let memory = GlobalPickMemory(file: nil)
        let ask = GlobalFallbacks.rows(for: "history") { _ in }.map(AppChatRow.dock)[0]
        memory.record(query: "history", row: ask, now: now)
        #expect(memory.picks.isEmpty)
    }

    @Test func picksSurviveARelaunch() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("picks-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let row = menu("Show Personal History", app: "Safari")
        let picks = ["history": [GlobalPickMemory.rowKey(row, scope: "global"): GlobalPickMemory.Pick(count: 2, last: now)]]
        try JSONEncoder().encode(picks).write(to: file)
        #expect(GlobalPickMemory(file: file).favourite(in: [row], query: "history", scope: "global", now: now)?.id == row.id)
    }

    /// One app's pick never reorders another app's list, even for an action two adapters
    /// share an id with.
    @Test func aPickBelongsToTheScopeItWasMadeIn() {
        let memory = GlobalPickMemory(file: nil)
        let assist = menu("Assist", app: "")
        memory.record(query: "assist", row: assist, scope: "com.apple.Notes", now: now)
        #expect(memory.favourite(in: [assist], query: "assist", scope: "com.apple.Notes", now: now)?.id == assist.id)
        #expect(memory.favourite(in: [assist], query: "assist", scope: "com.apple.Mail", now: now) == nil)
    }

    @Test func singleIncidentalMenuPickDoesNotOverridePrefixCommand() {
        let memory = GlobalPickMemory(file: nil)
        let incidentalMenu = menu("Preventing Sleep", app: "Activity Monitor")
        let randomFile = AppChatRow.file(URL(fileURLWithPath: "/tmp/sleep"))
        var sleepPill = DockPill(
            id: "dorax-v3-global-system-utilities::sleep-mac",
            name: "Sleep Mac", icon: "powersleep", badge: "System & Hardware", execute: {})
        sleepPill.rankingKind = "doraxPackV3"
        sleepPill.resultSection = "System & Hardware"
        let sleepCommand = AppChatRow.dock(sleepPill)

        #expect(GlobalQuery.topHit([incidentalMenu, sleepCommand, randomFile], query: "sleep")?.id == sleepCommand.id)

        memory.record(query: "sleep", row: incidentalMenu, scope: "global", now: now)
        let preferredOnce = memory.preferredTopHit(
            in: [incidentalMenu, sleepCommand, randomFile],
            fallback: GlobalQuery.topHit([incidentalMenu, sleepCommand, randomFile], query: "sleep"),
            query: "sleep",
            scope: "global",
            now: now)
        #expect(preferredOnce?.id == sleepCommand.id)

        // Repeatedly choosing the menu item earns Top Hit override.
        memory.record(query: "sleep", row: incidentalMenu, scope: "global", now: now)
        let preferredTwice = memory.preferredTopHit(
            in: [incidentalMenu, sleepCommand],
            fallback: sleepCommand,
            query: "sleep",
            scope: "global",
            now: now)
        #expect(preferredTwice?.id == incidentalMenu.id)
    }

    @Test func exactApplicationMatchBeatsSingleNonExactPick() {
        let memory = GlobalPickMemory(file: nil)
        var chatsPill = DockPill(
            id: "dorax-v3-global-messages::recent-chats",
            name: "Messages Chats", icon: "bubble.left.and.bubble.right", badge: "Messages", execute: {})
        chatsPill.rankingKind = "doraxPackV3"
        let chatsRow = AppChatRow.dock(chatsPill)

        var appPill = DockPill(
            id: "global-app-messages", name: "Messages", icon: "app", badge: "Application", execute: {})
        appPill.rankingKind = "application"
        appPill.resultSection = GlobalResultSection.applications
        let appRow = AppChatRow.dock(appPill)

        memory.record(query: "messages", row: chatsRow, scope: "global", now: now)
        let preferred = memory.preferredTopHit(
            in: [chatsRow, appRow],
            fallback: GlobalQuery.topHit([chatsRow, appRow], query: "messages"),
            query: "messages",
            scope: "global",
            now: now)
        #expect(preferred?.id == appRow.id)
    }
}
