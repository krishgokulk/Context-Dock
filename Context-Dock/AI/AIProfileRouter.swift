import Foundation

@MainActor
enum AIProfileRouter {
    static func provider(for profile: AIProfile, settings: AppSettings) -> AIProvider {
        switch profile.routingStrategy {
        case .selectedProvider:
            return settings.selectedAIProvider
        case .fixedProvider:
            return profile.preferredProvider
        case .cloudFirst:
            return settings.selectedAIProvider == .onDevice
                ? profile.preferredProvider
                : settings.selectedAIProvider
        case .onDeviceFirst:
            return .onDevice
        }
    }

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

    static func shouldCloudFallback(
        error: Error,
        profile: AIProfile,
        settings: AppSettings
    ) -> Bool {
        guard profile.allowCloudFallback else { return false }
        guard settings.selectedAIProvider != .onDevice else { return false }
        let message = String(describing: error).lowercased()
        return message.contains("apple intelligence not available")
            || message.contains("foundationmodels")
            || message.contains("not available")
            || message.contains("unsupported")
    }
}
