import Foundation
import Testing
@testable import Context_Dock

@Suite("Messages delivery honesty")
struct MessagesDeliveryHonestyTests {

    // MARK: - DeliveryStatus notes

    @Test("Confirmed delivery note says delivery confirmed")
    func confirmedNote() {
        let note = MessagesChatDBReader.DeliveryStatus.confirmed.statusNote
        #expect(note.contains("confirmed"))
    }

    @Test("Unconfirmed delivery note does not claim sent")
    func unconfirmedNote() {
        let note = MessagesChatDBReader.DeliveryStatus.unconfirmed.statusNote
        #expect(note.contains("unconfirmed"))
        #expect(!note.lowercased().contains("sent"))
    }

    @Test("Access denied note mentions Full Disk Access")
    func accessDeniedNote() {
        let note = MessagesChatDBReader.DeliveryStatus.accessDenied.statusNote
        #expect(note.contains("Full Disk Access"))
        #expect(note.contains("unconfirmed"))
    }

    @Test("Failed delivery note says delivery failed")
    func failedNote() {
        let note = MessagesChatDBReader.DeliveryStatus.failed.statusNote
        #expect(note.contains("failed"))
    }

    // MARK: - checkDelivery returns accessDenied when chat.db is unreadable

    @Test("checkDelivery returns accessDenied when chat.db path is not readable")
    func checkDeliveryAccessDenied() {
        // chat.db is not readable in the test sandbox: isAccessible will be false.
        // We test that the function returns .accessDenied rather than crashing or
        // returning .unconfirmed when the DB is absent.
        guard !MessagesChatDBReader.isAccessible else { return }
        let status = MessagesChatDBReader.checkDelivery(to: "+15551234567", textSnippet: "hello")
        #expect(status == .accessDenied)
    }

    // MARK: - ChatResultRow.MessageSentState mapping

    @Test("ChatResultRow.MessageSentState has three cases")
    func chatResultRowStates() {
        let states: [ChatResultRow.MessageSentState] = [.sent, .unconfirmed, .failed]
        #expect(states.count == 3)
    }

    @Test("MessageSentState unconfirmed maps to MessageSentAction.State.unconfirmed")
    func stateMapping() {
        var row = ChatResultRow(
            kind: .message, id: "+15550000001", title: "Test User",
            subtitle: "", detail: "", bundleID: "com.apple.MobileSMS")
        row.messageSentState = .unconfirmed

        let mapped = ChatResultRowMapper.map([row])
        #expect(mapped.messages.count == 1)
        #expect(mapped.messages[0].state == .unconfirmed)
    }

    @Test("MessageSentState sent maps to MessageSentAction.State.sent")
    func sentStateMapping() {
        var row = ChatResultRow(
            kind: .message, id: "+15550000002", title: "Test User",
            subtitle: "", detail: "", bundleID: "com.apple.MobileSMS")
        row.messageSentState = .sent

        let mapped = ChatResultRowMapper.map([row])
        #expect(mapped.messages.count == 1)
        #expect(mapped.messages[0].state == .sent)
    }

    @Test("MessageSentState failed maps to MessageSentAction.State.failed")
    func failedStateMapping() {
        var row = ChatResultRow(
            kind: .message, id: "+15550000003", title: "Test User",
            subtitle: "", detail: "", bundleID: "com.apple.MobileSMS")
        row.messageSentState = .failed

        let mapped = ChatResultRowMapper.map([row])
        #expect(mapped.messages.count == 1)
        #expect(mapped.messages[0].state == .failed)
    }
}
