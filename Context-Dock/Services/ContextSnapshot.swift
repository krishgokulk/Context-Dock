import Foundation

struct BrowserContextSnapshot: Codable {
    var url: String
    var title: String?
    var cleanMarkdown: String?
    var headings: [String] = []
    var links: [String] = []
    var images: [String] = []
    var source: String?
    var cacheKey: String?
    var appName: String?
    var bundleIdentifier: String?
    var capturedAt: Date?
    var qualityScore: Double?
    var wordCount: Int?
    var codeBlockCount: Int?
}

struct ContextSnapshot: Codable {
    var frontmostApp: String
    var bundleIdentifier: String
    var windowTitle: String?
    var selectedText: String?
    var selectedTextSource: String?
    var selectedTextCharacterCount: Int
    var selectedFiles: [String]
    var currentDirectory: String?
    var browserContext: BrowserContextSnapshot?
    var connectedBrowserContexts: [BrowserContextSnapshot] = []
    var menuCapabilities: [String]
    var registeredCapabilities: [String]

    var appName: String { frontmostApp }
    var bundleID: String { bundleIdentifier }
    var browserURL: String? { browserContext?.url }
    var browserTitle: String? { browserContext?.title }
    var browserCleanMarkdown: String? { browserContext?.cleanMarkdown }
    var browserHeadings: [String] { browserContext?.headings ?? [] }
}

@MainActor
final class ContextCollector {
    static let shared = ContextCollector()

    private init() {}

    func snapshot() -> ContextSnapshot {
        snapshot(from: AXContextReader.shared.current)
    }

    func snapshot(from context: AXContext) -> ContextSnapshot {
        let selectedText = context.selectedText?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedText = selectedText?.isEmpty == false ? selectedText : nil
        let currentDirectory: String? = {
            if context.bundleId == "com.apple.finder",
                let rawURL = context.currentURL,
                let url = URL(string: rawURL),
                url.isFileURL
            {
                return url.path
            }
            guard let firstPath = context.selectedFilePaths.first else { return nil }
            return URL(fileURLWithPath: firstPath).deletingLastPathComponent().path
        }()
        let webContext = WebContextEngine.shared.context(for: context)
        let connectedWebContexts = WebContextEngine.shared.connectedRunningBrowserContexts(
            current: context
        )
        let browserContext: BrowserContextSnapshot? = {
            guard let url = context.currentURL, !url.isEmpty else { return nil }
            return BrowserContextSnapshot(
                url: webContext?.url ?? url,
                title: webContext?.title ?? context.windowTitle,
                cleanMarkdown: webContext?.markdown,
                headings: webContext?.headings ?? [],
                links: webContext?.links ?? [],
                images: webContext?.images ?? [],
                source: webContext?.source,
                cacheKey: webContext?.cacheKey,
                appName: webContext?.appName ?? context.appName,
                bundleIdentifier: webContext?.bundleIdentifier ?? context.bundleId,
                capturedAt: webContext?.extractedAt,
                qualityScore: webContext?.qualityScore,
                wordCount: webContext?.wordCount,
                codeBlockCount: webContext?.codeBlockCount
            )
        }()

        return ContextSnapshot(
            frontmostApp: context.appName,
            bundleIdentifier: context.bundleId,
            windowTitle: context.windowTitle,
            selectedText: normalizedText,
            selectedTextSource: normalizedText == nil
                ? nil
                : [context.appName, context.focusedElementRole]
                    .compactMap { $0 }
                    .filter { !$0.isEmpty }
                    .joined(separator: " · "),
            selectedTextCharacterCount: normalizedText?.count ?? 0,
            selectedFiles: context.selectedFilePaths,
            currentDirectory: currentDirectory,
            browserContext: browserContext,
            connectedBrowserContexts: connectedWebContexts.map { web in
                BrowserContextSnapshot(
                    url: web.url,
                    title: web.title,
                    cleanMarkdown: web.markdown,
                    headings: web.headings,
                    links: web.links,
                    images: web.images,
                    source: web.source,
                    cacheKey: web.cacheKey,
                    appName: web.appName,
                    bundleIdentifier: web.bundleIdentifier,
                    capturedAt: web.extractedAt,
                    qualityScore: web.qualityScore,
                    wordCount: web.wordCount,
                    codeBlockCount: web.codeBlockCount
                )
            },
            menuCapabilities: context.menuItems
                .filter(\.enabled)
                .prefix(80)
                .map(\.fullPath),
            registeredCapabilities: CapabilityRegistry.shared
                .capabilities(for: context.bundleId)
                .map(\.id)
        )
    }
}
