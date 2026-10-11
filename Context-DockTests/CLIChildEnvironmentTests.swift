import Testing
import Foundation
@testable import Context_Dock

// MARK: - CLIChildEnvironment
// DoraX launched from inside a Claude Code session inherits that session's markers; a
// spawned `claude -p` that keeps them treats itself as the host's child and reports
// "Not logged in". The filter must drop them and keep what the person configured.

struct CLIChildEnvironmentTests {

    private let hostSession: [String: String] = [
        "PATH": "/usr/bin:/bin",
        "HOME": "/wrong",
        "CLAUDECODE": "1",
        "CLAUDE_CODE_ENTRYPOINT": "claude-desktop",
        "CLAUDE_CODE_CHILD_SESSION": "1",
        "CLAUDE_CODE_SDK_HAS_HOST_AUTH_REFRESH": "1",
        "CLAUDE_CODE_OAUTH_SCOPES": "user:inference",
        "CLAUDE_CODE_MESSAGING_SOCKET": "/tmp/sock",
        "CLAUDE_PID": "123",
        "CLAUDE_EFFORT": "high",
        "CLAUDE_AGENT_SDK_VERSION": "1.0",
        "CLAUDE_PREVIEW_CLASSIFIER_FLOOR": "x",
        "ANTHROPIC_BASE_URL": "http://127.0.0.1:9999",
        "MCP_CONNECTION_NONBLOCKING": "1",
        "ANTHROPIC_API_KEY": "sk-test",
        "CLAUDE_CONFIG_DIR": "/Users/me/.claude-alt",
    ]

    @Test func hostSessionVariablesAreRemoved() {
        let env = CLIChildEnvironment.make(from: hostSession, home: "/Users/me")
        #expect(!env.keys.contains { $0.hasPrefix("CLAUDE_CODE_") })
        for key in CLIChildEnvironment.hostSessionKeys.union(CLIChildEnvironment.hostInjectedKeys) {
            #expect(env[key] == nil, "\(key) leaked into the child")
        }
    }

    @Test func deliberateConfigurationIsKept() {
        let env = CLIChildEnvironment.make(from: hostSession, home: "/Users/me")
        #expect(env["ANTHROPIC_API_KEY"] == "sk-test")
        #expect(env["CLAUDE_CONFIG_DIR"] == "/Users/me/.claude-alt")
        #expect(env["PATH"] == "/usr/bin:/bin")
        #expect(env["HOME"] == "/Users/me")
    }

    @Test func gatewayBaseURLSurvivesOutsideAHostSession() {
        let env = CLIChildEnvironment.make(
            from: ["ANTHROPIC_BASE_URL": "https://gateway.example"], home: "/Users/me")
        #expect(env["ANTHROPIC_BASE_URL"] == "https://gateway.example")
    }
}
