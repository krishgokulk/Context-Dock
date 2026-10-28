import Foundation
import Testing

@testable import Context_Dock

// #46: the Claude Subscription bridge must not dead-end when the account is switched or the
// session expires. The CLI owns the login; DoraX reads `auth status`, classifies the CLI's
// auth failure, and offers one-click sign-in. These guard the two pure pieces of that.

@MainActor
struct ClaudeSubscriptionReauthTests {

    // MARK: - Auth-failure classification

    /// The exact string the `claude` CLI emits on a switched/expired account (owner-observed
    /// 2026-10-28). Misclassifying it as an ordinary failure is the #46 dead-end: it must read
    /// as an auth failure so the UI offers sign-in instead of the raw words.
    @Test func expiredOAuthReadsAsAuthFailure() {
        #expect(ClaudeCodeCLIService.isAuthFailure(
            "Failed to authenticate: OAuth session expired and could not be refreshed"))
    }

    @Test func notSignedInReadsAsAuthFailure() {
        #expect(ClaudeCodeCLIService.isAuthFailure(
            "Claude Code is installed but not signed in. Run `claude` and log in."))
    }

    /// An ordinary turn failure must NOT trigger the sign-in affordance.
    @Test func ordinaryFailureIsNotAuthFailure() {
        #expect(!ClaudeCodeCLIService.isAuthFailure("Rate limit exceeded; try again later."))
        #expect(!ClaudeCodeCLIService.isAuthFailure("Claude Code returned no answer."))
    }

    // MARK: - Reported login kind

    /// A Console (API-key) login is present but is not the subscription this provider is for,
    /// so it reads as `isConsole` and the UI nudges a subscription sign-in.
    @Test func consoleLoginIsFlagged() {
        #expect(ClaudeCodeCLIService.AuthStatus(loggedIn: true, method: "console").isConsole)
        #expect(!ClaudeCodeCLIService.AuthStatus(loggedIn: true, method: "claudeai").isConsole)
        #expect(!ClaudeCodeCLIService.AuthStatus.loggedOut.isConsole)
        #expect(!ClaudeCodeCLIService.AuthStatus.loggedOut.loggedIn)
    }
}
