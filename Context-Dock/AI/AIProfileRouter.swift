import Foundation

@MainActor
enum AIProfileRouter {
    static func decoratedContextPrompt(
        _ contextPrompt: String,
        profile: AIProfile,
        request: AIRequest
    ) -> String {
        var parts: [String] = []
        parts.append("Active Profile: \(profile.name)")
        parts.append(profile.systemInstruction)
        if let appName = request.frontmostAppName, let bundleId = request.frontmostBundleId {
            parts.append("Frontmost App: \(appName) [\(bundleId)]")
        }
        parts.append("Enabled Tool Scopes:")
        parts.append("- App adapter actions: \(profile.enableAppAdapterActions ? "enabled" : "disabled")")
        parts.append("- CLI tools: \(profile.enableCLITools ? "enabled" : "disabled")")
        parts.append("- Screen/OCR fallback: \(profile.enableScreenOCRFallback ? "enabled" : "disabled")")
        parts.append("\nContext:\n\(contextPrompt)")
        return parts.joined(separator: "\n")
    }

}
