import AppKit
import Foundation

enum ExtensionScope: String, Codable, CaseIterable {
    case globalWithSelection = "global_with_selection"
    case globalWithoutSelection = "global_without_selection"
    case contextDock = "context_dock"
    case mediaDock = "media_dock"
    case workflow
}

struct ExtensionContext {
    var scope: ExtensionScope
    var userContext: UserContext
    var frontmostAppName: String
    var frontmostBundleId: String
    var selectedFiles: [URL]
    var selectedText: String
    var selectedURL: String?
    var clipboardText: String

    var hasSelection: Bool {
        !selectedFiles.isEmpty || !selectedText.isEmpty || selectedURL != nil
    }

    static func collect(
        scope: ExtensionScope,
        userContext: UserContext,
        frontmostApp: NSRunningApplication? = NSWorkspace.shared.frontmostApplication
    ) -> ExtensionContext {
        let files: [URL]
        let text: String
        let url: String?
        switch userContext {
        case .filesSelected(let urls):
            files = urls
            text = ""
            url = nil
        case .textSelected(let selectedText):
            files = []
            text = selectedText
            url = nil
        case .url(let selectedURL):
            files = []
            text = ""
            url = selectedURL
        case .appFocused, .contactSelected, .none:
            files = []
            text = ""
            url = nil
        }

        return ExtensionContext(
            scope: scope,
            userContext: userContext,
            frontmostAppName: frontmostApp?.localizedName ?? "",
            frontmostBundleId: frontmostApp?.bundleIdentifier ?? "",
            selectedFiles: files,
            selectedText: text,
            selectedURL: url,
            clipboardText: NSPasteboard.general.string(forType: .string) ?? ""
        )
    }
}

struct ExtensionManifest: Identifiable {
    let extensionValue: ILExtension

    var id: UUID { extensionValue.id }
    var name: String { extensionValue.name }
    var summary: String { extensionValue.description }
    var requiresAI: Bool { extensionValue.tags.contains(.aiPowered) }
    var requiredPermissions: [String] { extensionValue.requiresPermissions }
}

@MainActor
final class ExtensionRegistry {
    static let shared = ExtensionRegistry()

    private let manager: LayeredExtensionManager

    init(manager: LayeredExtensionManager = .shared) {
        self.manager = manager
    }

    var manifests: [ExtensionManifest] {
        manager.allExtensions.map(ExtensionManifest.init)
    }
}

@MainActor
final class ExtensionMatcher {
    static let shared = ExtensionMatcher()

    private let registry: ExtensionRegistry

    init(registry: ExtensionRegistry = .shared) {
        self.registry = registry
    }

    func matching(_ context: ExtensionContext) -> [ExtensionManifest] {
        registry.manifests.filter { manifest in
            let ext = manifest.extensionValue
            guard ext.enabled else { return false }
            if context.scope == .workflow { return ext.layer == .crossLayer || ext.canChain }
            if context.scope == .mediaDock {
                return ext.tags.contains(.imageProcessing) || ext.tags.contains(.extraction)
            }
            if context.scope == .globalWithSelection { return context.hasSelection }
            if context.scope == .globalWithoutSelection { return !context.hasSelection }
            return ext.layer == .l2_context || ext.layer == .crossLayer
        }
    }
}

@MainActor
final class ExtensionAIAdapter {
    static let shared = ExtensionAIAdapter()

    private let planner: AIActionPlanner
    private let router: AIProviderRouter

    init(planner: AIActionPlanner = .shared, router: AIProviderRouter = .shared) {
        self.planner = planner
        self.router = router
    }

    func execute(_ manifest: ExtensionManifest, context: ExtensionContext) async throws -> String {
        try await router.send(
            AIProviderRequest(
                message: planner.prompt(for: manifest, context: context),
                context: context.userContext
            )
        )
    }
}

@MainActor
final class ExtensionRunner {
    static let shared = ExtensionRunner()

    private let manager: LayeredExtensionManager
    private let aiAdapter: ExtensionAIAdapter

    init(
        manager: LayeredExtensionManager = .shared,
        aiAdapter: ExtensionAIAdapter = .shared
    ) {
        self.manager = manager
        self.aiAdapter = aiAdapter
    }

    func execute(_ manifest: ExtensionManifest, context: ExtensionContext) async throws -> String {
        if manifest.requiresAI {
            return try await aiAdapter.execute(manifest, context: context)
        }
        return try await manager.execute(extension: manifest.extensionValue, with: context.selectedFiles)
    }
}

final class ExtensionPermissionManager {
    static let shared = ExtensionPermissionManager()

    private init() {}

    func missingPermissions(for manifest: ExtensionManifest) -> [String] {
        manifest.requiredPermissions.filter { !$0.isEmpty }
    }
}
