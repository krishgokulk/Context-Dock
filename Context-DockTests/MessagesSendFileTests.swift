import Testing
@testable import Context_Dock

struct MessagesSendFileTests {

    // MARK: - Capability Schema

    @Test @MainActor
    func messagesSendHasFilePathField() {
        let cap = CapabilityRegistry.shared.capability(id: "messages.send")
        #expect(cap != nil, "messages.send must be registered")
        let fields = cap!.inputSchema.fields
        #expect(fields.contains { $0.name == "filePath" && !$0.required },
                "messages.send must have an optional filePath field")
    }

    @Test @MainActor
    func messagesSendBodyIsOptional() {
        let cap = CapabilityRegistry.shared.capability(id: "messages.send")
        #expect(cap != nil)
        let bodyField = cap!.inputSchema.fields.first { $0.name == "body" }
        #expect(bodyField != nil, "body field must exist")
        #expect(!bodyField!.required, "body must be optional when filePath is provided")
    }

    @Test @MainActor
    func messagesSendRecipientIsRequired() {
        let cap = CapabilityRegistry.shared.capability(id: "messages.send")
        #expect(cap != nil)
        let recipientField = cap!.inputSchema.fields.first { $0.name == "recipient" }
        #expect(recipientField != nil)
        #expect(recipientField!.required, "recipient must remain required")
    }

    @Test @MainActor
    func messagesSendIsHighRisk() {
        let cap = CapabilityRegistry.shared.capability(id: "messages.send")
        #expect(cap != nil)
        #expect(cap!.riskLevel == .high, "messages.send must be high risk for the approval card")
    }

    // MARK: - Recipient Resolution with File

    @Test
    func resolveRecipientPhoneForFileSend() {
        let result = MessagesAutomation.resolveRecipient("+15559876543")
        if case .resolved(let contact) = result {
            #expect(contact.handle == "+15559876543")
        } else {
            Issue.record("Phone number must resolve for file sends")
        }
    }

    @Test
    func resolveRecipientEmailForFileSend() {
        let result = MessagesAutomation.resolveRecipient("test@example.com")
        if case .resolved(let contact) = result {
            #expect(contact.handle == "test@example.com")
        } else {
            Issue.record("Email must resolve for file sends")
        }
    }

    // MARK: - File Validation

    @Test
    func sendFileRejectsMissingFile() async {
        let res = await MessagesAutomation.sendFile(
            to: "+15551234567", filePath: "/nonexistent/file.png", body: nil)
        #expect(!res.success)
        #expect(res.message.contains("No file at"))
    }

    @Test
    func sendFileRejectsEmptyRecipient() async {
        let res = await MessagesAutomation.sendFile(to: "", filePath: "/tmp/test.png", body: nil)
        #expect(!res.success)
        #expect(res.message.contains("No recipient"))
    }

    // MARK: - OutboundGate Classification

    @Test @MainActor
    func messagesSendWithFileRequiresApproval() {
        let cap = CapabilityRegistry.shared.capability(id: "messages.send")
        #expect(cap != nil)
        #expect(cap!.riskLevel.requiresApproval,
                "messages.send with file must require approval before it runs")
    }
}
