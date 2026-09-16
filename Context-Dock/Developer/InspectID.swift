import Foundation

struct InspectID: RawRepresentable, Hashable, Codable, Sendable {
    let rawValue: String

    init(rawValue: String) {
        self.rawValue = rawValue
    }

    static let generalChat = GeneralChatNamespace()
    static let contextDockChat = ContextDockChatNamespace()
    static let shared = SharedNamespace()

    static let allCases: [InspectID] = [
        generalChat.thread,
        generalChat.message,
        generalChat.assistantMessage,
        generalChat.userMessage,
        generalChat.toolCard,
        generalChat.toolTimeline,
        generalChat.input,
        generalChat.attachments,
        generalChat.providerPicker,
        generalChat.sidebar,
        generalChat.send,
        contextDockChat.thread,
        contextDockChat.input,
        contextDockChat.header,
        contextDockChat.actionRow,
        shared.messageBubble,
        shared.markdownBody,
        shared.codeBlock,
        shared.streamingCursor,
    ]

    struct GeneralChatNamespace: Sendable {
        let thread = InspectID(rawValue: "generalChat.thread")
        let message = InspectID(rawValue: "generalChat.message")
        let assistantMessage = InspectID(rawValue: "generalChat.message.assistant")
        let userMessage = InspectID(rawValue: "generalChat.message.user")
        let toolCard = InspectID(rawValue: "generalChat.toolCard")
        let toolTimeline = InspectID(rawValue: "generalChat.toolTimeline")
        let input = InspectID(rawValue: "generalChat.input")
        let attachments = InspectID(rawValue: "generalChat.attachments")
        let providerPicker = InspectID(rawValue: "generalChat.providerPicker")
        let sidebar = InspectID(rawValue: "generalChat.sidebar")
        let send = InspectID(rawValue: "generalChat.send")
    }

    struct ContextDockChatNamespace: Sendable {
        let thread = InspectID(rawValue: "contextDockChat.thread")
        let input = InspectID(rawValue: "contextDockChat.input")
        let header = InspectID(rawValue: "contextDockChat.header")
        let actionRow = InspectID(rawValue: "contextDockChat.actionRow")
    }

    struct SharedNamespace: Sendable {
        let messageBubble = InspectID(rawValue: "shared.messageBubble")
        let markdownBody = InspectID(rawValue: "shared.markdownBody")
        let codeBlock = InspectID(rawValue: "shared.codeBlock")
        let streamingCursor = InspectID(rawValue: "shared.streamingCursor")
    }
}
