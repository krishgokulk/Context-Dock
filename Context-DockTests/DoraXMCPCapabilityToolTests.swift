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
        #expect(names.contains("look"))
        #expect(names.contains("do"))
        #expect(names.contains("script"))
        #expect(names.contains("read_data"))
        #expect(names.contains("ask"))
        #expect(names.contains("dorax_run_capability"))
        #expect(names.contains("dorax_list_capabilities"))
        #expect(names.contains("dorax_remember"))
    }

    @Test func registrationCommandUsesContextDockBranding() {
        let cmd = DoraXMCPServer.registrationCommand
        #expect(cmd.contains("claude mcp add --transport http context-dock"))
        #expect(cmd.contains("/mcp"))
    }

    @Test func doraxRememberSavesDirectlyToMemory() async {
        let server = DoraXMCPServer.shared
        let uniqueFact = "I prefer short bullet points for status \(UUID().uuidString)"
        let reply = await server.callTool(
            named: "dorax_remember", arguments: ["text": uniqueFact], attended: true)
        #expect(reply.lowercased().contains("remembered") || reply.lowercased().contains("prefer"))
    }

    @Test func screenshotIsDocumentedAsTextLastResort() {
        let tool = DoraXMCPServer.toolDefinitions(attended: true).first {
            $0["name"] as? String == "dorax_screenshot"
        }
        let description = tool?["description"] as? String ?? ""
        #expect(description.contains("Prefer dorax_ask and app text capabilities"))
        #expect(description.contains("only when text tools return nothing useful"))
    }

    @Test func thePromptNamesTheScopedAppsCapabilitiesAheadOfTheShell() {
        let block = CapabilityRegistry.shared.cliPromptBlock(
            for: "com.apple.mail", appName: "Mail")
        #expect(block.contains("mail.search"))
        #expect(block.contains("dorax_run_capability"))
        #expect(block.contains("BEFORE any shell"))
    }

    @Test func anAppWithNoCapabilitiesAddsNothingToThePrompt() {
        // Unowned capabilities (clipboard, browser) are listed in every app but are not the
        // app's own, so they must not make a prompt block for it.
        #expect(
            CapabilityRegistry.shared.cliPromptBlock(for: "com.example.none", appName: "None")
                .isEmpty)
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
