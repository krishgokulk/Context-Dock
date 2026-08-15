import Combine
import Foundation

struct AISafetyAssessment {
    let requiresCommandPreview: Bool
    let requiresFileChangeApproval: Bool
    let containsPrivateCloudData: Bool
}

@MainActor
final class AIPrivacyApprovalCenter: ObservableObject {
    static let shared = AIPrivacyApprovalCenter()

    struct PendingApproval: Identifiable {
        let id = UUID()
        let provider: AIProvider
        let contextDescription: String
        let continuation: CheckedContinuation<Bool, Never>
    }

    @Published private(set) var pending: PendingApproval?
    private var expiryTask: Task<Void, Never>?

    private init() {}

    func request(provider: AIProvider, context: UserContext) async -> Bool {
        await withCheckedContinuation { continuation in
            expiryTask?.cancel()
            pending = PendingApproval(
                provider: provider,
                contextDescription: context.description,
                continuation: continuation
            )
            expiryTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 60_000_000_000)
                guard !Task.isCancelled else { return }
                self?.deny()
            }
        }
    }

    func approve() {
        guard let pending else { return }
        expiryTask?.cancel()
        expiryTask = nil
        self.pending = nil
        pending.continuation.resume(returning: true)
    }

    func deny() {
        guard let pending else { return }
        expiryTask?.cancel()
        expiryTask = nil
        self.pending = nil
        pending.continuation.resume(returning: false)
    }
}

final class AISafetyPolicy {
    static let shared = AISafetyPolicy()

    private let destructivePatterns = [
        "rm -rf", "sudo rm", "erase disk", "format disk", "delete all",
        "sudo ", "chmod -r", "chown -r",
        "git reset --hard", "git clean -fd", "git push --force", "curl | sh",
        "shutdown -h",
    ]

    private init() {}

    func validate(message: String, context: UserContext, provider: AIProvider) throws {
        let lowered = message.lowercased()
        if destructivePatterns.contains(where: lowered.contains) {
            throw AIServiceError.unsupportedProvider(
                "Blocked destructive AI request. Use an explicit approved workflow instead."
            )
        }
    }

    func assess(message: String, context: UserContext, provider: AIProvider) -> AISafetyAssessment {
        let lowered = message.lowercased()
        let commandWords = ["run ", "execute ", "terminal", "shell", "command"]
        let fileWords = ["delete ", "remove ", "rename ", "move ", "overwrite ", "edit file"]
        return AISafetyAssessment(
            requiresCommandPreview: commandWords.contains(where: lowered.contains),
            requiresFileChangeApproval: fileWords.contains(where: lowered.contains),
            containsPrivateCloudData: !isLocal(provider) && hasPrivateContext(context)
        )
    }

    func isLocal(_ provider: AIProvider) -> Bool {
        switch provider {
        case .onDevice, .ollama:
            return true
        case .openAICompatible:
            guard let host = URLComponents(
                string: AppSettings.shared.openAICompatibleEndpoint
            )?.host?.lowercased() else { return false }
            return ["localhost", "127.0.0.1", "::1"].contains(host)
        case .claudeBridge, .chatGPTBridge:
            let endpoint = provider == .claudeBridge
                ? AppSettings.shared.claudeBridgeEndpoint
                : AppSettings.shared.chatGPTBridgeEndpoint
            guard let host = URLComponents(string: endpoint)?.host?.lowercased() else { return false }
            return ["localhost", "127.0.0.1", "::1"].contains(host)
        case .openAI, .anthropic, .googleGemini, .kimi, .shortcuts:
            return false
        }
    }

    private func hasPrivateContext(_ context: UserContext) -> Bool {
        switch context {
        case .filesSelected, .textSelected, .contactSelected:
            return true
        case .url, .appFocused, .none:
            return false
        }
    }
}
