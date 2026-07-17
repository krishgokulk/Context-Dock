import Foundation

@MainActor
final class DependencyContainer {
    static let shared = DependencyContainer()

    let appState = AppState.shared
    let router = AppRouter.shared

    let globalContextEngine = GlobalContextEngine.shared
    let contextDockEngine = ContextDockEngine.shared
    let mediaDockEngine = MediaDockEngine.shared
    let automationEngine = AutomationEngine.shared
    let aiProviderRouter = AIProviderRouter.shared
    let capabilityRegistry = CapabilityRegistry.shared
    let aiResponseParser = AIResponseParser.shared
    let aiExecutionEngine = AIExecutionEngine.shared

    let extensionRegistry = ExtensionRegistry.shared
    let extensionMatcher = ExtensionMatcher.shared
    let extensionRunner = ExtensionRunner.shared
    let extensionAIAdapter = ExtensionAIAdapter.shared

    let selectionContextService = SelectionContextService.shared
    let frontmostAppContextService = FrontmostAppContextService.shared
    let browserContextService = BrowserContextService.shared
    let mediaContextService = MediaContextService.shared

    private init() {}
}
