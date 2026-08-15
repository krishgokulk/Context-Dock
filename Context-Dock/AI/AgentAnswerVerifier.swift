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
        // The shared verify_outcome tool currently has typed filesystem criteria only.
        // A user-authored Global Command may open a URL/app or run AppleScript, for which
        // inventing a file path cannot prove anything. Its successful executor receipt is
        // deliberately "executor confirmed", not independently verified; do not force the
        // model into an invalid filesystem check merely to manufacture a verification chip.
        let successfulActions = executed.filter { $0.success && !$0.isVerification }
        if successfulActions.allSatisfy({
            $0.command.hasPrefix("run_capability(globalcmd.")
        }) {
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

    /// When the user states the criterion explicitly, a different successful verifier is not
    /// evidence. In particular, "verify the file exists" must never be satisfied by proving
    /// that it does not exist.
    static func requiredVerificationKind(in query: String) -> String? {
        let lowered = query.lowercased()
        guard let verifyRange = lowered.range(of: "verify", options: .backwards) else { return nil }
        let clause = String(lowered[verifyRange.lowerBound...])
        if clause.contains("does not exist") || clause.contains("doesn't exist") {
            return "file_does_not_exist"
        }
        if clause.contains(" exists") || clause.hasSuffix("exists") || clause.contains("exist.") {
            return "file_exists"
        }
        if clause.contains("exactly matches") || clause.contains("equals")
            || clause.contains("exact contents") {
            return "file_equals"
        }
        if clause.contains("contains") { return "file_contains" }
        return nil
    }

    static func explicitVerificationIsMissingOrMismatched(
        query: String,
        executed: [AIProviderService.ExecutedCommand]
    ) -> Bool {
        guard let requiredKind = requiredVerificationKind(in: query),
              executed.contains(where: { $0.success && !$0.isVerification }) else {
            return false
        }
        return !executed.contains {
            $0.success && $0.isVerification
                && $0.command.contains("verify_outcome(\(requiredKind),")
        }
    }

    static func explicitVerificationPrompt(originalQuery: String) -> String {
        let kind = requiredVerificationKind(in: originalQuery) ?? "the requested kind"
        return """
        SYSTEM NOTE — the verification criterion must match the user's request.

        The user explicitly requested `\(kind)`. A different or opposite verification cannot
        satisfy that criterion, even if it succeeds. Call verify_outcome with kind `\(kind)`
        and the path from the original request. Report success only if that exact check passes;
        otherwise report that the requested criterion failed.

        Original request: "\(originalQuery)"
        """
    }

    /// Runs the exact typed criterion requested by the user. This is a postcondition, not a
    /// second chance for the model to reinterpret words or filenames.
    static func executeRequiredVerification(
        query: String,
        commandExecutor: @escaping (String, String, Bool) async -> (Bool, String, Int32)
    ) async -> (answer: String, receipt: AIProviderService.ExecutedCommand)? {
        guard let kind = requiredVerificationKind(in: query),
              let path = explicitVerificationPath(in: query),
              let result = await AgentToolRegistry.shared.dispatch(
                name: "verify_outcome",
                arguments: ["kind": kind, "path": path],
                context: AgentToolContext(commandExecutor: commandExecutor)
              )
        else { return nil }

        let status = result.success ? "passed" : "failed"
        return (
            "Verification \(status): \(result.output)",
            AIProviderService.ExecutedCommand(
                command: result.displayCommand,
                output: result.output,
                success: result.success,
                isVerification: true
            )
        )
    }

    /// Narrow deterministic contract for requests shaped as "Run X, then/but verify Y".
    /// This is intentionally not a general NL-to-shell parser; it only prevents the agent
    /// from skipping an exact command the user explicitly supplied.
    static func explicitlyRequestedCommand(in query: String) -> String? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.lowercased().hasPrefix("run "),
              trimmed.range(of: "verify", options: .caseInsensitive) != nil else {
            return nil
        }
        let afterRun = String(trimmed.dropFirst(4))
        let separators = [", but verify", ", then verify", " and verify", "; verify"]
        let boundary = separators.compactMap {
            afterRun.range(of: $0, options: .caseInsensitive)?.lowerBound
        }.min()
        let command = String(boundary.map { afterRun[..<$0] } ?? afterRun[...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return command.isEmpty ? nil : command
    }

    static func explicitExecutionIsMissing(
        query: String,
        executed: [AIProviderService.ExecutedCommand]
    ) -> Bool {
        guard let command = explicitlyRequestedCommand(in: query) else { return false }
        return !executed.contains {
            !$0.isVerification && $0.command == "run_command(\(command))"
        }
    }

    static func explicitExecutionPrompt(originalQuery: String) -> String {
        let command = explicitlyRequestedCommand(in: originalQuery) ?? ""
        let verificationKind = requiredVerificationKind(in: originalQuery)
        let verificationInstruction = verificationKind.map {
            "After it runs, call verify_outcome with kind `\($0)` and the original path."
        } ?? "After it runs, perform the verification the user requested."
        return """
        SYSTEM NOTE — an explicitly requested execution was skipped.

        The user explicitly asked to run `\(command)`. Call run_command with exactly that
        command now. Do not omit it merely because it has no output or does not affect the
        later criterion. \(verificationInstruction) Report both outcomes honestly.

        Original request: "\(originalQuery)"
        """
    }

    /// Enforces the narrow `Run X, ... verify PATH exists` contract without asking the
    /// model to remember the skipped action a second time. The command still goes through
    /// TerminalCommandExecutor, including its classifier and approval gate. Verification is
    /// then repeated after execution so the receipt describes post-action state.
    static func executeMissingExplicitContract(
        query: String,
        executed: [AIProviderService.ExecutedCommand],
        commandExecutor: @escaping (String, String, Bool) async -> (Bool, String, Int32)
    ) async -> (answer: String, additions: [AIProviderService.ExecutedCommand])? {
        guard explicitExecutionIsMissing(query: query, executed: executed),
              let command = explicitlyRequestedCommand(in: query)
        else { return nil }

        let (commandSucceeded, commandOutput, _) = await commandExecutor(
            command,
            "Run the command explicitly requested by the user before verification.",
            false
        )
        var additions = [AIProviderService.ExecutedCommand(
            command: "run_command(\(command))",
            output: commandOutput,
            success: commandSucceeded
        )]

        guard let kind = requiredVerificationKind(in: query),
              let path = explicitVerificationPath(in: query),
              let result = await AgentToolRegistry.shared.dispatch(
                name: "verify_outcome",
                arguments: ["kind": kind, "path": path],
                context: AgentToolContext(commandExecutor: commandExecutor)
              )
        else {
            let status = commandSucceeded ? "succeeded" : "failed"
            return ("The requested command `\(command)` \(status).", additions)
        }

        additions.append(AIProviderService.ExecutedCommand(
            command: result.displayCommand,
            output: result.output,
            success: result.success,
            isVerification: true
        ))
        let commandStatus = commandSucceeded ? "succeeded" : "failed"
        let verificationStatus = result.success ? "passed" : "failed"
        return (
            "The command `\(command)` \(commandStatus). Verification \(verificationStatus): \(result.output)",
            additions
        )
    }

    private static func explicitVerificationPath(in query: String) -> String? {
        guard let verifyRange = query.range(of: "verify", options: .caseInsensitive) else {
            return nil
        }
        let clause = query[verifyRange.upperBound...]
        let punctuation = CharacterSet(charactersIn: ".,;:!?\"'()[]{}")
        return clause.split(whereSeparator: { $0.isWhitespace })
            .map { String($0).trimmingCharacters(in: punctuation) }
            .first { $0.hasPrefix("/") }
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
