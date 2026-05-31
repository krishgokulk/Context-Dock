import Combine
import Foundation

@MainActor
final class AutomationEngine: ObservableObject {
    static let shared = AutomationEngine()

    @Published private(set) var isRunning = false

    private init() {}

    func run(_ operation: @escaping () async throws -> Void) async rethrows {
        isRunning = true
        defer { isRunning = false }
        try await operation()
    }
}
