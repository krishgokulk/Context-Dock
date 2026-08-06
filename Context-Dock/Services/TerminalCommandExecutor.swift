import Foundation

@MainActor
final class TerminalCommandExecutor {
    static let shared = TerminalCommandExecutor()

    private let bridge = TerminalAIBridge.shared

    private init() {}

    func run(
        _ command: String,
        purpose: String,
        modelRequiresApproval: Bool = false
    ) async -> (success: Bool, output: String) {
        await bridge.processAICommand(
            command, purpose: purpose, modelRequiresApproval: modelRequiresApproval)
    }

    /// - Returns: the process exit code alongside the output, so a caller can tell "no
    ///   matches" from "bad usage" instead of only knowing that something failed.
    func runPreApproved(
        _ command: String,
        onLine: (@Sendable (String) -> Void)? = nil
    ) async -> (success: Bool, output: String, exitCode: Int32) {
        await bridge.runPreApprovedCommand(command, onLine: onLine)
    }

    func spawnWorker(command: String, purpose: String) -> String {
        bridge.spawnWorker(command: command, purpose: purpose)
    }

    func sendKeys(_ keys: String) -> String {
        bridge.sendKeys(keys)
    }
}
