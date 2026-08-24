import Foundation
import Testing

@testable import Context_Dock

/// The quota payload is the only thing a subscription bridge ever says about how much is
/// left, and it says it once. Parsing it wrong means the app either nags about a limit that
/// has passed or sends into one that has not.
struct SubscriptionQuotaTests {

    /// Verbatim from VibeProxy fronting ChatGPT Plus.
    private let chatGPTRefusal = """
        {"error":{"type":"usage_limit_reached","message":"The usage limit has been reached",\
        "plan_type":"plus","resets_at":1787278323,"eligible_promo":null,\
        "resets_in_seconds":3239}}
        """

    @Test func readsAbsoluteResetTime() throws {
        let date = try #require(AIProviderToolHTTP.quotaResetDate(in: chatGPTRefusal))
        #expect(date == Date(timeIntervalSince1970: 1_787_278_323))
    }

    @Test func readsPlanType() {
        #expect(AIProviderToolHTTP.capturedPlanType(in: chatGPTRefusal) == "plus")
    }

    /// A bridge that reports only the relative figure still has to produce a usable time.
    @Test func fallsBackToRelativeSeconds() throws {
        let body = #"{"error":{"type":"usage_limit_reached","resets_in_seconds":600}}"#
        let date = try #require(AIProviderToolHTTP.quotaResetDate(in: body))
        let seconds = date.timeIntervalSinceNow
        #expect(seconds > 590 && seconds <= 600)
    }

    /// An ordinary failure must not be filed as a spent plan — that would lock the provider
    /// out for a window nobody imposed.
    @Test func ignoresUnrelatedErrors() {
        let body = #"{"error":{"message":"unknown provider for model gpt-4o","code":"model_not_found"}}"#
        #expect(AIProviderToolHTTP.quotaResetDate(in: body) == nil)
    }

    /// The window is over, so the record is not news any more.
    @Test func elapsedQuotaIsNotExhausted() {
        let past = AISubscriptionQuota(
            id: AIProvider.chatGPTBridge.rawValue, providerName: "ChatGPT Plus (via Bridge)",
            planType: "plus", resetsAt: Date().addingTimeInterval(-60), capturedAt: Date())
        #expect(past.isExhausted == false)

        let live = AISubscriptionQuota(
            id: AIProvider.claudeBridge.rawValue, providerName: "Claude Pro (via Bridge)",
            planType: "pro", resetsAt: Date().addingTimeInterval(600), capturedAt: Date())
        #expect(live.isExhausted)
    }
}
