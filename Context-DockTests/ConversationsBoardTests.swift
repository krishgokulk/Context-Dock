// ConversationsBoardTests.swift
// Context-DockTests
//
// Unit tests for Task UI/UX 4/5 (#334): Conversations board (browse past conversations).

import Foundation
import Testing

@testable import Context_Dock

@Suite("Conversations Board (#334)", .serialized)
@MainActor
struct ConversationsBoardTests {

    @Test("Relative date formatting")
    func relativeDateFormatting() {
        let now = Date()
        #expect(ConversationsBoard.relativeDateString(for: now) == "just now")

        let tenMinsAgo = now.addingTimeInterval(-600)
        #expect(ConversationsBoard.relativeDateString(for: tenMinsAgo) == "10m ago")

        let threeHoursAgo = now.addingTimeInterval(-10800)
        #expect(ConversationsBoard.relativeDateString(for: threeHoursAgo) == "3h ago")

        let yesterday = now.addingTimeInterval(-90000)
        #expect(ConversationsBoard.relativeDateString(for: yesterday) == "yesterday")
    }

    @Test("ConversationsBoardItem mapping and scope labels")
    func itemMapping() {
        let appSession = GeneralChatSession(
            scope: .app(bundleId: "com.apple.Safari"),
            title: "Safari",
            createdAt: Date(),
            updatedAt: Date(),
            messageCount: 5
        )
        let generalSession = GeneralChatSession(
            scope: .general,
            title: "General Chat",
            createdAt: Date(),
            updatedAt: Date(),
            messageCount: 12
        )
        let combinedSession = GeneralChatSession(
            scope: .thread(id: "combined-safari-notes"),
            title: "Safari + Notes",
            createdAt: Date(),
            updatedAt: Date(),
            messageCount: 8
        )

        let items = ConversationsBoard.items(
            sessions: [appSession, generalSession, combinedSession],
            query: "",
            filter: .all
        )

        #expect(items.count == 3)

        let appItem = items.first { $0.session.scope == appSession.scope }
        #expect(appItem?.scopeLabel == "App Pet")
        #expect(appItem?.session.title == "Safari")

        let genItem = items.first { $0.session.scope == generalSession.scope }
        #expect(genItem?.scopeLabel == "General Chat")

        let combItem = items.first { $0.session.scope == combinedSession.scope }
        #expect(combItem?.scopeLabel == "Combined Chat")
    }

    @Test("Scope filter tabs: All, App Pets, and General & Combined")
    func scopeFiltering() {
        let appSession = GeneralChatSession(
            scope: .app(bundleId: "com.apple.TextEdit"),
            title: "TextEdit",
            createdAt: Date(),
            updatedAt: Date(),
            messageCount: 3
        )
        let cliSession = GeneralChatSession(
            scope: .cli(command: "git"),
            title: "git",
            createdAt: Date(),
            updatedAt: Date(),
            messageCount: 4
        )
        let generalSession = GeneralChatSession(
            scope: .general,
            title: "General",
            createdAt: Date(),
            updatedAt: Date(),
            messageCount: 6
        )
        let combinedSession = GeneralChatSession(
            scope: .thread(id: "combined-123"),
            title: "Project Alpha",
            createdAt: Date(),
            updatedAt: Date(),
            messageCount: 9
        )

        let allSessions = [appSession, cliSession, generalSession, combinedSession]

        let allItems = ConversationsBoard.items(sessions: allSessions, query: "", filter: .all)
        #expect(allItems.count == 4)

        let appPetItems = ConversationsBoard.items(sessions: allSessions, query: "", filter: .appPets)
        #expect(appPetItems.count == 2)
        #expect(appPetItems.contains { $0.session.scope == appSession.scope })
        #expect(appPetItems.contains { $0.session.scope == cliSession.scope })

        let genCombItems = ConversationsBoard.items(sessions: allSessions, query: "", filter: .generalCombined)
        #expect(genCombItems.count == 2)
        #expect(genCombItems.contains { $0.session.scope == generalSession.scope })
        #expect(genCombItems.contains { $0.session.scope == combinedSession.scope })
    }

    @Test("Search query filtering within conversation history")
    func searchFiltering() {
        let safariSession = GeneralChatSession(
            scope: .app(bundleId: "com.apple.Safari"),
            title: "Safari Browser",
            createdAt: Date(),
            updatedAt: Date(),
            messageCount: 2
        )
        let notesSession = GeneralChatSession(
            scope: .app(bundleId: "com.apple.Notes"),
            title: "Meeting Notes",
            createdAt: Date(),
            updatedAt: Date(),
            messageCount: 4
        )
        let generalSession = GeneralChatSession(
            scope: .general,
            title: "Trip to Kyoto",
            createdAt: Date(),
            updatedAt: Date(),
            messageCount: 7
        )

        let sessions = [safariSession, notesSession, generalSession]

        // Query matching title
        let kyotoResults = ConversationsBoard.items(sessions: sessions, query: "Kyoto", filter: .all)
        #expect(kyotoResults.count == 1)
        #expect(kyotoResults.first?.session.title == "Trip to Kyoto")

        // Query matching app bundle ID
        let safariResults = ConversationsBoard.items(sessions: sessions, query: "safari", filter: .all)
        #expect(safariResults.count == 1)
        #expect(safariResults.first?.session.title == "Safari Browser")

        // Query with no matches
        let emptyResults = ConversationsBoard.items(sessions: sessions, query: "nonexistent", filter: .all)
        #expect(emptyResults.isEmpty)
    }

    @Test("Keyboard navigation and DockKeyMap shortcut registration")
    func keyboardAndKeyMap() {
        let ids = ["chat-1", "chat-2", "chat-3"]

        // Moving down from first item
        let next = ConversationsBoard.moved(from: "chat-1", in: ids, down: true)
        #expect(next == "chat-2")

        // Clamping at end
        let end = ConversationsBoard.moved(from: "chat-3", in: ids, down: true)
        #expect(end == "chat-3")

        // Moving up from middle
        let prev = ConversationsBoard.moved(from: "chat-2", in: ids, down: false)
        #expect(prev == "chat-1")

        // Clamping at beginning
        let start = ConversationsBoard.moved(from: "chat-1", in: ids, down: false)
        #expect(start == "chat-1")

        // Pre-seeded system command
        let cmd = SystemCommandsRegistry.shared.commands.first { $0.isConversationsBoard }
        #expect(cmd != nil)
        #expect(cmd?.provider == "conversations")

        // DockKeyMap registration
        let allBindings = DockKeyMap.allBindings()
        let convBinding = allBindings.first { $0.id == "chat.conversationsBoard" }
        #expect(convBinding != nil)
        #expect(convBinding?.surface == .chatAndClipboard)
        #expect(convBinding?.keys == ["⌥", "H"])
    }
}
