import Foundation
import Testing
@testable import Context_Dock

struct AIOrchestrationScopeTests {
    @Test func contextDockAllowsItsOwnBundle() throws {
        try CapabilityAuthorizationGate.validateTarget(
            bundleID: "com.apple.Safari",
            scope: .contextDock(bundleID: "com.apple.Safari", appName: "Safari"))
    }

    @Test func contextDockRejectsAnotherBundle() {
        #expect(throws: CapabilityAuthorizationError.self) {
            try CapabilityAuthorizationGate.validateTarget(
                bundleID: "com.apple.mail",
                scope: .contextDock(bundleID: "com.apple.Safari", appName: "Safari"))
        }
    }

    @Test func systemWideAssistantAllowsNamedApp() throws {
        try CapabilityAuthorizationGate.validateTarget(
            bundleID: "com.apple.mail", scope: .general)
    }

    @Test func selectionRejectsAnyAppTarget() {
        let selection = AISelectionSnapshot(text: "hello", files: [], pageURL: nil)
        #expect(throws: CapabilityAuthorizationError.self) {
            try CapabilityAuthorizationGate.validateTarget(
                bundleID: "com.apple.mail",
                scope: .selection(selection))
        }
    }

    @Test func selectionRejectsTerminalPlan() {
        let selection = AISelectionSnapshot(text: "hello", files: [], pageURL: nil)
        let plan = AIActionPlan(
            capability: "terminal.runCommand",
            input: ["command": "ls", "purpose": "List files"],
            explanation: "test")
        #expect(throws: CapabilityAuthorizationError.self) {
            try CapabilityAuthorizationGate.validatePlan(plan, scope: .selection(selection))
        }
    }

    @Test func selectionAllowsShareInvocationOnly() throws {
        let selection = AISelectionSnapshot(text: "hello", files: [], pageURL: nil)
        let share = AITypedInvocation(
            kind: .share,
            capabilityID: "system.share",
            arguments: ["destination": "Mail", "text": "hello"],
            requiresApproval: true)
        try CapabilityAuthorizationGate.validateInvocation(share, scope: .selection(selection))

        let mcp = AITypedInvocation(
            kind: .mcp,
            capabilityID: "search_items",
            arguments: ["bundleId": "com.apple.Notes", "server": "notes"],
            requiresApproval: false)
        #expect(throws: CapabilityAuthorizationError.self) {
            try CapabilityAuthorizationGate.validateInvocation(mcp, scope: .selection(selection))
        }
    }

    @Test func contextDockRejectsCrossAppTypedInvocation() {
        let invocation = AITypedInvocation(
            kind: .mcp,
            capabilityID: "search_items",
            arguments: ["bundleId": "com.apple.mail", "server": "mail"],
            requiresApproval: false)
        #expect(throws: CapabilityAuthorizationError.self) {
            try CapabilityAuthorizationGate.validateInvocation(
                invocation,
                scope: .contextDock(bundleID: "com.apple.Safari", appName: "Safari"))
        }
    }

    @Test func typedResolverParsesFencedMCPDirective() throws {
        let text = """
        ```json
        {"mcp_call":{"app":"com.apple.Notes","server":"notes","tool":"search_items","arguments":{"query":"todo"}}}
        ```
        """
        let invocation = try #require(AITypedInvocationResolver.invocation(from: text))
        #expect(invocation.kind == .mcp)
        #expect(invocation.capabilityID == "search_items")
        #expect(invocation.arguments["bundleId"] == "com.apple.Notes")
        #expect(invocation.requiresApproval == false)
    }

    @Test func typedResolverParsesTerminalAsRegisteredCapability() throws {
        let invocation = try #require(AITypedInvocationResolver.invocation(from:
            #"{"terminal_call":{"command":"pwd","purpose":"Check directory"}}"#))
        #expect(invocation.kind == .terminal)
        #expect(invocation.capabilityID == "terminal.runCommand")
        #expect(invocation.requiresApproval)
    }

    @Test func mcpReadClassifierAllowsQueries() {
        #expect(MCPToolSafety.isClearlyReadOnly(name: "search_items"))
        #expect(MCPToolSafety.isClearlyReadOnly(name: "get_status"))
        #expect(MCPToolSafety.isClearlyReadOnly(name: "list_recent_chats"))
    }

    @Test func mcpReadClassifierBlocksMutationAndAmbiguity() {
        #expect(!MCPToolSafety.isClearlyReadOnly(name: "create_note"))
        #expect(!MCPToolSafety.isClearlyReadOnly(name: "get_or_create_item"))
        #expect(!MCPToolSafety.isClearlyReadOnly(name: "delete_message"))
        #expect(!MCPToolSafety.isClearlyReadOnly(name: "do_thing"))
    }
}
