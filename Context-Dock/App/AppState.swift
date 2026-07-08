import AppKit
import Combine
import Foundation

struct GlobalContextState {
    var query = ""
    var scopedBundleId: String?
    var activation: GlobalContextActivation?

    var isActive: Bool {
        activation != nil
    }
}

struct ContextDockState {
    var isActive = true
    var frontmost = FrontmostAppState()
}

struct MediaDockState {
    var isActive = false
    var title = ""
    var artist = ""
    var isPlaying = false
}

struct AIChatState {
    var isActive = false
    var isLoading = false
    var activeConversationId: String?
    var mode = AIModeState()
}

struct AutomationState {
    var isRunning = false
    var activeRuleId: String?
}

@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    @Published var globalContext = GlobalContextState()
    @Published var contextDock = ContextDockState()
    @Published var mediaDock = MediaDockState()
    @Published var aiChat = AIChatState()
    @Published var automation = AutomationState()

    private init() {}

    func setContextDockActiveDeferred(_ isActive: Bool) {
        guard contextDock.isActive != isActive else { return }
        Task { @MainActor [weak self] in
            guard let self, self.contextDock.isActive != isActive else { return }
            self.contextDock.isActive = isActive
        }
    }

    func setGlobalContextActivationDeferred(_ activation: GlobalContextActivation?) {
        guard globalContext.activation != activation else { return }
        Task { @MainActor [weak self] in
            guard let self, self.globalContext.activation != activation else { return }
            self.globalContext.activation = activation
        }
    }

    func resetLauncherModes(contextDockActive: Bool = true) {
        globalContext.activation = nil
        mediaDock.isActive = false
        aiChat.mode.isActive = false
        contextDock.isActive = contextDockActive
    }
}
