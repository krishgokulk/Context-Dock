import Combine
import Foundation

@MainActor
final class LauncherViewModel: ObservableObject {
    @Published var query = ""
    @Published var isCollapsed = false
}

@MainActor
final class GlobalContextViewModel: ObservableObject {
    @Published var state = GlobalContextState()
}

@MainActor
final class ContextDockViewModel: ObservableObject {
    @Published var state = ContextDockState()
    @Published var cachedPills: [DockPill] = []
    @Published var pendingAIProposal: AIMenuProposal?
    @Published var pendingPillQuery: String?
    @Published var pendingPreviewPills: [DockPill] = []
    @Published var lastPillQuery = ""
    @Published var menuDebugText = "menu debug unavailable"
    @Published var contextMenuPills: [AXMenuItem] = []
    @Published var previousEnabledIDs: Set<UUID> = []
    @Published var lastFinderSelectionRefresh: Date = .distantPast

    var pillBuildTask: Task<Void, Never>?
    var pillBuildGeneration = 0
}

@MainActor
final class MediaDockViewModel: ObservableObject {
    @Published var state = MediaDockState()
}

@MainActor
final class AIChatViewModel: ObservableObject {
    @Published var state = AIChatState()
}

@MainActor
final class AutomationViewModel: ObservableObject {
    @Published var state = AutomationState()
}
