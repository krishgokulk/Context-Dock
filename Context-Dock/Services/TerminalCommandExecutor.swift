import Foundation

@MainActor
final class TerminalCommandExecutor {
    static let shared = TerminalCommandExecutor()

    private let bridge = TerminalAIBridge.shared

    private init() {}

    /// - Parameter consoleScope: the chat thread this command belongs to. Given one, the
    ///   command is written to that thread's console live — a row when it starts, its real
    ///   output when it returns. Every surface routes shell work through here, so this is
    ///   the one place that has to know; the dock used to run commands the console never
    ///   heard about, which is why a thread full of executed commands could open in the
    ///   window under "Nothing has run in this thread yet".
    func run(
        _ command: String,
        purpose: String,
        modelRequiresApproval: Bool = false,
        consoleScope: GeneralChatScope? = nil
    ) async -> (success: Bool, output: String, exitCode: Int32) {
        let rowID = consoleScope.map {
            ChatConsoleLog.shared.begin(.command, title: command, scope: $0)
        }
        let result = await bridge.processAICommand(
            command, purpose: purpose, modelRequiresApproval: modelRequiresApproval)
        if let rowID, let consoleScope {
            ChatConsoleLog.shared.finish(
                rowID, output: consoleOutput(result.output, success: result.success),
                success: result.success, scope: consoleScope)
        }
        return result
    }

    /// - Returns: the process exit code alongside the output, so a caller can tell "no
    ///   matches" from "bad usage" instead of only knowing that something failed.
    func runPreApproved(
        _ command: String,
        consoleScope: GeneralChatScope? = nil,
        onLine: (@Sendable (String) -> Void)? = nil
    ) async -> (success: Bool, output: String, exitCode: Int32) {
        let rowID = consoleScope.map {
            ChatConsoleLog.shared.begin(.command, title: command, scope: $0)
        }
        let result = await bridge.runPreApprovedCommand(command, onLine: onLine)
        if let rowID, let consoleScope {
            ChatConsoleLog.shared.finish(
                rowID, output: consoleOutput(result.output, success: result.success),
                success: result.success, scope: consoleScope)
        }
        return result
    }

    /// A console row with an empty body reads as a bug. Say which kind of nothing it was.
    private func consoleOutput(_ output: String, success: Bool) -> String {
        guard output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return output
        }
        return success ? "(no output)" : "(failed, no output)"
    }

    func spawnWorker(command: String, purpose: String) -> String {
        bridge.spawnWorker(command: command, purpose: purpose)
    }

    func sendKeys(_ keys: String) -> String {
        bridge.sendKeys(keys)
    }
}
