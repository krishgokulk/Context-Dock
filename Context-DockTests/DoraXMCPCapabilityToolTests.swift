import Foundation
import Testing

@testable import Context_Dock

/// A CLI scoped to an app chat reaches that app's capabilities as MCP tools, instead of
/// hand-writing osascript for `mail.search`.
@MainActor
@Suite("DoraX MCP capability tools")
struct DoraXMCPCapabilityToolTests {
    @Test func theToolListOffersRunAndListCapabilities() {
        let names = DoraXMCPServer.toolDefinitions(attended: false).compactMap { $0["name"] as? String }
        #expect(names.contains("dorax_run_capability"))
        #expect(names.contains("dorax_list_capabilities"))
    }

    @Test func thePromptNamesTheScopedAppsCapabilitiesAheadOfTheShell() {
        let block = CapabilityRegistry.shared.cliPromptBlock(
            for: "com.apple.mail", appName: "Mail")
        #expect(block.contains("mail.search"))
        #expect(block.contains("dorax_run_capability"))
        #expect(block.contains("BEFORE any shell"))
    }

    @Test func anAppWithNoCapabilitiesAddsNothingToThePrompt() {
        #expect(
            CapabilityRegistry.shared.cliPromptBlock(for: "com.example.none", appName: "None")
                .isEmpty
                == CapabilityRegistry.shared.capabilities(for: "com.example.none").isEmpty)
    }

    @Test func anUnknownIdIsRefusedNotRun() async {
        let server = DoraXMCPServer.shared
        server.capabilityTurn = .init(scope: .app(bundleId: "com.apple.mail"))
        defer { server.capabilityTurn = nil }
        let reply = await server.callTool(
            named: "dorax_run_capability", arguments: ["capability_id": "mail.nope"], attended: true)
        #expect(reply.hasPrefix("Did not run"))
    }

    @Test func aCapabilityOfAnotherAppIsOutOfScope() async {
        let server = DoraXMCPServer.shared
        server.capabilityTurn = .init(scope: .app(bundleId: "com.apple.mail"))
        defer { server.capabilityTurn = nil }
        let reply = await server.callTool(
            named: "dorax_run_capability", arguments: ["capability_id": "notes.search"], attended: true)
        #expect(reply.hasPrefix("Did not run"))
    }
}
