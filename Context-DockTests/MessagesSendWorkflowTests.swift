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

    func testParseMessageIntentExactUserQuery() {
        let query = "to \"Gokula kannan J \" hey \"testing context-dock agent\""
        let parsed = MessagesAutomation.parseMessageIntent(from: query)
        XCTAssertNotNil(parsed, "Should parse exact user query syntax")
        XCTAssertEqual(parsed?.recipient, "Gokula kannan J")
        XCTAssertEqual(parsed?.body, "testing context-dock agent")
    }

    func testParseMessageIntentVariations() {
        // Curly quotes
        let q1 = "to “Gokula kannan J” hello there"
        let p1 = MessagesAutomation.parseMessageIntent(from: q1)
        XCTAssertEqual(p1?.recipient, "Gokula kannan J")
        XCTAssertEqual(p1?.body, "hello there")

        // Unquoted name with colon
        let q2 = "to Alex: I'm on my way"
        let p2 = MessagesAutomation.parseMessageIntent(from: q2)
        XCTAssertEqual(p2?.recipient, "Alex")
        XCTAssertEqual(p2?.body, "I'm on my way")

        // Verb: tell Mom
        let q3 = "tell Mom I will be late for dinner"
        let p3 = MessagesAutomation.parseMessageIntent(from: q3)
        XCTAssertEqual(p3?.recipient, "Mom")
        XCTAssertEqual(p3?.body, "I will be late for dinner")

        // Verb: text + phone
        let q4 = "text +15551234567 Hello Context-Dock"
        let p4 = MessagesAutomation.parseMessageIntent(from: q4)
        XCTAssertEqual(p4?.recipient, "+15551234567")
        XCTAssertEqual(p4?.body, "Hello Context-Dock")
    }

    func testIsActionRequestRecognizesMessageSendSyntax() {
        let query = "to \"Gokula kannan J \" hey \"testing context-dock agent\""
        XCTAssertTrue(ChatRouteResolver.isActionRequest(query), "Direct 'to' message syntax should be recognized as an action request")
        XCTAssertTrue(ChatRouteResolver.isActionRequest("tell Mom hello"))
        XCTAssertTrue(ChatRouteResolver.isActionRequest("text Alex I'm home"))
        XCTAssertFalse(ChatRouteResolver.isActionRequest("to whom did I send the email?"))
    }

    @MainActor
    func testMessagesAppPetDefaultModeIsAssist() {
        let manifest = AppPetManifestRegistry.messagesManifest
        XCTAssertEqual(manifest.defaultMode, "assist")
        let assistMode = manifest.modes.first { $0.id == "assist" }
        XCTAssertNotNil(assistMode)
        XCTAssertEqual(assistMode?.effectiveFilter, .allowAll)
    }

    @MainActor
    func testMessagesRoutingForSendIntentSelectsSendNotSearch() async {
        AppleMessagesMCPCapabilities.register(in: CapabilityRegistry.shared)
        let query = "to \"Gokula kannan J \" hey \"testing context-dock agent\""
        let routes = await ChatRouteResolver.routes(for: query, bundleId: "com.apple.MobileSMS", appName: "Messages")
        
        let hasSend = routes.contains { $0.payload == "messages.send" }
        let hasSearch = routes.contains { $0.payload == "messages.search" }
        
        XCTAssertTrue(hasSend, "Routes must include messages.send for direct send syntax")
        XCTAssertFalse(hasSearch, "Routes must NOT include messages.search for direct send syntax")
        
        let primary = ChatRouteResolver.clearPrimaryRoute(routes)
        XCTAssertEqual(primary?.payload, "messages.send", "Primary route must be messages.send")
    }
}
