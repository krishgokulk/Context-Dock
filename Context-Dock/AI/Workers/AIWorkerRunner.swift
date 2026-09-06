import Foundation

/// Runs a bounded task on a specialist and brings back a report.
///
/// The envelope is not advice to the worker; it is how the worker is launched. Read-only tool
/// access, one directory added, and the forbidden list stated in the prompt as well — an agent
/// that can only read cannot be talked into writing, and an agent told what it may not do
/// stops asking.
///
/// The result is a report, never a fact. A worker's word is not proof, and the receipt says
/// `executorConfirmed` at best until something reads the machine back.
enum AIWorkerRunner {
    @MainActor
    static func run(
        _ task: AIWorkerTask,
        on kind: AIWorkerKind,
        onProgress: (@Sendable (String) -> Void)? = nil
    ) async -> String {
        switch kind {
        case .claudeCode:
            return await runClaudeCode(task, onProgress: onProgress)
        case .codex:
            // Codex is discovered and offered only where it can be run; until its bounded
            // invocation is written, saying so is better than launching it with a shape
            // borrowed from another agent's flags.
            return "Codex delegation is not wired yet — ask Claude Code, or run it yourself in "
                + "\(task.authority.scopeDescription)."
        }
    }

    @MainActor
    private static func runClaudeCode(
        _ task: AIWorkerTask,
        onProgress: (@Sendable (String) -> Void)?
    ) async -> String {
        do {
            let answer = try await ClaudeCodeCLIService.send(
                prompt: prompt(for: task),
                systemPrompt: systemPrompt(for: task),
                model: nil,
                // Read and research: the CLI's own read-only tool set. The envelope said no
                // writes, and this is that sentence expressed as how the process starts rather
                // than as something the model is asked to respect.
                access: .research,
                workingDirectory: task.authority.allowedPaths.first,
                onProgress: onProgress)
            return answer
        } catch {
            return "\(AIWorkerKind.claudeCode.displayName) could not run: \(error.localizedDescription)"
        }
    }

    private static func prompt(for task: AIWorkerTask) -> String {
        """
        \(task.goal)

        Report what you find. Do not change anything.
        """
    }

    private static func systemPrompt(for task: AIWorkerTask) -> String {
        """
        You are investigating one bounded problem for another app, which will show your answer \
        to the person who asked and check it before believing it.

        Scope: \(task.authority.scopeDescription)
        You may read: \(task.authority.allowedPaths.map(\.path).joined(separator: ", "))

        You may not:
        \(task.forbidden.map { "- \($0)" }.joined(separator: "\n"))

        Expected answer: \(task.expectedOutput)

        Say plainly when the evidence does not support a conclusion. A report that names what \
        it could not determine is more useful than one that guesses.
        """
    }
}
