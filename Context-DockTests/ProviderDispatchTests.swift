import Foundation
import Testing

@testable import Context_Dock

// Which providers are reached over HTTP, and which are run on this Mac.
//
// "Claude Subscription" answered in one surface and failed in another with "Provider does not
// use an HTTP adapter". Both statements were true: AIProviderService intercepted .claudeCode
// and ran the CLI, while AIProviderRouter intercepted only .onDevice and let .claudeCode fall
// through to `configuration(for:)`, which has no endpoint to give it and throws.
//
// The interception is per-send-path and easy to forget, so the thing worth pinning is the
// list itself: every provider is either run locally, or has an endpoint to call.

@MainActor
struct ProviderDispatchTests {

    private var router: AIProviderRouter { AIProviderRouter.shared }

    /// The two that run something on this Mac. A third arriving without being added here —
    /// and intercepted in every send path — is the bug this test exists to catch.
    @Test func onlyTheLocalProvidersSkipTheHTTPPath() {
        #expect(AIProviderRouter.localProviders == [.onDevice, .claudeCode])
    }

    /// Every other provider must reach a real endpoint. Missing credentials or an unset
    /// bridge endpoint are ordinary configuration problems and are allowed here; what must
    /// never happen is `unsupportedProvider`, which means the provider has no HTTP path at
    /// all and nobody intercepted it.
    @Test func everyRemoteProviderHasAnEndpointToCall() {
        for provider in AIProvider.allCases where !AIProviderRouter.localProviders.contains(provider) {
            do {
                _ = try router.configuration(for: provider, apiKeyOverride: "test-key")
            } catch let error as AIServiceError {
                if case .unsupportedProvider(let message) = error {
                    Issue.record(
                        """
                        \(provider.rawValue) has no HTTP configuration (\(message)) and is not \
                        in localProviders — every send path will throw on it
                        """)
                }
                // missingAPIKey / networkError are configuration, not dispatch. Fine here.
            } catch {
                // Anything else is also not a dispatch failure.
            }
        }
    }

    /// The subscription is the CLI the user has already signed in to, so it must not be
    /// treated as a provider awaiting an API key — that would put a key field in front of
    /// someone who does not need one, and block the send until they filled it in.
    @Test func theSubscriptionNeedsNoAPIKey() {
        #expect(!AIProvider.claudeCode.requiresAPIKey)
        #expect(!AIProvider.onDevice.requiresAPIKey)
    }
}
