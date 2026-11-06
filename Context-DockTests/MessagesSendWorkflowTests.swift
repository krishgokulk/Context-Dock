import XCTest
@testable import Context_Dock

final class MessagesSendWorkflowTests: XCTestCase {

    func testResolveRecipientDirectPhoneNumber() {
        let result = MessagesAutomation.resolveRecipient("+15551234567")
        if case .resolved(let contact) = result {
            XCTAssertEqual(contact.handle, "+15551234567")
        } else {
            XCTFail("Expected direct phone number to resolve immediately")
        }
    }

    func testResolveRecipientEmail() {
        let result = MessagesAutomation.resolveRecipient("alex@example.com")
        if case .resolved(let contact) = result {
            XCTAssertEqual(contact.handle, "alex@example.com")
        } else {
            XCTFail("Expected email to resolve immediately")
        }
    }

    @MainActor
    func testSendMessageToolIsRegistered() {
        let tool = AgentToolRegistry.shared.tool(named: "send_message")
        XCTAssertNotNil(tool, "send_message tool should be registered in AgentToolRegistry")
        XCTAssertEqual(tool?.required, ["recipient", "body"])
    }

    @MainActor
    func testMessagesSendCapabilityIsRegistered() {
        let cap = CapabilityRegistry.shared.capability(id: "messages.send")
        XCTAssertNotNil(cap, "messages.send capability should be registered in CapabilityRegistry")
        XCTAssertEqual(cap?.appBundleID, "com.apple.MobileSMS")
        XCTAssertEqual(cap?.riskLevel, .high)
    }
}
