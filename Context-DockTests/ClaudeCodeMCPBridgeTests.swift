import Foundation
import Testing

@testable import Context_Dock

/// Handing DoraX's own tools to the Claude Code CLI.
///
/// The server that answers them has existed and been switched on, but nothing pointed the CLI
/// at it: no --mcp-config was passed, and `claude mcp list` knew nothing about DoraX. The app
/// printed a `claude mcp add` line and left the wiring to the user, so a turn under this
/// provider saw none of the app's context and could act on none of it.
@MainActor
@Suite("Claude Code MCP bridge")
struct ClaudeCodeMCPBridgeTests {
    private func arguments(configPath: String?) -> [String] {
        ClaudeCodeCLIService.arguments(
            prompt: "update the app",
            systemPrompt: nil,
            model: nil,
            access: .research,
            workingDirectory: nil,
            mcpConfigPath: configPath)
    }

    @Test func theConfigIsPassedWhenThereIsOne() throws {
        let args = arguments(configPath: "/tmp/dorax-mcp.json")
        let index = try #require(args.firstIndex(of: "--mcp-config"))
        #expect(args[index + 1] == "/tmp/dorax-mcp.json")
    }

    /// Declaring the server is not the same as being allowed to call it: --tools says what
    /// exists, --allowedTools is the permission list, and the CLI refuses a tool missing from
    /// the second even when the first names it.
    @Test func theServersToolsAreAllowedTooNotJustDeclared() throws {
        let args = arguments(configPath: "/tmp/dorax-mcp.json")
        let allowedIndex = try #require(args.firstIndex(of: "--allowedTools"))
        #expect(args[allowedIndex + 1].contains("mcp__dorax"))
        let toolsIndex = try #require(args.firstIndex(of: "--tools"))
        #expect(args[toolsIndex + 1].contains("mcp__dorax"))
    }

    /// With the server switched off there is nothing to point at, and the CLI runs as before.
    @Test func nothingIsPassedWithoutAConfig() {
        let args = arguments(configPath: nil)
        #expect(!args.contains("--mcp-config"))
        #expect(!args.joined(separator: " ").contains("mcp__dorax"))
    }

    /// The token is a bearer credential for anything on this Mac. Passed in argv it would sit
    /// in every `ps` listing, so it goes in a file only its owner can read.
    @Test func theConfigIsWrittenPrivatelyRatherThanPassedInArgv() throws {
        let url = try #require(DoraXMCPServer.writeCLIConfig())
        defer { try? FileManager.default.removeItem(at: url) }

        let contents = try String(contentsOf: url, encoding: .utf8)
        #expect(contents.contains("127.0.0.1"))
        #expect(contents.contains("Authorization"))

        let permissions = try FileManager.default
            .attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        #expect(permissions?.int16Value == 0o600)
    }
}
