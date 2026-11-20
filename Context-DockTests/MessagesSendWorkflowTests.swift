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
    func testSendAndComposeMessageToolsAreRetired() {
        XCTAssertNil(
            AgentToolRegistry.shared.tool(named: "send_message"),
            "send_message tool was retired into messages.send capability")
        XCTAssertNil(
            AgentToolRegistry.shared.tool(named: "compose_message"),
            "compose_message tool was retired into messages.compose capability")
    }

    @MainActor
    func testMessagesSendCapabilityIsRegistered() {
        AppleMessagesMCPCapabilities.register(in: CapabilityRegistry.shared)
        let cap = CapabilityRegistry.shared.capability(id: "messages.send")
        XCTAssertNotNil(cap, "messages.send capability should be registered in CapabilityRegistry")
        XCTAssertEqual(cap?.appBundleID, "com.apple.MobileSMS")
        XCTAssertEqual(cap?.riskLevel, .high)
        XCTAssertEqual(cap?.runsWithoutAdapter, true)
    }
}
