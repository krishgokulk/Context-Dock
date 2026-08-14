// AgentAnswerVerifier.swift
// Catches an answer that claims work the app never did.
//
// Asked to "minimize" with VS Code scoped, the model replied "The window has been
// minimized." Nothing ran: no tool chip, and no entry in AIAuditHistory, which records every
// capability execution. The window was never touched.
//
// The system prompt already forbids this — "do not pretend the task is complete before
// approval/executor success" — and the model ignored it. Instructions do not constrain
// behaviour reliably; a check does. And the app holds the fact needed for that check: it
// knows exactly which tools ran this turn. That fact was being discarded (`let (response, _)
// = …`), so the app had no basis on which to disagree.
//
// A false claim about the user's machine is a worse failure than a refusal. "I can't do
// that" is annoying and honest. "Done" when nothing happened teaches the user to trust
// output that cannot be trusted, and they only find out later.

import Foundation

enum AgentAnswerVerifier {

    /// Phrases that assert a completed action.
    ///
    /// This is a SCREEN, not a router — the distinction that matters everywhere else in this
    /// codebase. A router decides what the app may do, so a wrong guess produces wrong
    /// behaviour. This only decides whether to spend one extra turn double-checking:
    ///   - false positive → a wasted verification turn on an answer that was already fine
    ///   - false negative → today's behaviour, unchanged
    /// Neither outcome can cause an action. It is allowed to be imperfect.
    private static let completionAssertions = [
        "has been", "have been", "i've ", "i have ", "successfully",
        "done —", "done.", "completed", "is now ", "are now ",
        "minimized", "maximized", "opened", "closed", "created", "deleted",
        "removed", "sent", "saved", "moved", "renamed", "added", "updated",
        "installed", "started", "stopped", "executed", "ran the",
    ]

    /// True when the text reads as a claim that something was carried out.
    static func assertsCompletedAction(in text: String) -> Bool {
        let lowered = text.lowercased()
        // A question or an offer is not a claim: "shall I minimize it?" and "I can minimize
        // it" describe an option, not an event.
        let hedges = ["would you like", "shall i", "do you want", "i can ", "you can ", "to do this"]
        if hedges.contains(where: lowered.contains), !lowered.contains("has been") {
            return false
        }
        return completionAssertions.contains(where: lowered.contains)
    }

    /// True when this turn's answer claims work that provably did not happen.
    static func claimsUnperformedWork(
        answer: String,
        executed: [AIProviderService.ExecutedCommand]
    ) -> Bool {
        guard executed.filter(\.success).isEmpty else { return false }
        return assertsCompletedAction(in: answer)
    }

    /// A successful tool call proves execution, not the requested outcome. Completed-action
    /// claims need an explicit read-back criterion from the shared typed verification tool.
    static func claimsUnverifiedWork(
        answer: String,
        executed: [AIProviderService.ExecutedCommand]
    ) -> Bool {
        guard assertsCompletedAction(in: answer),
              executed.contains(where: { $0.success && !$0.isVerification }) else {
            return false
        }
        return !executed.contains(where: { $0.success && $0.isVerification })
    }

    static func verificationPrompt(originalQuery: String, answer: String) -> String {
        """
        SYSTEM NOTE — outcome verification required.

        A tool executed, but execution is not proof that the user's requested outcome now
        exists. Your draft claims completion without a successful typed verification:
        "\(answer.prefix(500))"

        Call verify_outcome now with the narrowest read-only criterion that proves the result.
        Do not use run_command, cat, test, ls, or another mutation as a substitute. If the
        criterion fails, say the task is not complete and report the observed state. Only claim
        success after verify_outcome returns status: ok.

        Original request: "\(originalQuery)"
        """
    }

    /// The correction turn. Hands the model the ground truth and asks for one honest rewrite.
    ///
    /// Deliberately not "try again" — a retry invites another guess. It states the fact and
    /// offers exactly two acceptable outcomes: call the tool that does the thing, or tell the
    /// user it was not done.
    static func correctionPrompt(
        originalQuery: String,
        answer: String,
        executed: [AIProviderService.ExecutedCommand]
    ) -> String {
        let ran = executed.isEmpty
            ? "You called no tools at all this turn."
            : "The only tools you called were: "
                + executed.map { "\($0.command) → \($0.success ? "ok" : "FAILED")" }
                    .joined(separator: ", ")

        return """
            SYSTEM NOTE — factual correction required.

            \(ran) DoraX records every execution, so this is not a matter of opinion: no \
            action was performed on the user's machine.

            Your draft answer was:
            "\(answer.prefix(500))"

            That answer states or implies work was completed. It was not. Rewrite it, choosing \
            exactly one:

            1. If a tool CAN do what was asked, call that tool now. Use find_capability to \
               locate it if you do not know its name, then run_capability. Do not describe \
               calling it — call it.
            2. If nothing available can do it, say so plainly in one sentence and name what \
               is missing.

            Never report an action as done when no tool ran. The user cannot see your \
            reasoning, only your answer, and a false report of success is worse than any \
            refusal.

            The user originally asked: "\(originalQuery)"
            """
    }

    /// What the transcript should show when a turn ran nothing. Without it the chip row is
    /// simply empty, which reads as "no detail" rather than "nothing happened".
    static func noActionChip(executed: [AIProviderService.ExecutedCommand]) -> String? {
        executed.isEmpty ? "No tools ran" : nil
    }
}
