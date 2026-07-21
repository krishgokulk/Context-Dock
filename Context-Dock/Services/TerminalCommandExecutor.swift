import Foundation

@MainActor
final class TerminalCommandExecutor {
    static let shared = TerminalCommandExecutor()

    private let bridge = TerminalAIBridge.shared

    private init() {}

    func run(
        _ command: String,
        purpose: String
    ) async -> (success: Bool, output: String) {
        await bridge.processAICommand(command, purpose: purpose)
    }

    func runPreApproved(_ command: String) async -> (success: Bool, output: String) {
        await bridge.runPreApprovedCommand(command)
    }

    func spawnWorker(command: String, purpose: String) -> String {
        bridge.spawnWorker(command: command, purpose: purpose)
    }

    func sendKeys(_ keys: String) -> String {
        bridge.sendKeys(keys)
    }
}
