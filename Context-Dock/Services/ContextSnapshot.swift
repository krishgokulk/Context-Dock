import Foundation

struct BrowserContextSnapshot: Codable {
    var url: String
    var title: String?
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
    var menuCapabilities: [String]
    var registeredCapabilities: [String]

    var appName: String { frontmostApp }
    var bundleID: String { bundleIdentifier }
    var browserURL: String? { browserContext?.url }
    var browserTitle: String? { browserContext?.title }
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
        let browserContext = context.currentURL.flatMap { url in
            url.isEmpty ? nil : BrowserContextSnapshot(url: url, title: context.windowTitle)
        }

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
