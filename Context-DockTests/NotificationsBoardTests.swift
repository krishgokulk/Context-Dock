import Foundation
import Testing

@testable import Context_Dock

/// Notifications in the Corner's result board (issue #247, D9): a built-in Global Command
/// the field steps into, filtered by the field and walked with the arrows.
@MainActor
struct NotificationsBoardTests {
    private func usage(_ title: String, _ subtitle: String = "") -> SharedResultRowModel {
        SharedResultRowModel(id: "usage-\(title)", title: title, subtitle: subtitle, systemIcon: "gauge")
    }

    @Test func theBoardIsABuiltInCommand() {
        let command = SystemCommandsRegistry.defaults.first { $0.name == "Notifications" }
        #expect(command?.isNotificationsBoard == true)
        #expect(command?.behavesAsPanel == true)
        // Quick Note answers to its own provider, not this board.
        let note = SystemCommandsRegistry.defaults.first { $0.name == "Quick Note" }
        #expect(note?.provider == "notepad")
        #expect(note?.isNotificationsBoard == false)
    }

    @Test func notificationsLeadAndTheFieldFiltersBoth() {
        let build = ILauncherNotification(title: "Build finished", body: "Exit 0")
        let mail = ILauncherNotification(title: "AI reply", body: "Your mail summary")
        let all = NotificationsBoard.items(
            notifications: [build, mail], usage: [usage("Claude", "requests 4/50")], query: "")
        #expect(all.notifications.map(\.id) == [build.id.uuidString, mail.id.uuidString])
        #expect(all.usage.map(\.id) == ["usage-Claude"])

        let typed = NotificationsBoard.items(
            notifications: [build, mail], usage: [usage("Claude", "requests 4/50")],
            query: "  MAIL ")
        #expect(typed.notifications.map(\.id) == [mail.id.uuidString])
        #expect(typed.usage.isEmpty)
        // The usage line's subtitle matches too.
        #expect(NotificationsBoard.items(
            notifications: [], usage: [usage("Claude", "requests 4/50")], query: "requests"
        ).usage.count == 1)
    }

    @Test func theKeysWalkTheRowsAndHoldAtTheEnds() {
        let ids = ["a", "b", "c"]
        #expect(NotificationsBoard.moved(from: nil, in: ids, down: true) == "a")
        #expect(NotificationsBoard.moved(from: "a", in: ids, down: true) == "b")
        #expect(NotificationsBoard.moved(from: "c", in: ids, down: true) == "c")
        #expect(NotificationsBoard.moved(from: "a", in: ids, down: false) == "a")
        // Filtered away: back to the top.
        #expect(NotificationsBoard.moved(from: "gone", in: ids, down: true) == "a")
        #expect(NotificationsBoard.moved(from: "a", in: [], down: true) == nil)
    }
}
