import Foundation
import Testing
@testable import Context_Dock

@MainActor
struct ChatGPTSubscriptionTests {
    @Test func subscriptionDispatchNeverRequiresAnHTTPConfiguration() throws {
        let provider = try #require(AIProvider(rawValue: "chatGPTSubscription"))
        #expect(AIProviderRouter.localProviders.contains(provider))
        #expect(!provider.requiresAPIKey)
        #expect(!provider.requiresEndpoint)
        #expect(!provider.supportsNativeTools)
        #expect(!AISafetyPolicy.shared.isLocal(provider))
        #expect(!AIProviderRouter.shared.capabilities(for: provider).runsLocally)
    }

    @Test func topLevelErrorsAreNotSilentlyDiscarded() {
        #expect(CodexCLIService.parse(streamLine:
            #"{"type":"error","message":"Usage limit reached"}"#)
            == .failure("Usage limit reached"))
        #expect(CodexCLIService.parse(streamLine:
            #"{"type":"turn.failed","error":{"message":"Please sign in"}}"#)
            == .failure("Please sign in"))
    }

    @Test func subscriptionCannotInheritAPIOrHostRouting() {
        let env = CodexCLIService.subscriptionEnvironment(from: [
            "OPENAI_API_KEY": "secret", "OPENAI_BASE_URL": "https://proxy.invalid",
            "CODEX_API_KEY": "secret", "CODEX_ACCESS_TOKEN": "host",
            "CODEX_INTERNAL_ORIGINATOR_OVERRIDE": "host", "CODEX_HOME": "/tmp/own-auth",
            "CLAUDECODE": "1", "PATH": "/usr/bin"
        ])
        #expect(env["OPENAI_API_KEY"] == nil)
        #expect(env["OPENAI_BASE_URL"] == nil)
        #expect(env["CODEX_API_KEY"] == nil)
        #expect(env["CODEX_ACCESS_TOKEN"] == nil)
        #expect(env["CODEX_INTERNAL_ORIGINATOR_OVERRIDE"] == nil)
        #expect(env["CLAUDECODE"] == nil)
        #expect(env["CODEX_HOME"] == "/tmp/own-auth")
        #expect(env["PATH"] == "/usr/bin")
    }

    @Test func subscriptionArgumentsForceChatGPTAndWithholdNativeTools() {
        let args = CodexCLIService.subscriptionArguments(model: "account-model")
        #expect(args.contains("--ignore-user-config"))
        #expect(args.contains("--ignore-rules"))
        #expect(args.contains("forced_login_method=\"chatgpt\""))
        #expect(args.contains("model_provider=\"openai\""))
        #expect(args.contains("web_search=\"disabled\""))
        #expect(args.contains("read-only"))
        for tool in ["shell_tool", "unified_exec", "view_image", "computer_use", "apps", "plugins", "hooks"] {
            #expect(args.indices.contains { args[$0] == "--disable" && args.indices.contains($0 + 1)
                && args[$0 + 1] == tool })
        }
        #expect(args.last == "-")
        #expect(args.contains("account-model"))
        #expect(!CodexCLIService.subscriptionArguments(model: nil).contains("--model"))
    }

    @Test func APIKeyAndSignedOutAccountsAreRefused() throws {
        try CodexCLIService.validateSubscriptionLogin(output: "Logged in using ChatGPT\n", status: 0)
        #expect(throws: (any Error).self) {
            try CodexCLIService.validateSubscriptionLogin(output: "Logged in using an API key", status: 0)
        }
        #expect(throws: (any Error).self) {
            try CodexCLIService.validateSubscriptionLogin(output: "Not logged in", status: 1)
        }
    }

    @Test func catalogUsesAccountModelsAndRejectsAPIAuthentication() throws {
        let account = #"{"id":2,"result":{"account":{"type":"chatgpt","email":"redacted","planType":"plus"},"requiresOpenaiAuth":true}}"#
        let page = #"{"id":3,"result":{"data":[{"id":"opaque","model":"plan-model","displayName":"Plan model","isDefault":true,"hidden":false},{"model":"hidden","hidden":true}],"nextCursor":"next"}}"#
        let result = try CodexCLIService.subscriptionCatalog(from: page + "\n" + account)
        #expect(result.models.map(\.id) == ["plan-model"])
        #expect(result.models.first?.name == "Plan model")
        #expect(result.nextCursor == "next")
        #expect(throws: (any Error).self) {
            try CodexCLIService.subscriptionCatalog(from:
                #"{"id":2,"result":{"account":{"type":"apiKey"}}}"# + "\n" + page)
        }
    }

    @Test func incompleteAndFailedTurnsCannotBecomeSuccessfulAnswers() throws {
        let text = #"{"type":"item.completed","item":{"type":"agent_message","text":"partial"}}"#
        #expect(throws: (any Error).self) {
            try CodexCLIService.subscriptionAnswer(transcript: text, status: 0)
        }
        let done = text + "\n" + #"{"type":"turn.completed"}"#
        #expect(try CodexCLIService.subscriptionAnswer(transcript: done, status: 0) == "partial")
        #expect(throws: (any Error).self) {
            try CodexCLIService.subscriptionAnswer(transcript: done, status: 1)
        }
        #expect(throws: (any Error).self) {
            try CodexCLIService.subscriptionAnswer(transcript: text + "\n"
                + #"{"type":"turn.failed","error":{"message":"quota"}}"#, status: 0)
        }
    }
}
